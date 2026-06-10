# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Reliability + UX patterns adopted after a deep review of Basecamp's
open-source Campfire (https://github.com/basecamp/once-campfire) — see
`docs/campfire_review.md` for the full adopt/skip ledger:

### Added
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
