# `chats` — PRD (draft v0.2)

**A drop-in, real-time messaging engine for any Rails 8+ app.**
Direct messages, group chats, reactions, attachments, read receipts — Hotwire-native, polymorphic, and wired into the rest of our gem ecosystem (`moderation`/`banbanban`, `goodmail`, future `notifications`/push) so a developer gets messaging **and** its Trust & Safety + notifications story by configuring once.

> **Status: SHIPPED as v0.1.0 (2026-06-09).** This PRD is kept as the original design document; the README and the code are the source of truth now. What shipped vs. this draft:
>
> - **Built gem-first** (not CarHey-first): by build time the moderation system had already been extracted as the `moderate` gem, so the proven-shape argument for incubating in-app no longer applied. The gem was built standalone with its own dummy-app suite and integrated into CarHey in the same change (Gemfile `github: "rameerez/chats"`).
> - **Namespace drift**: everywhere this doc says `Moderation::*` / `moderates_content` / `filter_policy`, the real extracted API is `Moderate::*`, `has_reportable_content`, `moderates`, `config.filter`, `Moderate.blocked_ids_for`. The interop shipped duck-typed (no hard dependency, §7's resolution), via `config.blocked_messager_ids` + plain contract methods on `Chats::Message`/`Chats::Conversation`.
> - **No `Chats::MessageReceipt` table**: read state shipped as a per-participant horizon (`last_read_at`), which delivers unread counts + "Seen" with zero per-message writes (the Campfire model). Receipts can be added later without breaking API — see `Chats::Participant`'s doc.
> - **Typing indicators** shipped as a Turbo Stream custom action over the existing `Turbo::StreamsChannel` (a debounced POST + broadcast), not a bespoke `Chats::ConversationChannel` — no Action Cable identification requirements on the host.
> - **Noticed** remains uninstalled in CarHey; the interim notifier proc schedules a debounced goodmail job exactly as §8's caveat anticipated. The `c.notifier` seam is Noticed-ready.
> - Open question §12 (cardinality) resolved: per-pair-**per-subject** when `about:` is passed, plain per-pair otherwise — the host picks. CarHey threads per listing.

---

## 1. Vision & positioning

A gem you add to a Rails app to get **Instagram/X-DM-class** user-to-user messaging without building it again. The happy path is one generator + one `acts_as_messager` line + a mounted engine; the result is a working, real-time, polished inbox. Power users override views, policies, and adapters.

It is **not** a chatbot/LLM framework, not a Slack-clone with workspaces, and not a support-ticketing tool (that is `support_desk`, a separate product gem built on this one — see README). It is peer-to-peer (and group) human messaging.

**Why it exists:** every consumer app eventually needs DMs, and everyone rebuilds the same Conversation/Message/Participant/Receipt model, the same Action Cable + Turbo plumbing, and the same "report this message / block this user / filter this text" surface. We already built the moderation half for CarHey; `chats` is the messaging half, and the two snap together.

---

## 2. Design principles

1. **Hotwire-native, zero custom JS by default.** Turbo Streams for live message append/update/delete, Turbo Frames for lazy panes, Stimulus only for the few genuinely-interactive bits (composer autosize, typing throttle, scroll-to-bottom). No SPA, no build step (importmap-friendly).
2. **Mountable engine, `isolate_namespace Chats`.** All models/controllers/tables namespaced (`Chats::Conversation`, `chats_messages`). Host route names stay the host's choice.
3. **Polymorphic from day one.** A participant is not hard-typed to `User`. Any model that `acts_as_messager` can converse — `User`, `Organization`, a support `Agent`, a bot. This is the same inversion discipline the moderation gem uses (configurable class names + polymorphic targets).
4. **Good defaults, easy override.** Ships working controllers + views; every view is overridable by copying into the host; every policy is a config hook.
5. **Decoupled, adapter-driven ecosystem interop.** `chats` does not depend on CarHey. It depends on small, documented adapter interfaces for moderation, notifications, and auth — defaulting to no-ops so it runs standalone, and snapping onto `moderation`/`goodmail` when present.
6. **Compliance by composition.** Messages are UGC. Rather than re-implement report/block/filter, `chats` content plugs into the `moderation` gem, so adding `chats` to a compliant app keeps it compliant (DSA + Apple 1.2 + Google Play) instead of reopening those gaps.
7. **Delightful DX.** Consistent with the ecosystem: a `Chats.configure do |c| … end` block, `acts_as_*` macros, adapter objects, and an install generator — so `railsfast` + `goodmail` + `moderation` + `chats` feel like one coherent toolkit.

---

## 3. Architecture & data model

### Engine
`Chats::Engine < ::Rails::Engine` with `isolate_namespace Chats`. Ships migrations, models, controllers, views, Stimulus controllers, Action Cable channels, and generators.

### Core models (namespaced, UUID PKs to match the ecosystem)
- **`Chats::Conversation`** — `kind` (`direct` | `group`), `title` (groups), `last_message_at` (denormalized for inbox ordering), optional polymorphic `subject` (so a conversation can be *about* a host record — a ride, an order, a listing — which is how CarHey attaches a chat to a trip).
- **`Chats::Participant`** — polymorphic `messager` (`messager_type`/`messager_id`), `conversation_id`, `role` (`member` | `admin` | `owner` for groups), `last_read_at`, `muted_at`, `left_at`. Unique on `[conversation_id, messager_type, messager_id]`.
- **`Chats::Message`** — `conversation_id`, polymorphic `sender` (the messager), `body` (text), `reply_to_id` (self-ref for threads/quotes), `edited_at`, `deleted_at` (soft delete / "deleted for everyone"), `metadata` jsonb. Has many attachments (ActiveStorage) and reactions.
- **`Chats::MessageReceipt`** — per-recipient delivery/read state (`message_id`, `participant_id`, `delivered_at`, `read_at`). Powers read receipts + unread counts. (For large groups, receipts are opt-in / aggregated — see §6.)
- **`Chats::Reaction`** — `message_id`, polymorphic `reactor`, `emoji`. Unique on `[message_id, reactor, emoji]`.
- Attachments via **ActiveStorage** `has_many_attached :files` on `Message` (configurable: disabled, images-only, any).

### Host integration: `acts_as_messager`
```ruby
class User < ApplicationRecord
  acts_as_messager   # injects has_many :chat_participations, :chat_messages, helpers
end
```
The macro is the single host contract on the actor side. A model can also `acts_as_chat_subject` if conversations attach to it (e.g. `Ride`).

### Tables (sketch)
`chats_conversations`, `chats_participants`, `chats_messages`, `chats_message_receipts`, `chats_reactions`. All UUID, all polymorphic where noted, indexed for the two hot queries: **a messager's inbox** (`participants` by messager + `conversations.last_message_at`) and **a conversation's message page** (`messages` by `conversation_id, created_at`).

---

## 4. Real-time (Hotwire)

- **Turbo Streams over Action Cable.** `Chats::Conversation` broadcasts `append`/`replace`/`remove` to a per-conversation stream; participants subscribe via `turbo_stream_from conversation`. New message → append to the thread + update each inbox row's preview/unread badge.
- **`Chats::ConversationChannel`** (Action Cable) for presence + typing indicators (ephemeral, not persisted) and for authorizing the stream subscription (a non-participant must not subscribe).
- **Stimulus** controllers (namespaced `chats--*`): `composer` (autosize, Enter-to-send, typing-throttle ping), `scroll` (stick-to-bottom, infinite-scroll older pages via Turbo Frame pagination), `receipts` (mark-read on viewport intersection).
- **Read state**: when a participant views a conversation, mark messages read (debounced) → broadcast a lightweight receipt update so the sender sees "Seen".
- Degrades gracefully: with cable down, it's still a working request/response inbox (Turbo Drive navigation); realtime is an enhancement, not a requirement.

---

## 5. Generators & onboarding

- `rails g chats:install` → writes `config/initializers/chats.rb`, copies migrations, mounts the engine (`mount Chats::Engine => "/chats"`), adds `acts_as_messager` guidance.
- `rails chats:install:migrations` → idempotent migration copy.
- `rails g chats:views [scope]` → eject overridable views into the host.
- `rails g chats:stimulus` / component generator → eject the Stimulus controllers / view components for deep customization.

One-command setup; explicit initializer; no magic.

---

## 6. Configurable features

`Chats.configure do |c| … end`:
- `c.messager_class = "User"` (default) — the primary actor; polymorphic participants still allow others.
- Feature flags (all default sensible): `c.groups = true`, `c.attachments = :images` (`false`/`:images`/`:any`), `c.reactions = true`, `c.read_receipts = true`, `c.typing_indicators = true`, `c.editing = true`, `c.deletion = :soft`, `c.search = true`, `c.threads = false`.
- `c.messages_per_page = 30`, `c.max_message_length`, `c.max_group_size`.
- `c.read_receipts_max_group_size` — disable per-recipient receipts above N (perf).
- **Policies** (the authorization seam): `c.can_message = ->(from:, to:) { … }` (default: true unless blocked — see moderation), `c.can_create_group`, `c.can_join`. Defaults are permissive but trivially overridable; CarHey will scope DMs to a confirmed ride relationship initially.
- **Adapters** (the ecosystem seam — §7/§8): `c.moderation`, `c.notifiers`, `c.authorizer`, `c.current_messager`.

---

## 7. Moderation interop (the critical seam)

`chats` content is UGC; it must be reportable, blockable, and filterable. Instead of re-implementing T&S, `chats` plugs into the **`moderation`** gem (the system CarHey is extracting from PR #28). The interop is via small, documented contracts so `chats` works standalone (no-op adapter) and lights up when `moderation` is present.

### 7.1 Reportable messages & conversations
`Chats::Message` (and `Chats::Conversation`) `include Moderation::Reportable` and implement the concern contract already proven in CarHey:
```ruby
class Chats::Message < ApplicationRecord
  include Moderation::Reportable
  reportable_fields :body
  def reported_owner = sender
  def moderation_label = "Message #{id}"
  def moderation_snapshot_text(field) = body if field.to_s == "body"
  def remove_reported_field!(field) = (update!(body: nil, deleted_at: Time.current); true) if field.to_s == "body"
  def report_visible_to?(viewer, field:) = participant?(viewer)   # only people in the convo can report it
  # moderation_subject_url / return_path / admin_path take a routes object (already the concern's shape)
end
```
The host registers these in `Moderation.config.reportable_class_names`. **No CarHey coupling** — this is exactly the polymorphic adapter the moderation concern was designed for. A "Denunciar mensaje" affordance reuses moderation's `report_link` helper.

### 7.2 Block enforcement (blocked users can't DM)
`chats`' default `can_message` policy and inbox/visibility queries consult a **block adapter** that defaults to `Moderation::Block.user_ids_related_to(user)` (the bidirectional SSOT query). A blocked pair: cannot start a new conversation, cannot send into an existing one, and don't surface to each other. Wire-once: `c.moderation.blocked_ids_for = ->(user) { Moderation::Block.user_ids_related_to(user) }`. When `moderation` isn't installed, the default is "nobody blocked".

### 7.3 Content filtering with configurable modes
Filtering is configurable **per class/field** via a registry on the moderation gem (keyed by `"Class#field"`, ancestor-aware), with three modes:
- **`:off`** — no check.
- **`:block`** — reject at write time. Stays an ActiveModel **validator** (it legitimately stops the save).
- **`:flag`** — the write **succeeds**, and a pending review item is created **out-of-band**.

Wired once in `config/initializers/moderation.rb`:
```ruby
Moderation.configure do |c|
  c.filter_policy "Chats::Message", :body, mode: :flag
  c.filter_policy "Chats::Message", :files, mode: :flag, adapter: Chats::AttachmentReviewAdapter
end
```

Two design rules are now proven in CarHey:
1. **`:flag` does not live in a validator.** Validators remain side-effect-free. `:flag` runs from `Moderation::ContentFilterable` after commit, so system-generated review rows survive only after the host row exists and can be safely consumed by human/admin or ML workers.
2. **The flag is a separate `Moderation::Flag` table, not `Moderation::Report`.** `Report` models a human notice/report with contact fields, message, good-faith confirmation, DSA taxonomy, decision, and appeal window. A system flag has no notifier. Current CarHey shape: polymorphic `flaggable`, optional `owner`, `field`, `source` (`text_filter`, `image_filter`, `external_classifier`, `manual`), `mode` (`flag`, `block`), `status` (`pending`, `actioned`, `dismissed`), `excerpt`, `categories`, `scores`, and `context`. A shared `pending` scope is the SSOT both a Madmin queue and future ML consumers read.

**Adapter interface** (one method, score-carrying so a wordlist and an AI classifier are interchangeable):
```ruby
adapter.classify(value) # => { allowed:, categories:, scores:, source:, metadata: }
```
The moderation core wraps adapter hashes in `Moderation::FilterResult`. Built-in wordlist behavior is CarHey's `TextFilter` (NFKD normalization, leetspeak folding, spacing/accent resistance, Spanish/English YAML blocklist), score `1.0` per hit. Optional `:openai`/`:ruby_llm` adapters can return real `0..1` scores, and should run from a background job in `:flag` mode for expensive media/ML checks. Report intake only re-runs a block-mode adapter synchronously when the adapter explicitly exposes `synchronous? == true`; external/network adapters should leave that false and rely on `Moderation::Flag` evidence instead. The existing `moderate` gem remains a possible upstream home for this adapter interface, but not a hard dependency: today it is English-oriented and too narrow for CarHey/Spanish compliance needs.

`chats` consumes all of this with the real **two-part** shape: on the model, `include Moderation::ContentFilterable` **+ `moderates_content :body`** (declares the scanned fields — drives the `validate` for `:block` and the `after_commit` for `:flag`); in the initializer, one `c.filter_policy "Chats::Message", :body, mode: :flag` line (sets the mode). A `filter_policy` line **without** `moderates_content` silently does nothing. Flagging is `Moderation::Flag.flag!` called from `ContentFilterable` (there is **no** `Moderation.flag` facade, and the standalone `ObjectionableContentValidator` is dead code — the concern owns `:block` too). For `:files` (attachments), override `moderation_field_value` / `moderation_field_changed_for_commit?` since the default `public_send(:files)` returns an ActiveStorage proxy, not classifiable content (mirror CarHey's host-supplied `ImageReviewAdapter`). The filter-mode + `Flag` machinery is a **moderation-gem change to land first** (independently useful for CarHey avatars today).

### 7.4 Compliance inheritance
Because messages flow through moderation, adding `chats` to a DSA/Apple/Google-compliant app **keeps it compliant only if the host enables the required policies**:
- `Chats::Message` and `Chats::Conversation` are registered reportable classes.
- Message body and attachment policies are configured (`:block`, `:flag`, or explicit `:off`).
- Blocking is enforced before conversation creation and before every send.
- Every message/conversation UI exposes report and block affordances.
- Admins can see `Moderation::Report`, `Moderation::Flag`, and `Moderation::Appeal` queues.
- Report decisions are delivered via moderation: the **DSA legal email** (receipt / decision / statement-of-reasons) goes through moderate's direct, synchronous goodmail seam (its boolean return gates the `*_notified_at` DSA timestamps — Noticed's fire-and-forget can't honor that), while **affected-user surfaces** (in-app feed + push) are layered via a host Noticed notifier. This is moderation's responsibility, not "the chats bus."

This is a launch gate for the CarHey chats PR, not optional polish. A chat surface is high-velocity UGC; shipping it without these hooks would regress App Store Guideline 1.2, Google Play UGC, and DSA notice-and-action.

---

## 8. Notifications: integrate with Noticed (the host's adopted orchestrator)

**The host has chosen [Noticed](https://github.com/excid3/noticed) v3 as the notification orchestrator + in-app feed, and `action_push_native` for push** (see CarHey's `docs/notifications_architecture_prd.md`). `chats` does **not** build its own fan-out bus — Noticed already owns multi-subscriber fan-out, the per-recipient in-app feed (`Noticed::Notification` records), per-user preferences (`if/unless`), and the channel adapters (email/action_cable/action_push_native/custom). A second bus inside `chats` would double-wire goodmail and strand chats events away from push/feed/telegram. (Do **not** route chats through the `moderate` gem's `Moderation.notify` PORO either — that bus exists only to gate moderate's synchronous DSA legal email; it is not the cross-channel orchestrator.)

The shape:
- **`chats` is a Noticed event *source*.** On notification-worthy domain moments, `chats` fires a host **Noticed Notifier** through a single no-op-default `c.notifier` adapter proc. In CarHey that proc is `->(event, **p) { NewMessageNotifier.with(message: p[:message]).deliver }`. The gem takes **no hard dependency on Noticed** (the default proc is a no-op, so `chats` runs standalone).
- **Recipients live in the host Notifier**, not in `chats`. `chats` passes the domain object (the message/conversation); the Notifier's `recipients -> { params[:message].conversation.participants.excluding(params[:message].sender) }` computes who gets it.
- **The 5 channels are host-owned Noticed delivery methods**, wired once: in-app feed (Noticed core + a `TurboStream` delivery method for the live bell), the **chats DM surface** (a custom `DeliveryMethods::Chats`), **email via goodmail** (Noticed's built-in `:email` pointing at a normal `ApplicationMailer` that uses `goodmail_mail` — **goodmail needs zero changes**, and it is **not** `Goodmail::Base`), **push via `action_push_native`**, and **admin Telegram via `telegrama`** as a `bulk_deliver_by`.
- **The in-app feed is Noticed's, not chats'.** `chats` owns only the chat/DM surface (channel 2). The bell/feed is `current_user.notifications` (`Noticed::Notification`).
- **Debounced email is a Noticed config**, not a chats-owned digest job: `config.wait = 10.minutes` + `config.unless = -> { read? }` gives the classic "email only if still unread."

> **Status caveat:** Noticed + `action_push_native` are **not yet installed** in CarHey. Until they are, the interim CarHey wiring may call goodmail directly. The *target* is the Noticed integration above; `chats`'s hooks are designed so that milestone wires Noticed **once** with no gem changes. Two push gotchas to honor when it lands (from the action_push_native source): the `:action_push_native` delivery method calls `with_apple`/`with_google`/`with_data` unconditionally — **all three must be set** (at least `-> { {} }`); and `before_enqueue` is a real Noticed v3 callback that may `throw(:abort)`, while `config.if`/`config.unless` remain the clearer preference gates.

### 8.1 Chats domain moments → Noticed notifiers (not a private bus)

These are the moments at which `chats` fires a host Notifier — they are **not** events on a chats-owned bus:

| Domain moment | Host Notifier | Channels |
|---|---|---|
| message created | `NewMessageNotifier` | feed + chats DM + push + debounced email |
| @mention | `MentionNotifier` (optional) | feed + push + email |
| added to conversation | `ParticipantAddedNotifier` (optional) | feed + push |

Non-notification domain changes (edited / deleted / reacted) need **no** notification framework — handle locally, or emit `ActiveSupport::Notifications` if instrumentation is wanted. **Do not emit a `message_flagged` event** — flagging is owned by `Moderation::Flag` / `ContentFilterable`; re-emitting it would double-count. Each Notifier's payload carries the domain object + actor + a stable idempotency key (Noticed `params` + dedup).

### 8.2 `chats` is both a Noticed *source* and a Noticed *target*

These are different directions and both are true (this resolves the ambiguity flagged in the host PRD §11):
- **Source:** a user message fires `NewMessageNotifier` (above) → participants get bell + push + email.
- **Target:** other notifiers post a *system* message **into** a conversation via the custom `DeliveryMethods::Chats`, calling a stable chats API — `Chats::Conversation#post_system_message!(body:)` (a `Chats::SystemSender` participant), e.g. "Your ride was cancelled" dropped into the ride's chat. The host delivery method must match chats' real signature — messages have a **conversation + participants**, not a per-message `recipient:`, so the illustrative `Chats::Message.create!(recipient:)` in the host PRD §5.5 is wrong; chats exposes `post_system_message!` instead.

---

## 9. Security, privacy, performance

- **Authorization everywhere**: channel subscriptions, message reads, and mutations all gate on participation + the `authorizer` adapter. A non-participant can't read or stream a conversation.
- **Privacy**: soft-delete semantics ("delete for me" vs "delete for everyone"); optional message encryption-at-rest (ActiveRecord Encryption) behind a flag; PII-aware (don't leak presence to blocked users).
- **Abuse/rate limits**: per-sender send rate limit (Rails 8 `rate_limit`); attachment type/size limits; optional attachment scanning hook.
- **Compliance rate limits**: reporting/appeal forms use anti-abuse checks owned by moderation; message sends have separate high-throughput per-sender limits so attackers cannot create unlimited UGC before moderation catches up.
- **Scale**: denormalized `last_message_at`, receipt opt-out for large groups, cursor pagination, `find_each`-friendly broadcasts, counter-cached unread.

---

## 10. Cross-gem DX conventions (the ecosystem)

To make this "the best Ruby gem ecosystem," `chats` follows and reinforces shared conventions with `railsfast`, `goodmail`, `moderation`, `organizations`, `pricing_plans`:
- **One `X.configure do |c| … end` block per gem**, required keys validated at boot.
- **`acts_as_*` host macros** for model integration (`acts_as_messager`, `acts_as_reportable`/`Moderation::Reportable`, etc.).
- **Adapter objects + procs** for cross-gem seams (notifier, moderation, audit), defaulting to no-ops so each gem runs standalone.
- **Configurable class-name strings + polymorphic targets** (never hard constants) so no gem depends on a host's `User`.
- **Install generators** writing a templated initializer + idempotent migrations + engine mount.
- **Goodmail for all transactional mail**; **moderation for all UGC T&S**; **a shared event/notifier contract** so notifications fan out uniformly.

Target experience: `bundle add chats moderation goodmail`, run three installers, add `acts_as_messager` + `include Moderation::Reportable`, set a couple of adapter procs in initializers — and you have real-time DMs with reporting, blocking, filtering, email + push notifications, and DSA/store compliance, with every view overridable.

---

## 11. Build plan

**Phase 0 — in CarHey (validate the shape against a real app):**
1. Replace the interim coordination model (the `Ride::JoinRequest#message` free-text + the `/messages` "Próximamente" placeholder) with real `Chats` conversations attached to a ride (`acts_as_chat_subject` on `Ride`).
2. `Chats::Message include Moderation::Reportable`; register it in `Moderation.config.reportable_class_names`; reuse `report_link` + the block enforcement.
3. Wire `Chats.config.notifier` → goodmail (`ChatsGoodmailer`) and `Chats.config.moderation` → the moderation adapters.
4. Scope `can_message` to confirmed ride relationships (CarHey policy); prove the polymorphic/adapter seams under a real workload + tests.
5. Launch gate: no chat PR merges unless report/block/filter/flag/appeal paths are green for `Chats::Message`, attachments, and conversations.

**Phase 1 — extract to the gem:** `bundle gem chats` (engine), move the namespaced models/controllers/views/channels/generators, add `messager_class` string + `constantize`, ship default `en` locale + overridable views, write the install generator, and replace CarHey's direct usage with the gem.

**Phase 2 — ecosystem polish:** extract the shared event dispatcher if moderation + chats both prove the same API; ship optional `goodmail`, `moderation`, `noticed`, and push adapters; document one canonical RailsFast setup.

---

## 11.1 Acceptance criteria for CarHey v1

- A driver/passenger with an accepted ride relationship can open a conversation from the ride screen.
- New messages appear in real time through Turbo Streams and still work without WebSockets.
- A participant can report a message, block the sender, and stop receiving future messages from that sender.
- `Chats::Message#body` goes through moderation filter policy; attachments create `Moderation::Flag` rows in `:flag` mode.
- Madmin shows reports, flags, and appeals for chat content without CarHey-specific case statements.
- Goodmail sends a debounced unread-message digest through the shared notifier array.
- Full CarHey test suite covers send/read/receipt/report/block/filter/appeal happy paths and authz negatives.

---

## 12. Open questions
- Conversation ↔ subject cardinality (one chat per ride? per pair-per-ride?).
- Group membership model for very large groups (receipts, fan-out) — start capped.
- E2E encryption: out of scope v1 (at-rest only); revisit.
- Search backend: start with Postgres `ILIKE`/trigram; pluggable adapter for later.
- Exact dependency direction: does `chats` depend on `moderation` directly, or only on a `moderation`-shaped adapter interface? → **adapter interface** (keeps `chats` usable without `moderation`), with a first-class `moderation` adapter shipped.

---

## 13. Non-goals (v1)
Bots/LLM agents, workspaces/tenancy, voice/video, message scheduling, public channels/communities, federation. Deferred, not designed against.
