# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.2] - 2026-10-18

### Fixed
- **A moderation removal that removed nothing said it had.**
  `Chats::Message#remove_reported_field!(:body)`, the seam moderate calls to
  take reported content down, returned true for a message that was already
  deleted, so moderate recorded a second "content removed" with a statement
  of reasons that was false. It now returns whether anything was removed:
  false for a message already deleted (by its sender or an earlier
  decision), one whose body is already blank, and one already gone
  (`deletion: :hard`); true only when it tombstoned the message. It decides
  under the message's row lock and reads the message again under it, so two
  decisions taken at once cannot both see it standing. moderate refuses a
  removal that removed nothing. A group's `remove_reported_field!(:title)`
  keeps the same contract (false for a title already removed).

## [0.6.1] - 2026-10-18

The package is the gem again, and three fixes to the two-pane page.
**No migration, nothing to configure.**

### Fixed
- **The package shipped seven old packages.** The gemspec takes its files
  from `git ls-files`, and the built `chats-0.3.2.gem` … `chats-0.5.1.gem`
  had been committed (`chats-0.3.1.gem` since 0.3.1), so 0.6.0 weighed
  3.5 MB. They are untracked, `*.gem` is in `.gitignore`, and the gemspec
  leaves out any `*.gem` it is handed anyway; `test/gemspec_test.rb` keeps
  it so. The README's screenshots still ship, since the README links them.
