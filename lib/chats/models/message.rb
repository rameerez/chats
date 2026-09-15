# frozen_string_literal: true

module Chats
  # A message in a conversation. Two kinds:
  #
  #   "text"    a human message from a +sender+ (any acts_as_messager model)
  #   "system"  posted by the HOST APP via Conversation#post_system_message!
  #             ("Your ride was cancelled") — no sender, centered rendering
  #
  # == Soft deletion ("delete for everyone")
  #
  # With `config.deletion = :soft` (the default), deleting clears the body,
  # purges attachments and stamps +deleted_at+ — the row stays as a tombstone
  # ("Message deleted") exactly like WhatsApp/Telegram, which keeps thread
  # continuity AND leaves an auditable trail for Trust & Safety. Note that
  # moderation evidence is still safe: the moderate gem snapshots reported
  # content AT REPORT TIME, so removing the body later never destroys the
  # evidence a moderator needs.
  #
  # == Real-time
  #
  # All Turbo Stream fan-out lives in Chats::Broadcasts (one place to read
  # the whole live behavior). Broadcasts run in `after_*_commit` callbacks —
  # never inside the transaction — and use the `_later` job variants so
  # rendering never blocks the request.
  class Message < ApplicationRecord
    self.table_name = "chats_messages"

    KINDS = %w[text system].freeze

    belongs_to :conversation,
               class_name: "Chats::Conversation",
               inverse_of: :messages,
               counter_cache: :messages_count
    belongs_to :sender, polymorphic: true, optional: true
    # The person (or bot) who WROTE this on the sender's behalf — an agent
    # answering from a shared support-desk seat. The sender stays the
    # conversation identity ("Soporte CarHey"); the author signs the bubble
    # ("— Lucía G."). Optional, and nil for every ordinary message.
    belongs_to :author, polymorphic: true, optional: true
    belongs_to :reply_to, class_name: "Chats::Message", optional: true

    has_many :reactions,
             class_name: "Chats::Reaction",
             inverse_of: :message,
             foreign_key: :message_id,
             dependent: :destroy

    # Attachments ride on ActiveStorage when the host has it installed.
    # What's *allowed* (none / images only / anything) is enforced by
    # validations reading `Chats.config.attachments` — see below.
    has_many_attached :files if defined?(ActiveStorage)

    # Ruby-side default so metadata is always a Hash even on MySQL, where the
    # migration can't give JSON columns a DB default (MySQL 8+ limitation —
    # see the migration template's json_column_default).
    attribute :metadata, default: -> { {} }

    scope :recent_first, -> { order(created_at: :desc, id: :desc) }
    scope :oldest_first, -> { order(created_at: :asc, id: :asc) }
    scope :visible, -> { where(deleted_at: nil) }

    # Keyset (cursor) pagination for infinite scroll-up. OFFSET pagination
    # drifts when new messages arrive mid-scroll; anchoring on the oldest
    # loaded message can't skip or duplicate. `(created_at, id)` because
    # created_at alone isn't unique.
    scope :before_message, lambda { |message|
      where(
        "(chats_messages.created_at < :at) OR (chats_messages.created_at = :at AND chats_messages.id < :id)",
        at: message.created_at, id: message.id
      )
    }

    # Catch-up scopes for ConversationsController#refresh (the stale-thread
    # recovery path — see the thread controller's refresh trigger). `since`
    # is the newest `updated_at` the client has rendered:
    #   created_since — messages that arrived while the tab was asleep
    #                   (appended);
    #   updated_since — messages the client HAS rendered that changed since
    #                   (edits, soft-delete tombstones — replaced in place).
    # `updated_since` excludes fresh rows so nothing renders twice — a Turbo
    # append of an existing dom_id would otherwise also MOVE that bubble to
    # the end (Turbo removes-then-appends on id collision).
    # Pattern from Basecamp's Campfire (Rooms::RefreshesController):
    # https://github.com/basecamp/once-campfire
    scope :created_since, ->(time) { where("chats_messages.created_at > ?", time) }
    scope :updated_since, lambda { |time|
      where("chats_messages.updated_at > ?", time).where("chats_messages.created_at <= ?", time)
    }

    validates :kind, inclusion: { in: KINDS }
    validates :body, presence: true, if: :system?
    validate :sender_required_for_text_messages, on: :create
    validate :body_or_files_required
    validate :body_must_fit_length_limit
    validate :sender_must_be_active_participant, on: :create
    validate :sender_must_not_be_blocked, on: :create
    validate :conversation_must_not_be_locked, on: :create
    validate :files_must_be_allowed

    after_create :register_on_conversation
    after_create_commit :broadcast_created
    after_create_commit :notify_host
    after_update_commit :broadcast_updated
    after_destroy_commit :broadcast_destroyed
    after_destroy :heal_conversation_pointers

    def system? = kind == "system"
    def text? = kind == "text"
    def deleted? = deleted_at.present?
    def edited? = edited_at.present?

    def sender_key
      sender && Chats.messager_key(sender)
    end

    def sent_by?(messager)
      sender.present? && sender == messager
    end

    # Written by someone OTHER than the seat it was sent from — the case a
    # signature exists for. A message an author sent from their own seat is
    # not "signed"; it's just theirs.
    def signed?
      author.present? && author != sender
    end

    def authored_by?(messager)
      author.present? && author == messager
    end

    # The body as the UI should show it (tombstones render a localized
    # "Message deleted" placeholder straight from the view, not from here —
    # this just guards against showing stale bodies by accident).
    def visible_body
      deleted? ? nil : body
    end

    # Whether +messager+ has read this message, derived from their read
    # horizon (see Chats::Participant for why there's no receipts table).
    def read_by?(messager)
      participant = conversation.participant_for(messager)
      participant&.last_read_at.present? && participant.last_read_at >= created_at
    end

    # Edit the body (sender-only — controllers enforce who; the model
    # enforces *that* editing is enabled). Stamps +edited_at+ so the UI can
    # show "edited", and broadcasts the replacement bubble.
    def edit!(new_body)
      raise Chats::NotAllowedError, "editing is disabled" unless Chats.config.editing
      raise Chats::NotAllowedError, "can't edit a deleted message" if deleted?

      refuse_when_locked!
      update!(body: new_body, edited_at: Time.current)
    end

    # Delete according to `config.deletion` (see class comment). Returns
    # false when deletion is disabled.
    # `enforce_lock: false` is for MODERATION only (see
    # #remove_reported_field!): a product lock must never shield reported
    # content from removal.
    def soft_delete!(enforce_lock: true)
      refuse_when_locked! if enforce_lock

      case Chats.config.deletion
      when :soft
        transaction do
          files.purge_later if respond_to?(:files) && files.attached?
          update!(body: nil, deleted_at: Time.current)
        end
        true
      when :hard
        destroy!
        true
      else
        false
      end
    end

    def attachments?
      respond_to?(:files) && files.attached?
    end

    # Every WRITE to an existing message goes through here, for the same
    # reason `create` validates the lock: a closed conversation is closed for
    # editing and deleting too, not just for new messages. System messages
    # stay exempt — the app owns them.
    def refuse_when_locked! # :nodoc:
      return if system? || conversation.nil? || !conversation.locked?

      raise Chats::LockedError.new(conversation: conversation)
    end

    # --- Moderation contract (duck-typed, zero coupling) ------------------------
    #
    # Plain-Ruby methods that make a message a first-class citizen of the
    # moderate gem the moment the HOST wires it up (see README "Trust &
    # Safety"): they satisfy Moderate::Reportable's contract (owner, label,
    # snapshot, removal, visibility) and Moderate::ContentFilterable's field
    # seams for attachment filtering. Without moderate installed they're
    # inert and cost nothing.

    def reported_owner
      sender
    end

    def moderation_label
      "Chat message #{id}"
    end

    def moderation_snapshot(field)
      body if field.to_s == "body"
    end

    def removable_reported_field?(field)
      field.to_s == "body" && body.present? && !deleted?
    end

    # A moderator removing a reported message body = the soft-delete
    # tombstone path, so the thread shows "Message deleted" instead of a
    # hole, and attachments are purged with it.
    def remove_reported_field!(field)
      return false unless field.to_s == "body"

      # Trust & Safety outranks a product lock: a closed conversation must
      # never be a place reported content can hide.
      soft_delete!(enforce_lock: false)
    end

    # Only people *in* the conversation may report a message (a message
    # isn't public content), and you can't report your own.
    def report_visible_to?(viewer, field: nil)
      return false if viewer.nil? || sent_by?(viewer)

      conversation.participant?(viewer)
    end

    def moderation_content_type
      "message"
    end

    # Moderate::ContentFilterable seam: when the host declares
    # `moderates :files, mode: :flag, with: :some_image_adapter`, the default
    # `public_send(:files)` would hand the adapter an ActiveStorage proxy.
    # Most image adapters (like a custo ImageReviewAdapter, or an AWS
    # Rekognition adapter fed via ClassifyJob) don't read the value anyway —
    # they re-fetch the blob — but we make the value meaningful and
    # change-detection correct regardless.
    def moderation_field_value(field)
      return files if field.to_s == "files" && respond_to?(:files)

      public_send(field)
    end

    def moderation_field_changed_for_commit?(field)
      if field.to_s == "files" && respond_to?(:files)
        # Attachments don't have a column; detect "files changed in this
        # commit" via the attachment records created in this transaction.
        files.attachments.any?(&:previously_new_record?)
      elsif respond_to?(:saved_change_to_attribute?)
        saved_change_to_attribute?(field)
      else
        true
      end
    end

    private

    def sender_required_for_text_messages
      errors.add(:sender, :blank) if text? && sender.nil?
    end

    def body_or_files_required
      return if system? || deleted?
      return if body.present?
      return if attachments?

      errors.add(:body, :blank)
    end

    def body_must_fit_length_limit
      max = Chats.config.max_message_length
      return if max.nil? || body.nil?

      errors.add(:body, :too_long, count: max) if body.length > max
    end

    def sender_must_be_active_participant
      return if system? || sender.nil? || conversation.nil?

      errors.add(:sender, :not_a_participant) unless conversation.participant?(sender)
    end

    # Block enforcement at the WRITE, not just at conversation creation: a
    # block placed mid-conversation must stop the very next send. Direct
    # threads only — see Conversation.excluding_blocked_for for the group
    # rationale.
    def sender_must_not_be_blocked
      return if system? || sender.nil? || conversation.nil? || !conversation.direct?

      other = conversation.other_participants(sender).first&.messager
      errors.add(:base, :blocked) if other && Chats.blocked_between?(sender, other)
    end

    # The subject owns the conversation's openness (Chats::ChatSubject#
    # chat_locked?). System messages are exempt: the host must always be able
    # to post "This ticket was closed" into the thread it just closed.
    def conversation_must_not_be_locked
      return if system? || conversation.nil?
      return unless conversation.locked?

      errors.add(:base, :locked)
    end

    def files_must_be_allowed
      return unless respond_to?(:files)
      return unless files.attached?

      mode = Chats.config.attachments
      if mode == false
        errors.add(:files, :not_allowed)
        return
      end

      if (max_count = Chats.config.max_attachments_per_message) && files.size > max_count
        errors.add(:files, :too_many, count: max_count)
      end

      files.each do |file|
        errors.add(:files, :must_be_images) if mode == :images && !file.content_type.to_s.start_with?("image/")

        if (max_size = Chats.config.max_attachment_size) && file.byte_size.to_i > max_size
          errors.add(:files, :too_big, count: max_size / (1024 * 1024))
        end
      end
    end

    def register_on_conversation
      conversation.register_last_message!(self)
    end

    def heal_conversation_pointers
      conversation.recompute_last_message! if conversation.last_message_id == id
    end

    def broadcast_created
      Chats::Broadcasts.message_created(self)
    end

    def broadcast_updated
      Chats::Broadcasts.message_updated(self)
    end

    def broadcast_destroyed
      Chats::Broadcasts.message_destroyed(self)
    end

    # The single notifier hook (see Chats.notify). System messages don't
    # notify: the host posted them itself and already knows — re-emitting
    # would double-count, the same reasoning the chats PRD applies to
    # moderation flag events.
    def notify_host
      return if system?

      Chats.notify(:message_created, message: self)
    end
  end
end
