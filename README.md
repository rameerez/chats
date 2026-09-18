# 💬 `chats` - Add user-to-user DMs & group chats to your Rails app

[![Gem Version](https://badge.fury.io/rb/chats.svg)](https://badge.fury.io/rb/chats) [![Build Status](https://github.com/rameerez/chats/workflows/Tests/badge.svg)](https://github.com/rameerez/chats/actions)

> [!TIP]
> **🚀 Ship your next Rails app 10x faster!** I've built **[RailsFast](https://railsfast.com/?ref=chats)**, a production-ready Rails boilerplate template that comes with everything you need to launch a software business in days, not weeks. Go [check it out](https://railsfast.com/?ref=chats)!

`chats` gives your Rails app **Instagram-class user-to-user messaging**: direct messages, group chats, image attachments, emoji reactions, read receipts, unread badges, and typing indicators — all real-time, all server-rendered.

It's **Hotwire-native**: messages stream live over Turbo Streams + Action Cable, the inbox refreshes itself with Turbo 8 morphing, and the only JavaScript is a few tiny Stimulus controllers the gem ships and registers for you. No SPA, no build step, no custom WebSocket code — and everything degrades gracefully to plain request/response when WebSockets are down. Both the thread and the inbox self-heal after a missed broadcast (cable reconnect / return-to-visible), so a client that slept through a WebSocket drop still catches up.

Every consumer app eventually needs DMs, and everyone rebuilds the same conversation/participant/message schema, the same Action Cable plumbing, and the same "report this message, block this user" story. `chats` is that whole rebuild, done once, done right.

**Contents:** [Example](#-example) · [Quickstart](#quickstart) · [Data model](#-the-data-model) · [The macros](#-the-macros) · [Real-time](#-real-time-the-hotwire-way) · [Trust & Safety](#%EF%B8%8F-trust--safety-snaps-onto-the-moderate-gem) · [Events](#-events-subscribe-to-the-domain-moments) · [Headless messagers](#-headless-messagers-desks-bots-storefronts) · [Official accounts](#-official-accounts-the-verified-badge) · [Grouped inbox](#%EF%B8%8F-grouped-inbox-rows) · [Locked conversations](#-locked-conversations) · [Signed messages](#%EF%B8%8F-signed-messages) · [View slots](#-view-slots) · [Profile links](#-profile-links) · [Theming](#-make-it-yours) · [Configuration reference](#configuration-reference) · [The full Ruby API](#-the-full-ruby-api) · [View helpers](#-view-helpers) · [Errors](#errors) · [Locales](#locales) · [Upgrading](#upgrading) · [Testing](#testing)

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

> [!NOTE]
> **Want customer support?** Ticketing stays out of `chats` on purpose — queues, assignment and SLAs are not messaging. [`support_desk`](https://github.com/rameerez/support_desk) is the product gem that adds them ON TOP of this one: tickets that are real conversations, a support desk that sends while your staff sign, and a BYOUI agent console. It uses the seams below (headless messagers, subject locks, message authorship, grouped inbox rows), so you get the same threads, attachments and read state you already have.

## 🧱 The data model

Five concepts, namespaced and polymorphic from day one (no hard `User` coupling anywhere):

- **`Chats::Conversation`** — `direct` or `group`, optionally *about* a polymorphic `subject` (a ride, an order, a listing). Denormalized `last_message_at` / `last_message_id` / `messages_count` so the inbox is one indexed query.
- **`Chats::Participant`** — a messager's seat in a conversation. Holds role, read horizon, mute, soft-leave, and notification bookkeeping.
- **`Chats::Message`** — `text` (human) or `system` (posted by your app). Soft-deletes to a tombstone. Attachments via ActiveStorage.
- **`Chats::Reaction`** — one row per (message, reactor, emoji); tap-to-toggle, race-safe.
- **Any model with `acts_as_messager`** — users, organizations, support desks, bots: participants and senders are polymorphic. A messager that is not a person declares it (`notifications: false, blockable: false, inbox: :grouped`) and the gem stops treating it like one; an official one (`verified: true`) gets the badge everywhere its name appears. See [`support_desk`](https://github.com/rameerez/support_desk) for the worked example.

Two deliberate design decisions worth knowing:

1. **Read state is a horizon, not per-message receipts.** A participant has ONE `last_read_at`; a message is unread iff it's newer. That's unread counts, badges, and "Seen" indicators with zero extra writes per message (a receipts table writes N rows per message — the classic chat-schema scaling trap), and it's exactly how Basecamp's Campfire models it.
2. **Direct conversations have a deterministic identity** (`direct_key`, unique-indexed): two people DMing each other in the same instant race into the SAME conversation, guaranteed by the database, not by hope.

## 🧩 The macros

### `acts_as_messager(notifications: true, blockable: true, inbox: :default, group_path: nil, verified: false)`

Anyone (or anything) that can hold a seat in a conversation. Every option is a
class-level fact the gem reads duck-typed, so an ordinary model behaves exactly
as before and nothing asks `is_a?(User)`:

| option | default | what it means |
|---|---|---|
| `notifications:` | `true` | `false` for a headless seat: `Participant#notifiable_for?` is never true for it, and `Chats.notifications_for?(messager)` says so |
| `blockable:` | `true` | `false` hides block/report affordances against it and makes `Chats.blockable?(messager)` false |
| `inbox:` | `:default` | `:grouped` folds every direct thread with this messager into ONE inbox row (`Chats::InboxGroup`) |
| `group_path:` | `nil` | `->(viewer) { path }` — where a deep stack opens; default is chats' own filtered inbox |
| `verified:` | `false` | the official-account badge wherever the name renders; refuses to coerce (`"false"` raises at boot) |

Class predicates: `Klass.chat_notifications?`, `.chat_blockable?`, `.chat_inbox_mode`,
`.chat_group_path`, `.chat_verified?`. Instance API below.

### `acts_as_chat_subject`

A domain record conversations can be *about*. Adds `chat_conversations` (`has_many`)
and three overridable readers — the contract a product built on chats (a ticket, an
order) implements:

```ruby
class Ticket < ApplicationRecord
  acts_as_chat_subject

  def chat_subject_label = "Ticket #{reference}"        # the context line in inbox rows and the thread header
  def chat_locked?       = closed?                       # whether the conversation still takes messages
  def chat_locked_notice = "This ticket is closed."      # what replaces the composer when it doesn't
end
```

All three are inert by default (the label falls back to the record's `to_s`, nothing is locked).

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

| event | block arguments | when |
|---|---|---|
| `:message_created` | `message` | after a **text** message commits (system messages never notify) |
| `:conversation_created` | `conversation` | once per conversation, never when an existing one is resumed |
| `:participant_left` | `participant` | someone left a group |
| `:conversation_read` | `conversation:, participant:` | a read advanced the horizon past unread content |


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

> **Deprecated:** `config.notifier = ->(event, **payload) {}` still works and will be removed in 1.0. It receives `:message_created` and `:conversation_read` — the two events that existed in 0.1.1 — and *only* those, so an old `->(event, message:, **)` hook can never start raising on an event it was never written for. The events added in 0.2.0 are `Chats.on`-only. Move it to `Chats.on` — that's the whole migration.

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

## ✅ Official accounts: the verified badge

A support desk, an organization, a shop or a brand is an **official** counterpart, and the person talking to it should see that at a glance — the blue tick everyone already reads. Say it once, on the model, next to the other `acts_as_messager` options:

```ruby
class SupportDesk < ApplicationRecord
  acts_as_messager verified: true
end
```

Every bundled view that shows a messager's name now marks it: the inbox row, the stacked inbox row, and the thread header. The mark is an image with a name, not decoration — `role="img"` plus a localized label (`chats.verified.label`: "Official account" / "Cuenta oficial"), with the glyph itself `aria-hidden` so nothing is announced twice.

`verified:` is **independent of everything else**. A desk is usually headless *and* official; a shop is usually official and completely ordinary otherwise. Combine what you need:

```ruby
acts_as_messager verified: true                                   # official, notifiable, blockable
acts_as_messager notifications: false, inbox: :grouped, verified: true  # an official desk
```

It is the one boolean option that **refuses to coerce**, and that is deliberate — please don't "fix" it into a `!!` to match its neighbours. `notifications:` and `blockable:` coerce, so `notifications: "false"` quietly means `true`; on those two the damage is a stray notification. Here the same slip would hand an account the mark that tells people it is really us, and the strings that reach a model declaration come from exactly the places that produce `"false"`: an ENV var, a YAML round-trip, a settings row. So `verified: "false"` raises `Chats::ConfigurationError` at boot, where somebody is looking, rather than shipping a verified impostor nobody notices.

Read it anywhere you render your own screens — duck-typed, never a class check:

```ruby
SupportDesk.chat_verified?       # the class predicate
Chats.verified?(messager)        # false for a plain model, a nil, a non-messager
chats_verified_badge(messager)   # the view helper: markup, or nil for everyone else
```

**Change the colour** with one CSS variable (the badge inherits it through `currentColor`):

```css
:root { --chats-verified: #0284c7; }
```

The default is `#0284c7` rather than the more familiar `#1d9bf0`. The badge is a meaningful graphic, so it owes 3:1 against what it sits on (WCAG 1.4.11), and `#1d9bf0` is 3.00:1 on the page but **2.73:1 on `--chats-surface`** — the inbox row's hover background, so it failed exactly while someone was pointing at it. `#0284c7` clears the bar on both (4.10 and 3.72) and on a dark ground too (4.33 on `#111827`), so inverting the palette doesn't leave you with a badge you have to remember to fix. If you override it, `test/verified_badge_contrast_test.rb` shows the arithmetic worth repeating.

**Change the glyph** — to your design system's icon, a per-messager mark, or nothing — with a callable that gets the messager and returns html_safe markup (or `nil` for no badge):

```ruby
config.verified_badge = lambda do |messager|
  ApplicationController.helpers.image_tag("official.svg", class: "badge", alt: "Official account")
end
```

Or eject `app/views/chats/shared/_verified_badge.html.erb` with `rails generate chats:views` and rewrite it.

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

- `config.inbox_limit` bounds **rows**, not conversations: stacked threads are queried separately from ordinary ones, so a desk with 500 open tickets can never evict your friends from the inbox. A stack's `open_count` and `unread_count` are **global** — two indexed aggregates per stack, however deep it runs — so stacking neither goes N+1 nor loads a stack to count it.
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

Every other write refuses too: `Message#edit!`, `#soft_delete!` and
`Chats::Reaction.toggle!` raise `Chats::LockedError` (a `NotAllowedError`
subclass), the edit/delete/react endpoints answer 422 with the notice, and the
bundled bubble stops offering them. Moderation is the one exception —
`remove_reported_field!` removes reported content from a locked conversation,
because a product lock must never shield it.

## ✍️ Signed messages

`sender` is the seat a message came from; `author` is who **wrote** it on that seat's behalf. That's how a shared desk answers as itself while the human stays visible:

```ruby
desk.message!(alice, "On it!", author: lucia)   # sender: the desk, author: Lucía
message.signed?          # true — author present and not the sender
message.authored_by?(lucia)
```

The bundled bubble renders a signature line ("— Lucía G.") via `Chats.display_name_for`; `config.message_signature = ->(message) { … }` rewrites it. Ordinary messages have no author and render exactly as before.

An author must be persisted, but needs neither `acts_as_messager` nor a conversation
seat. The host authorizes who may send on behalf of a shared identity; the HTTP
message controller never accepts an author from request parameters.

Existing installs get the columns with one command:

```bash
rails generate chats:upgrade && rails db:migrate
```


## ⏱️ One send budget for every composer

`config.send_rate_limit` (60 per minute per sender by default) is enforced by
the gem's own message controller. A product with its **own** composer that
still ends in a chats message — a support form, an order note — shares the
same budget by including one concern, so nobody gets two allowances:

```ruby
class Support::TicketsController < ApplicationController
  include Chats::SendRateLimited
  before_action :enforce_chat_send_rate_limit, only: :create

  private

  def chat_rate_limit_messager = current_user   # whose budget; defaults to the configured current messager
end
```

It counts in the host's cache store (atomic increment, so it works on Rails 7.1
too) and answers `429` with `chats.flashes.rate_limited` when the budget is spent.

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
config.messager_url = lambda do |messager|
  routes = Rails.application.routes.url_helpers

  case messager
  when User then routes.user_path(messager)   # a desk or a bot has no profile: nil
  end
end
```

## 🎨 Make it yours

The bundled UI is intentionally framework-free (semantic `chats-*` classes + one self-contained stylesheet, themed with CSS variables):

```css
:root {
  --chats-accent: #facc15;           /* own bubbles, send button, badges */
  --chats-accent-contrast: #111827;
  --chats-verified: #0284c7;         /* the "official account" badge */
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
  config.send_rate_limit = { to: 60, within: 1.minute }  # shared sender budget; nil disables
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
  config.verified_badge = nil                                # ->(messager) { markup } for verified: true
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
Chats.verified?(desk)                         # official account? (acts_as_messager verified: true)

# Conversations
conversation.participant?(user)               # active membership
conversation.other_participants(user)
conversation.counterpart_for(viewer)          # the other messager (nil for groups)
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

# Conversations — finding and creating
Chats::Conversation.direct_between(alice, bob, about: ride)    # nil when none exists
Chats::Conversation.direct_between!(alice, bob, about: ride)   # find-or-create; checks blocks and can_message(alice, bob)
Chats::Conversation.group!(alice, [bob, carol], title: "Trip")
Chats::Conversation.direct .groups .about(ride) .recent_first
Chats::Conversation.inbox_for(alice) .excluding_blocked_for(alice) .unread_by(alice)
Chats::Conversation.unread_counts_for(alice, conversations)    # { id => count } in one query
conversation.direct? / conversation.group?
conversation.participant_for(alice)                            # the seat, or nil
ride.chat_conversations                                        # every conversation about a subject

# Messages — reading
message.system? / message.text? / message.deleted? / message.edited?
message.visible_body                                           # body, or the tombstone text
message.attachments?
message.sent_by?(alice)  message.sender_key
Chats::Message.visible .oldest_first .recent_first .before_message(message)   # keyset pagination
Chats::Message.created_since(time) .updated_since(time)                       # what the stale-thread catch-up reads

# Participants — reading
participant.active? / participant.left? / participant.muted? / participant.owner?
participant.unread? / participant.unread_count / participant.unread_messages
participant.display_name
Chats::Participant.active .muted

# The inbox
inbox = Chats::Inbox.for(alice, query: "trip", with: sgid)   # search, or filtered to one counterpart's stack
inbox.rows  inbox.each  inbox.to_a  inbox.size  inbox.any?  inbox.empty?  inbox.filtered?
inbox.conversations                                          # the flat, unstacked list
inbox.unread_counts  inbox.unread_count_for(conversation)  inbox.unread_count
group = inbox.rows.first                                     # a Chats::InboxGroup when the counterpart is inbox: :grouped
group.messager  group.conversations  group.conversation  group.single?
group.unread_count  group.unread?  group.open_count  group.last_message  group.last_message_at
group.title_for(viewer)  group.dom_id  group.with_sgid        # the signed token GET /conversations?with= takes

# Module-level
Chats.display_name_for(messager)  Chats.avatar_for(messager)  Chats.messager_url_for(messager)
Chats.message_signature_for(message)                         # "— Lucía G." or nil
Chats.verified?(m)  Chats.notifications_for?(m)  Chats.blockable?(m)  Chats.grouped_inbox?(m)
Chats.blocked_ids_for(messager)  Chats.blocked_between?(a, b)  Chats.can_message?(sender, recipient)
Chats.inbox_with_sgid(messager)                              # the token behind a stack's "see all"
Chats.messager_key(messager)                                 # "User:42" — what bubbles carry to align own-vs-other
Chats.messager_class?(klass)  Chats.chat_subject_class?(klass)
Chats.on(event, key: nil) { … }  Chats.reset_subscribers!  Chats.reset!  Chats.deprecator
```

Errors are namespaced and meaningful, all under `Chats::Error`:
`Chats::BlockedError` (a blocked pair opening or sending), `Chats::NotAllowedError`
(`can_message` / `can_create_group` said no, groups disabled, a reseat that would
collide) and its subclass `Chats::LockedError` (any non-system write into a
locked conversation), `Chats::ConfigurationError` (boot).

## 🧰 View helpers

All available in the bundled views **and** in your own templates:

| helper | renders |
|---|---|
| `chat_button_to(other, about:, label:, **html)` | a "Message" button, only when the viewer may message them |
| `chats_unread_badge(messager = viewer)` | the live unread badge with its own stream |
| `chats_messager_name(messager, css_class:)` | the name, linked through `messager_url`, badged when verified |
| `chats_messager_avatar(messager)` / `chats_conversation_avatar(conversation, viewer)` | avatar (URL, attachment, variant or initials) |
| `chats_verified_badge(messager)` | the official-account mark, or nil |
| `chats_message_signature(message)` | the "— Lucía G." line for a signed message |
| `chats_preview_for(conversation, viewer)` | the inbox row's last-message preview with its speaker |
| `chats_timestamp(time)` | "12:04" · "Yesterday" · "12 Sep" |
| `chats_slot(name, **locals)` / `chats_slot?(name)` | render a host slot partial when it exists |
| `chats_blockable?(messager)` / `chats_messager_url(messager)` | the duck-typed reads, for your own screens |
| `chats_group_path(group)` / `chats_group_path_for(messager)` | where a stack opens |
| `chats_styles` | the bundled stylesheet tag for your `<head>` |
| `chats_viewer` | the current messager, as the engine resolved it |

## Errors

See the end of [the full Ruby API](#-the-full-ruby-api): `Chats::Error` → `BlockedError`, `NotAllowedError` → `LockedError`, `ConfigurationError`.

## Locales

`en` and `es` ship with the gem under `chats.*` (`inbox`, `thread`, `conversation`, `verified`, `message`, `composer`, `buttons`, `flashes`). Your own locale
files **outrank** the gem's — Rails loads every engine's locales first and the
app's last (a 0.2.0 fix; the gem used to re-append its files after yours and
silently win) — so override any key in your `es.yml` and the gem's copy loses.
Bubbles, flashes, the empty inbox, the locked composer and the verified label
(`chats.verified.label`) are all there.


## Upgrading

`chats` ships the migrations a version bump needs; your initializer and views stay yours:

```bash
rails generate chats:upgrade   # 0.2.0: message authorship columns
rails db:migrate
```

0.3.x needs no migration and no new configuration: `verified: true` (0.3.0) and `Chats::SendRateLimited` (0.3.2) are opt-in. Nothing in 0.2.0 changes behaviour until you set an option — see the [CHANGELOG](CHANGELOG.md).

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
