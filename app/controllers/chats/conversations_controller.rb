# frozen_string_literal: true

module Chats
  # The inbox (index), the thread (show), starting conversations from host
  # pages (create), and the per-member actions (read/typing/leave/mute).
  class ConversationsController < ApplicationController
    before_action :set_conversation, only: %i[show read typing leave mute unmute refresh]
    helper_method :chats_counterpart

    # The inbox. Everything is preloaded/batched so rendering N rows costs a
    # constant number of queries (conversations + last messages + participants
    # + one grouped unread-count query — see Conversation.unread_counts_for).
    # Rows are Conversation | InboxGroup: stacking, search and the `?with=`
    # filter all live in Chats::Inbox, so this action stays three lines.
    def index
      @inbox = Chats::Inbox.for(chats_current_messager, query: params[:q], with: inbox_filter)
      @rows = @inbox.rows
      @unread_counts = @inbox.unread_counts
      # Back-compat for inboxes ejected under 0.1.x, which loop over
      # @conversations: they keep rendering the flat list (no stacking, i.e.
      # exactly what they rendered before). Re-eject or delete your copy to
      # get the stacked rows.
      @conversations = @inbox.conversations
    end

    # The thread. Renders the LATEST page of messages; older pages stream in
    # through a lazy Turbo Frame chain (keyset-paginated — see
    # Message.before_message and _messages_page.html.erb).
    def show
      @participant = @conversation.participant_for(chats_current_messager)

      anchor = params[:before].present? ? @conversation.messages.find_by(id: params[:before]) : nil
      scope = @conversation.messages.includes(:sender, :reactions)
      scope = scope.with_attached_files if scope.respond_to?(:with_attached_files)
      scope = scope.before_message(anchor) if anchor

      # Fetch newest-first + reverse so "the last N messages" render in
      # chronological order. One extra record peeks whether older pages exist.
      page = scope.recent_first.limit(Chats.config.messages_per_page + 1).to_a
      @more_messages = page.size > Chats.config.messages_per_page
      @messages = page.first(Chats.config.messages_per_page).reverse

      if anchor
        # Older-page request from the pagination frame: render just the page.
        render partial: "chats/conversations/messages_page",
               locals: { conversation: @conversation, messages: @messages, more: @more_messages }
      else
        # The «new messages» divider: computed BEFORE read! advances the
        # horizon (after it, nothing is unread anymore). Anchored to the
        # oldest unread bubble on the rendered page; when the backlog runs
        # deeper than one page it pins to the top of the page instead —
        # the scroll-up frame chain holds the rest.
        if @participant&.unread?
          @first_unread_id = @participant.unread_messages.where(id: @messages.map(&:id)).oldest_first.pick(:id) ||
                             @messages.first&.id
        end

        # Opening the thread reads it. (Live appends while the thread stays
        # open are read via the thread controller's POST to #read.)
        @participant&.read!
      end
    end

    # Stale-thread catch-up: appends messages created — and replaces ones
    # edited/tombstoned — since the newest `updated_at` the client has
    # rendered (`?since=` in ms). The thread controller calls this when the
    # tab wakes from a long sleep or its Turbo Stream subscription
    # reconnects, i.e. whenever broadcasts may have been missed. Mobile
    # WebViews suspend WebSockets aggressively, so without this a
    # backgrounded chat silently loses messages until a manual reload.
    # Pattern from Basecamp's Campfire (Rooms::RefreshesController):
    # https://github.com/basecamp/once-campfire
    def refresh
      head :no_content and return if params[:since].blank?

      since = Time.zone.at(0, params[:since].to_i, :millisecond)
      scope = @conversation.messages.includes(:sender, :reactions)
      scope = scope.with_attached_files if scope.respond_to?(:with_attached_files)

      @new_messages = scope.created_since(since).oldest_first.limit(Chats.config.messages_per_page + 1).to_a

      # A backlog deeper than one page would mean splicing an arbitrary
      # amount of history through surgical appends; a Turbo 8 page refresh
      # (morph + scroll preservation) re-renders the latest page + frame
      # chain correctly instead.
      #
      # `render turbo_stream:`, NOT `render html: … content_type:` — the
      # latter forces text/html and silently ignores the content type, so the
      # body says <turbo-stream> while the response says it isn't one.
      #
      # `request_id: nil` on purpose: Turbo skips a refresh tagged with a
      # request id it recognizes as its own, and this response is the answer
      # to the client's OWN catch-up fetch — the one client that must not
      # skip it.
      if @new_messages.size > Chats.config.messages_per_page
        render turbo_stream: turbo_stream.refresh(request_id: nil)
        return
      end

      @updated_messages = scope.updated_since(since)
      render "chats/conversations/refresh", formats: :turbo_stream
    end

    # Start (or resume) a direct conversation from a host page. The
    # recipient/subject arrive as SIGNED GlobalIDs minted by the
    # `chat_button_to` helper — unforgeable and purpose-scoped, so raw
    # polymorphic params never reach `GlobalID::Locator`. Policy and block
    # checks still run inside `chat_with` (defense in depth).
    def create
      recipient = locate_signed!(params.require(:recipient_sgid), purpose: :chats_recipient)
      raise ActiveRecord::RecordNotFound unless Chats.messager_class?(recipient.class)

      subject = params[:subject_sgid].presence &&
                locate_signed!(params[:subject_sgid], purpose: :chats_subject)

      conversation = chats_current_messager.chat_with(recipient, about: subject)
      redirect_to conversation_path(conversation)
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
