# 💬 `chats` - Add user-to-user DMs & group chats to your Rails app

[![Gem Version](https://badge.fury.io/rb/chats.svg)](https://badge.fury.io/rb/chats) [![Build Status](https://github.com/rameerez/chats/workflows/Tests/badge.svg)](https://github.com/rameerez/chats/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=chats)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=chats)!

`chats` gives your Rails app **Instagram-class user-to-user messaging**: direct messages, group chats, image attachments, emoji reactions, read receipts, unread badges, and typing indicators — all real-time, all server-rendered.

It's **Hotwire-native**: messages stream live over Turbo Streams + Action Cable, the inbox refreshes itself with Turbo 8 morphing, and the only JavaScript is a few tiny Stimulus controllers the gem ships and registers for you. No SPA, no build step, no custom WebSocket code — and everything degrades gracefully to plain request/response when WebSockets are down. Both the thread and the inbox self-heal after a missed broadcast (cable reconnect / return-to-visible), so a client that slept through a WebSocket drop still catches up.

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

That's it. `/messages` is now a working, real-time inbox: threads, bubbles, reactions, read receipts, typing indicators. The engine inherits your `ApplicationController` (so your auth, layout, and locale apply automatically — Devise works out of the box), and its bundled Stimulus controllers register themselves through your existing importmap setup. Zero JavaScript changes.

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

Messages are user-generated content — App Store Guideline 1.2, Google Play's UGC policy, and the EU DSA all expect **report**, **block**, and **filter** capabilities before you ship a chat. Instead of re-implementing any of that, `chats` exposes the exact seams the `moderate` gem expects, with **no hard dependency in either direction**: each gem runs standalone, and together they behave like one system. This section is the complete recipe.

### 1. One line of blocking

```ruby
# config/initializers/chats.rb
Chats.configure do |config|
  config.blocked_messager_ids = ->(user) { Moderate.blocked_ids_for(user) }
end
```

That single hook makes moderate's bidirectional block table the law everywhere chats makes a decision:

- a blocked pair **can't open** a conversation (`Chats::BlockedError`),
- **can't send** into an existing one (a block placed mid-conversation stops the very next message),
- and **stop seeing** each other's direct threads in the inbox and unread counts — *hidden, never deleted*: lift the block and the history reappears.

Two semantics worth knowing: blocking is enforced **beneath** your `can_message` policy (a permissive or buggy policy can never let a blocked pair talk), and **group conversations are exempt from pair blocks** — the industry standard: blocking someone removes your private line, not your seat in shared spaces. If your domain should eject blocked members from groups, do it in moderate's `on_block` hook by tearing down whatever domain relationship feeds the group membership.

### 2. Reportable + filtered messages

```ruby
# An after-boot hook (config.to_prepare) so the macros re-apply on every reload:
Rails.application.config.to_prepare do
  Chats::Message.has_reportable_content :body, :files
  Chats::Message.moderates :body, mode: :flag    # text → built-in wordlist
  Chats::Message.moderates :files, mode: :flag, with: :your_image_adapter
end

# config/initializers/moderate.rb — the central policy registry:
config.filter "Chats::Message", :body, mode: :flag
config.filter "Chats::Message", :files, mode: :flag, with: :your_image_adapter
```

Use **`:flag`, never `:block`** for chat: you don't gag someone mid-conversation on a wordlist false positive. The message sends; a pending `Moderate::Flag` lands in the moderation queue for human (or ML) review.

`Chats::Message` and `Chats::Conversation` already implement moderate's full duck-typed reportable contract, so everything downstream just works:

| moderate calls… | chats answers… |
|---|---|
| `reported_owner` | the sender (who a decision notifies, who a ban targets) |
| `moderation_snapshot(:body)` | the body — frozen as evidence at report time, surviving later edits/deletes |
| `remove_reported_field!(:body)` | the **soft-delete tombstone** — a moderator's removal looks exactly like a user deletion ("Message deleted"), no special admin rendering path |
| `report_visible_to?(viewer)` | participants only (a DM isn't public content), and never the author |
| `moderation_field_value(:files)` / change detection | attachment-aware seams so image filters classify what actually changed |

### 3. The report affordance — mind the broadcast

Put a report link on every bubble **someone else** sent. One nuance matters: `chats` renders each bubble **once per broadcast, viewer-agnostically** (that's what makes real-time fan-out cheap), so anything depending on `current_user` at render time — like moderate's `report_link` helper, which checks `report_visible_to?(viewer)` — would silently vanish from live-appended bubbles. Use the **signed-target URL** instead (viewer-independent), and hide it on own bubbles with the same client-side mechanism the gem uses for edit/delete:

```erb
<%# in your ejected chats/messages/_message.html.erb, inside the actions row %>
<% if message.sender %>
  <%= link_to "Report",
        main_app.new_abuse_report_path(
          target: message.to_sgid_param(for: Moderate::Report::SIGNED_GLOBAL_ID_PURPOSE),
          field: "body"
        ),
        class: "chats-message__action in-own-hidden" %>
        <%# hide on .chats-message--own via your CSS; moderate's controller
            re-checks report_visible_to? server-side, so hiding is cosmetic %>
<% end %>
```

And give direct threads a **block** action in the thread menu (your ejected `show.html.erb`) pointing at your moderate-backed blocks endpoint. One UX trap: blocking hides the very thread the user is standing in — redirect to the inbox, not back.

### 4. The admin side

Reported and auto-flagged chat messages flow into moderate's standard queues (`Moderate::Report` / `Moderate::Flag` are polymorphic) with **zero chat-specific case statements**: resolving a report with content removal calls `remove_reported_field!` → the tombstone; banning goes through your configured `ban_handler`. For browsing context, point your admin tool at `Chats::Conversation` / `Chats::Message` read-only — and if you want a "flag this while browsing" affordance, file a manual flag and jump to its queue page rather than growing enforcement buttons on the browse surface:

```ruby
Moderate::Flag.flag!(
  flaggable: message, field: "body", owner: message.reported_owner,
  source: "manual", mode: "flag",
  excerpt: message.body.to_s.truncate(500),
  categories: ["manual_review"], scores: {}, context: { flagged_by_admin_id: admin.id }
)
```

### 5. Did you wire it all? The launch checklist

- [ ] `blocked_messager_ids` → `Moderate.blocked_ids_for`
- [ ] `Chats::Message` reportable (`:body`, and `:files` if attachments are on)
- [ ] body + files filter policies in `:flag` mode
- [ ] report link on foreign bubbles (signed target, broadcast-safe)
- [ ] block action on direct threads (redirecting away from the hidden thread)
- [ ] admin queue handles chat flags/reports (it does, automatically — verify with one test)
- [ ] a test that a block placed mid-conversation stops the next send

## 🔔 Events: subscribe to the domain moments

`chats` fires domain moments at subscribers — it does **not** build its own notification bus:

```ruby
# config/initializers/chats.rb (or anywhere that runs at boot)
Chats.on(:message_created)      { |message| NewMessageNotifier.with(record: message).deliver }
Chats.on(:conversation_created) { |conversation| Analytics.track("chat_started", conversation) }
Chats.on(:participant_left)     { |participant| AuditLog.log("chat_left", participant) }
Chats.on(:conversation_read)    { |conversation:, participant:| Bell.mark_read(participant.messager, conversation) }
```

Four properties, all of which matter the first time something goes wrong at 3am:

- **Many subscribers per event.** Your mailer, your analytics and your audit log don't have to share one `case` statement.
- **Each one is isolated.** A raising subscriber is reported through `Rails.error.report(e, handled: true, context: { event: })` — *visible*, not swallowed — and the next subscriber still runs. The message is already committed; notifications are best-effort fan-out.
- **Reload-safe.** Registering from reloadable code? Pass a key and a reload replaces the subscriber instead of stacking a second one:

  ```ruby
  Rails.application.config.to_prepare do
    Chats.on(:message_created, key: :unread_email) { |message| … }
  end
  ```
- **Unknown events fail loudly**, at boot, naming the ones that exist.

> **Deprecated:** `config.notifier = ->(event, **payload) {}` still works (it subscribes one proc to every event) and will be removed in 1.0. Move it to `Chats.on` — that's the whole migration.

The etiquette helpers every messaging product needs ship on the participant, so a debounced "email me only once until I come back" digest is a tiny host job:

```ruby
class ChatsUnreadEmailJob < ApplicationJob
  def perform(message)
    message.conversation.participants.active.each do |participant|
      next unless participant.notifiable_for?(message) # not the sender, not muted, not departed, not headless
      next unless participant.should_notify?           # unread + not already notified this burst

      ChatsMailer.with(participant: participant).unread_messages.deliver_now
      participant.mark_notified!
    end
  end
end

Chats.on(:message_created) { |message| ChatsUnreadEmailJob.set(wait: 10.minutes).perform_later(message) }
```

And it works in the other direction too — your app can post **into** conversations:

```ruby
ride.chat_conversations.find_each { |c| c.post_system_message!("Your ride was cancelled") }
```

## 🤖 Headless messagers: desks, bots, storefronts

Not every messager is a person. A support desk, an order bot or an organization mailbox converses like anyone else but must never be notified, can't meaningfully be blocked, and shouldn't fill the inbox with one row per thread. Say so once, on the model:

```ruby
class SupportDesk < ApplicationRecord
  acts_as_messager notifications: false,   # Participant#notifiable_for? says no, always
                   blockable:     false,   # the views hide block/report affordances
                   inbox:         :grouped # every thread with it is ONE inbox row
end
```

That's the whole point of the option: **your notifiers and views stop asking `is_a?(User)`**. The predicates are on the class (`SupportDesk.chat_notifications?`, `.chat_blockable?`, `.chat_inbox_mode`) and duck-typed everywhere the gem reads them, so an ordinary `acts_as_messager` model behaves exactly as it always did.

## 🗂️ Grouped inbox rows

With `inbox: :grouped`, every direct conversation a viewer has with that messager folds into a single inbox row — a stack:

```ruby
inbox = Chats::Inbox.for(current_user)   # [Chats::Conversation | Chats::InboxGroup], newest activity first
inbox.unread_count                       # the stack-aware badge number

group = inbox.rows.first
group.messager       # the desk
group.conversations  # the stacked threads, freshest first
group.unread_count   # aggregated across the stack
group.open_count     # how many are in it
```

- Grouping happens in **one place** (`Chats::Inbox`), folded out of the already-limited relation plus one grouped unread-count query — so stacking never turns the inbox into an N+1 and pagination stays honest.
- A stack of one links **straight to the thread**, which then carries a small "see all" link back to the stack.
- The stack list is chats' own filtered inbox — `GET /conversations?with=<signed gid>` — unless you point it somewhere else with `group_path: ->(viewer) { support_path }`.
- Two knobs shape the whole query: `config.inbox_limit` (200) and `config.inbox_scope = ->(relation, viewer) { relation }`.

`user.unread_chats_count` is unchanged (it counts conversations); `Chats::Inbox#unread_count` is the stack-aware number for badges.

## 🔒 Locked conversations

Whether a conversation still takes messages belongs to the thing it's **about** — a closed ticket, a delivered order, an archived listing. The subject already owns the conversation's meaning; it owns its openness too:

```ruby
class Ticket < ApplicationRecord
  acts_as_chat_subject

  def chat_locked?       = closed?
  def chat_locked_notice = "This ticket is closed. Reply to reopen it."
end
```

- `Chats::Message` refuses new messages with an `:locked` error; `Conversation#locked?` and `#locked_notice` read the subject.
- **System messages are exempt**: your app can always post "This ticket was closed" into the thread it just closed.
- The thread **stays readable**. Only the composer changes: it's replaced by the notice (the `locked_composer` slot overrides the body). Gate the action, never hide the explanation.
- A send that lands on a conversation locked since the page loaded gets a **422 that swaps the composer for the notice** — no raise, no lying screen.

## ✍️ Signed messages

`sender` is the seat a message came from; `author` is who **wrote** it on that seat's behalf. That's how a shared desk answers as itself while the human stays visible:

```ruby
desk.message!(alice, "On it!", author: lucia)   # sender: the desk, author: Lucía
message.signed?          # true — author present and not the sender
message.authored_by?(lucia)
```

The bundled bubble renders a signature line ("— Lucía G.") via `Chats.display_name_for`; `config.message_signature = ->(message) { … }` rewrites it. Ordinary messages have no author and render exactly as before.

Existing installs get the columns with one command:

```bash
rails generate chats:upgrade && rails db:migrate
```

## 🔌 View slots

Ejecting a whole screen to add one row or one button is too coarse. The bundled views render a partial named `chats/slots/_<slot>` **when it exists** — no configuration, no registration, and an absent slot costs one memoized lookup:

| slot | where it renders |
|---|---|
| `inbox_top` | above the first inbox row |
| `inbox_empty` | inside the empty state |
| `conversation_header_actions` | the thread's menu (gets `blockable:`) |
| `locked_composer` | the locked composer's body |
| `message_meta` | after each bubble's timestamp |

```erb
<%# app/views/chats/slots/_inbox_top.html.erb %>
<%= link_to "Need help? Write to us", support_path, class: "support-door" %>
```

An engine mounted on top of chats ships its own `app/views/chats/slots/…`; the host's file wins by view-path order. `rails generate chats:views` is still there for wholesale restyling.

## 🔗 Profile links

`chats` never assumes your app has a `user_path`. Tell it where a messager lives and names become links; leave it alone and they render as plain text:

```ruby
config.messager_url = ->(messager) { messager.is_a?(User) ? user_path(messager) : nil }
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

Override any bundled Stimulus controller by pinning the same importmap key — host pins win. The current keys are `controllers/chats/thread_controller`, `controllers/chats/composer_controller`, `controllers/chats/debounced_submit_controller`, and `controllers/chats/refresh_inbox_controller`.

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

  # Inbox shaping
  config.inbox_limit = 200
  config.inbox_scope = ->(relation, viewer) { relation }

  # Ecosystem seams (no-op defaults; chats runs standalone)
  config.blocked_messager_ids = ->(messager) { [] }
  config.notifier = ->(event, **payload) {}   # DEPRECATED — use Chats.on

  # Display (used by the bundled views)
  config.messager_display_name = ->(messager) { messager.display_name }
  config.messager_avatar = ->(messager) { messager.avatar }  # URL/attachment/variant or nil
  config.messager_url = ->(messager) { nil }                 # nil ⇒ names render as plain text
  config.message_signature = nil                             # ->(message) { } for signed bubbles
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
alice.message!(bob, "hi", author: lucia)      # written by lucia, sent from alice's seat
Chats::Inbox.for(alice)                       # [Conversation | InboxGroup] + #unread_count

# Conversations
conversation.participant?(user)               # active membership
conversation.other_participants(user)
conversation.title_for(viewer)                # counterpart name / group title
conversation.subject_label                    # "Madrid → Barcelona"
conversation.unread_count_for(user)
conversation.mark_read_by!(user)
conversation.post_system_message!("Ride cancelled")
conversation.add_participant!(user)           # idempotent, race-safe
conversation.locked?                          # the SUBJECT decides (chat_locked?)
conversation.locked_notice                    # why, in words

# Messages
message.edit!("fixed")                        # stamps edited_at
message.soft_delete!                          # tombstone (or destroy, per config)
message.read_by?(user)
message.signed? / message.authored_by?(lucia) # authorship
Chats::Reaction.toggle!(message:, reactor:, emoji: "👍")

# Participants (the per-member state)
participant.read!                             # advance the read horizon
participant.mute! / participant.unmute!
participant.leave!                            # groups
participant.notifiable_for?(message)          # notification etiquette
participant.should_notify? / participant.mark_notified!
participant.reseat!(new_messager)             # hand the seat over, read horizon intact

# Events
Chats.on(:message_created) { |message| }      # also :conversation_created,
                                              # :participant_left, :conversation_read
```

Errors are namespaced and meaningful: `Chats::BlockedError`, `Chats::NotAllowedError`, `Chats::ConfigurationError` — all under `Chats::Error`.

## Upgrading

`chats` ships the migrations a version bump needs; your initializer and views stay yours:

```bash
rails generate chats:upgrade   # 0.2.0: message authorship columns
rails db:migrate
```

Nothing in 0.2.0 changes behaviour until you set an option — see the [CHANGELOG](CHANGELOG.md).

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
