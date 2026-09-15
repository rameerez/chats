# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-09-15

The release that makes `chats` a foundation other products can be built on:
a messager that isn't a person, a conversation whose openness belongs to its
subject, a message someone wrote on someone else's behalf, and extension
points that don't require ejecting a screen. **Nothing here changes existing
behaviour until you set an option** — 0.1.1 installs upgrade by running
`rails generate chats:upgrade && rails db:migrate`.

### Added
- **Headless messagers.** `acts_as_messager notifications: false, blockable:
  false, inbox: :grouped` — a support desk, a bot, an org mailbox. Class
  predicates (`chat_notifications?`, `chat_blockable?`, `chat_inbox_mode`,
  `chat_group_path`) are read duck-typed everywhere, `Participant#
  notifiable_for?` honours them, and the bundled views hide block/report
  affordances against a non-blockable counterpart. Hosts stop writing
  `is_a?(User)` in every notifier and view.
- **Subject-owned locks.** `Chats::ChatSubject#chat_locked?` /
  `#chat_locked_notice` (both inert by default) decide whether a conversation
  still accepts messages; `Conversation#locked?` / `#locked_notice` read
  them, and `Chats::Message` refuses non-system writes with an `:locked`
  error. The thread stays readable: the composer is replaced by the notice
  (`chats/conversations/_locked_composer`, overridable through the
  `locked_composer` slot), and a send that lands on a freshly locked
  conversation gets a **422 that swaps the composer** instead of an
  exception. System messages are exempt, so your app can always explain the
  lock in the thread it just closed.
- **Message authorship.** `chats_messages.author_type/author_id` (nullable,
  polymorphic, indexed) plus `Message#author`, `#signed?`, `#authored_by?`
  and `Messager#message!(…, author:)`. `sender` stays the seat; `author` is
  who wrote it. Signed bubbles render a signature line ("— Lucía G."),
  rewritable with `config.message_signature`. New generator: **`rails
  generate chats:upgrade`** writes the migration (guarded, so it is a no-op
  on a fresh 0.2.0 install, which already has the columns).
- **Grouped inbox rows.** `Chats::Inbox.for(viewer)` returns
  `Chats::Conversation | Chats::InboxGroup` rows sorted by activity; every
  direct thread with an `inbox: :grouped` counterpart folds into one stack
  (`#messager`, `#conversations`, `#unread_count`, `#last_message`,
  `#last_message_at`, `#open_count`). A stack of one links straight to its
  thread, which gains a "see all" link back; a deeper stack opens
  `GET /conversations?with=<signed gid>` (purpose `:chats_inbox_with`, minted
  by `Chats.inbox_with_sgid`) or wherever `group_path:` points. Grouping
  happens in ONE place, folded out of the already-limited relation plus the
  existing grouped unread-count query — no N+1, no "load everything to
  group it". `Chats::Inbox#unread_count` is the stack-aware badge number;
  `unread_chats_count` is unchanged.
- **`config.inbox_limit`** (200, replacing a literal in the controller) and
  **`config.inbox_scope`** `->(relation, viewer) { relation }`, composed into
  the inbox query before the limit.
- **View slots.** The bundled views render `chats/slots/_inbox_top`,
  `_inbox_empty`, `_conversation_header_actions`, `_locked_composer` and
  `_message_meta` when such a partial exists — one memoized lookup when it
  doesn't. Hosts (and engines mounted on top of chats) add a row or a button
  without ejecting a screen.
- **Subscribers.** `Chats.on(:message_created | :conversation_created |
  :participant_left | :conversation_read)` replaces the single notifier
  proc: many subscribers per event, each isolated through
  `Rails.error.report(e, handled: true, context: { event: })` so a failing
  one is *visible* and never stops the others or the write that emitted
  them. Registration is reload-safe (`key:` replaces in place;
  `Chats.reset_subscribers!` clears). Two NEW events:
  `:conversation_created` (once per conversation, never on resume) and
  `:participant_left`.
- **`config.messager_url`** `->(messager) { nil }` — the bundled views link
  names and titles to it, and render plain text when it returns nil. The gem
  no longer assumes a host has `user_path`.
- **`Participant#reseat!(new_messager)`** — hand a seat to another messager
  inside a transaction, keeping the read horizon, the role and the history,
  and re-indexing a direct thread's `direct_key` so `chat_with` keeps
  resolving to it instead of stranding a duplicate.
- **Inbox missed-broadcast recovery** (`chats--refresh-inbox` controller): the
  inbox already receives Turbo 8 page *refreshes*, but Action Cable has no
  replay — a refresh broadcast sent while the client's socket was down
  (backgrounded tab/app, network blip) was lost and the inbox sat stale until
  the user navigated. The new controller re-runs the same page refresh on
  cable reconnect and on return-to-visible, extending the thread's
  stale-catch-up doctrine (`docs/campfire_review.md`) to the inbox. It reuses
  the thread's channel-free reconnect detection (observing the
  `<turbo-cable-stream-source>` `connected` attribute), so no new Action Cable
  channel is introduced. Auto-registered via the engine importmap pin; hosts
  need zero changes.

