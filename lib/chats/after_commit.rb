# frozen_string_literal: true

module Chats
  # Work that must not happen before the change it announces is durable,
  # owned by the TRANSACTION, the way a record's after_commit callbacks are.
  #
  #   Chats::AfterCommit.run(connection, key: [:unread_consumed, seat.id]) { … }
  #
  # The block is wrapped in an Envelope and enrolled in the connection's
  # current transaction (`connection.add_transaction_record`, the call Active
  # Record makes for a saved record, on every supported Rails), which
  # finalizes it: runs it on commit, drops it on rollback or when an exception
  # ends the transaction. Nothing lives on a Ruby instance or on the thread,
  # so it doesn't matter which instance of a row was saved, whether the row
  # survives the transaction (a seat destroyed after its read), or which
  # thread runs next. The rules are after_commit's:
  #
  #   - with no transaction open, it runs at once;
  #   - in a transaction that joins its parent, and in a savepoint
  #     (`requires_new: true`) under a joinable parent, it moves up and runs
  #     at the outermost commit; a savepoint that rolls back drops only its
  #     own envelopes;
  #   - under a parent that is not joinable (and the wrapper Rails'
  #     transactional tests run each test in), it runs when the savepoint is
  #     released, when after_commit runs too.
  #
  # +key+: at most one envelope per key per transaction (the first one wins).
  #
  # The same shape as moderate's Moderate::DeferredNotices.
  module AfterCommit
    # What a transaction finalizes: Active Record calls `before_committed!`,
    # then `committed!` or `rolledback!` on every record enrolled in it, and
    # reads `trigger_transactional_callbacks?`, `destroyed?` and
    # `_new_record_before_last_commit` when it chooses which instance of a
    # row runs callbacks.
    class Envelope
      attr_accessor :_new_record_before_last_commit

      def initialize(work)
        @work = work
        @finalized = false
      end

      def trigger_transactional_callbacks? = true
      def has_transactional_callbacks? = true # rubocop:disable Naming/PredicatePrefix -- Active Record's name
      def destroyed? = false
      def before_committed!; end

      # Once, when the transaction that owns it runs commit callbacks. (Active
      # Record also calls it with should_run_callbacks: false when it is only
      # cleaning up after an exception: nothing runs then.)
      def committed!(should_run_callbacks: true)
        return if @finalized

        @finalized = true
        @work.call if should_run_callbacks
      end

      def rolledback!(force_restore_state: false, should_run_callbacks: true)
        @finalized = true
      end
    end

    # The keys already enrolled, per transaction object (gone with it).
    KEYS = ObjectSpace::WeakMap.new
    private_constant :KEYS

    class << self
      def run(connection, key: nil, &work)
        transaction = connection&.current_transaction
        return work.call unless transaction&.open?

        if key
          keys = (KEYS[transaction] ||= Set.new)
          return unless keys.add?(key)
        end
        connection.add_transaction_record(Envelope.new(work))
        nil
      end

      # A model's connection, as of now (Rails 7.2 renamed it lease_connection).
      def connection_for(model)
        model.respond_to?(:lease_connection) ? model.lease_connection : model.connection
      end
    end
  end
end
