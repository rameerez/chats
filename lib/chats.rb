# frozen_string_literal: true

require "active_support/core_ext/string/inflections"
require "global_id"

require_relative "chats/version"
require_relative "chats/errors"
require_relative "chats/configuration"
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
      self
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

    # Fire a domain event through the host's notifier hook (no-op by default).
    # Events (see Chats::Configuration#notifier):
    #   :message_created      message:      (every persisted, non-system message)
    #   :participant_added    participant:  (someone added to a group)
    #
    # Hosts typically point this at a Noticed notifier or a mailer job:
    #   config.notifier = ->(event, **payload) {
    #     NewMessageNotifier.with(**payload).deliver if event == :message_created
    #   }
    def notify(event, **payload)
      config.notifier.call(event, **payload)
    rescue StandardError => e
      # A broken notifier must never break message delivery itself — the
      # message is already committed; notifications are best-effort fan-out.
      # Same error-isolation philosophy as pricing_plans' lifecycle callbacks.
      logger&.error("[chats] notifier raised on #{event}: #{e.class}: #{e.message}")
      nil
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
