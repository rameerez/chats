# frozen_string_literal: true

module Chats
  # All of the gem's knobs, with delightful defaults: a fresh `Configuration`
  # is fully working out of the box for the classic Devise + `User` Rails app.
  #
  # Two design rules, shared across the gem ecosystem (moderate, api_keys, …):
  #
  #   1. Class names are stored as STRINGS and constantized lazily, so the
  #      initializer can reference app classes before they're loaded and
  #      everything survives Zeitwerk reloads.
  #   2. Cross-gem seams are PROCS with no-op defaults, so `chats` runs
  #      standalone and lights up when the host wires moderate / Noticed /
  #      goodmail in.
  class Configuration
    ATTACHMENT_MODES = [false, :images, :any].freeze
    DELETION_MODES = [false, :soft, :hard].freeze

    # --- Host integration -----------------------------------------------------

    # The primary conversing model. Participants stay polymorphic regardless
    # (any `acts_as_messager` model can join a conversation); this is the
    # class the engine's controllers resolve `current_messager` against and
    # the default for docs/generators.
    attr_reader :messager_class

    # The controller the engine inherits from. Pointing this at the host's
    # `ApplicationController` (the default) gives the engine the host's
    # layout, helpers, `current_user`, locale switching, etc. — the same
    # pattern api_keys uses for its dashboard.
    attr_reader :parent_controller

    # Method called on the controller to fetch the current messager
    # (`:current_user` works with Devise out of the box).
    attr_accessor :current_messager_method

    # Method called as a `before_action` to require authentication
    # (`:authenticate_user!` works with Devise out of the box).
    attr_accessor :authenticate_method

    # Optional explicit layout for the engine's screens. `nil` (default)
    # inherits whatever layout the parent controller resolves — usually the
    # host's `application` layout. Set to e.g. `"app"` if your host renders
    # its logged-in surfaces with a different layout.
    attr_accessor :layout

    # --- Feature flags --------------------------------------------------------

    # Group conversations (3+ participants, a title, join/leave). Direct 1:1
    # conversations are always available.
    attr_accessor :groups

    # Emoji reactions on messages.
    attr_accessor :reactions

    # Read receipts ("Seen") + unread tracking. Read state is stored on the
    # participant (`last_read_at`), not per-message — see Chats::Participant
    # for the rationale.
    attr_accessor :read_receipts

    # Live "X is typing…" indicators (Turbo Stream custom action; no Action
    # Cable channel of its own, see Chats::ConversationsController#typing).
    attr_accessor :typing_indicators

    # Whether senders can edit their own messages after sending.
    attr_accessor :editing

    # What "delete" means: `:soft` keeps a tombstone ("message deleted", body
    # gone — the WhatsApp model, and the safest for Trust & Safety evidence),
    # `:hard` destroys the row, `false` disables deletion entirely.
    attr_reader :deletion

    # Message attachments: `false` (none), `:images` (images only — the
    # default), or `:any` (any content type). Backed by ActiveStorage's
    # `has_many_attached`, so the host must have ActiveStorage installed to
    # enable this.
    attr_reader :attachments

    # Inbox search box (partial matching across participant names, conversation
    # titles, subject labels, and message bodies — no extra dependencies; swap
    # in pg_search & friends by overriding the controller if you outgrow it).
    attr_accessor :search

    # --- Limits ---------------------------------------------------------------

    attr_accessor :messages_per_page, :max_message_length, :max_group_size, :max_attachment_size,
                  :max_attachments_per_message

    # Per-sender send throttle, enforced with Rails 8's built-in controller
    # `rate_limit` when available (feature-detected; on Rails 7.1 it's a
    # no-op). Shape: `{ to: Integer, within: ActiveSupport::Duration }`.
    # Set to `nil` to disable.
    attr_reader :send_rate_limit

    # Encrypt message bodies at rest with ActiveRecord Encryption
    # (`encrypts :body`). Requires the host to have AR encryption keys
    # configured (`bin/rails db:encryption:init`). Note: turning this on
    # makes message-body search degrade to title/participant matching.
    attr_accessor :encrypt_messages

    # --- Policies (procs) -----------------------------------------------------

    # Host authorization on top of block enforcement: may +sender+ open a
    # conversation with / send to +recipient+? Blocking is ALWAYS enforced
    # underneath this (see Chats.can_message?) so a permissive or buggy
    # policy can never let a blocked pair talk.
    attr_reader :can_message

    # May +creator+ create a group conversation?
    attr_reader :can_create_group

    # --- Ecosystem seams (procs, no-op defaults) ------------------------------

    # ->(messager) { ids } — every messager id that can't talk with the given
    # one (bidirectional). Wire to the moderate gem with one line:
    #   config.blocked_messager_ids = ->(user) { Moderate.blocked_ids_for(user) }
    attr_reader :blocked_messager_ids

    # ->(event, **payload) — domain-moment fan-out (see Chats.notify).
    attr_reader :notifier

    # --- Display procs (used by the bundled views) ----------------------------

    # ->(messager) { String } — how a messager is named in inboxes, bubbles
    # and typing indicators. The default tries the obvious candidates.
    attr_reader :messager_display_name

    # ->(messager) { url/attachment/nil } — an avatar for the messager.
    # Return anything `image_tag` accepts (a URL, an ActiveStorage attachment
    # or variant), or nil to render an initials placeholder.
    attr_reader :messager_avatar

    def initialize
      @messager_class = "User"
      @parent_controller = "::ApplicationController"
      @current_messager_method = :current_user
      @authenticate_method = :authenticate_user!
      @layout = nil

      @groups = true
      @reactions = true
      @read_receipts = true
      @typing_indicators = true
      @editing = true
      @deletion = :soft
      @attachments = :images
      @search = true

      @messages_per_page = 30
      @max_message_length = 5_000
      @max_group_size = 32
      @max_attachment_size = 10 * 1024 * 1024 # 10 MB
      @max_attachments_per_message = 4
      @send_rate_limit = { to: 60, within: 60 } # 60 messages per minute per sender

      @encrypt_messages = false

      @can_message = ->(_sender, _recipient) { true }
      @can_create_group = ->(_creator) { true }

      @blocked_messager_ids = ->(_messager) { [] }
      @notifier = ->(_event, **_payload) {}

      @messager_display_name = lambda do |messager|
        messager.try(:display_name) || messager.try(:name) ||
          messager.try(:full_name) || messager.try(:username) ||
          messager.try(:email) || "#{messager.class.model_name.human} #{messager.id}"
      end
      @messager_avatar = ->(messager) { messager.try(:avatar) }
    end

    # --- Validating setters ---------------------------------------------------
    #
    # Fail at boot with a plain-English message, not at 3am with a NoMethodError.

    def messager_class=(value)
      name = value.is_a?(Class) ? value.name : value.to_s
      raise ConfigurationError, "messager_class can't be blank" if name.strip.empty?

      @messager_class = name
    end

    def parent_controller=(value)
      name = value.is_a?(Class) ? value.name : value.to_s
      raise ConfigurationError, "parent_controller can't be blank" if name.strip.empty?

      @parent_controller = name
    end

    def attachments=(value)
      normalized = normalize_flag(value)
      unless ATTACHMENT_MODES.include?(normalized)
        raise ConfigurationError, "attachments must be one of #{ATTACHMENT_MODES.inspect}, got #{value.inspect}"
      end

      @attachments = normalized
    end

    def deletion=(value)
      normalized = normalize_flag(value)
      unless DELETION_MODES.include?(normalized)
        raise ConfigurationError, "deletion must be one of #{DELETION_MODES.inspect}, got #{value.inspect}"
      end

      @deletion = normalized
    end

    def send_rate_limit=(value)
      if value.nil?
        @send_rate_limit = nil
        return
      end

      hash = value.to_h.symbolize_keys
      unless hash[:to].is_a?(Integer) && hash[:to].positive? && hash[:within].respond_to?(:to_i)
        raise ConfigurationError,
              "send_rate_limit must be nil or { to: Integer, within: duration }, got #{value.inspect}"
      end

      @send_rate_limit = hash
    end

    def can_message=(value)
      @can_message = ensure_callable(value, "can_message")
    end

    def can_create_group=(value)
      @can_create_group = ensure_callable(value, "can_create_group")
    end

    def blocked_messager_ids=(value)
      @blocked_messager_ids = ensure_callable(value, "blocked_messager_ids")
    end

    def notifier=(value)
      @notifier = ensure_callable(value, "notifier")
    end

    def messager_display_name=(value)
      @messager_display_name = ensure_callable(value, "messager_display_name")
    end

    def messager_avatar=(value)
      @messager_avatar = ensure_callable(value, "messager_avatar")
    end

    # Cross-field validation, run at the end of `Chats.configure`.
    def validate!
      if max_message_length && max_message_length < 1
        raise ConfigurationError, "max_message_length must be positive (got #{max_message_length})"
      end

      if max_group_size && max_group_size < 3
        # 2 participants is a direct conversation; a "group" of 2 is a smell.
        raise ConfigurationError, "max_group_size must be at least 3 (got #{max_group_size})"
      end

      if messages_per_page.to_i < 1
        raise ConfigurationError, "messages_per_page must be positive (got #{messages_per_page.inspect})"
      end

      true
    end

    # The constantized messager class (resolved lazily — see class comment).
    def messager_model
      messager_class.constantize
    end

    private

    def normalize_flag(value)
      return value if value == false || value.nil?

      value.to_sym
    end

    def ensure_callable(value, name)
      unless value.respond_to?(:call)
        raise ConfigurationError, "#{name} must respond to #call (a proc/lambda), got #{value.inspect}"
      end

      value
    end
  end
end
