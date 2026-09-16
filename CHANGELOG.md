# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - Unreleased

### Fixed

- Grouped inbox limits preserve other counterparts even when one desk has many recent conversations.
- Conversation creation and participant departure events run after commit and remain silent on rollback. Direct conversation creation includes its roster in the transaction.
- A message author may be any persisted model; staff need not become messagers to sign a desk's reply.

### Added

- `Chats::SendRateLimited`, a controller concern sharing the configured sender budget across chat and product-specific composers, using the host's cache store on all supported Rails versions.

## [0.2.0] - 2026-09-16

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
  error, and every OTHER write refuses too — `Message#edit!`,
  `#soft_delete!` and `Reaction.toggle!` raise `Chats::LockedError` (a
  `NotAllowedError` subclass), and the edit/delete/react endpoints answer 422
  with the notice. The bundled bubble stops offering what would only fail:
  no Edit, no Delete, no reaction toggles, while existing reactions still
  render as plain counts and Copy still works. Moderation is the one
  exception — `remove_reported_field!` removes reported content from a locked
  conversation, because a product lock must never shield it. The thread stays
  readable: the composer is replaced by the notice
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
  happens in ONE place. `config.inbox_limit` bounds ROWS, not
  conversations: stacked threads are queried separately from ordinary ones,
  so a desk with hundreds of open threads can never evict the rest of the
  inbox, and a stack's `open_count`/`unread_count` are GLOBAL — two indexed
  aggregates per stack, never per conversation and never by loading the
  stack to count it. `Chats::Inbox#unread_count` is the stack-aware badge number;
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
  resolving to it instead of stranding a duplicate. Refuses with
  `Chats::NotAllowedError` when the resulting pair already has a direct
  conversation, checked BEFORE the write so a unique-index violation can
  never poison a host's transaction.
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
  receives `:message_created` and `:conversation_read` — the two events 0.1.1
  had — and ONLY those: the events added in 0.2.0 are `Chats.on`-only, so a
  0.1.x hook written `->(event, message:, **)` can never be handed an event
  it has no keyword for. It registers as a subscriber under a reserved key,
  so re-assigning it replaces rather than stacks, and warns through
  `Chats.deprecator`, which the engine registers with
  `Rails.application.deprecators`.
  **If your test environment sets `config.active_support.deprecation =
  :raise`** (a common default) and you still assign `config.notifier`, that
  warning now raises at boot, because the engine registers the gem's
  deprecator with the app. Either move the hook to `Chats.on` — the migration
  is one line — or silence just this one:

  ```ruby
  # config/initializers/chats.rb
  Chats.deprecator.silence do
    Chats.configure { |config| config.notifier = ->(event, **payload) { … } }
  end
  ```
- The install migration now creates the `author` columns, so a fresh install
  needs no upgrade step.
- **If you ejected the inbox or the composer under 0.1.x**, nothing breaks:
  `ConversationsController#index` still assigns `@conversations` (the flat,
  unstacked list an ejected inbox loops over), and an ejected composer simply
  misses the DOM id the locked-composer swap targets — the 422 is then a
  no-op instead of a replace. Re-eject (or delete) those two files to pick up
  stacked rows and locked composers.

### Fixed
- **A host's own locale file no longer loses to the gem's.** The engine
  appended its `config/locales` onto the application's `i18n.load_path` on
  top of Rails' own `:add_locales`. Railtie paths are unshifted ahead of
  everything, so that second copy landed *after* the host's files and
  silently overrode them — a host rewording `chats.flashes.blocked` in its
  own `es.yml` kept reading ours, with no error to see. Gem first, host last,
  pinned by a test that ships a host override in the dummy app.
- **Migrations name every adapter they actually run on.** `json_column_type`
  matched `"postgresql"`, which activerecord-postgis-adapter never reports
  (it answers `"PostGIS"`), so PostGIS hosts silently got `json` where the
  gem meant `jsonb`. `json_column_default` matched `/mysql/`, which misses
  Trilogy (Rails reports `"Trilogy"`), handing those hosts a default MySQL
  rejects. Both now match by prefix and by both spellings.
- **The thread's missed-broadcast recovery never took effect for a deep
  backlog.** `ConversationsController#refresh` answered with `render html:
  … content_type: "text/vnd.turbo-stream.html"`, and `render html:` forces
  `text/html` and ignores the content type — so the response said
  `<turbo-stream action="refresh">` in a body nothing would treat as a
  stream. It now renders `turbo_stream.refresh(request_id: nil)`; the nil
  request id matters, because Turbo skips a refresh tagged with a request id
  it recognizes as its own, and this response answers the client's own
  catch-up fetch. The failure was invisible by construction: a recovery path
  that does nothing looks exactly like the staleness it exists to fix.
- `:participant_added` was documented as a notifier event but never emitted.
  The event catalogue is now exactly what the gem fires, and registering for
  anything else raises at boot with the valid list.
- **A signed message is its author's to answer for.** `Message#reported_owner`
  now returns `author || sender`. With authorship, an answer sent from a
  headless seat (a support desk) carries a human author, and a host's
  moderation `owner` is typed to its user class — a desk there raised an
  association type mismatch from inside the agent's own reply the first time
  a text filter tripped, and the moderation screens then asked the desk for
  an avatar it does not have.
- **`jsonb` on PostGIS.** The install migration decided jsonb-or-json with
  `adapter_name.downcase.include?("postgresql")`, and activerecord-postgis-
  adapter answers `"PostGIS"`, so PostGIS hosts silently got plain `json`
  columns. The template now matches the prefix (`/\Apostg/i`). Existing
  installs are unaffected; a host that wants jsonb can `change_column` it.

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