- **The tab kept the previous page's title after a row click.** Turbo
  leaves `<head>` alone when it promotes a frame load to a visit, so from
  `/messages/A` clicking B left A's title. The messaging page's title now
  has one source, the new `chats_page_title` helper ("Messages", "Bob ·
  Messages": `chats.page_title.inbox` / `.conversation`, localized), which
  `config.page_title = ->(conversation, viewer) { … }` rewords. The bundled
  `index` and `show` give it to `content_for :title` (a layout doing
  `yield(:title)` shows it on a full page), and the pane carries it
  (`data-title`), which `chats--split` gives the tab when a row opens it.
  The pane's answer stays in turbo-rails' minimal frame layout, now even
  under a `config.layout`. A layout that titles pages from what the
  controller loaded keeps its title on full pages and shows
  `chats_page_title` after a row click: say it the same way in
  `config.page_title`.
- **A tapped row kept its hover tint on touch screens.** Every hover rule
  on inbox rows and on the dock (rows, the bar's chevron, "See all
  messages", the window buttons) now sits inside `@media (hover: hover)`.
- **The open row kept its unread count until the list's live refresh.** The
  pane says when the server read the conversation as it rendered it
  (`data-read`), and the thread now dispatches `chats:read` once a read it
  posted lands; on either, `chats--split` clears that row's count and bold
  at once. The refresh that follows renders the same.

## [0.6.0] - 2026-10-18

The messaging page is two panes, LinkedIn-style: on a wide screen
`/messages` is the conversation list beside the open conversation, and
`/messages/:id` is that same page with its conversation open. Phones keep
the separate pages. **No migration; `config.inbox_layout = :stacked` keeps
the old pages everywhere.**

### Added
- **Two panes (`config.inbox_layout = :split`, the default).** From 700px
  wide (the width at which the dock turns into a phone sheet) the list sits
  on the left in a `<nav>` named "Messages", `--chats-list-width` (320px)
  wide, and the open conversation on the right in a
  `turbo_frame_tag "chats_conversation"`; with none open, the pane says
  "Select a conversation" (`chats.inbox.select_hint`), and with no
  conversations at all it holds the inbox's empty state and the
  `inbox_empty` slot (rendered once, in the pane, no longer in the list
  too). Both panes are as tall as `--chats-split-height` (the screen,
  `100dvh`, by default; a host with its own header above the page sets what
  is left, `calc(100dvh - 4rem)`, which a phone's list page also takes as
  its least height) and scroll on their own; the page is as
  wide as the list plus a thread page (`--chats-max-width`).
  Below 700px it is one column, exactly the separate pages: `/messages` is
  the list, `/messages/:id` the thread with its back link. One media query
  decides, so the layout holds before JavaScript and without it.
- **A row opens its conversation in the pane.** Each row is a real link to
  `/messages/:id` aimed at the frame (`data-turbo-frame`); the frame is
  `data-turbo-action="advance"`, so the address bar and history follow, and
  the server answers the frame with the pane alone (new `pane.html.erb`: the
  header over `chats/conversations/_thread`, no list, no layout). A reload, a
  deep link or back/forward renders the whole page, the row current
  (`.chats-row--current`, `aria-current="page"`). The new `chats--split`
  controller (`controllers/chats/split_controller`, pinned like the others)
  enables the frame only on a wide screen; on a phone, before it connects
  and without JavaScript, the same link opens the page. It also skips the
  hover prefetch of a row while the frame is disabled (Turbo would ask for
  the pane alone and then render it as the page), marks the row the pane
  opened current at once, and takes the viewer into it, as LinkedIn does:
  the focus goes to its composer, inside the pane a screen reader names
  after the conversation; on a touch screen (`pointer: coarse`), and in a
  locked conversation, to the pane's title (`tabindex="-1"`), so no
  keyboard rises over a conversation not read yet.
- **A filtered list stays filtered.** A row of a search's results or of a
  stack (`?with=`) links to `/messages/:id?q=…` / `?with=…`: the address
  bar names the list the page shows, so the list's refreshes, which
  re-request it, keep it, and the pane's back link (phones) returns to it.
- **The open conversation survives the list's refreshes.** The inbox's live
  updates are Turbo 8 morphs of the whole page; the pane's thread sits in a
  `data-turbo-permanent` element keyed by the conversation and the viewer
  (`chats_conversation_pane_<id>_<viewer key>`), so a refresh re-renders the
  rows and leaves the draft, the scroll position, the read state and the
  stream subscription alone, while another conversation (another id)
  replaces it. The pane's header (avatar, name, verified badge, subject, the
  ⋯ menu) stays outside it, so a mute or a renamed group still shows. The
  list and the pane each catch up on missed broadcasts once: a page refresh
  for the list, the thread catch-up for the conversation.
- **`config.inbox_layout`**, `:split` or `:stacked`, checked at boot (a
  wrong value fails the initializer), in the generated initializer and the
  README.

### Changed
- **When `/messages/:id` reads.** Opening a conversation still reads it: a
  row clicked (the pane's frame), a link from elsewhere, a reload, a page
  loaded without JavaScript. A Turbo visit of the two-pane page does not
  read on the server, because the inbox's own refresh is one: it may arrive
  in a background tab, and a read there said "Seen" while nobody looked and
  refreshed the inbox again, in a loop. The pane renders `read-pending`
  instead and its thread reads once it is on screen, as a dock window does.
  A prefetched thread page (`:stacked`), which nothing used to read when
  Turbo showed it, now reads itself the same way.
- **The inbox's search form has no `action`**, so it searches whatever page
  it is on (an HTML form without one submits to the page's URL): after a row
  opened a conversation and moved the address bar to `/messages/:id`, a
  search keeps that conversation open (`/messages/:id?q=…`) instead of
  going back to `/messages`.
- **The dock** drops a window whose conversation a frame of the page loads
  (`turbo:frame-load`), as it did after a visit: one copy of a thread's DOM
  ids per page, with `chats_dock everywhere: true` too.
- **Templates.** Hosts with ejected views are unaffected: an app whose own
  `index` or `show` came from a `rails generate chats:views` before 0.6
  (no `_conversation_pane` of its own) keeps its separate pages, rendered
  and read exactly as before; re-eject to get the panes. The bundled
  templates that changed:
  - `chats/conversations/index.html.erb`: the two-pane page (the list in
    `nav.chats-split__list`, the `chats_conversation` frame), rendered for
    `/messages/:id` too; the list alone under `:stacked`. The search form is
    a bare `<form>` with no `action`.
  - `chats/conversations/show.html.erb`: the thread page, now only under
    `:stacked` (or for views ejected before 0.6); its header moved to the new
    `chats/conversations/_thread_header.html.erb`, shared with the pane.
  - new `chats/conversations/_conversation_pane.html.erb` (the pane:
    `section.chats-split__pane`, labelled by its `h2` title, the header, and
    the permanent `.chats-split__thread` around the thread),
    `chats/conversations/_empty_pane.html.erb` (`.chats-split__empty`,
    `--inbox` for an empty inbox) and `chats/conversations/pane.html.erb`
    (the frame's answer).
  - `chats/conversations/_thread.html.erb`: `pane:` (rooted at
    `.chats-thread--pane`, inside the page's `.chats` shell) and
    `read_pending:` locals.
  - `chats/conversations/_conversation_row.html.erb` and `_group.html.erb`:
    with `pane: true` the link carries
    `data-turbo-frame="chats_conversation"` (a stack only when it holds one
    conversation) and the list's `filter:` (`q`, `with`) in its URL, and
    with `current:` the current row its class and `aria-current="page"`;
    the `<li>`'s classes come from `class_names` (no trailing space).
  - `chats/conversations/_thread_header.html.erb` takes `back_path:` (the
    pane's keeps the list's filter) and gives a titled pane's heading
    `tabindex="-1"`.
  - `chats/dock/_dock.html.erb`: one more action,
    `turbo:frame-load@document->chats--dock#pageFrameLoaded`.
  - `chats.css`: the `chats-split`, `chats-split__list`,
    `chats-split__conversation`, `chats-split__pane`, `chats-split__thread`,
    `chats-split__empty` and `chats-thread--pane` rules and
    `--chats-list-width`; `--chats-split-height` is read with a `100dvh`
    fallback and never declared by the gem, so a host's declaration wins
    wherever it is. The existing class names are unchanged, so a theme on
    `.chats`, `.chats-row` or `.chats-thread` keeps applying.

## [0.5.1] - 2026-10-18

A page that missed a broadcast is never left stale: every live surface
catches up on its own, without polling (fixes
[#1](https://github.com/rameerez/chats/issues/1)). Also: the dock's unread
count in every language's plural forms, one extension point for a
conversation that must open although the inbox hides it
(`conversation_lookup_scopes`), and real conversations told from
system-only threads. **No migration, nothing to configure.**

### Added
- **Real conversations vs system-only threads.** `with_messages` asks whether
  a conversation holds anything at all, system lines and tombstones
  included; ops walls, moderation lists and analytics ask whether a messager
  wrote something there that still stands. Four additive reads answer that:
  `Chats::Message.human` (kind `text`, not deleted: written by a messager,
  person or not, as opposed to posted by the app, so a bot's or a headless
  desk's text message counts and a photo with no caption counts too), `Chats::Conversation.with_human_messages` and
  `.without_human_messages` (one correlated `EXISTS` / `NOT EXISTS` built
  from `Message.human`, so they compose with `alice.chats`, `inbox_for`,
  `about`, `unread_by` and `with_messages` and never multiply rows),
  `Conversation#last_human_message` (a query, not the `last_message`
  pointer), and its batch twin `Chats::Message.last_human_in(conversations)`:
  the newest human message of each conversation in ONE query, for a loaded
  page, ids, a single record, or an unloaded relation, which is read as a
  subquery and never loaded first. It returns a relation, so a `.select` can
  narrow the columns. Viewer-facing lists start from `alice.chats`, which
  applies blocks and `config.inbox_scope`; the bare `Chats::Conversation`
  scopes see every conversation and belong behind staff authorization.
  Nothing changes by default: system messages still bump `messages_count`
  and `last_message`, and the inbox still lists system-only threads.
- **`Chats::ApplicationController#conversation_lookup_scopes`, the one
  extension point for a conversation that must open although the inbox
  hides it.** Every engine endpoint (the thread, a dock window, sending,
  editing, reacting, reading) finds a conversation through
  `find_conversation(id)`, which now asks each relation
  `conversation_lookup_scopes` returns, in order (`find_by(id:)`), and
  raises `ActiveRecord::RecordNotFound` when none has it. By default that is
  `[chats_current_messager.chats]`, exactly the old lookup. A product gem
  (support_desk: a requester's own ticket, which the host's `inbox_scope`
  keeps out of the inbox) prepends a module whose
  `conversation_lookup_scopes` returns `super + [its own scope]`, instead of
  re-implementing the lookup and recognising a miss by the exception's
  details. Later scopes are asked only on a miss; each scope must hold only
  conversations the viewer may open, so nothing outside them becomes
  reachable; and an error a scope raises is not rescued into a 404.

### Fixed
- **The dock's window count used the right plural form only in two-form
  languages.** `dock_controller.js` picked `one` for exactly 1 and `other`
  for everything else, so Polish, Russian, Ukrainian, Croatian or Serbian
  (one/few/many, with 21 read like 1 in the East Slavic ones) and
  Arabic-style zero/two read wrong. The dock now renders every plural form
  the locale provides for `chats.dock.window_unread` (`zero`, `one`, `two`,
  `few`, `many`, `other`; new helper `chats_plural_forms`), and the
  controller picks one with `Intl.PluralRules` in the page's language
  (`<html lang>`, else the browser's), reading a missing form as `other`
  and falling back to the old rule where `Intl` is unavailable. The gem's
  `en` and `es` keep `one`/`other`; a host adds the forms its languages need
  in its own locale files.
- **Every live surface catches up on the broadcasts it missed.** Action
  Cable has no replay, so a broadcast sent while a page's socket was down
  (a laptop asleep, a backgrounded tab or Hotwire Native WebView, a network
  blip) never reached it, and the inbox, a thread, the unread badge or the
  dock could sit on old content until the next navigation. One shared
  module, `chats/recovery` (pinned for importmap hosts, like the
  controllers), now watches each surface's own
  `<turbo-cable-stream-source>` and the page, and asks for what was missed
  when the stream reconnects, when the page comes back after 10 seconds or
  more hidden, when the network comes back online (it asks Action Cable to
  check its socket at once instead of after its backoff, and catches up
  anyway: after a short outage the socket can look open while what was
  sent during it is gone) and when the page
  is restored from the back/forward cache or from Turbo's snapshot cache (a
  back navigation, a Hotwire Native stack pop). Never otherwise: a healthy,
  visible page fetches nothing. A hidden page never fetches; what it missed
  waits until it is seen. Triggers that arrive together make one catch-up,
  and catch-ups are at least five seconds apart.
- **A reconnect Action Cable never reported is seen.** When Action Cable
  reopens a socket that went quiet (the half-open connection of a phone that
  slept), it drops the old socket's handlers before its close event can
  arrive: subscribers hear "connected" again and never "disconnected", and
  the `reconnected: true` detail reaches only the first subscription
  confirmed. Every confirmation after the first now counts.
- **A page restored from Turbo's snapshot cache catches up.** It came back
  as old as when it was left, with no request: a thread restored by a back
  navigation missed every message sent since. Its stream sources are marked
  as they go into the cache, and a restored one catches up once it is live.
- **The inbox** reruns a refresh that arrived while another visit was
  loading, which Turbo ignores (`Session#refresh` skips one while
  `navigator.currentVisit` is set): a message landing mid-refresh was lost
  with a healthy socket. A refresh no longer rewrites the field you're
  typing in, no longer drops the search (see Changed), and a morph no longer
  strips the stream source's `connected` attribute.
- **The inbox refresh is durable.** `refresh_inbox_of` enqueues
  `Chats::InboxRefreshJob` straight from the after_commit instead of calling
  `broadcast_refresh_later_to`, which parked the refresh for half a second
  in an in-process timer (`Turbo::Debouncer`) before enqueueing it, so a
  deploy or a crash inside that window dropped it. At most one is queued
  per recipient: while one is queued and hasn't started, it stands for
  every write that commits before it runs (a short-lived marker in
  `Rails.cache`, removed by the job as it starts, before it broadcasts), so
  a burst is one job per recipient. A lost marker costs an extra job, never
  a missed refresh, and the marker expires after two seconds. Only a
  marker that is really there counts as "queued": a store that can't hold
  it (RedisCacheStore answers nil when a write fails; any store may raise)
  means the write queues its own refresh. Since another
  write may count on a refresh whose enqueue is still in flight, a failed
  enqueue is retried once, then the refresh is broadcast on the spot. Every
  refusal goes to `Rails.error` (raised, `false`, or a job the adapter
  declined), never up through the write that committed. The refresh
  tag carries `method="morph" scroll="preserve"`, so the inbox morphs
  whatever the host layout's refresh meta says, and no request id, since
  it may stand for several requests' writes.
- **The thread's catch-up asks on two cursors.** It sent only the newest
  `updated_at` it had rendered and the server appended what was created
  after it, so a message created at 10:15 and missed, while a bubble on
  screen was edited at 10:20, never came. Now `after=` (the newest creation
  on screen) decides what is appended and `changed=` (the newest change)
  what is replaced, and both scopes split on the same creation cursor
  (`created_after` / `created_through(…).updated_after(…)`). Each cursor is
  a moment to the microsecond plus the ids on screen at it (`after_ids=`,
  `changed_ids=`): a message missed in the very instant of one on screen,
  or a change missed inside the same millisecond as one on screen (the old
  cursor rounded up to the millisecond), is no longer lost. The cursors
  are reconciled moments: a complete render sets them (the page, a window,
  a history re-render), and so does a catch-up that arrived (its
  `chats_caught_up` action); a live bubble never moves them, since it can
  arrive after one that was missed (a message missed at 10:15, then one
  live at 10:20). What arrived live is named instead, at most 200 ids
  (`after_ids`, `changed_ids`, each id at most 64 characters); past that,
  or with `full=1`, the history is re-rendered. Kept on the element
  (`data-chats-reconciled`), so a dock window moved by a Turbo visit, or a
  restored snapshot, keeps them. Each catch-up is bound to one render of
  the thread (`render=`, echoed by the answer): an answer that arrives
  after the page or a dock window rendered the conversation again is
  dropped unrendered, and its cursors ignored — checked again by every
  stream of it at the moment Turbo applies it, a repaint later, so a visit
  or a window reload in between can't hand the old streams the new render.
  A history re-render is followed by one more catch-up from its own
  cursors once Turbo has actually applied it, however late that is, so a
  message written while that page was being built isn't lost. Every
  catch-up is bounded: a request with no answer after 15 seconds is
  aborted (a fetch can hang across a network interruption, and would
  otherwise stand in for every later one), a thread has at most one answer
  waiting for Turbo (a newer one, or the thread going away, drops the
  older one's leftover streams and stops watching for them — going away
  for good: a dock window Turbo carries across a visit is off the page
  until that render ends, which a host's asynchronous `turbo:before-render`
  can make last many tasks, and keeps its answer, decided only once every
  `turbo:before-render` has had its `turbo:render`, paired first in, first
  out; a render that runs past 10 seconds stops holding things up but stays
  paired until its own end, and one that never ends is forgotten after a
  minute), and only the
  answer's own streams are guarded (`data-chats-answer`), never a host's
  stream rendered at the same moment. A thread whose catch-up didn't apply,
  for any reason (its page rendered it away, the request failed, Turbo
  never got to it), is marked behind (`data-chats-stale`, on the thread
  element itself, so the mark travels with the dock and can't be
  forgotten while the thread exists) and catches up again when it
  connects, on its stream's confirmation and after every page render,
  through the same coalescing and 5-second spacing as every other trigger;
  only the answer of the newest catch-up clears it (they are numbered on
  the element, `data-chats-catch-up`), so an older answer that applies
  after a newer one failed leaves the thread marked; and nothing older
  than the newest catch-up that has applied (`data-chats-applied`) may
  apply after it, so an older answer arriving last can't put back older
  bubbles, read state or cursors. A catch-up always gets an answer built
  after it was asked: the same request asked in the same instant is made
  once, but asked while it is already on its way, it is made once more as
  soon as that one has its answer from the network (never waiting on
  Turbo to apply it), for everyone who asked meanwhile, each keeping its
  own `when` and its own outcome. An answer Turbo hasn't applied 10
  seconds after it joined the page is cancelled (its callers settle, and a
  thread stays marked behind), and neither a caller's hook that throws nor
  a stream that fails to render can leave an answer half-applied or its
  callers waiting. An empty
  thread, which used to ask nothing, asks from the epoch: its first message
  may be the one it missed.
- **The thread's catch-up is complete.** `GET /:id/refresh` now also
  replaces the read state (a read the stream missed left "Sent" where it
  should say "Seen"), catches reactions (a reaction now moves its message's
  `updated_at`, with `update_columns`, so the bubble is not broadcast twice),
  and, under `deletion: :hard`, lists the messages that still exist from the
  oldest rendered bubble on (`from=`), so the thread removes the ones that
  are gone (the `chats_prune` stream action). Catching up still reads
  nothing.
- **The unread badge and the dock catch up.** The viewer's own
  `chats_unread_badge` is wrapped in a `chats--unread-badge` controller (a
  `span.chats-unread-badge-live`, `display: contents`, so it changes no
  layout) that asks the new `GET /badge` for every unread badge on the page:
  the nav badge and the dock's, with the count the badge streams send
  (`unread_chats_count`). Someone else's badge stays live but doesn't catch
  up. The dock fetches the same, and reloads its recent list; each open
  window's thread catches up by itself. A message missed while offline
  never pops a window open late.

- **Both search forms are search landmarks.** `form_with … role: "search"`
  rendered no `role` at all (`form_with` drops HTML attributes it doesn't
  know unless they go through `html:`), on the inbox and in the dock.

### Changed
- A page now counts as having been away after 10 seconds hidden, not 60
  (the inbox and the thread used 60).
- A thread more than a page behind no longer gets a page refresh, which
  cleared the composer's draft and, in a dock window, refreshed the host's
  whole page: its history (`chats/conversations/_history`, inside
  `#history_conversation_<id>`) is re-rendered at the latest page, the
  composer untouched. An ejected thread whose scroller has no
  `id="<%= dom_id(conversation, :history) %>"` keeps getting the page
  refresh.
- The inbox's search keeps its query in the URL (`data-turbo-action=
  "replace"`, submitting to the inbox's own path), so a refresh re-renders
  the same results instead of the unfiltered list. The dock's recent list
  frame has `refresh="morph"`, so a reload keeps its scroll and its search.
- New: the `GET /badge` collection route, the `chats--unread-badge`
  controller, `Chats::InboxRefreshJob`, and `data-message-id`,
  `data-created-at-us` and `data-updated-at-us` on every bubble, which no
  longer carries `data-updated-at-ms`.
- **If you wrapped the inbox in a reconciler of your own** (a
  stream-reconciler controller around `turbo_stream_from … :chats_inbox`),
  remove it: two on one page both fire, and the gem's covers what yours did.
  **If you ejected the inbox**, keep the
  `data-controller="chats--refresh-inbox"` element around its
  `turbo_stream_from chats_current_messager, :chats_inbox` (an inbox without
  it doesn't catch up), and add `turbo_action: "replace"` to the search
  form's `data` and `url: request.original_fullpath.split("?").first`. An
  ejected message partial (with only `data-updated-at-ms`) keeps the one
  cursor it had (`since=`), and a hard delete missed while offline stays on
  screen until the next load.

## [0.5.0] - 2026-10-18

The messaging dock. LinkedIn and Steam keep your conversations in small
windows in the bottom-right corner while you go on using the app; one line
in a layout, `<%= chats_dock %>`, now does that. **No migration.** The dock
is opt-in, but a few things change without asking, all under Changed: a
conversation with no messages is no longer listed, a direct thread the
host's policy no longer allows says so up front, a hover prefetch no longer
reads a thread, and the thread body moved into a partial.

### Added
- **`chats_dock`**, the messaging dock: `aside.chats-dock`, fixed to the
  bottom-right corner, holding the floating windows (`#chats_dock_windows`,
  newest nearest the panel) and the panel. The panel is a `<details>`: its
  header is the bar (the viewer's avatar, "Messages", the unread badge),
  and open it has the inbox's search, the viewer's most recent inbox rows
  (stacks, verified badges, a bell-slash on muted ones, previews, unread
  counts) and "See all messages". It opens without JavaScript, and its
  rows, search and links are real links and forms. Options: `windows:` (3),
  `recent:` (10), `launcher:` (true; false drops the phone's round button
  for a host whose own nav opens the sheet) and `everywhere:` (see below).
  Renders nothing for a signed-out visitor and nothing on the engine's own
  pages.
- **It survives Turbo visits, per viewer.** The element is
  `data-turbo-permanent`, so its windows, drafts, scroll positions and
  subscriptions ride along from page to page. Its id names the viewer
  (`chats_dock_<messager key>`), so a visit that lands on another
  account's page (a sign-out and sign-in, an account switcher) never
  matches it, and every window carries its viewer and is dropped on connect
  if it names someone else. Because the server can't remove a permanent
  element from the next page, the dock also hides itself on any page with
  `data-chats-dock-hide`; the engine's inbox and thread roots carry it.
  `everywhere: true` renders the dock on the engine's pages and ignores the
  attribute.
- **Floating windows.** A window is a turbo frame
  (`dom_id(conversation, :window)`) loading `GET /:id?window=1`, which,
  from inside a frame, renders the same thread body as the page, rooted at
  `.chats-thread.chats-thread--window` (never `.chats`, the full-page
  shell), under a compact header: a title button (avatar, name, verified
  badge, subject, the waiting count) that minimizes it, the
  `conversation_header_actions` slot in a ⋯ menu with the page's locals
  (`blockable:` included), ⤢ for the full page, – and ×. Until the thread
  arrives, and if it can't, the window shows the same header over
  "Loading…" or "Couldn't load this conversation." with "Try again"; a 404
  (left, blocked) closes it, read from the response before Turbo acts on
  it (an error page carrying `turbo-visit-control`, as Rails' own do, would
  otherwise take the whole page with it), keeping what was typed in it; a
  5xx shows the failed shell. An empty conversation's window says "Say
  hello to …". The dock never opens a window for a conversation the page itself
  shows (the streams address the thread's DOM ids, which must exist once).
- **What fits.** `min(windows, floor((viewport − 312) / 344))` windows beside
  the panel: two at 1280px, one at 768px, three from 1344px. Opening one
  more closes the least recently used window that isn't in use. A window in
  use (it has the focus, or unsent text) is never closed to make room: it
  folds to a 104px header (avatar and ×, `--chats-dock-squeezed-width`)
  beside the new one. Two limits are absolute: never more than `windows:`
  windows, folded ones included, and never wider than the viewport beside
  the panel. An open that can't fit even with every window in use folded is
  declined, changing nothing, and the row's link (or the `dock: true`
  button) opens the conversation's page instead; a pop-up just doesn't
  happen. Unfolding a folded window (its title, a row, a repeated `dock:
  true`) makes room exactly as an open does, and when it can't, the window
  stays folded. Narrowing the viewport closes what isn't in use and folds
  what is, the focused window last; when even a row of folded headers is
  too wide, it closes the least recently used windows in use too, keeping
  their unsent text, and announces nothing. A window the viewer closes
  keeps its unsent text for when it comes back. Every way a window leaves
  the dock (closed, evicted, declined, gone for the viewer, shown by the
  page, another viewer's) goes through one path that keeps the draft and
  resyncs the rows and the phone sheet.
- **Reading waits for the viewer.** A window never reads on render. A
  minimized window never marks anything read, and a window that popped
  open, or came back after a reload, marks messages read only once the
  viewer focuses it, presses in it or scrolls it: the dock sets
  `data-chats-minimized` and `data-chats-active` on the window and the
  thread controller obeys them, checking again when its delayed read fires
  (state, not geometry: a folded window's scroller also loses its padding,
  but a size check alone is never trusted). A window the viewer opened
  is engaged from the start. The thread page has no gate and is unchanged.
- **Live, server-driven.** A new per-messager stream,
  **`[messager, :chats_dock]`**, gets one render per participant per event
  (`chats/dock/_update`): the dock's badges (the nav badge's count) when
  the count moves, and a signal template (`chats/dock/_signal`). The signal
  reloads the recent list, debounced, for every participant, the sender and
  edits and deletes included. For a message the participant would be
  notified about (`Participant#notifiable_for?`: not theirs, not muted, not
  a headless seat) it also names the conversation, the sender and the
  unread count there. The dock then pops that conversation's window open,
  waiting with the accent header and its count, and announces "New message
  from …" in a polite live region (at most once per conversation every 30
  seconds, never for the window you're typing in). The pop-up only happens
  in dock mode, never moves the focus, never for a conversation the viewer
  closed in the last five minutes, and never by closing a window someone is
  using; with no room, there's no pop. **The signal names a conversation
  only to a participant who can see it** (`messager.chats`, so blocks and
  `inbox_scope` apply), because the dock's list and window refuse anything
  else. The badges stay truthful either way. No polling.
- **Memory.** Per viewer in `localStorage`: `chats:dock:v1:<messager key>`
  (which windows, minimized or folded or not, when each was used, the
  recently closed ones and the panel) and `chats:draft:<messager key>:
  <conversation id>` (unsent text, saved as you type and whenever a window
  goes, by any path, a refused or missing one included, and before a
  failure (5xx, network) replaces the window's content; restored the moment
  the window's composer appears, cleared on send, kept seven days). A saved
  draft goes back only into an EMPTY composer: if something was already
  typed there, it stays, and the saved draft is never replaced by anything
  shorter, so neither text is lost. A reload restores the
  saved arrangement as it was, folded windows included, up to the cap, then
  fits it to the width there is now by the resize rules; none of them is
  engaged. The panel comes back in dock mode only, and the phone's sheet
  always starts closed. Every access is guarded,
  so a browser that refuses storage only means forgetting.
- **Phones.** Under 700px wide or 500px tall the closed bar is a 56px round
  launcher, the open panel a full-screen sheet, and a conversation one
  full-screen window with ← back to the list, sized to the visual viewport
  so the composer sits on the keyboard. The list behind a window is `inert`
  until Back, which returns the focus to it. The sheet makes the rest of the page
  `inert` (the siblings of the dock and of each of its ancestors, so a
  layout that wraps the dock never inerts the sheet) and stops it scrolling. Inputs are 16px, so iOS doesn't zoom.
  Messages never pop a window on a phone. The layout is one media query, so
  it applies before JavaScript connects and without it; the controller reads
  the same query.
- **Keyboard and screen readers.** Escape unwinds from the inside out: the
  thread's popup or photo, an edit (the composer now cancels one on
  Escape), the ⋯ menu, then the window (minimized, focus to its title), the
  panel (closed, focus to the bar); on a phone, the window back to the list,
  then the sheet closed. Focus goes into a window only when the viewer
  opened it: its composer on a desktop, ← on a phone. Close returns the
  focus to whatever opened the window. Focus rings are inset, the history
  scroller is focusable, the badge is not a live region, and the bar reads
  "Messages, 3 unread" from its own text.
- **`chat_button_to(other, dock: true)`** posts `dock=1`, and
  `ConversationsController#create` answers a Turbo Stream that appends the
  conversation's window to `#chats_dock_windows`. When that conversation is
  already in a window, the dock focuses it instead of letting the append
  replace it, so nothing typed is lost. It belongs with `chats_dock`: on a
  page without the dock the stream has no target and does nothing. Without
  Turbo, and without `dock`, the redirect is unchanged.
- **`chats_dock_opener(conversation)`** and **`chats_dock_toggle`**: data for
  any link on the page to open that conversation's window, or the dock's
  panel (the sheet on a phone). They stay plain links without a dock or
  JavaScript. **`chats_muted?(conversation, viewer)`** reads the viewer's
  seat.
- **`GET /dock`** (`dock_conversations_path`), the panel's list:
  `Chats::Inbox` with `?q=` and `?recent=` (1 to 50), rendered into the
  `chats_dock_list` frame without a layout. The inbox answers a request from
  that frame (the dock's search, which submits to the inbox so that it
  lands on the full inbox's results without JavaScript) with the same list.
- **`Chats::Inbox.for(viewer, limit:)`**: how many rows come back
  (`config.inbox_limit` by default, never more). A smaller limit is a
  smaller query; a search still looks through the whole `inbox_limit`
  window.
- **`Chats::Conversation.with_messages`**: conversations that have at least
  one message, system messages and tombstones included (`last_message_id`
  set, which the denormalized pointer already gives). It doesn't mean a
  person wrote there: a thread holding only a system note is listed.
- **The `dock_panel_footer` slot** (receives `viewer:`): your own link next
  to "See all messages".
- **Theming.** The dock's variables are declared on `:where(.chats-dock)`,
  not `:root`, so a host re-pointing `--chats-bg` or `--chats-accent` on the
  dock reaches them: `--chats-dock-z` (40), `-offset` (bottom clearance),
  `-inset` (right edge), `-gap`, `-bar-height` (48px), `-panel-width`
  (288px), `-panel-height`, `-window-width` (336px), `-window-height`
  (480px), `-radius`, `-bg`, `-header-bg`, `-hover` (`#f9fafb`: muted text
  at 4.63:1, where `--chats-surface` gives 4.39), `-edge`, `-shadow`,
  `-unread-bg` / `-unread-text` (the accent pair), `-focus`,
  `-title-font`, `-launcher-size`, `-duration`, `-ease`, plus
  `--chats-safe-top/right/bottom/left` on `:root`. Nothing leaves a
  transform, filter or `contain` on the dock or an expanded window, which
  would trap the thread's fixed popup and photo preview inside it; entrance
  animations end at `transform: none`, and `prefers-reduced-motion` turns
  them all off. Strings under `chats.dock.*` in `en` and `es`. The
  controller is pinned as `controllers/chats/dock_controller`, and
  `rails generate chats:views` has a `dock` group (`app/views/chats/dock/`).

### Changed
- **A conversation with no messages is never listed.** Opening a
  conversation (`chat_with`, the Message button) creates it, and until now
  the inbox listed it straight away as a "No messages yet" row. Every list
  now reads through `Chats::Conversation.with_messages`: the inbox rows,
  a stack's rows and its `open_count` / `unread_count`, search, the
  `?with=` view and the dock. **If your inbox showed rows for threads
  that were opened and never used, it no longer does.** The conversation
  still opens when addressed directly (the thread page and its dock
  window work), because `Messager#chats`, the relation every engine lookup
  authorizes through, is unchanged; use `chats.with_messages` for lists of
  your own. `unread_chats_count` already agreed (an empty conversation has
  nothing unread).
- **A direct thread nobody may write in says so up front.** When the host's
  `can_message` policy no longer allows the pair, or the other account is
  gone, the thread (page and window) shows "You can't message this person."
  in the composer's place, through the locked-composer box (same id; the
  `locked_composer` slot gets it as `notice:`), instead of a composer whose
  sends fail. `_locked_composer` takes an optional `notice:` local.
- **A hover prefetch never reads a thread.** Turbo 8 prefetches a link when
  the pointer rests on it, and `ConversationsController#show` used to read
  the thread on that request, so hovering an inbox row cleared its unread
  badge. A request with `X-Sec-Purpose: prefetch` no longer reads; the
  visit does. The dock's list turns prefetch off altogether.
- **The thread body moved into `chats/conversations/_thread.html.erb`.**
  It holds the `chats--thread` element and everything inside it except the
  header: the `turbo_stream_from`, the scroller with the older-pages frame
  and the «new messages» line, read state, typing, the long-press popup,
  the photo preview and the composer. It renders as a partial layout whose
  `yield` is the header, with locals `conversation:`, `messages:`, `more:`,
  `first_unread_id:`, `counterpart:` and `window:`. `show.html.erb` is now
  its header wrapped in that partial. The page's DOM gains
  `data-chats-dock-hide` and `data-chats--thread-read-pending-value="false"`
  on its root and `tabindex="0"` on the scroller. **If you ejected
  `show.html.erb`**, your copy keeps rendering the page as before; add
  `data-chats-dock-hide` to its root if you render the dock everywhere.
  Dock windows render the gem's `_thread` (or yours, if you eject it), so a
  restyle that lives in your `show.html.erb` doesn't reach them: move it
  into an ejected `_thread.html.erb` to style both.
- **Grouped inbox rows cost two queries in all.** A stack's `open_count` and
  `unread_count` were two aggregates per stack; they are now two grouped
  queries for every stack the inbox shows, so an inbox (or a dock) with many
  stacked counterparts stays constant-query.
- The unread badge partial (`chats/shared/_unread_badge`) carries
  `data-chats-unread-badge`, the mark every unread badge has, the dock's
  included. Its broadcast still targets `#chats_unread_badge`, so a badge
  ejected earlier keeps updating unchanged. Add the attribute if your own
  CSS or JS wants to find every badge.
- The inbox row partials (`_conversation_row`, `_group`) take an optional
  `dock:` local that marks their link as a dock opener, and a direct or
  group row shows the bell-slash when the viewer muted it. Rows ejected
  earlier still work in the dock; they navigate instead of opening a
  window.
- **The composer's fields have per-conversation ids**
  (`dom_id(conversation, :message_body)`, `:message_files`), instead of
  `form_with`'s `message_body` / `message_files`. A page can now hold
  several composers, and Turbo restores focus by id after rendering a
  stream, so a shared id moved the cursor into another window's composer.
  CSS or JS that selected `#message_body` should select `.chats-composer__input`.
- The long-press Edit event (`chats:edit-message`) now carries its thread
  element, and a composer only starts editing for a message of its own
  thread, since a page can hold several threads now. The check lives in
  the controller, so ejected composer views get it too; a host that pinned
  its own `composer_controller` reacts to every thread's Edit, as before.
- The dummy app has a real importmap setup (Turbo, Stimulus, the stock
  eager loader) and a host home page with the dock, which is how the
  screenshots were taken. `test/system` measures the dock's rendered layout
  in a headless Chrome (capybara and selenium-webdriver join the test
  bundle). Under CI (`CI=true`) Chrome is a prerequisite: the tests fail
  when it can't start, and the workflow checks for it first; on a machine
  without Chrome they skip. The suite prints how many ran.

## [0.4.2] - 2026-10-17

### Changed
**Upgrade note: your `can_message` policy now runs on every direct send,
not only when a thread is opened.** Read yours before upgrading. If it
means "who may OPEN a conversation" (a listing must be live, a ride must be
accepted), existing threads will stop taking messages the moment it turns
false for the pair — which is usually what you want (a block already
behaves this way), but is a change. If it is expensive, it now costs that
on every direct message; make it cheap or cache what it reads. It must not
raise: an exception escapes the send like any other host error. Group
conversations and system messages are unchanged.

- **`can_message` holds on every direct send.** A block placed
  mid-conversation already stopped the next message; the host's policy
  turning false did not, so a pair allowed when the thread was opened kept
  talking after an account was banned or a membership ended. Every text
  message into a direct conversation now re-runs `Chats.can_message?`
  exactly like the block check: `:blocked` when either side blocked the
  other, `:not_allowed` (new, in `en` and `es`) when the policy says no.
  The policy is asked last, only of a send that is otherwise valid (a
  stranger, a locked thread or an empty body is refused before it runs).
  The composer answers with its errors stream as before.
- **A direct thread with nobody on the other side takes no messages.** When
  the counterpart's account was destroyed, its seat went with it (the
  gem's `dependent: :destroy` on participations); a text message into that
  thread is refused with `:not_allowed` instead of slipping past both the
  block and the policy checks. The thread stays readable.

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
