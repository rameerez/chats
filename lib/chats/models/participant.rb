# frozen_string_literal: true

module Chats
  # A messager's seat in a conversation. The +messager+ is polymorphic — any
  # `acts_as_messager` model can sit here (a User, an Organization, a support
  # Agent) — and ALL per-member state lives on this row:
  #
  #   role        "member" | "owner" (group creator/admin)
  #   last_read_at    the read horizon (see "Read state" below)
  #   muted_at        notifications muted (the gem still delivers messages;
  #                   hosts consult `notifiable?` in their notifier hook)
  #   left_at         soft-left groups (history kept, no new messages seen)
  #   last_notified_at  bookkeeping for "notify once per unread burst"
  #                     debounced notifications (see #should_notify?)
  #
  # == Read state: a horizon, not per-message receipts
  #
  # We deliberately store ONE timestamp per participant instead of a
  # per-message receipts table. A message is unread for you iff
  # `created_at > your last_read_at`; you "read" a conversation by advancing
  # the horizon. This gives unread counts, unread badges and "Seen"
  # indicators with zero extra writes per message (a receipts table writes
  # N rows per message per N participants — the classic chat-schema scaling
  # trap), and it's exactly how Basecamp's Campfire models it. If a future
  # use case truly needs per-message receipts (e.g. per-member "read by 7/9"
  # in large groups), they can be added as a new table without breaking this
  # API.
  class Participant < ApplicationRecord
    self.table_name = "chats_participants"

    ROLES = %w[member owner].freeze

    belongs_to :conversation, class_name: "Chats::Conversation", inverse_of: :participants
    belongs_to :messager, polymorphic: true

    scope :active, -> { where(left_at: nil) }
    scope :muted, -> { where.not(muted_at: nil) }

    validates :role, inclusion: { in: ROLES }
    # One-seat-per-messager uniqueness is enforced by the DB unique index
    # ONLY: Conversation#add_participant! relies on `create_or_find_by!`,
    # which needs the index violation (not a pre-insert validation) to make
    # concurrent joins race-safe. Same rationale as Conversation#direct_key.
    validate :group_must_have_room, on: :create

    def owner? = role == "owner"
    def left? = left_at.present?
    def active? = left_at.nil?
    def muted? = muted_at.present?

    def display_name
      Chats.display_name_for(messager)
    end

    # --- Read state -----------------------------------------------------------

    # Messages this participant hasn't seen: anything newer than their read
    # horizon, excluding their own messages and deleted tombstones. The
    # explicit IS NULL leg keeps senderless SYSTEM messages counted — SQL's
    # three-valued logic would otherwise drop them (NOT(NULL = …) is NULL,
    # not TRUE). Same fix as Conversation.unread_by.
    def unread_messages
      conversation.messages.visible
                  .where("chats_messages.created_at > ?", last_read_at || Conversation::EPOCH)
                  .where(
                    "chats_messages.sender_type IS NULL OR " \
                    "NOT (chats_messages.sender_type = ? AND chats_messages.sender_id = ?)",
                    messager_type, messager_id.to_s
                  )
    end

    def unread_count
      unread_messages.count
    end

    def unread?
      unread_messages.exists?
    end

    # Advance the read horizon to now and tell everyone who cares:
    #   - the conversation stream gets a fresh read-state payload (powers the
    #     "Seen" indicator on the other side, when read receipts are on)
    #   - this messager's OWN inbox + badge refresh (their other devices/tabs
    #     should drop the unread highlight too)
    #   - the HOST gets a `:conversation_read` notifier event — but only when
    #     the horizon actually swallowed unread content. Hosts use it to keep
    #     external notification surfaces truthful (e.g. mark this chat's rows
    #     read in a notification center the moment the thread is read, so a
    #     bell badge doesn't keep advertising messages the user has already
    #     seen). Same notify hook as :message_created; error-isolated.
    def read!(at: Time.current)
      return self if last_read_at && last_read_at >= at

      had_unread = unread?
      update!(last_read_at: at)
      broadcast_read_state if Chats.config.read_receipts
      Chats::Broadcasts.refresh_inbox_of(messager)
      Chats::Broadcasts.update_badge_of(messager)
      Chats.notify(:conversation_read, conversation: conversation, participant: self) if had_unread
      self
    end

    def mute! = update!(muted_at: Time.current)
    def unmute! = update!(muted_at: nil)

    def leave!
      update!(left_at: Time.current)
    end

    # --- Notification etiquette (for host notifier hooks) ----------------------

    # Should the host notify this participant about +message+? Encapsulates
    # the etiquette every messaging product implements so each host doesn't
    # re-derive it: don't notify yourself, the muted, the departed — and for
    # debounced email digests, don't notify twice for the same unread burst.
    def notifiable_for?(message)
      return false if left? || muted?
      return false if message.sender == messager

      true
    end

    # For "email me only once until I come back" digests: true when there's
    # something unread AND we haven't already notified since the last read.
    # Pair with `mark_notified!` after actually sending.
    def should_notify?
      return false unless unread?

      last_notified_at.nil? || last_notified_at < (last_read_at || Conversation::EPOCH)
    end

    def mark_notified!(at: Time.current)
      update!(last_notified_at: at)
    end

    private

    def group_must_have_room
      return if conversation.nil? || conversation.direct?

      max = Chats.config.max_group_size
      return unless max && conversation.participants.active.count >= max

      errors.add(:base, :group_full, count: max)
    end

    def broadcast_read_state
      Chats::Broadcasts.read_state(conversation)
    end
  end
end
