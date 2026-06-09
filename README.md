# 💬 `chats` - Real-time DMs and group chats for your Rails users

[![Gem Version](https://badge.fury.io/rb/chats.svg)](https://badge.fury.io/rb/chats) [![Build Status](https://github.com/rameerez/chats/workflows/Tests/badge.svg)](https://github.com/rameerez/chats/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=chats)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=chats)!

`chats` gives your Rails app **Instagram-class user-to-user messaging**: direct messages, group chats, image attachments, emoji reactions, read receipts, unread badges, and typing indicators — all real-time, all server-rendered.

It's **Hotwire-native**: messages stream live over Turbo Streams + Action Cable, the inbox refreshes itself with Turbo 8 morphing, and the only JavaScript is two tiny Stimulus controllers the gem ships and registers for you. No SPA, no build step, no custom WebSocket code — and everything degrades gracefully to plain request/response when WebSockets are down.

Every consumer app eventually needs DMs, and everyone rebuilds the same conversation/participant/message schema, the same Action Cable plumbing, and the same "report this message, block this user" story. `chats` is that whole rebuild, done once, done right.

## 👨‍💻 Example

`chats` reads like plain English:

```ruby
class User < ApplicationRecord
  acts_as_messager
end

alice.message!(bob, "hola!")              # DM in one line
alice.chat_with(bob)                       # ...or just open the conversation
alice.chat_with(bob, carol, title: "Trip") # groups
alice.unread_chats_count                   # for your nav badge
```

Conversations can be *about* things in your domain:

```ruby
class Ride < ApplicationRecord
  acts_as_chat_subject
end

passenger.message!(driver, "Can I bring a suitcase?", about: ride)
```

That `about:` gives you marketplace-style threading for free: one conversation per pair *per ride* — and the ride shows up as a context line in the inbox and the thread header.

## Quickstart

Add the gem:

```ruby
gem "chats"
```

Install it (creates the migration + an initializer):

```bash
bundle install
rails generate chats:install
rails db:migrate
```

Make your users conversational and mount the inbox:

```ruby
# app/models/user.rb
class User < ApplicationRecord
  acts_as_messager
end

# config/routes.rb
mount Chats::Engine => "/messages"
```

That's it. `/messages` is now a working, real-time inbox: threads, bubbles, reactions, read receipts, typing indicators. The engine inherits your `ApplicationController` (so your auth, layout, and locale apply automatically — Devise works out of the box), and its two Stimulus controllers register themselves through your existing importmap setup. Zero JavaScript changes.

Drop a "Message" button anywhere — it renders only when the viewer is allowed to message that person:

```erb
<%= chat_button_to @driver, about: @ride %>
```

And a live unread badge in your nav:

```erb
<%= chats_unread_badge %>
```

## What `chats` does (and doesn't) do

**Does:** direct 1:1 threads, group conversations, image (or any) attachments via ActiveStorage, emoji reactions, read receipts ("Seen"), unread counts and live badges, typing indicators, message editing, soft deletion (WhatsApp-style tombstones), system messages your app posts into threads, per-sender rate limiting, inbox search, infinite scroll-up pagination, optional encryption at rest, and small adapter seams for moderation + notifications.

**Doesn't:** chatbots/LLM agents, workspaces/tenancy, voice/video, public channels, federation. It's peer-to-peer (and group) human messaging — not a Slack clone, not a support-ticketing tool.

## 🧱 The data model

Five concepts, namespaced and polymorphic from day one (no hard `User` coupling anywhere):

- **`Chats::Conversation`** — `direct` or `group`, optionally *about* a polymorphic `subject` (a ride, an order, a listing). Denormalized `last_message_at` / `last_message_id` / `messages_count` so the inbox is one indexed query.
- **`Chats::Participant`** — a messager's seat in a conversation. Holds role, read horizon, mute, soft-leave, and notification bookkeeping.
- **`Chats::Message`** — `text` (human) or `system` (posted by your app). Soft-deletes to a tombstone. Attachments via ActiveStorage.
- **`Chats::Reaction`** — one row per (message, reactor, emoji); tap-to-toggle, race-safe.
- **Any model with `acts_as_messager`** — users, organizations, support agents: participants and senders are polymorphic.

Two deliberate design decisions worth knowing:

1. **Read state is a horizon, not per-message receipts.** A participant has ONE `last_read_at`; a message is unread iff it's newer. That's unread counts, badges, and "Seen" indicators with zero extra writes per message (a receipts table writes N rows per message — the classic chat-schema scaling trap), and it's exactly how Basecamp's Campfire models it.
2. **Direct conversations have a deterministic identity** (`direct_key`, unique-indexed): two people DMing each other in the same instant race into the SAME conversation, guaranteed by the database, not by hope.

## ⚡ Real-time, the Hotwire way

- **The thread** subscribes to one conversation stream. New messages append surgically; edits/deletes replace bubbles in place; the sender's own bubble comes straight back in the form response (no cable round-trip), and Turbo's same-id dedup makes the echo broadcast a no-op.
- **Bubbles are broadcast viewer-agnostic** — one render shared by every subscriber. A tiny Stimulus controller aligns own-vs-other client-side by comparing sender keys. This is what makes single-render broadcasts possible at all.
- **The inbox** receives Turbo 8 page *refreshes* (morphing, scroll-preserving) instead of surgically patched rows: inbox rows are intensely per-viewer (unread badges, bold states, ordering), so each client re-requests and gets a correct, personalized render. Refreshes are debounced and tagged so the tab that caused the change skips its own.
- **Unread badges** get their own stream (`chats_unread_badge` helper) so any page can host a live badge without inheriting inbox refreshes.
- **Typing indicators** are a Turbo Stream *custom action* — ephemeral, nothing persisted, no Action Cable channel class, no connection identification requirements.
- **Cable down?** Everything still works request/response. Real-time is an enhancement, not a requirement.

## 🛡️ Trust & Safety: snaps onto the [`moderate`](https://github.com/rameerez/moderate) gem

Messages are user-generated content. Instead of re-implementing report/block/filter, `chats` exposes the exact seams the `moderate` gem expects — wired with a few lines, with **no hard dependency** in either direction:

```ruby
# config/initializers/chats.rb
Chats.configure do |config|
  # Blocked pairs can't start conversations, can't send into existing ones,
  # and don't see each other's threads — enforced at creation, at every
  # write, and in every inbox query:
  config.blocked_messager_ids = ->(user) { Moderate.blocked_ids_for(user) }
end

# Make messages reportable + filterable (an after-boot hook so the macros
# re-apply on reload):
Rails.application.config.to_prepare do
  Chats::Message.has_reportable_content :body
  Chats::Message.moderates :body, mode: :flag   # never block someone mid-conversation
end

# config/initializers/moderate.rb
config.filter "Chats::Message", :body, mode: :flag
```

`Chats::Message` and `Chats::Conversation` already implement moderate's full reportable contract (`reported_owner`, `moderation_snapshot`, `remove_reported_field!`, `report_visible_to?`, …) as plain duck-typed methods — a moderator removing a reported message body becomes the same soft-delete tombstone users see. Only participants can report a message (it's not public content), and you can't report your own.

Block enforcement is **hardcoded beneath the policy layer**: a host overriding `can_message` can never accidentally let a blocked pair talk.

## 🔔 Notifications: one hook, fan out anywhere

`chats` fires domain moments through a single no-op-default notifier — it does **not** build its own notification bus:

```ruby
config.notifier = ->(event, **payload) {
  NewMessageNotifier.with(**payload).deliver if event == :message_created  # Noticed
}
```

The etiquette helpers every messaging product needs ship on the participant, so a debounced "email me only once until I come back" digest is a tiny host job:

```ruby
class ChatsUnreadEmailJob < ApplicationJob
  def perform(message)
    message.conversation.participants.active.each do |participant|
      next unless participant.notifiable_for?(message) # not the sender, not muted, not departed
      next unless participant.should_notify?           # unread + not already notified this burst

      ChatsMailer.with(participant: participant).unread_messages.deliver_now
      participant.mark_notified!
    end
  end
end

config.notifier = ->(event, message:, **) {
  ChatsUnreadEmailJob.set(wait: 10.minutes).perform_later(message) if event == :message_created
}
```

And it works in the other direction too — your app can post **into** conversations:

```ruby
ride.chat_conversations.find_each { |c| c.post_system_message!("Your ride was cancelled") }
```

## 🎨 Make it yours

The bundled UI is intentionally framework-free (semantic `chats-*` classes + one self-contained stylesheet, themed with CSS variables):

```css
:root {
  --chats-accent: #facc15;           /* own bubbles, send button, badges */
  --chats-accent-contrast: #111827;
}
```

Want full control? Eject the views Devise-style and restyle with your own stack (Tailwind classes added there get picked up by your build, since the files live in your `app/views`):

```bash
rails generate chats:views
```

Override the two Stimulus controllers by pinning the same importmap keys (`controllers/chats/thread_controller`, `controllers/chats/composer_controller`) — host pins win.

## Configuration reference

Everything lives in `config/initializers/chats.rb` (the install generator writes a fully-annotated version):

```ruby
Chats.configure do |config|
  config.messager_class = "User"

  # Controller integration (Devise-compatible defaults)
  config.parent_controller = "::ApplicationController"
  config.current_messager_method = :current_user
  config.authenticate_method = :authenticate_user!
  config.layout = nil                       # nil inherits the parent controller's

  # Features — all on by default
  config.groups = true
  config.reactions = true
  config.read_receipts = true
  config.typing_indicators = true
  config.editing = true
  config.deletion = :soft                   # :soft (tombstone) | :hard | false
  config.attachments = :images              # false | :images | :any
  config.search = true

  # Limits
  config.messages_per_page = 30
  config.max_message_length = 5_000
  config.max_group_size = 32
  config.max_attachment_size = 10.megabytes
  config.max_attachments_per_message = 4
  config.send_rate_limit = { to: 60, within: 1.minute }  # Rails 8 rate_limit; nil disables
  config.encrypt_messages = false           # ActiveRecord Encryption on bodies

  # Policies (on top of — never instead of — block enforcement)
  config.can_message = ->(sender, recipient) { true }
  config.can_create_group = ->(creator) { true }

  # Ecosystem seams (no-op defaults; chats runs standalone)
  config.blocked_messager_ids = ->(messager) { [] }
  config.notifier = ->(event, **payload) {}

  # Display (used by the bundled views)
  config.messager_display_name = ->(messager) { messager.display_name }
  config.messager_avatar = ->(messager) { messager.avatar }  # URL/attachment/variant or nil
end
```

## 🤓 The full Ruby API

```ruby
# Messagers
alice.chat_with(bob)                          # find-or-create the DM
alice.chat_with(bob, about: ride)             # the DM about that ride
alice.chat_with(bob, carol, title: "Trip")    # a group (alice is owner)
alice.message!(bob, "hi", about: ride)        # send (resolves the thread)
alice.message!(conversation, "hi", files: []) # send into a conversation
alice.chats                                   # inbox relation, newest first
alice.unread_chats_count                      # conversations with unread messages

# Conversations
conversation.participant?(user)               # active membership
conversation.other_participants(user)
conversation.title_for(viewer)                # counterpart name / group title
conversation.subject_label                    # "Madrid → Barcelona"
conversation.unread_count_for(user)
conversation.mark_read_by!(user)
conversation.post_system_message!("Ride cancelled")
conversation.add_participant!(user)           # idempotent, race-safe

# Messages
message.edit!("fixed")                        # stamps edited_at
message.soft_delete!                          # tombstone (or destroy, per config)
message.read_by?(user)
Chats::Reaction.toggle!(message:, reactor:, emoji: "👍")

# Participants (the per-member state)
participant.read!                             # advance the read horizon
participant.mute! / participant.unmute!
participant.leave!                            # groups
participant.notifiable_for?(message)          # notification etiquette
participant.should_notify? / participant.mark_notified!
```

Errors are namespaced and meaningful: `Chats::BlockedError`, `Chats::NotAllowedError`, `Chats::ConfigurationError` — all under `Chats::Error`.

## Database support

PostgreSQL, MySQL, and SQLite. The migration adapts automatically: it honors your app's configured primary key type (**uuid or bigint** — same detection `rails g model` uses), picks `jsonb` on Postgres / `json` elsewhere, and handles MySQL's no-defaults-on-JSON rule. Works on Rails 7.1+ and shines on the Rails 8 omakase.

## Testing

The gem is tested with Minitest against a real dummy host app — models, broadcasts (over the Action Cable test adapter), full request cycles, generators, and every authorization negative (outsiders, leavers, and blocked pairs all get plain 404s; existence never leaks).

```bash
bundle exec rake test            # full suite
bundle exec appraisal install    # then test across Rails versions:
bundle exec appraisal rails-7.1 rake test
bundle exec appraisal rails-8.1 rake test
```

## Development

After checking out the repo, run `bundle install`, then `bundle exec rake test`. The dummy app lives in `test/dummy` and mounts the engine at `/messages` exactly like a real host.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rameerez/chats. Our code of conduct is: just be nice and make your mom proud of what you do and post online.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
