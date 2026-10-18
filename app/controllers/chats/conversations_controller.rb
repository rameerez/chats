# frozen_string_literal: true

module Chats
  # The inbox (index), the thread (show), starting conversations from host
  # pages (create), the messaging dock's recent list (dock), and the
  # per-member actions (read/typing/leave/mute).
  class ConversationsController < ApplicationController
    # The most rows the dock's recent list shows, whatever `recent:` asks.
    DOCK_RECENT_LIMIT = 50
    # How far before its list of what exists a catch-up stops naming
    # deletions (see #present_messages).
    PRESENT_MARGIN = 10.seconds

    before_action :set_conversation, only: %i[show read typing leave mute unmute refresh]
    helper_method :chats_counterpart

    # The inbox. Everything is preloaded/batched so rendering N rows costs a
    # constant number of queries (conversations + last messages + participants
    # + one grouped unread-count query — see Conversation.unread_counts_for).
    # Rows are Conversation | InboxGroup: stacking, search and the `?with=`
    # filter all live in Chats::Inbox, so this action stays three lines.
    def index
      # The dock's search form posts here, so that without JavaScript it
      # lands on the full inbox's results; from the dock's frame, the answer
      # is the dock's own list.
      return dock if turbo_frame_request_id == "chats_dock_list"

      @inbox = Chats::Inbox.for(chats_current_messager, query: params[:q], with: inbox_filter)
      @rows = @inbox.rows
      @unread_counts = @inbox.unread_counts
      # Back-compat for inboxes ejected under 0.1.x, which loop over
      # @conversations: they keep rendering the flat list (no stacking, i.e.
      # exactly what they rendered before). Re-eject or delete your copy to
      # get the stacked rows.
      @conversations = @inbox.conversations
    end

    # The messaging dock's recent list (`chats_dock`): the first rows of the
    # viewer's inbox — the same rows, stacks and search, through the same
    # Chats::Inbox — rendered into the dock's `chats_dock_list` frame. The
    # frame asks for `?recent=` rows (the helper's `recent:` option).
    def dock
      @inbox = Chats::Inbox.for(chats_current_messager, query: params[:q], limit: dock_recent)
      @rows = @inbox.rows
      @unread_counts = @inbox.unread_counts

      render :dock, layout: false
    end

    # The viewer's unread badges as a Turbo Stream: the nav badge
    # (`chats_unread_badge`) and every badge in the dock, replaced with the
    # same count the badge streams send. What a page asks for when it may
    # have missed them (chats/recovery: a reconnect, a return to a hidden
    # page, a restored page). Reads nothing, writes nothing.
    def badge
      render :badge, formats: :turbo_stream, locals: { count: chats_current_messager.unread_chats_count }
    end

    # The thread. Renders the LATEST page of messages; older pages stream in
    # through a lazy Turbo Frame chain (keyset-paginated — see
    # Message.before_message and _messages_page.html.erb).
    #
    # `?window=1` from a Turbo frame is the same thread as a floating dock
    # window: the window template (its compact header around the same
    # thread body), no layout.
    def show
      @participant = @conversation.participant_for(chats_current_messager)

      anchor = params[:before].present? ? @conversation.messages.find_by(id: params[:before]) : nil
      scope = rendered_messages
      scope = scope.before_message(anchor) if anchor
      @messages, @more_messages = latest_page_of(scope)

      if anchor
        # Older-page request from the pagination frame: render just the page.
        render partial: "chats/conversations/messages_page",
               locals: { conversation: @conversation, messages: @messages, more: @more_messages }
      else
        # The «new messages» divider: computed BEFORE read! advances the
        # horizon (after it, nothing is unread anymore).
        @first_unread_id = first_unread_id(@participant, @messages)

        if dock_window?
          # A window does NOT read on render: it may be restored minimized
          # after a reload, and a header nobody has looked at must not
          # swallow the unread badge. The thread controller posts #read once
          # the window is actually on screen (`read-pending`).
          render :window, layout: false
        elsif !prefetch?
          # Opening the thread reads it. (Live appends while the thread
          # stays open are read via the thread controller's POST to #read.)
          @participant&.read!
        end
      end
    end

    # Stale-thread catch-up (`?since=` ms, the newest `updated_at` the client
    # has rendered; `from=` ms, its oldest bubble's `created_at`). The thread
    # controller calls this whenever chats/recovery says the stream may have
    # missed something: a reconnect, a return after 10 seconds hidden, the
    # network back, a restored page. Mobile WebViews suspend WebSockets
    # aggressively, so without this a backgrounded chat silently loses
    # messages until a manual reload. Pattern from Basecamp's Campfire
    # (Rooms::RefreshesController): https://github.com/basecamp/once-campfire
    #
    # The answer touches the history only, never the composer or its draft:
    # messages created since are appended, ones changed since (edits,
    # tombstones, reactions) replaced, the read state replaced, and — under
    # `deletion: :hard` — the bubbles that no longer exist removed. Reads
    # nothing: catching up is not reading (the controller posts #read once
    # the viewer can see the new messages).
    #
    # `render turbo_stream:`, NOT `render html: … content_type:` — the
    # latter forces text/html and silently ignores the content type, so the
    # body says <turbo-stream> while the response says it isn't one.
    def refresh
      head :no_content and return if params[:since].blank?

      since = time_from_ms(params[:since])
      scope = rendered_messages

      @new_messages = scope.created_since(since).oldest_first.limit(Chats.config.messages_per_page + 1).to_a

      # More than a page behind: splicing an arbitrary backlog through
      # surgical appends would leave a hole in the scroll-up chain. Re-render
      # the history at the latest page instead, exactly as opening the thread
      # does, frame chain included. A thread view ejected before the history
      # had its id (no `history=1`) gets the page refresh it always got;
      # `request_id: nil`, because Turbo skips a refresh tagged with a request
      # of its own, and this one answers the client's own catch-up.
      if @new_messages.size > Chats.config.messages_per_page
        return render_latest_history if params[:history].present?

        return render turbo_stream: turbo_stream.refresh(request_id: nil)
      end

      @updated_messages = scope.updated_since(since)
      @present = present_messages if Chats.config.deletion == :hard && params[:from].present?
      render "chats/conversations/refresh", formats: :turbo_stream
    end

    # Start (or resume) a direct conversation from a host page. The
    # recipient/subject arrive as SIGNED GlobalIDs minted by the
    # `chat_button_to` helper — unforgeable and purpose-scoped, so raw
    # polymorphic params never reach `GlobalID::Locator`. Policy and block
    # checks still run inside `chat_with` (defense in depth).
    #
    # `dock=1` (`chat_button_to …, dock: true`) answers a Turbo Stream that
    # appends the conversation's floating window to the dock instead of
    # navigating. Same id, so a window already open is replaced, not
    # doubled; on a page without the dock the stream has no target and does
    # nothing. Without Turbo it is the plain redirect.
    def create
      recipient = locate_signed!(params.require(:recipient_sgid), purpose: :chats_recipient)
      raise ActiveRecord::RecordNotFound unless Chats.messager_class?(recipient.class)

      subject = params[:subject_sgid].presence &&
                locate_signed!(params[:subject_sgid], purpose: :chats_subject)

      conversation = chats_current_messager.chat_with(recipient, about: subject)

      if params[:dock].present? && request.format.turbo_stream?
        render turbo_stream: turbo_stream.append(
          "chats_dock_windows",
          partial: "chats/dock/window",
          locals: { conversation: conversation, focus: true }
        )
      else
        redirect_to conversation_path(conversation)
      end
    rescue Chats::BlockedError
      # Fallback is the INBOX (engine root) — inside the engine, `root_path`
      # already resolves there, never to the host root.
      redirect_back fallback_location: conversations_path, alert: t("chats.flashes.blocked")
    rescue Chats::NotAllowedError
      redirect_back fallback_location: conversations_path, alert: t("chats.flashes.not_allowed")
    end

    # Advance the viewer's read horizon. Called by the thread Stimulus
    # controller (debounced) when new messages arrive while the thread is
    # visible. Side effects (read-state broadcast, badge refresh) live in
    # Participant#read!.
    def read
      @conversation.participant_for(chats_current_messager)&.read!
      head :no_content
    end

    # Ephemeral typing ping (client throttles to ~1 every 3s while typing).
    # Nothing is persisted; see Chats::Broadcasts.typing.
    def typing
      Chats::Broadcasts.typing(@conversation, chats_current_messager) if Chats.config.typing_indicators
      head :no_content
    end

    def leave
      # Direct threads can't be left (mute or block instead) — leaving would
      # strand a 1:1 thread in a weird half-state.
      raise ActiveRecord::RecordNotFound if @conversation.direct?

      title = @conversation.title_for(chats_current_messager)
      @conversation.participant_for(chats_current_messager)&.leave!
      redirect_to conversations_path, notice: t("chats.flashes.left", title: title)
    end

    def mute
      @conversation.participant_for(chats_current_messager)&.mute!
      redirect_to conversation_path(@conversation), notice: t("chats.flashes.muted")
    end

    def unmute
      @conversation.participant_for(chats_current_messager)&.unmute!
      redirect_to conversation_path(@conversation), notice: t("chats.flashes.unmuted")
    end

    private

    def set_conversation
      @conversation = find_conversation
    end

    def time_from_ms(value)
      Time.zone.at(0, value.to_i, :millisecond)
    end

    # The conversation's messages with everything a bubble renders.
    def rendered_messages
      scope = @conversation.messages.includes(:sender, :reactions)
      scope.respond_to?(:with_attached_files) ? scope.with_attached_files : scope
    end

    # The newest page of +scope+, oldest first, and whether older pages
    # exist. Fetched newest-first and reversed; one extra record peeks.
    def latest_page_of(scope)
      page = scope.recent_first.limit(Chats.config.messages_per_page + 1).to_a
      [page.first(Chats.config.messages_per_page).reverse, page.size > Chats.config.messages_per_page]
    end

    # Where the «new messages» line goes: the oldest unread bubble on the
    # page; when the backlog runs deeper than one page, the top of the page
    # (the scroll-up frame chain holds the rest). Nil when nothing is unread.
    def first_unread_id(participant, messages)
      return unless participant&.unread?

      participant.unread_messages.where(id: messages.map(&:id)).oldest_first.pick(:id) || messages.first&.id
    end

    # The thread's history at its latest page, for a catch-up more than a
    # page behind: the same messages, frame chain and «new messages» line
    # the thread opens with (chats/conversations/_history).
    def render_latest_history
      messages, more = latest_page_of(rendered_messages)
      participant = @conversation.participant_for(chats_current_messager)

      render turbo_stream: turbo_stream.update(
        helpers.dom_id(@conversation, :history),
        partial: "chats/conversations/history",
        locals: { conversation: @conversation, messages: messages, more: more,
                  first_unread_id: first_unread_id(participant, messages),
                  counterpart: chats_counterpart, window: false }
      )
    end

    # Under `deletion: :hard` a deleted message leaves nothing to replace:
    # the catch-up names every message from the client's oldest bubble on
    # that still exists, and the client removes the bubbles not named.
    # `until` sits PRESENT_MARGIN before the list is read: a message whose
    # insert had not committed yet is missing from the list but may already
    # have reached the client live — it must not be taken for a deleted one.
    def present_messages
      until_ms = ((Time.current - PRESENT_MARGIN).to_f * 1000).floor
      ids = @conversation.messages.where(created_at: time_from_ms(params[:from])..).pluck(:id)

      { ids: ids.map { |id| helpers.dom_id(Chats::Message.new(id: id)) }, until: until_ms }
    end

    # A dock window asks for its thread from inside its own turbo frame. A
    # plain visit to the same URL (no frame) still gets the page.
    def dock_window?
      params[:window].present? && turbo_frame_request?
    end

    # Turbo 8 prefetches a link when the pointer rests on it, and a pointer
    # resting on an inbox row is not somebody reading the thread. The visit
    # itself, if it happens, reads.
    # https://turbo.hotwired.dev/handbook/drive#prefetching-links-on-hover
    def prefetch?
      request.headers["X-Sec-Purpose"] == "prefetch" || request.headers["Sec-Purpose"]&.include?("prefetch")
    end

    def dock_recent
      Integer(params[:recent], exception: false)&.clamp(1, DOCK_RECENT_LIMIT) || 10
    end

    def locate_signed!(sgid, purpose:)
      GlobalID::Locator.locate_signed(sgid, for: purpose) || raise(ActiveRecord::RecordNotFound)
    end

    # `?with=<signed gid>` — the inbox filtered to one counterpart (a stack's
    # contents). Signed and purpose-scoped like every other polymorphic
    # param the engine accepts; a tampered one is a plain 404.
    def inbox_filter
      return nil if params[:with].blank?

      messager = locate_signed!(params[:with], purpose: :chats_inbox_with)
      raise ActiveRecord::RecordNotFound unless Chats.messager_class?(messager.class)

      messager
    end

    # The other party of a direct thread (nil for groups) — the thread header
    # names them, links to their profile, and decides whether to offer the
    # "see all" link back to their stack. LAZY and memoized: a group thread
    # never pays for it, and a direct one pays once no matter how many of
    # those three things the rendered view asks for.
    def chats_counterpart
      return @chats_counterpart if defined?(@chats_counterpart)

      @chats_counterpart = @conversation&.counterpart_for(chats_current_messager)
    end
  end
end
