# Campfire review — what we adopted, what we skipped, and why

A deep read of Basecamp's open-source Campfire
([basecamp/once-campfire](https://github.com/basecamp/once-campfire), DHH's
production chat app) against this gem, done while the gem was still
unreleased and fully malleable. Every pattern below got a deliberate
verdict; "skip" always carries the reason, so future-us can re-litigate
with the same facts.

## Adopted

| Campfire pattern | Where it landed here | Notes |
| --- | --- | --- |
| **Stale-room refresh** (`Rooms::RefreshesController` + `refresh_room_controller.js`): on tab-visible-after-sleep or cable reconnect, fetch `?since=` and append new / replace updated | `ConversationsController#refresh`, `Message.created_since/.updated_since`, thread controller `refreshThread()`; **and the inbox** via `refresh_inbox_controller.js` (same reconnect/visibility triggers, but the recovery action is a Turbo 8 page `refresh` since inbox broadcasts already are page refreshes) | The single biggest reliability pattern in their codebase — mobile WebViews reap WebSockets constantly. We improved the trigger: instead of their dedicated `HeartbeatChannel`, we observe the `connected` attribute turbo-rails already toggles on `<turbo-cable-stream-source>`. Zero new channels. We also added a deep-backlog escape hatch: > 1 page missed answers with a Turbo 8 `refresh` stream action (full morph) instead of splicing arbitrary history. The inbox got the same doctrine (missed inbox refreshes had no recovery before). |
| **DOM cap** (`message_paginator.js` `maxMessages: 300`) | Thread controller `trimExcessMessages()` (300 + 20 leeway) | Only trims while the viewer is parked at the bottom. Our pagination is a server-rendered lazy-frame chain (theirs is JS-driven), so trimming also re-plants the keyset anchor frame (`rebuildPaginationAnchor()`) — trimmed history stays reachable on scroll-up with no gaps. |
| **Out-of-order arrival handling** (their `messages_controller.js` re-sorts on insert) | Thread controller `ensureChronological()` | Broadcast appends from concurrent host job workers can land out of order. ISO8601 lexicographic compare; equal timestamps keep arrival order. |
| **First-unread anchoring** (they page around the first unread; membership unread marker) | The «new messages» divider: `@first_unread_id` computed in `#show` *before* `read!` advances the horizon | We render a divider rather than re-anchoring the page — the thread still opens at the bottom (coordination chats are short; jumping deep into history on open would feel broken at our scale). Backlogs deeper than a page pin the divider to the top of the page. |
| **Read state as a side-channel that other surfaces consume** (their unread membership drives sidebar + Web Push badge) | `:conversation_read` notifier event from `Participant#read!` | Hosts use it to keep external notification centers truthful (mark a chat's bell rows read the instant the thread is read). Fired only when the read actually consumed unread content. |

## Already had (independently converged, kept ours)

| Pattern | Theirs | Ours |
| --- | --- | --- |
| Unread without a receipts table | `membership.unread_at` flag, set on disconnect | Per-participant `last_read_at` **horizon** — strictly more expressive (drives unread counts *and* "Seen" receipts from one column) |
| Direct-conversation identity | `Rooms::Direct.find_or_create_for(users)` set-comparison (their own FIXME flags it as O(rooms) slow) | Deterministic `direct_key` + unique index + `create_or_find_by!` — race-safe at the DB, O(1) lookup |
| Client-side own/other + day separators + message grouping | `message_formatter.js` (`--me`, threading window, first-of-day) | `chats--thread` classify + separators + grouping — same philosophy (broadcast once, personalize client-side), already shipped |
| Typing TTL + stop-on-message | `typing_tracker.js` 5s TTL | Same shape (stale cutoff + `hideTypingFor` on message arrival), ours rides a Turbo Stream custom action instead of a bespoke channel |
| Keyset pagination | `created_at` cursors (`page_before/page_after`) | `(created_at, id)` compound cursor — same idea, tiebreaker included |
| Composer file UX | picked-file previews via `URL.createObjectURL` | Same, shipped in the composer controller |
| Search-input hygiene | strips non-word chars before FTS | `sanitize_sql_like` on the inbox LIKE search |

## Considered and skipped (with reasons)

| Pattern | Why skipped |
| --- | --- |
| **Involvement enum** (`invisible/nothing/mentions/everything` per membership) | The mentions level only earns its keep with @mention support, which we don't have (plain-text coordination chats). Without mentions the enum collapses to exactly our `muted_at`. Revisit alongside mentions, together. |
| **Optimistic client messages** (client-generated id, pending template, server echo reconciliation) | Real complexity (failure rollback for rate-limits/validation, template duplication) for latency our sync form-submit→stream path already keeps low. Our dedup-by-`dom_id` append already absorbs the double-delivery half of the problem. Revisit if send latency ever feels bad on real networks. |
| **Presentation-div edit broadcasts** (replace `[message, :presentation]`, not the whole bubble) | Our Stimulus target callbacks re-normalize a replaced bubble anyway (classify/receipts/grouping re-run), so the only residual win is not closing an open popover during someone *else's* edit — marginal vs. restructuring the partial in the gem **and** every host's ejected copy. |
| **Web Push w/ VAPID + service worker + thread pool** | Hosts own push (this gem is host-agnostic; our reference host pushes through Noticed + action_push_native). Their `WebPush::Pool` is the right reference if a host ever needs self-hosted web push. |
| **ActionText/Trix rich text + OpenGraph unfurls + mentions-as-attachments** | Deliberate scope line: plain-text coordination chat. ActionText would drag in Trix, sanitization surface, and attachment semantics that fight our moderation contract (flag/snapshot plain columns). |
| **FTS message search** (SQLite FTS5 virtual table) | DB-specific (we're adapter-agnostic), and message-content search cuts against the privacy posture our reference host wants. Inbox search (participants/title/subject) covers the recall need. |
| **Bots + webhooks** (bot users, webhook reply parsing) | No host demand yet. The seam already exists (`post_system_message!` + the messager abstraction); a bot is just a messager. |
| **Room types as STI** (`Rooms::Open/Closed/Direct`) | Our `kind` enum (direct/group) + policy procs cover the same ground without STI's autoload/migration sharp edges in an engine. "Open" rooms (auto-grant to everyone) are an account-wide chat concept, not a host-policy one. |
| **Connection-TTL presence** (`connected_at`, 60s TTL, gate push on disconnected) | Needs a presence channel we deliberately don't have. Hosts get the same outcome cheaper at the delivery layer: suppress push when the recipient's participant has already read the message by delivery time (see the reference host's `push_suppressed_for?`), plus `:conversation_read` keeps badges truthful. |
| **Sounds / `/play` commands** | Not a desktop social chat. |
| **`maintain_scroll` stream attribute + scroll promise chain** | Our containment (stick-to-bottom + prepend restoration in the frame chain) already covers the cases we have; their generalized scroll manager solves a problem (interleaved arbitrary stream mutations) we don't generate. |
