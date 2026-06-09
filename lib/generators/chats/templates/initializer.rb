# frozen_string_literal: true

Chats.configure do |config|
  # ==========================================================================
  # WHO CONVERSES?
  # ==========================================================================
  #
  # The model that opens conversations and sends messages — the one with
  # `acts_as_messager`. Participants are polymorphic, so OTHER models with
  # `acts_as_messager` can join conversations too; this names the primary one
  # the engine's controllers resolve against. Stored as a string and resolved
  # lazily, so it works no matter when your app boots.
  #
  # Default: "User"
  config.messager_class = "User"

  # ==========================================================================
  # CONTROLLER INTEGRATION
  # ==========================================================================
  #
  # The engine inherits from your controller, so your layout, helpers, locale
  # switching, and auth all apply to the chat screens automatically.
  #
  # config.parent_controller = "::ApplicationController"
  #
  # How the engine finds the current messager and requires login. The
  # defaults work with Devise out of the box.
  #
  # config.current_messager_method = :current_user
  # config.authenticate_method = :authenticate_user!
  #
  # Render the chat screens with a specific layout (nil inherits whatever
  # your parent controller uses):
  #
  # config.layout = "application"

  # ==========================================================================
  # FEATURES — everything on by default; switch off what you don't want
  # ==========================================================================
  #
  # config.groups = true              # group conversations (3+ people)
  # config.reactions = true           # emoji reactions on messages
  # config.read_receipts = true       # "Seen" + unread tracking
  # config.typing_indicators = true   # live "X is typing…"
  # config.editing = true             # senders can edit their messages
  # config.deletion = :soft           # :soft (tombstone) | :hard | false
  # config.attachments = :images      # false | :images | :any (ActiveStorage)
  # config.search = true              # inbox search box

  # ==========================================================================
  # LIMITS
  # ==========================================================================
  #
  # config.messages_per_page = 30
  # config.max_message_length = 5_000
  # config.max_group_size = 32
  # config.max_attachment_size = 10.megabytes
  # config.max_attachments_per_message = 4
  #
  # Per-sender send throttle (enforced with Rails 8's controller rate_limit;
  # a no-op on Rails 7.x). Set to nil to disable.
  #
  # config.send_rate_limit = { to: 60, within: 1.minute }
  #
  # Encrypt message bodies at rest (ActiveRecord Encryption; requires
  # `bin/rails db:encryption:init`). Body search degrades when enabled.
  #
  # config.encrypt_messages = false

  # ==========================================================================
  # POLICIES — who may talk to whom
  # ==========================================================================
  #
  # Runs ON TOP of block enforcement (a blocked pair can never talk, no
  # matter what this returns). Default: anyone can message anyone — scope it
  # to your domain, e.g. "only people who share an accepted ride":
  #
  # config.can_message = ->(sender, recipient) {
  #   sender.shares_a_ride_with?(recipient)
  # }
  #
  # config.can_create_group = ->(creator) { creator.admin? }

  # ==========================================================================
  # TRUST & SAFETY — snap onto the `moderate` gem (or anything else)
  # ==========================================================================
  #
  # One line wires bidirectional block enforcement into conversation
  # creation, message sends, inbox visibility, and unread counts:
  #
  # config.blocked_messager_ids = ->(user) { Moderate.blocked_ids_for(user) }
  #
  # To also make messages reportable and filtered, declare it where you
  # configure moderate (an after-boot hook so model macros apply on reload):
  #
  # Rails.application.config.to_prepare do
  #   Chats::Message.has_reportable_content :body
  #   Chats::Message.moderates :body, mode: :flag   # never block mid-conversation
  # end
  #
  # …and register the filter policy in config/initializers/moderate.rb:
  #
  # config.filter "Chats::Message", :body, mode: :flag

  # ==========================================================================
  # NOTIFICATIONS — one hook, fan out anywhere
  # ==========================================================================
  #
  # Called on notification-worthy domain moments. Keep it fast (enqueue jobs,
  # don't do work inline). Events:
  #
  #   :message_created    message:      every persisted human message
  #   :participant_added  participant:  someone added to a group
  #
  # With Noticed:
  #   config.notifier = ->(event, **payload) {
  #     NewMessageNotifier.with(**payload).deliver if event == :message_created
  #   }
  #
  # With a plain debounced-email job (see Chats::Participant#should_notify?
  # for the "only email once until they come back" etiquette helper):
  #   config.notifier = ->(event, message:, **) {
  #     ChatsUnreadEmailJob.set(wait: 10.minutes).perform_later(message) if event == :message_created
  #   }

  # ==========================================================================
  # DISPLAY — how messagers appear in the bundled views
  # ==========================================================================
  #
  # config.messager_display_name = ->(messager) { messager.display_name }
  #
  # Return anything image_tag accepts (URL, ActiveStorage attachment or
  # variant), or nil for an initials placeholder:
  #
  # config.messager_avatar = ->(messager) {
  #   messager.avatar.attached? ? messager.avatar.variant(:thumb) : nil
  # }
end
