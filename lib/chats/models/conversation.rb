# frozen_string_literal: true

module Chats
  # A conversation: either a +direct+ 1:1 thread or a +group+. Optionally
  # *about* a host record (the polymorphic +subject+ — a ride, an order, a
  # listing), which is how marketplace-style apps attach a chat to a domain
  # object.
  #
  # == Direct conversations & the +direct_key+
  #
  # Two people opening a DM with each other at the same instant must end up
  # in the SAME conversation. We guarantee that with a deterministic
  # +direct_key+ ("the sorted pair of participant keys, plus the subject key
  # when the conversation is about something") backed by a UNIQUE index, and
  # `create_or_find_by!` which turns the index violation into a find. See
  # `.direct_between!`.
  #
  # The subject participates in the key on purpose: the same pair can have
  # one thread per subject (per-listing threads, marketplace-style) AND one
  # subjectless thread (classic DMs). The host picks the cardinality simply
  # by passing or omitting `about:`.
  #
  # == Denormalization
  #
  # +last_message_at+ and +last_message_id+ exist so the inbox (the hottest
  # query in any messaging product) is one indexed ORDER BY plus one
  # `includes(:last_message)` — no MAX() subqueries, no N+1.
  class Conversation < ApplicationRecord
    self.table_name = "chats_conversations"

    KINDS = %w[direct group].freeze
    TITLE_MAX_LENGTH = 120
    EPOCH = Time.utc(1970).freeze

    belongs_to :subject, polymorphic: true, optional: true
    # No DB foreign key on last_message_id (see migration): a circular
    # conversations<->messages FK pair makes deletes order-dependent. The
    # association is best-effort denormalization, never authority.
    belongs_to :last_message, class_name: "Chats::Message", optional: true

    has_many :participants,
             class_name: "Chats::Participant",
             inverse_of: :conversation,
             dependent: :destroy
    has_many :messages,
             class_name: "Chats::Message",
             inverse_of: :conversation,
             dependent: :destroy

    scope :direct, -> { where(kind: "direct") }
    # `groups` (plural): `scope :group` would collide with ActiveRecord's own
    # GROUP BY class method.
    scope :groups, -> { where(kind: "group") }
    scope :about, ->(subject) { where(subject: subject) }
    scope :recent_first, lambda {
      # COALESCE keeps freshly-created (still message-less) conversations
      # sorted by creation time, portable across sqlite/postgres/mysql
      # (no NULLS LAST, which sqlite/mysql spell differently).
      order(Arel.sql("COALESCE(chats_conversations.last_message_at, chats_conversations.created_at) DESC"))
    }

    # A messager's inbox: every conversation they're an active participant of
    # (not left), minus direct threads with someone they're blocked with,
    # newest activity first. THE hot query — keep it composable and indexed.
    scope :inbox_for, lambda { |messager|
      joins(:participants)
        .where(chats_participants: { left_at: nil })
        .where(chats_participants: { messager_type: messager.class.polymorphic_name, messager_id: messager.id })
        .excluding_blocked_for(messager)
        .recent_first
    }

    # Hide direct conversations whose counterpart is blocked (either
    # direction — `Chats.blocked_ids_for` is bidirectional by contract).
    # Group conversations are NOT hidden: industry standard is that blocking
    # someone doesn't eject you from shared group spaces. Data is never
    # deleted — lift the block and the thread reappears.
    scope :excluding_blocked_for, lambda { |messager|
      blocked_ids = Chats.blocked_ids_for(messager)
      next all if blocked_ids.respond_to?(:empty?) && blocked_ids.empty?

      blocked_seats = Chats::Participant.select(:conversation_id).where(
        messager_type: messager.class.polymorphic_name, messager_id: blocked_ids
      )

      where.not(id: direct.where(id: blocked_seats))
    }

    # Conversations holding messages the messager hasn't read yet (excluding
    # their own messages and tombstones). Compose with `inbox_for`:
    #   Chats::Conversation.inbox_for(user).unread_by(user).distinct.count
    scope :unread_by, lambda { |messager|
      joins(:participants, :messages)
        .where(chats_participants: { messager_type: messager.class.polymorphic_name, messager_id: messager.id })
        .where(chats_messages: { deleted_at: nil })
        .where("chats_messages.created_at > COALESCE(chats_participants.last_read_at, ?)", EPOCH)
        # "Not sent by me" — with an explicit IS NULL leg: system messages
        # have a NULL sender, and in SQL's three-valued logic a bare
        # NOT(sender_type = X AND …) evaluates to NULL (not TRUE) for them,
        # silently dropping system messages from unread counts.
        .where(
          "chats_messages.sender_type IS NULL OR NOT (chats_messages.sender_type = ? AND chats_messages.sender_id = ?)",
          messager.class.polymorphic_name, messager.id.to_s
        )
    }

    validates :kind, inclusion: { in: KINDS }
    validates :title, length: { maximum: TITLE_MAX_LENGTH }, allow_blank: true
    # direct_key uniqueness is enforced by the DB unique index ONLY — on
    # purpose, not an oversight. `create_or_find_by!` (the race-safe
    # find-or-create in .direct_between!) works by attempting the INSERT and
    # converting the index violation into a find; a model-level uniqueness
    # validation would fire first, raise RecordInvalid, and break the whole
    # mechanism. https://api.rubyonrails.org/classes/ActiveRecord/Relation.html#method-i-create_or_find_by
    validate :groups_must_be_enabled, if: :group?

    after_create_commit -> { Chats.notify(:conversation_created, conversation: self) }

    # --- Finding & creating ---------------------------------------------------

    class << self
      # The direct conversation between +a+ and +b+ (about +subject+, when
      # given), or nil. Read-only twin of `.direct_between!`.
      def direct_between(a, b, about: nil)
        find_by(direct_key: direct_key_for([a, b], subject: about))
      end

      # Find-or-create the direct conversation between two messagers,
      # race-safely (see class comment). Raises:
      #   Chats::BlockedError    if the pair is blocked (either direction)
      #   Chats::NotAllowedError if the host `can_message` policy says no
      def direct_between!(a, b, about: nil)
        raise ArgumentError, "both participants are required" if a.nil? || b.nil?
        raise ArgumentError, "can't open a conversation with yourself" if a == b
        raise Chats::BlockedError, "messagers are blocked" if Chats.blocked_between?(a, b)
        raise Chats::NotAllowedError, "policy forbids messaging" unless Chats.can_message?(a, b)

        transaction do
          conversation = create_or_find_by!(direct_key: direct_key_for([a, b], subject: about)) do |c|
            c.kind = "direct"
            c.subject = about
          end
          # Keep the roster in the creation transaction: the after-commit
          # event must describe a complete conversation, including under an
          # outer host transaction or a failed participant insertion.
          [a, b].each { |messager| conversation.add_participant!(messager) }
          conversation
        end
      end

      # Create a group conversation. +others+ excludes the creator (who joins
      # as "owner"). Raises Chats::NotAllowedError when groups are disabled
      # or the host `can_create_group` policy says no.
      def group!(creator, others, title: nil, about: nil)
        raise Chats::NotAllowedError, "group conversations are disabled" unless Chats.config.groups
        unless Chats.config.can_create_group.call(creator)
          raise Chats::NotAllowedError,
                "policy forbids creating groups"
        end

        others = Array(others) - [creator]
        raise ArgumentError, "a group needs at least 2 other participants" if others.size < 2

        transaction do
          created = create!(kind: "group", title: title, subject: about)
          created.add_participant!(creator, role: "owner")
          others.each { |messager| created.add_participant!(messager) }
          created
        end
      end

      # Deterministic identity for a direct pair (+ optional subject).
      # GlobalID params already encode class + id, so "User 4" and
      # "Organization 4" can never collide. Sorting makes it order-independent.
      def direct_key_for(pair, subject: nil)
        key = pair.map { |messager| Chats.messager_key(messager) }.sort.join("|")
        key += "|about:#{subject.to_global_id.to_param}" if subject
        key
      end

      # Per-conversation unread counts for a messager over a set of
      # conversations, in ONE grouped query — the inbox uses this to render
      # row badges without N+1:
      #   Chats::Conversation.unread_counts_for(user, conversations) # => { id => count }
      def unread_counts_for(messager, conversations)
        ids = Array(conversations).map { |c| c.is_a?(Conversation) ? c.id : c }
        return {} if ids.empty?

        unread_by(messager).where(chats_conversations: { id: ids })
                           .group("chats_conversations.id")
                           .count("chats_messages.id")
      end
    end

    # --- Predicates & lookups -------------------------------------------------

    def direct? = kind == "direct"
    def group? = kind == "group"

    def participant_for(messager)
      return nil if messager.nil?

      participants.find_by(messager: messager)
    end

    def participant?(messager)
      return false if messager.nil?

      participants.active.exists?(messager_type: messager.class.polymorphic_name, messager_id: messager.id)
    end

    def other_participants(messager)
      participants.active.where.not(
        messager_type: messager.class.polymorphic_name, messager_id: messager.id
      )
    end

    # The OTHER messager in a direct thread, from +viewer+'s seat — nil for a
    # group, and nil for a direct thread whose other seat has left. The one
    # place the counterpart is resolved, so the title, the avatar and the
    # verified badge on an inbox row always name the same person.
    #
    # Memoized per viewer: an inbox row asks for it two or three times, and a
    # row that cost one query in 0.2.0 must not start costing three.
    def counterpart_for(viewer)
      return nil unless direct?

      @counterparts ||= {}
      key = viewer && Chats.messager_key(viewer)
      return @counterparts[key] if @counterparts.key?(key)

      @counterparts[key] = other_participants(viewer).includes(:messager).first&.messager
    end

    # What this conversation is called from +viewer+'s seat: a direct thread
    # is named after the counterpart; a group after its title (or its
    # members, when untitled).
    def title_for(viewer)
      if direct?
        other = counterpart_for(viewer)
        other ? Chats.display_name_for(other) : I18n.t("chats.conversation.empty_title")
      else
        title.presence || participants.active.includes(:messager).limit(4).map do |p|
          Chats.display_name_for(p.messager)
        end.join(", ")
      end
    end

    # A short human label for the subject ("Madrid → Barcelona", "Order
    # #4221"), provided by the subject model via `chat_subject_label`
    # (see Chats::ChatSubject). Nil when the conversation is about nothing.
    def subject_label
      return nil if subject.nil?

      subject.try(:chat_subject_label) || "#{subject.class.model_name.human} #{subject.id}"
    end

    # Whether new messages are refused here, decided by the SUBJECT (see
    # Chats::ChatSubject#chat_locked?). A subjectless conversation is never
    # locked. Reading is never affected — only sending.
    def locked?
      return false if subject.nil?

      subject.try(:chat_locked?) || false
    end

    # The host's explanation for the lock, or the gem's localized fallback.
    # Always a sentence worth showing: a locked composer that says nothing is
    # indistinguishable from a broken one.
    def locked_notice
      return nil unless locked?

      subject.try(:chat_locked_notice).presence || I18n.t("chats.composer.locked")
    end

    # The guard every write that ISN'T a message itself calls (reactions
    # today). Message writes go through Chats::Message#refuse_when_locked!,
    # which exempts system messages.
    def refuse_writes_when_locked! # :nodoc:
      raise Chats::LockedError.new(conversation: self) if locked?
    end

    # --- Membership -----------------------------------------------------------

    # Idempotent, race-safe membership. Re-adding someone who left re-joins
    # them (their read state survives — by design, so history isn't re-marked
    # unread).
    def add_participant!(messager, role: "member")
      participant = participants.create_or_find_by!(
        messager_type: messager.class.polymorphic_name, messager_id: messager.id
      ) do |p|
        p.role = role
      end
      participant.update!(left_at: nil) if participant.left?
      participant
    end

    # Recompute the deterministic identity of a DIRECT thread after its
    # roster changed (see Chats::Participant#reseat!). Without this the key
    # would still name the old pair, and `chat_with` would open a SECOND
    # thread for the new one. No-op for groups (they have no key).
    def reindex_direct_key! # :nodoc:
      return self unless direct?

      # `reset`: the caller just changed a seat, and a participants
      # association loaded BEFORE that would name the old pair.
      messagers = participants.reset.includes(:messager).filter_map(&:messager)
      return self unless messagers.size == 2

      update_columns(
        direct_key: self.class.direct_key_for(messagers, subject: subject),
        updated_at: Time.current
      )
      self
    end

    # --- Messaging ------------------------------------------------------------

    # Post a message from your APP into the conversation — "Your ride was
    # cancelled", "Payment received" — rendered as a centered system note,
    # not a bubble. This is the stable entry point notification systems
    # (e.g. a Noticed delivery method) should call.
    def post_system_message!(body)
      messages.create!(kind: "system", body: body)
    end

    # --- Read state -----------------------------------------------------------

    def unread_count_for(messager)
      participant_for(messager)&.unread_count || 0
    end

    def unread_for?(messager)
      unread_count_for(messager).positive?
    end

    def mark_read_by!(messager)
      participant_for(messager)&.read!
    end

    # Denormalized pointers the inbox sorts/previews by. Called from
    # Chats::Message callbacks inside the message's own transaction.
    # `update_columns` on purpose: no validations/callbacks/broadcast loops —
    # this is bookkeeping, not domain change. updated_at is bumped manually
    # so fragment caches keyed on the conversation still invalidate.
    def register_last_message!(message) # :nodoc:
      update_columns(
        last_message_at: message.created_at,
        last_message_id: message.id,
        updated_at: Time.current
      )
    end

    def recompute_last_message! # :nodoc:
      latest = messages.order(created_at: :desc, id: :desc).first
      update_columns(
        last_message_at: latest&.created_at,
        last_message_id: latest&.id,
        updated_at: Time.current
      )
    end

    # --- Moderation contract (duck-typed, zero coupling) ------------------------
    #
    # These methods make the conversation a well-behaved reportable the moment
    # the HOST includes the moderate gem's concern (`Chats::Conversation.
    # has_reportable_content :title`). They're plain Ruby — defining them
    # without moderate installed costs nothing. See README "Trust & Safety".

    def reported_owner
      # The accountable human for a conversation: its owner (groups) or the
      # first participant (direct — moderation of direct threads usually
      # targets a specific *message*, but DSA tooling wants an owner).
      owner = participants.find_by(role: "owner") || participants.order(:created_at).first
      owner&.messager
    end

    def moderation_label
      "Chat conversation #{id}"
    end

    def moderation_snapshot(field)
      title if field.to_s == "title"
    end

    def removable_reported_field?(field)
      field.to_s == "title" && title.present?
    end

    def remove_reported_field!(field)
      return false unless field.to_s == "title"

      update!(title: nil)
      true
    end

    def report_visible_to?(viewer, field: nil)
      participant?(viewer)
    end

    def moderation_content_type
      group? ? "group" : "conversation"
    end

    private

    def groups_must_be_enabled
      errors.add(:kind, :groups_disabled) unless Chats.config.groups
    end
  end
end
