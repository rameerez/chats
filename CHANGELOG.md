# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.1] - 2026-10-17

### Fixed
- **An action's strings are frozen copies.** `Data` freezes the action but
  not the strings it was handed, so `action.url.replace("javascript:…")`,
  or the caller mutating the string they passed in, could rewrite a
  validated action in memory before the bubble rendered it. `Chats::Action`
  now keeps a frozen copy of both members: what the validator saw is what
  renders.
- **An empty port suffix is refused.** `https://host:/x` parses as the
  default port and slipped past the 1..65535 rule; a named port must have
  digits.
- **An action's label is a plain String.** A label handed over as an
  html_safe string (a host's `t("…_html")`) kept the mark through the copy
  and rendered unescaped in the button. The copy is now a plain `String`,
  so the bubble escapes it like any other content.
- **`config.inbox_scope` is one rule, applied once.** `Messager#chats` now
  applies it, so the inbox relation, `unread_chats_count`, the inbox screen
  and the live badge all agree. The badge broadcast used to count through
  the raw `inbox_for` relation and could light up for a conversation the
  inbox would never show (a host scoping game records out of the inbox saw
  the badge count them). `Chats::Inbox` builds on `viewer.chats`, so a
  host's own override of `chats` reaches the inbox screen too.
- The README said the inbox preview still shows a soft-deleted message's
  body; it reads "Message deleted", as for any tombstone.

## [0.4.0] - 2026-10-17

Action buttons. A support desk writes "Your invoice is ready" and wants a
*Pay now* button under it; a game writes "Let's play!" and wants *Join my
room*. Until now a host pasted a URL into the body. **0.4.0 needs one
migration** (`rails generate chats:upgrade && rails db:migrate`, one
nullable JSON column) and otherwise changes nothing until you pass
`action:`.

### Added
- **One action per message.** `alice.message!(bob, "Let's play!", action:
  { label: "Join my room", url: "/play/abcd" })`, and the same `action:` on
  `Conversation#post_system_message!`. `message.action` is a
  `Chats::Action` (an immutable `Data` value: `#label`, `#url`, `#to_h`) or
  nil, and `message.action?` says which. `Chats::Action.wrap` accepts a
  Hash with string or symbol keys, an Action, or nil, and raises
  `ArgumentError` for anything else, including a key an action doesn't have
  (`method: :post` would otherwise have turned into a GET link silently).
  Assigning goes through `wrap` immediately, so a mistake raises on the line
  that made it.
- **Validated at the write.** The label is present and at most 80
  characters. The url is at most 2048 characters and is either an absolute
  http(s) URL with a host (and a port from 1 to 65535, if it names one) or
  a path on this site starting with a single `/`. `javascript:`, `data:`,
  other schemes and relative paths are refused, and so is everything a
  browser would send off-site: `//host`, `///host` (which URI.parse reads
  as a hostless path), `/\host` and `/<tab>/host`. Anything starting with
  `//` or `/\` is refused before the url is even parsed. The error is
  `:action, :invalid`, in `en` and `es`. It is checked only when the action
  changes, so editing an old message never fails because of an action
  nobody touched.
- **The bubble renders it** as `a.chats-message__action` under the text and
  attachments, and inside the note for system messages
  (`.chats-message__system--with-action`). The link has
  `data-turbo-frame="_top"`: older pages of a thread load inside lazy
  turbo-frames, and without it a link there would navigate only the frame.
  It is a link and never a form because the bubble is rendered once for
  every viewer and cloned into the long-press popup, so it cannot hold a
  per-viewer CSRF token. An action is a destination; a host that needs a
  POST points it at a page that asks first. The markup lives in its own
  partial, `chats/messages/_action`. The button uses the accent pair: filled
  with the accent on foreign bubbles and system notes, reversed on your own
  accent bubble.
- **Tombstones drop it.** Soft deletion clears the action along with the
  body, and so does moderation's `remove_reported_field!`, which goes
  through the same path. `edit!` keeps it.
- **The composer can never set one.** `Chats::MessagesController` still
  permits only `body` and `files`, the same as with `author:`, and a test
  checks that a posted `message[action]` is ignored.
- **`chats_messages.action`** (jsonb on PostgreSQL, json elsewhere, nullable,
  no default), created by the install migration and added to existing
  installs by `rails generate chats:upgrade`. The generator doesn't write
  that migration where the column already exists (it asks the database; a
  fresh 0.4.0 install has it), its `up` is guarded, and rolling it back
  KEEPS the column: nothing a migration can see records whether it or the
  create migration added it, and it must never drop a column, with every
  message's button in it, that it did not add.
- **The `composer_actions` slot.** `app/views/chats/slots/_composer_actions.
  html.erb` (receives `conversation:`) renders a row of your own buttons
  above the composer's input ("Create a game", "Send my location") without
  ejecting it. The row is outside the composer's `<form>`, so `button_to`
  works there. It goes away with the composer when the thread locks, whether
  on page load or through the live 422 swap. Unstyled links and buttons get
  a chip look applied with zero specificity, so any class you add wins.

### Changed
- **The composer partial's DOM.** `chats/messages/_composer` is now a dock
  wrapping the form:
  `div#<dom_id(conversation, :composer)>.chats-composer` contains the
  `.chats-composer__actions` row (only when the slot exists) and then
  `form.chats-composer__form`, which keeps the `chats--composer` controller,
  its data-actions and everything inside it. In 0.3.x the form itself was
  `form#…composer.chats-composer`. The swap id moved to the dock so the live
  lock replaces the host's buttons along with the form. **If you ejected the
  composer** (CarHey did), your copy keeps working unchanged:
  `.chats-composer` still styles whatever element carries it, and the
  locked-composer swap still targets your form's id. You only need to
  re-eject to use `composer_actions`. If your own CSS or JS selects
  `form.chats-composer`, change it to `form.chats-composer__form` (or
  `.chats-composer form`) once you're on the bundled partial.
- The Trust & Safety report-link recipe in the README referred to the
  inline actions row that 0.1.1 removed, and to its `chats-message__action`
  class, which now names the action button. It now puts the link in the
  long-press menu as a `chats-popup__item` with `data-chats-other-only`. The
  bundled CSS styles `.chats-message__action` only as a direct child of a
  bubble, so links in views ejected from 0.1.0 that still use the class are
  left alone.

## [0.3.2] - 2026-09-17

### Fixed

- Grouped inbox limits preserve other counterparts even when one desk has many recent conversations.
- Conversation creation and participant departure events run after commit and remain silent on rollback. Direct conversation creation includes its roster in the transaction.
- A message author may be any persisted model; staff need not become messagers to sign a desk's reply.

### Added

- `Chats::SendRateLimited`, a controller concern sharing the configured sender budget across chat and product-specific composers, using the host's cache store on all supported Rails versions.

## [0.3.1] - 2026-09-16

### Fixed
- **The verified badge was a star, not a check.** 0.3.0 shipped a
  five-pointed star as the "official account" mark, copied from a host icon
  that was named `verified_badge` but drawn as a star. A star reads as
  "favourite" or "rated", not "this account is really us", and at 14px a
  solid star and a solid rosette are the same blob. It is now heroicons
  `check-badge`: a scalloped rosette with a tick knocked out of it, which
  is the mark people already read as verified. `fill-rule="evenodd"` is
  what knocks the tick out — without it the rosette fills solid.

## [0.3.0] - 2026-09-16

Official accounts. Some counterparts are not people you met — they are a
support desk, an organization, a shop, a brand — and a person should be able
to tell at a glance. **Nothing changes until a model says so**: 0.2.x
installs upgrade by bumping the gem, with no migration and no new
configuration.

### Added
- **`acts_as_messager verified: true`.** A messager declares itself an
  OFFICIAL account, and every bundled view that shows its name marks it: the
  inbox row, the stacked inbox row, and the thread header. `Klass.
  chat_verified?` is the class predicate and `Chats.verified?(messager)`
  reads it duck-typed — false for a plain model, a nil, a non-messager — so
  hosts can badge their own screens without a class check. The option is
  independent of the headless ones: a desk is usually headless *and*
  official, a shop is usually official and nothing else. Unlike its boolean
  neighbours it refuses to coerce — `verified: "false"` raises
  `Chats::ConfigurationError` at boot rather than quietly verifying an
  account, because a badge is a trust claim and not a display preference.
- **The badge itself**, `chats/shared/_verified_badge` — an inline rosette
  that sizes itself from the text it sits beside. It is an image with a
  name, not decoration: `role="img"` plus a localized label
  (`chats.verified.label`, "Official account" / "Cuenta oficial"), and the
  glyph is `aria-hidden` so a screen reader never announces it twice.
- **`config.verified_badge`** `->(messager) { markup }` — swap the glyph for
  your design system's own, vary it per messager, or return nil for no badge.
  The default (nil) renders the gem's rosette.
- **`--chats-verified`** (`#0284c7`) — the badge colour, a CSS custom
  property like the rest of the gem's theming, inherited through
  `currentColor`. Not the familiar `#1d9bf0`: the badge is a meaningful
  graphic, so WCAG 1.4.11 asks 3:1 of it, and `#1d9bf0` is 3.00:1 on
  `--chats-bg` but 2.73:1 on `--chats-surface` — the inbox row's HOVER
  background, so it failed exactly while somebody was pointing at it.
  `#0284c7` clears the bar on both grounds and on a dark one, so a host
  inverting the palette inherits a badge that still passes.
  `test/verified_badge_contrast_test.rb` computes it rather than trusting a
  swatch.
- **`chats_verified_badge(messager)`** — the view helper behind all three
  surfaces, available in host views too. Nil for everyone who hasn't
  declared `verified: true`, so it is safe to drop next to any name
  unconditionally.
- **`Chats::Conversation#counterpart_for(viewer)`** — the other messager in a
  direct thread (nil for a group, and for a thread whose other seat left).
  The title, the avatar and the badge on an inbox row now resolve the
  counterpart through this one method, memoized per viewer, so a row that
  cost one query in 0.2.0 still costs one.

### Changed
- The bundled inbox row wraps its title in `.chats-row__name`, and the thread
  header wraps its name in `.chats-thread__name`, so a long name still
  ellipsizes while the badge beside it stays visible. If you ejected these
  views with `rails generate chats:views`, your copies are untouched and keep
  working; re-run the generator only if you want the badge.

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
