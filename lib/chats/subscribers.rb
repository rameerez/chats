# frozen_string_literal: true

module Chats
  # The event bus behind `Chats.on`. One registry per event, many
  # subscribers per event, each one isolated:
  #
  #   Chats.on(:message_created)    { |message| NewMessageNotifier.deliver(message) }
  #   Chats.on(:conversation_read)  { |conversation:, participant:| Bell.mark_read(participant) }
  #
  # Two rules make this safe to use from a gem (the shape the `wallets` gem's
  # CallbackDispatcher established):
  #
  #   1. A raising subscriber is REPORTED, never swallowed and never fatal —
  #      `Rails.error.report(e, handled: true, context: { event: })` — so the
  #      next subscriber still runs and the message still gets delivered.
  #   2. Registration is reload-safe: pass `key:` and re-registering the same
  #      key REPLACES the subscriber in place, so a `to_prepare` block in a
  #      host app doesn't stack duplicates on every code reload.
  module Subscribers
    # Every event the gem emits, mapped to the payload key it yields
    # POSITIONALLY to subscribers (nil = the whole payload is yielded as
    # keywords). Registering for anything else raises at boot.
    #
    #   :message_created       message:                   every persisted human message
    #   :conversation_created  conversation:              a conversation just came into being
    #   :participant_left      participant:               someone left a group
    #   :conversation_read     conversation:, participant: a read consumed unread content
    EVENTS = {
      message_created: :message,
      conversation_created: :conversation,
      participant_left: :participant,
      conversation_read: nil
    }.freeze

    # The events the deprecated `config.notifier=` hook is subscribed to:
    # exactly the two that existed in 0.1.1, and no more. A 0.1.x notifier is
    # commonly written `->(event, message:, **)`, which would raise
    # ArgumentError on an event that carries no `message:` — so the new
    # events are `Chats.on` only, and an old hook keeps behaving exactly as
    # it did.
    LEGACY_NOTIFIER_EVENTS = %i[message_created conversation_read].freeze

    # Reserved key for the subscriber `config.notifier=` registers, so
    # re-assigning the deprecated hook replaces rather than stacks.
    NOTIFIER_KEY = :chats_config_notifier

    # One registered callable. +style+ is how it gets invoked:
    #   :payload  the modern `Chats.on` shape (positional record, or keywords)
    #   :event    the deprecated `config.notifier` shape — `(event, **payload)`
    class Subscriber
      attr_reader :key, :callable, :style

      def initialize(callable, key: nil, style: :payload)
        @callable = callable
        @key = key
        @style = style
      end

      # Invoke the subscriber for +event+ with the emitted +payload+ hash.
      def call(event, payload)
        if style == :event
          callable.call(event, **payload)
        elsif (positional = EVENTS[event])
          callable.call(payload[positional])
        else
          callable.call(**payload)
        end
      end
    end

    class << self
      # Register +block+ for +event+. Returns the Subscriber.
      def on(event, key: nil, style: :payload, &block)
        event = validate_event!(event)
        raise ConfigurationError, "Chats.on(#{event.inspect}) requires a block" if block.nil?

        subscriber = Subscriber.new(block, key: key, style: style)
        replace_or_append(registry[event], subscriber)
        subscriber
      end

      # Every subscriber registered for +event+, in registration order.
      def for(event)
        registry[validate_event!(event)].dup
      end

      # Run every subscriber of +event+, each isolated from the others.
      # Returns the number of subscribers invoked.
      def emit(event, **payload)
        subscribers = registry[validate_event!(event)]

        subscribers.each do |subscriber|
          subscriber.call(event, payload)
        rescue StandardError => e
          report(e, event)
        end

        subscribers.size
      end

      # Drop every registration (used by `Chats.reset!` and by hosts that
      # re-register from a `to_prepare` block).
      def reset!
        @registry = nil
        self
      end

      private

      def registry
        @registry ||= EVENTS.keys.index_with { [] }
      end

      def validate_event!(event)
        event = event.to_sym
        return event if EVENTS.key?(event)

        raise ConfigurationError,
              "unknown chats event #{event.inspect} — valid events are #{EVENTS.keys.map(&:inspect).join(", ")}"
      end

      # Keyed subscribers replace in place (same position, so ordering is
      # stable across code reloads); keyless ones always append.
      def replace_or_append(list, subscriber)
        index = subscriber.key && list.index { |existing| existing.key == subscriber.key }
        if index
          list[index] = subscriber
        else
          list << subscriber
        end
      end

      # A failing subscriber must be VISIBLE (not just logged): the host's
      # error reporter is the one surface that pages someone.
      def report(error, event)
        if defined?(::Rails) && ::Rails.respond_to?(:error) && ::Rails.error
          ::Rails.error.report(error, handled: true, context: { event: event })
        else
          Chats.logger&.error("[chats] subscriber raised on #{event}: #{error.class}: #{error.message}")
        end
      end
    end
  end
end
