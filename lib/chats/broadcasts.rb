# frozen_string_literal: true

require "action_view/record_identifier"

module Chats
  # ALL of the gem's real-time fan-out, in one file — read this and you know
  # the entire live behavior. Three streams exist:
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
  # Everything uses the `_later` variants (rendering happens in background
  # jobs, never inline in the request) except `message_destroyed`, where the
  # record is gone and can't be serialized for a job.
  module Broadcasts
    extend ActionView::RecordIdentifier # dom_id

    MESSAGE_PARTIAL = "chats/messages/message"
    BADGE_PARTIAL = "chats/shared/unread_badge"
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

        fan_out_inboxes(conversation, skip_badge_for: message.sender)
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

      def update_badge_of(messager)
        # REPLACE, not update: the partial renders the whole badge element
        # (its id included) — an `update` would nest it inside the existing
        # element and duplicate the id. Replace keeps it idempotent.
        Turbo::StreamsChannel.broadcast_replace_later_to(
          messager, :chats_badge,
          target: "chats_unread_badge",
          partial: BADGE_PARTIAL,
          # Counted at broadcast-enqueue time: the badge is advisory UI; a
          # count that's seconds stale self-heals on the next event.
          # reorder(nil): COUNT(DISTINCT) + the inbox's COALESCE order would
          # error on PostgreSQL.
          locals: { count: Chats::Conversation.inbox_for(messager).unread_by(messager).reorder(nil).distinct.count }
        )
      end

      private

      # New activity: every active participant's inbox refreshes (including
      # the sender's — their OTHER tabs/devices need the new ordering; the
      # originating tab skips its own refresh via Turbo's request-id dedup),
      # and every participant except the sender gets a fresh unread badge.
      def fan_out_inboxes(conversation, skip_badge_for: nil, badges: true)
        conversation.participants.active.includes(:messager).each do |participant|
          messager = participant.messager
          next if messager.nil?

          refresh_inbox_of(messager)
          update_badge_of(messager) if badges && messager != skip_badge_for
        end
      end
    end
  end
end
