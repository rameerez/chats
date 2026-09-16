# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "global_id"

require_relative "chats/version"
require_relative "chats/errors"
require_relative "chats/configuration"
require_relative "chats/subscribers"
require_relative "chats/macros"

require_relative "chats/engine" if defined?(::Rails::Engine)

# == Chats
#
# A drop-in, real-time messaging engine for Rails: DMs, group chats, reactions,
# attachments, read receipts — Hotwire-native, polymorphic, adapter-driven.
#
# The public surface is intentionally tiny:
#
#   Chats.configure { |config| ... }   # one block, in an initializer
#   acts_as_messager                   # on any model that can converse
#   acts_as_chat_subject               # on any model conversations can be about
#
#   user.chat_with(other)              # find-or-create a direct conversation
#   user.message!(other, "hello!")     # ...and say something in one line
#
#   Chats.on(:message_created) { |m| } # subscribe to the domain moments
#
# Everything else (controllers, views, broadcasts) ships with the engine and
# is overridable the Devise way (`rails g chats:views`).
module Chats
  class << self
    # --- Configuration --------------------------------------------------------

    def config
      @config ||= Configuration.new
    end

    alias configuration config

    def configure
      yield config if block_given?
      config.validate!
      config
    end

    # Reset all global state. Used by the test suite to keep examples isolated;
    # also handy in a console when experimenting with configuration.
    def reset!
      @config = Configuration.new
      @messager_classes = nil
      @subject_classes = nil
      reset_subscribers!
      self
    end

    # The gem's own deprecator (registered with `Rails.application.deprecators`
    # by the engine, so `config.active_support.deprecation` governs it).
    def deprecator
      @deprecator ||= ActiveSupport::Deprecation.new("1.0", "chats")
    end

    # --- Registries -----------------------------------------------------------
    #
    # `acts_as_messager` / `acts_as_chat_subject` self-register the calling
    # class here. We store class NAMES (strings), not Class objects, so the
    # registry survives Zeitwerk code reloading in development (a reloaded
    # class is a brand-new object; its name is stable).

    def register_messager(klass)
      messager_class_names << klass.name if klass.name
    end

    def register_chat_subject(klass)
      subject_class_names << klass.name if klass.name
    end

    def messager_class_names
      @messager_class_names ||= Set.new
    end

    def subject_class_names
      @subject_class_names ||= Set.new
    end

    # Whether +klass+ (a Class or class name) is a registered messager.
    # Ancestor-aware so an STI subclass of a messager is accepted too.
    def messager_class?(klass)
      registered_class?(messager_class_names, klass)
    end

    def chat_subject_class?(klass)
      registered_class?(subject_class_names, klass)
    end

    # --- Ecosystem seams ------------------------------------------------------

    # The single source of truth for "who can't talk to whom". Wraps the
    # host-provided `config.blocked_messager_ids` proc (no-op by default, or
    # `Moderate.blocked_ids_for(user)` when the moderate gem is wired in) and
    # always returns something usable in a `WHERE id IN (...)` — an Array of
    # ids or an AR relation selecting ids.
    def blocked_ids_for(messager)
      return [] if messager.nil?

      config.blocked_messager_ids.call(messager) || []
    end

    # True when +a+ and +b+ can't message each other (either one blocked the
    # other — blocking is enforced bidirectionally, like every serious
    # messaging product). Only meaningful between messagers of the same class
    # (a User blocks a User); cross-class pairs are never considered blocked.
    def blocked_between?(a, b)
      return false if a.nil? || b.nil?
      return false unless a.class.base_class == b.class.base_class

      blocked_ids = blocked_ids_for(a)
      if blocked_ids.respond_to?(:exists?)
        # An AR relation: resolve with one indexed query instead of loading ids.
        blocked_ids.exists?(b.id)
      else
        blocked_ids.include?(b.id)
      end
    end

    # Host policy on top of (never instead of) block enforcement. The blocked
    # check is hardcoded in the models so a host overriding `can_message`
    # cannot accidentally disable Trust & Safety guarantees.
    def can_message?(sender, recipient)
      return false if blocked_between?(sender, recipient)

      config.can_message.call(sender, recipient)
    end

    # --- Events ---------------------------------------------------------------

    # Subscribe to a domain moment. Many subscribers per event; each one runs
    # isolated, so a raising subscriber is reported and the others still run.
    #
    #   Chats.on(:message_created)      { |message| }
    #   Chats.on(:conversation_created) { |conversation| }
    #   Chats.on(:participant_left)     { |participant| }
    #   Chats.on(:conversation_read)    { |conversation:, participant:| }
    #
    # Pass `key:` from reloadable code (a `to_prepare` block): re-registering
    # the same key REPLACES the previous subscriber instead of stacking a
    # duplicate on every code reload.
    def on(event, key: nil, &block)
      Subscribers.on(event, key: key, &block)
    end

    # Drop every `Chats.on` registration (also called by `reset!`).
    def reset_subscribers!
      Subscribers.reset!
      self
    end

    # Fire a domain event at every subscriber (see Chats.on). Error-isolated:
    # a broken subscriber must never break message delivery itself — the
    # message is already committed; notifications are best-effort fan-out.
    def notify(event, **payload)
      Subscribers.emit(event, **payload)
    end

    # --- Display helpers (used by the bundled views) --------------------------

    def display_name_for(messager)
      return "" if messager.nil?

      config.messager_display_name.call(messager).to_s
    end

    def avatar_for(messager)
      return nil if messager.nil?

      config.messager_avatar.call(messager)
    end

    # Where a messager's profile lives, per `config.messager_url` (nil by
    # default — the bundled views then render plain text, never a dead link).
    def messager_url_for(messager)
      return nil if messager.nil?

      config.messager_url.call(messager).presence
    end

    # The signature line under a signed message ("— Lucía G."), per
    # `config.message_signature` when the host sets one. Nil for messages
    # that aren't signed (see Chats::Message#signed?).
    def message_signature_for(message)
      return nil if message.nil? || !message.signed?

      if config.message_signature
        config.message_signature.call(message).presence
      else
        I18n.t("chats.message.signature", name: display_name_for(message.author))
      end
    end

    # --- Messager options (see acts_as_messager) --------------------------------

    # Whether +messager+ can be notified at all. False for headless messagers
    # declared with `acts_as_messager notifications: false` (a support desk, a
    # bot): hosts stop branching on class in every notifier.
    def notifications_for?(messager)
      messager_option(messager, :chat_notifications?)
    end

    # Whether block/report affordances make sense against +messager+.
    # False for `acts_as_messager blockable: false`.
    def blockable?(messager)
      messager_option(messager, :chat_blockable?)
    end

    # Whether +messager+'s direct conversations stack into one inbox row
    # (`acts_as_messager inbox: :grouped`).
    def grouped_inbox?(messager)
      messager_option(messager, :chat_grouped_inbox?, default: false)
    end

    # Whether +messager+ is an OFFICIAL account (`acts_as_messager verified:
    # true`) — a support desk, an organization, a brand. The bundled views
    # badge its name; hosts can read it to do the same on their own screens.
    # Defaults to false: nothing is verified until a model says so.
    def verified?(messager)
      messager_option(messager, :chat_verified?, default: false)
    end

    # The polymorphic type names of every registered messager class that
    # stacks (`inbox: :grouped`). Empty in an ordinary app — which is what
    # keeps the inbox query there byte-identical to 0.1.x. Used as a SQL
    # PREFILTER only; whether a given counterpart actually stacks is still
    # decided per-record by `grouped_inbox?` (STI subclasses share a
    # polymorphic_name with siblings that may not be grouped).
    def grouped_messager_types
      messager_class_names.filter_map do |name|
        klass = name.safe_constantize
        next unless klass.respond_to?(:chat_grouped_inbox?) && klass.chat_grouped_inbox?

        klass.polymorphic_name
      end.uniq
    end

    # The signed GlobalID that scopes the inbox to conversations with
    # +messager+ (`GET /conversations?with=…`). Purpose-scoped and
    # non-expiring: inbox rows live on long-lived pages.
    def inbox_with_sgid(messager)
      return nil if messager.nil?

      messager.to_sgid(expires_in: nil, for: :chats_inbox_with).to_s
    end

    # --- Internals ------------------------------------------------------------

    def logger
      defined?(::Rails) ? ::Rails.logger : nil
    end

    # A stable, URL-safe, non-guessy key for a messager, used in DOM data
    # attributes (the Stimulus thread controller compares it to decide
    # own-vs-other bubble alignment) and in direct-conversation keys.
    # GlobalID params are opaque-ish (Base64) and already encode class + id.
    def messager_key(messager)
      messager.to_global_id.to_param
    end

    private

    # Ask a messager's CLASS about an `acts_as_messager` option. Duck-typed
    # (never `is_a?`): anything that doesn't answer is treated as a stock
    # messager, so a plain host model keeps 0.1.x behaviour.
    def messager_option(messager, predicate, default: true)
      return default if messager.nil?

      klass = messager.is_a?(Class) ? messager : messager.class
      return default unless klass.respond_to?(predicate)

      klass.public_send(predicate)
    end

    def registered_class?(registry, klass)
      klass = klass.class unless klass.is_a?(Class) || klass.is_a?(String)
      name = klass.is_a?(String) ? klass : klass.name
      return true if registry.include?(name)

      # Ancestor-aware fallback: accept subclasses of registered classes
      # (e.g. an STI `Admin < User` when `User` is the registered messager).
      constant = klass.is_a?(String) ? name.safe_constantize : klass
      return false unless constant.respond_to?(:ancestors)

      constant.ancestors.any? { |ancestor| registry.include?(ancestor.name) }
    end
  end
end
