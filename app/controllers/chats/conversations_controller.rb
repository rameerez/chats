# frozen_string_literal: true

module Chats
  # The inbox (index), the thread (show), starting conversations from host
  # pages (create), and the per-member actions (read/typing/leave/mute).
  class ConversationsController < ApplicationController
    before_action :set_conversation, only: %i[show read typing leave mute unmute]

    # The inbox. Everything is preloaded/batched so rendering N rows costs a
    # constant number of queries (conversations + last messages + participants
    # + one grouped unread-count query — see Conversation.unread_counts_for).
    def index
      @conversations = chats_current_messager.chats
                                             .includes(:last_message, :subject, participants: :messager)
                                             .limit(200)
      @conversations = apply_search(@conversations)
      @unread_counts = Chats::Conversation.unread_counts_for(chats_current_messager, @conversations)
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
        # Opening the thread reads it. (Live appends while the thread stays
        # open are read via the thread controller's POST to #read.)
        @participant&.read!
      end
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

    # Plain SQL LIKE over message bodies and group titles — fast enough for
    # an inbox, zero dependencies, portable across sqlite/postgres/mysql
    # (LOWER + LIKE instead of ILIKE). Bodies encrypted at rest
    # (config.encrypt_messages) won't match, by design. Outgrow it by
    # overriding the inbox view + this scope with pg_search & friends.
    def apply_search(conversations)
      return conversations unless Chats.config.search

      query = params[:q].to_s.strip
      return conversations if query.empty?

      # EXISTS instead of a JOIN + DISTINCT: DISTINCT would fight the inbox's
      # COALESCE(...) ORDER BY on PostgreSQL ("ORDER BY expressions must
      # appear in select list"), and EXISTS doesn't multiply rows to begin with.
      pattern = "%#{Chats::Conversation.sanitize_sql_like(query.downcase)}%"
      conversations.where(
        "EXISTS (SELECT 1 FROM chats_messages cm WHERE cm.conversation_id = chats_conversations.id " \
        "AND cm.deleted_at IS NULL AND LOWER(cm.body) LIKE :q) OR LOWER(chats_conversations.title) LIKE :q",
        q: pattern
      )
    end
  end
end
