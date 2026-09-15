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

  # Any model can converse, and a model that isn't a person can say so:
  #
  #   class SupportDesk < ApplicationRecord
  #     acts_as_messager notifications: false,   # never notifiable
  #                      blockable:     false,   # no block/report affordances
  #                      inbox:         :grouped # every thread with it is ONE
  #                                              # inbox row (a "stack")
  #   end
  #
  # `group_path:` says where that stacked row goes when it holds more than
  # one conversation (default: chats' own filtered inbox):
  #
  #   acts_as_messager inbox: :grouped, group_path: ->(viewer) { support_path }

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
  # How many conversations the inbox loads (and therefore how deep search
  # and stacking see). The inbox is a "recent activity" surface, not an
  # archive.
  #
  # config.inbox_limit = 200
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
  #
  # Composed into the inbox query before the limit — hide rows, re-scope
  # them, whatever your product needs, without overriding the controller:
  #
  # config.inbox_scope = ->(relation, viewer) { relation }
  #
  # Whether a conversation still accepts messages is NOT a proc: the SUBJECT
  # owns it, because the subject already owns the conversation's meaning.
  #
  #   class Ticket < ApplicationRecord
  #     acts_as_chat_subject
  #     def chat_locked?       = closed?
  #     def chat_locked_notice = "This ticket is closed. Reply to reopen it."
  #   end
  #
  # Locking gates SENDING only: the thread stays readable and the composer
  # is replaced by the notice (see the `locked_composer` slot below).

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
  # EVENTS — subscribe to the domain moments, fan out anywhere
  # ==========================================================================
  #
  # Many subscribers per event; each runs isolated (a raising one is reported
  # through Rails.error and never breaks message delivery). Keep them fast —
  # enqueue jobs, don't do work inline.
  #
  #   Chats.on(:message_created)      { |message| }       # every human message
  #   Chats.on(:conversation_created) { |conversation| }  # a thread came into being
  #   Chats.on(:participant_left)     { |participant| }   # someone left a group
  #   Chats.on(:conversation_read)    { |conversation:, participant:| }
  #
  # With Noticed:
  #   Chats.on(:message_created) { |message| NewMessageNotifier.with(record: message).deliver }
  #
  # With a debounced-email job (see Chats::Participant#should_notify? for the
  # "only email once until they come back" etiquette helper):
  #   Chats.on(:message_created) { |message| ChatsUnreadEmailJob.set(wait: 10.minutes).perform_later(message) }
  #
  # Registering from reloadable code? Pass a key, and a reload replaces the
  # subscriber instead of stacking a second one:
  #
  #   Rails.application.config.to_prepare do
  #     Chats.on(:message_created, key: :unread_email) { |message| … }
  #   end
  #
  # DEPRECATED (removed in 1.0): `config.notifier = ->(event, **payload) {}`
  # still works and receives every event.

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
  #
  # Where a messager's profile lives. nil (the default) means the bundled
  # views render names as plain text — chats never assumes you have a
  # `user_path`, and never renders a dead anchor:
  #
  # config.messager_url = ->(messager) { Rails.application.routes.url_helpers.user_path(messager) }
  #
  # The signature under a message written by an AUTHOR on a sender's behalf
  # (`desk.message!(user, "On it!", author: agent)`). Defaults to the
  # localized "— Agent Name":
  #
  # config.message_signature = ->(message) { "answered by #{message.author.first_name}" }

  # ==========================================================================
  # SLOTS — add one row or one button without ejecting a screen
  # ==========================================================================
  #
  # The bundled views render a partial named `chats/slots/_<slot>` whenever
  # one exists in your app. No configuration, no registration: create the
  # file and it appears.
  #
  #   app/views/chats/slots/_inbox_top.html.erb                 above the first inbox row
  #   app/views/chats/slots/_inbox_empty.html.erb               inside the empty state
  #   app/views/chats/slots/_conversation_header_actions.html.erb  thread menu
  #   app/views/chats/slots/_locked_composer.html.erb           the locked composer's body
  #   app/views/chats/slots/_message_meta.html.erb              after each bubble's timestamp
  #
  # `rails generate chats:views` is still there for wholesale restyling.
end
