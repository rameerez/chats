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
  # == Actions
  #
  # A message may carry ONE featured button — a label and a url, set by the
  # host from Ruby ("Your invoice is ready" → *Pay now*). See Chats::Action
  # for the value and #action_must_be_well_formed for what a safe one is.
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

    # The shape of a renderable action (see #action_must_be_well_formed): a
    # label short enough to be a button, a url short enough to be a link,
    # and only the schemes a browser navigates to safely.
    ACTION_LABEL_LIMIT = 80
    ACTION_URL_LIMIT = 2048
    ACTION_URL_SCHEMES = %w[http https].freeze
    # An authority ending in ":" with nothing after it ("https://host:/x").
    EMPTY_PORT = %r{\A[a-z][a-z0-9+.-]*://[^/?#]*:(?:[/?#]|\z)}i
    ACTION_URL_PORTS = (1..65_535)

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

    # The featured button (Chats::Action), or nil. Its own column rather than
    # a key in `metadata`, which stays the host's bag: an action is a
    # contract the bundled bubble renders, so the gem must own where it lives.
    attribute :action, Chats::Action::Type.new

    scope :recent_first, -> { order(created_at: :desc, id: :desc) }
    scope :oldest_first, -> { order(created_at: :asc, id: :asc) }
    scope :visible, -> { where(deleted_at: nil) }

    # What messagers wrote: text messages that still stand. "Human" is the
    # gem's word for a text message, written by a messager, person or not
    # (a bot's or a headless desk's message counts), as opposed to a system
    # line ("Alice joined", "Your ride was cancelled"), which is the app
    # talking. A tombstone no longer says anything. A photo with no caption
    # is still a text message and still counts. The inbox does NOT read through this,
    # on purpose — see README "Real conversations vs system-only threads".
    scope :human, -> { where(kind: "text").visible }

    # The newest human message of each given conversation, at most one row
    # per conversation, in ONE query: the batch twin of
    # Conversation#last_human_message for lists (admin walls, moderation
    # queues). +conversations+ is a page of records, ids, a single record, or
    # a Chats::Conversation relation — an unloaded relation is read as a
    # subquery, never loaded first, and without its `includes`/`preload`/
    # `eager_load` (they load records; a subquery has none to load). So a
    # relation that FILTERS on an associated table must join it explicitly
    # (`joins` / `left_joins`): `includes(:x).references(:x).where(x: …)`
    # loses the join and raises. Or pass the loaded page, or its ids.
    #
    # The result is a relation, so the columns can be narrowed:
    #
    #   Chats::Message.last_human_in(conversations)
    #                 .select(:id, :conversation_id, :created_at)
    #                 .index_by(&:conversation_id)          # { id => message }
    #
    # A conversation nobody wrote in has no row. ROW_NUMBER works on every
    # supported adapter (PostgreSQL, SQLite and MySQL 8), the same ranking
    # Chats::Inbox uses for its stacks. The ranked subquery is built unscoped,
    # so neither a scope it is called on nor a `.select` chained onto the
    # result leaks into it.
    scope :last_human_in, lambda { |conversations|
      ids = Chats::Message.conversation_ids_in(conversations)
      next none if ids.is_a?(Array) && ids.empty?

      ranking = "ROW_NUMBER() OVER (PARTITION BY chats_messages.conversation_id " \
                "ORDER BY chats_messages.created_at DESC, chats_messages.id DESC) AS human_rank"
      ranked = Chats::Message.unscoped.human.where(conversation_id: ids)
                             .select(Arel.sql("chats_messages.id"), Arel.sql(ranking))
      newest = Chats::Message.unscoped.from(ranked, :ranked_messages)
                             .where(Arel.sql("ranked_messages.human_rank = 1"))
                             .select(Arel.sql("ranked_messages.id"))
      where(id: newest)
    }

    # The conversation ids +last_human_in+ ranks within: an Array for records
    # and ids (a loaded relation included, read from memory), a subquery for
    # an unloaded relation, as a derived table because MySQL rejects LIMIT
    # directly inside IN, and a page is usually limited.
    #
    # A LIMITed or OFFSET page is its own query, word for word (its select
    # list, DISTINCT and ORDER BY decide WHICH rows it holds, and PostgreSQL
    # refuses a DISTINCT whose ORDER BY left the select list), so it must
    # expose an `id` column, as the default select list does. Any other
    # relation is just a set of ids: narrowed to `id`, unordered (the inbox's
    # ORDER BY COALESCE(…) next to DISTINCT id is another refusal).
    def self.conversation_ids_in(conversations) # :nodoc:
      unless conversations.is_a?(ActiveRecord::Relation)
        return Array(conversations).map { |c| c.is_a?(Chats::Conversation) ? c.id : c }
      end
      unless conversations.klass <= Chats::Conversation
        raise ArgumentError, "expected Chats::Conversation records, ids or a relation of them, " \
                             "got a #{conversations.klass.name} relation"
      end
      return conversations.map(&:id) if conversations.loaded?

      page = conversations.except(:includes, :preload, :eager_load)
      page = page.reselect(page.arel_table[:id]).reorder(nil) unless page.limit_value || page.offset_value
      Chats::Conversation.unscoped.from(page, :conversation_page).select(Arel.sql("conversation_page.id"))
    end

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
    # recovery path — see the thread controller's catch-up), on the client's
    # two cursors. Each is a moment, to the microsecond, up to which the
    # client KNOWS it has everything (a complete render, or a catch-up that
    # succeeded — never a live bubble, which can arrive past one it missed),
    # with the ids it has on screen from that moment on:
    #   created_after(at, seen:)   — created at or after that moment and not
    #                                on screen: appended;
    #   created_through(at, seen:) — the complement: what the client has;
    #   updated_after(at, seen:)   — changed after that moment, or at it and
    #                                not among the ones seen in that version.
    # Replacements are created_through(after).updated_after(changed): changes
    # to what is on screen, never a second copy of what is appended — a Turbo
    # append of an existing dom_id would MOVE that bubble to the end. Two
    # cursors, because one can't answer both: a message created at 10:15 and
    # missed is older than a 10:20 edit that did arrive.
    # Pattern from Basecamp's Campfire (Rooms::RefreshesController):
    # https://github.com/basecamp/once-campfire
    scope :created_after, lambda { |at, seen: []|
      where(arel_table[:created_at].gteq(at)).where.not(id: seen)
    }
    scope :created_through, lambda { |at, seen: []|
      where(arel_table[:created_at].lt(at)).or(where(id: seen))
    }
    scope :updated_after, lambda { |at, seen: []|
      where(arel_table[:updated_at].gt(at)).or(where(updated_at: at).where.not(id: seen))
    }
    # The one-cursor catch-up of bubbles ejected before they carried the
    # cursors above (`data-updated-at-ms` alone, rounded up): what was
    # created after it, and what was rendered by then and changed since.
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
    validate :conversation_must_not_be_locked, on: :create
    validate :author_must_be_persisted
    # Checked at the write that SETS it, not on every save: an edit must
    # never fail over an action nobody touched.
    validate :action_must_be_well_formed, if: :will_save_change_to_action?
    validate :files_must_be_allowed
    # Last on purpose: the host's policy is asked only of a send that is
    # otherwise valid (see the method).
    validate :sender_must_still_be_allowed, on: :create

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
    def action? = !action.nil?

    # Wraps on the way in, not lazily on first read (ActiveModel casts user
    # input when it is read): `message.action = "/pay"` raises right here,
    # at the line that made the mistake.
    def action=(value)
      super(Chats::Action.wrap(value))
    end

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

    # Whether +messager+ is the one who WROTE this (not necessarily the seat
    # it was sent from).
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
    #
    # A tombstone shows neither the words nor the button that came with
    # them, so the soft path clears the action too — and moderation, which
    # removes content through here, takes the link down with the body.
    #
    # `enforce_lock: false` is for MODERATION only (see
    # #remove_reported_field!): a product lock must never shield reported
    # content from removal.
    def soft_delete!(enforce_lock: true)
      refuse_when_locked! if enforce_lock

      case Chats.config.deletion
      when :soft
        transaction do
          files.purge_later if respond_to?(:files) && files.attached?
          update!(body: nil, action: nil, deleted_at: Time.current)
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

    # Who answers for this message: its AUTHOR when it is signed, else its
    # sender. A signed message was written by a human from a seat that is not
    # a person — an agent answering from a support desk — and the seat cannot
    # be the owner a moderation flag or report points at: the host's `owner`
    # is typed to its user class, so a desk there is a type mismatch raised
    # from inside the agent's own reply the first time a filter trips.
    def reported_owner
      author || sender
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

    # Who may talk to whom is decided at the WRITE, not just when the
    # conversation was opened: a block placed mid-conversation stops the very
    # next send, and so does the host's `can_message` policy turning false —
    # an account banned, a listing closed, a membership ended. The pair was
    # allowed when the thread began; what matters is whether it still is.
    # Direct threads only — see Conversation.excluding_blocked_for for the
    # group rationale. Two errors, because they read differently to the
    # sender: `:blocked` (either side blocked the other) and `:not_allowed`
    # (the policy said no).
    #
    # Asked last, and only of a send that is otherwise valid: a stranger to
    # the conversation, a locked thread or an empty body is refused before
    # the host's policy runs, so the policy is never consulted about a
    # message that could not be sent anyway (it may be expensive, and it
    # runs on every direct send now). A policy must not raise: an
    # exception escapes the send like any other host error.
    #
    # A direct thread with nobody on the other side — the counterpart's
    # account was destroyed and its seat went with it — takes no messages:
    # there is no one the policy could allow.
    def sender_must_still_be_allowed
      return if system? || sender.nil? || conversation.nil? || !conversation.direct? || errors.any?

      other = conversation.other_participants(sender).first&.messager
      if other.nil?
        errors.add(:base, :not_allowed)
      elsif Chats.blocked_between?(sender, other)
        errors.add(:base, :blocked)
      elsif !Chats.config.can_message.call(sender, other)
        errors.add(:base, :not_allowed)
      end
    end

    # Authorship is a signature, not a conversation seat. A host may keep
    # staff in a separate model without giving them messaging capabilities.
    # Never implicitly create that identity while sending a message.
    def author_must_be_persisted
      return if author.nil? || author.persisted?

      errors.add(:author, :invalid)
    end

    # What a button the bubble renders may be: a short label, and a link to
    # an http(s) URL or a path on this site. The host is trusted, but a bad
    # action has to fail HERE, loudly, rather than render a dead link or a
    # `javascript:` one.
    #
    # Two layers, because a browser and URI.parse disagree about where a url
    # goes. First, a string check BEFORE parsing: nothing starting with `//`
    # or `/\` is a path on this site. URI.parse reads `///evil.example/x`
    # as a path with no host, yet a browser resolves it to
    # https://evil.example/x, and treats `/\` like `//`. Then the parse,
    # which rejects whitespace, control characters and backslashes anywhere
    # (`/<tab>/evil.example` is stripped into `//evil.example` by browsers),
    # and decides scheme, host and port.
    def action_must_be_well_formed
      return if action.nil?

      errors.add(:action, :invalid, count: ACTION_LABEL_LIMIT) unless action_label_fits? && action_url_safe?
    end

    def action_label_fits?
      action.label.present? && action.label.length <= ACTION_LABEL_LIMIT
    end

    def action_url_safe?
      url = action.url
      return false if url.blank? || url.length > ACTION_URL_LIMIT
      return false if url.start_with?("//", "/\\")
      # `https://host:` parses as the default port, so an empty port suffix
      # would pass the range check below; a named port must have digits.
      return false if url.match?(EMPTY_PORT)

      uri = URI.parse(url)
      if uri.scheme
        ACTION_URL_SCHEMES.include?(uri.scheme.downcase) && uri.host.present? && ACTION_URL_PORTS.cover?(uri.port)
      else
        # A path on this site: "/rides/new", never "//elsewhere.example".
        url.start_with?("/") && uri.host.nil?
      end
    rescue URI::InvalidURIError
      false
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