### Changed
- `config.notifier` is **deprecated** (removed in 1.0). It still works and
  still receives every event — it now registers as a subscriber under a
  reserved key, so re-assigning it replaces rather than stacks — and warns
  through `Chats.deprecator`, which the engine registers with
  `Rails.application.deprecators`.
- The install migration now creates the `author` columns, so a fresh install
  needs no upgrade step.

### Fixed
- `:participant_added` was documented as a notifier event but never emitted.
  The event catalogue is now exactly what the gem fires, and registering for
  anything else raises at boot with the valid list.

## [0.1.1] - 2026-06-10

Reliability + UX patterns adopted after a deep review of Basecamp's
open-source Campfire (https://github.com/basecamp/once-campfire) — see
`docs/campfire_review.md` for the full adopt/skip ledger:

### Added
- **Telegram-style long-press message actions**: nothing actionable
  renders inline on bubbles anymore. Long-press (or right-click) lifts a
  clone of the bubble to the center over a blurred glass backdrop, with
  the reactions pill above and the contextual menu below (Copy · Edit ·
  Delete in red — plus whatever the host's ejected views inject, e.g. a
  report link). Menu content ships per-bubble as an inert
  `<template data-chats-message-menu>`; `data-chats-own-only` items are
  stripped for foreign messages (cosmetic — the server still authorizes).
- **Composer edit mode**: the long-press Edit closes the popup (the bubble
  morphs back home) and loads the body into the composer under a
  quote-style "Edit message" cue (left accent border, one-line trimmed
  original, ✕ to cancel); the SAME form re-targets to the message's
  update URL with `_method=patch`. The old in-bubble edit form (GET
  `/messages/:id/edit`, `_edit_form`) is REMOVED — update failures now
  render into the composer's error slot. New locale keys:
  `chats.message.copy/.copied`, `chats.composer.editing/.cancel_edit`.
- **Stale-thread catch-up**: `GET /:id/refresh?since=ms` appends messages
  created — and replaces ones edited/tombstoned — while the client was
  asleep; answers deep backlogs with a Turbo 8 page refresh instead of
  splicing. The thread controller calls it when the tab wakes after 60s+
  hidden and whenever the Turbo Stream subscription reconnects (observed
  via turbo-rails' `connected` attribute on the stream source — no extra
  Action Cable channel). Mobile WebViews suspend sockets aggressively;
  without this a backgrounded chat silently loses messages.
- **«New messages» divider**: thread open renders a separator before the
  first unread bubble (computed before `read!` advances the horizon).
  New locale key: `chats.thread.new_messages`.
- **`:conversation_read` notifier event**: fired from `Participant#read!`
  when the horizon actually consumes unread content (`conversation:`,
  `participant:` payload) — lets hosts keep external notification
  surfaces (bells, badges) truthful the moment a thread is read.
- **DOM budget**: the thread caps rendered bubbles (~300) in long live
  sessions, trimming oldest only while parked at the bottom and
  re-planting the keyset pagination anchor so trimmed history stays
  reachable on scroll-up.
- **Chronology guard**: out-of-order broadcast appends (concurrent host
  job workers) are re-slotted into timestamp order client-side.

### Changed
- The recommended `config.notifier` signature is `->(event, **payload)`;
  events now carry different payloads (`:message_created` → `message:`,
  `:conversation_read` → `conversation:, participant:`). Keyword-specific
  lambdas keep working for `:message_created` but log a harmless,
  error-isolated complaint on other events.

## [0.1.0] - 2026-06-09

Initial release. A drop-in, real-time messaging engine for Rails 7.1+ (built for the Rails 8 omakase):

- Direct (1:1) and group conversations, polymorphic participants via `acts_as_messager`
- Conversations attachable to any domain record via `acts_as_chat_subject` (`about:`)
- Real-time everything over Turbo Streams + Action Cable: message append/edit/delete, Turbo 8 inbox refreshes, live unread badges, typing indicators (custom stream action), read receipts ("Seen")
- Read state as a per-participant horizon (no per-message receipts table)
- Race-safe direct-conversation identity (`direct_key` + `create_or_find_by!`)
- Image/any attachments (ActiveStorage), emoji reactions, message editing, soft-delete tombstones, system messages (`post_system_message!`)
- Inbox with search, previews, unread counts; keyset-paginated infinite scroll-up
- Block enforcement seam (`blocked_messager_ids`) hardcoded beneath the `can_message` policy; full duck-typed reportable contract for the `moderate` gem
- Notifier hook (`config.notifier`) + notification-etiquette helpers (`notifiable_for?`, `should_notify?`, `mark_notified!`)
- Per-sender rate limiting (Rails 8 `rate_limit`, feature-detected), optional encryption at rest
- Adaptive install generator (uuid/bigint primary keys; postgres/mysql/sqlite JSON handling), Devise-style views ejector
- Two self-registering Stimulus controllers (importmap pins under `controllers/chats/*`), bundled CSS-variable-themed stylesheet, `en`/`es` locales
