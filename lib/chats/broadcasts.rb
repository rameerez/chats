# frozen_string_literal: true

require "action_view/record_identifier"

module Chats
  # ALL of the gem's real-time fan-out, in one file — read this and you know
  # the entire live behavior. Four streams exist:
  #
  #   1. The CONVERSATION stream (`turbo_stream_from @conversation` on the
  #      thread page): surgical message append/replace/remove, the read-state
  #      payload, and the typing custom action. One render per event, shared
  #      by every subscriber — bubbles are rendered VIEWER-AGNOSTIC and the
  #      `chats--thread` Stimulus controller aligns own-vs-other client-side
  #      (comparing each bubble's sender key against its own `me` value),
  #      which is what makes a single broadcast render possible at all.
  #   2. The per-messager INBOX stream (`[messager, :chats_inbox]`, subscribed
  #      only on the inbox page): we broadcast Turbo 8 page REFRESHES instead
  #      of surgically patching rows. An inbox row is intensely per-viewer
  #      (unread badge, bold state, ordering), so patching it from a shared
  #      broadcast would force per-viewer renders of per-viewer partials;
  #      a refresh makes each client re-request the page and get a correct,
  #      personalized render with morphing + scroll preservation for free.
  #      Turbo debounces refreshes per stream and tags them with the
  #      originating request id so the tab that caused the change skips its
  #      own refresh. https://turbo.hotwired.dev/handbook/streams
  #
  #   3. The per-messager BADGE stream (`[messager, :chats_badge]`,
  #      subscribable from ANY page via the `chats_unread_badge` helper —
  #      e.g. a bottom-nav dock): a tiny `update` of the badge element.
  #      Deliberately separate from the inbox stream — if badges rode on it,
  #      every page embedding a badge would full-refresh on every message.
  #
  #   4. The per-messager DOCK stream (`[messager, :chats_dock]`, subscribed
  #      by the messaging dock — `chats_dock`). One render per participant
  #      per event (chats/dock/_update), carrying up to two things:
  #        * the dock's BADGES, with the same count as stream 3, whenever the
  #          badge moves (a message for them, a read of theirs);
  #        * the SIGNAL (chats/dock/_signal), replaced so the dock's
  #          controller sees it connect: reload the recent list, and — for a
  #          new message the participant should hear about — which
  #          conversation it was, from whom, how much is unread there, and
  #          that its window may pop open. Senders and edits/deletes get the
  #          signal too (their lists reorder), never the pop-up.
  #      The hint names a conversation only to a participant who can SEE it
  #      (`messager.chats`: blocks and `inbox_scope` applied) — the dock's
  #      own list and window endpoints refuse anything else, and the stream
  #      must not tell them what those hide. No polling, no Action Cable
  #      channel of our own.
  #
  # Everything uses the `_later` variants (rendering happens in background
  # jobs, never inline in the request) except `message_destroyed`, where the
  # record is gone and can't be serialized for a job.
  module Broadcasts
    extend ActionView::RecordIdentifier # dom_id

    MESSAGE_PARTIAL = "chats/messages/message"
    BADGE_PARTIAL = "chats/shared/unread_badge"
    DOCK_UPDATE_PARTIAL = "chats/dock/update"
    READ_STATE_PARTIAL = "chats/conversations/read_state"

    class << self
      def message_created(message)
        conversation = message.conversation

        Turbo::StreamsChannel.broadcast_append_later_to(
          conversation,
          target: dom_id(conversation, :messages),
          partial: MESSAGE_PARTIAL,
          locals: { message: message }
        )

        fan_out_inboxes(conversation, skip_badge_for: message.sender, message: message)
      end

      def message_updated(message)
        Turbo::StreamsChannel.broadcast_replace_later_to(
          message.conversation,
          target: dom_id(message),
          partial: MESSAGE_PARTIAL,
          locals: { message: message }
        )

        # Edits/deletes change the inbox preview when they touch the latest
        # message; a refresh is debounced and cheap, so just fan out.
        fan_out_inboxes(message.conversation, badges: false)
      end

      def message_destroyed(message)
        # Hard delete: the row is gone — broadcast synchronously (nothing to
        # serialize into a job) and let inboxes re-render.
        Turbo::StreamsChannel.broadcast_remove_to(
          message.conversation,
          target: dom_id(message)
        )

        fan_out_inboxes(message.conversation, badges: false)
      end

      # The viewer-agnostic read-state payload (a hidden element carrying
      # every participant's read horizon as JSON). The thread controller
      # turns it into a per-viewer "Seen" indicator client-side.
      def read_state(conversation)
        Turbo::StreamsChannel.broadcast_replace_later_to(
          conversation,
          target: dom_id(conversation, :read_state),
          partial: READ_STATE_PARTIAL,
          locals: { conversation: conversation }
        )
      end

      # Ephemeral "X is typing…" — a Turbo Stream CUSTOM ACTION (registered
      # in chats/thread_controller.js as Turbo.StreamActions.chats_typing),
      # carrying the typist in attributes. Nothing is persisted; if nobody's
      # subscribed it evaporates, which is exactly right for presence-ish
      # signals. No `_later`: typing is only meaningful NOW.
      def typing(conversation, messager)
        Turbo::StreamsChannel.broadcast_action_to(
          conversation,
          action: :chats_typing,
          target: dom_id(conversation, :typing),
          attributes: {
            "data-name" => Chats.display_name_for(messager),
            "data-key" => Chats.messager_key(messager)
          }
        )
      end

      def refresh_inbox_of(messager)
        Turbo::StreamsChannel.broadcast_refresh_later_to(messager, :chats_inbox)
      end

      # The unread badges of +messager+: the nav badge (stream 3) and the
      # dock's (stream 4), with the signal that tells the dock what changed.
      # +conversation+ and +message+ say what happened (both nil for a
      # read); +participant+ is the messager's seat there.
      def update_badge_of(messager, conversation: nil, message: nil, participant: nil)
        # Counted at broadcast-enqueue time: the badge is advisory UI; a
        # count that's seconds stale self-heals on the next event. The SAME
        # count the page renders (`chats_unread_badge`), so what the inbox
        # scope hides never lights the badge. Counted once for both.
        count = messager.unread_chats_count

        # REPLACE, not update: the partial renders the whole badge element
        # (its id included) — an `update` would nest it inside the existing
        # element and duplicate the id. Replace keeps it idempotent.
        Turbo::StreamsChannel.broadcast_replace_later_to(
          messager, :chats_badge,
          target: "chats_unread_badge",
          partial: BADGE_PARTIAL,
          locals: { count: count }
        )

        update_dock_of(messager, count: count, conversation: conversation, message: message, participant: participant)
      end

      # The dock's update (stream 4): the badges when +count+ is given, and
      # the signal. A conversation the messager cannot see is never named:
      # its badge count is still truthful, the signal is simply not sent.
      def update_dock_of(messager, count: nil, conversation: nil, message: nil, participant: nil)
        signal = dock_signal(messager, conversation, message, participant)
        return if count.nil? && signal.nil?

        Turbo::StreamsChannel.broadcast_render_later_to(
          messager, :chats_dock,
          partial: DOCK_UPDATE_PARTIAL,
          locals: { count: count, signal: signal }
        )
      end

      private

      # New activity: every active participant's inbox refreshes (including
      # the sender's — their OTHER tabs/devices need the new ordering; the
      # originating tab skips its own refresh via Turbo's request-id dedup),
      # and every participant except the sender gets a fresh unread badge.
      # Everyone else — the sender, and every seat on an edit or a delete —
      # gets the dock's list refresh alone.
      def fan_out_inboxes(conversation, skip_badge_for: nil, badges: true, message: nil)
        conversation.participants.active.includes(:messager).each do |participant|
          messager = participant.messager
          next if messager.nil?

          refresh_inbox_of(messager)
          if badges && messager != skip_badge_for
            update_badge_of(messager, conversation: conversation, message: message, participant: participant)
          else
            update_dock_of(messager, conversation: conversation)
          end
        end
      end

      # What the dock is told, or nil for nothing at all. A read (no
      # conversation) only reloads the list. A conversation the messager
      # can't see (blocked, scoped out) is never named. A new message the
      # participant would be notified about (Participant#notifiable_for?:
      # not theirs, not muted, not a headless seat) may pop its window and
      # be announced, with who it is from and how much is unread there.
      def dock_signal(messager, conversation, message, participant)
        return {} if conversation.nil?
        return nil unless messager.chats.exists?(conversation.id)

        signal = { conversation_id: conversation.id }
        return signal unless message && participant&.notifiable_for?(message)

        signal.merge(
          notify: true,
          sender_name: message.sender ? Chats.display_name_for(message.sender) : conversation.title_for(messager),
          unread_count: participant.unread_count
        )
      end
    end
  end
end
