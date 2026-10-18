# Manifold — design

Manifold is a desk, not a set of windows. Terminals, files, notes, folders,
web pages and searches are **blocks**; you arrange blocks to work, and an
arrangement is itself a block you can name and come back to. Nothing is
closed. What isn't in use is collected out of the way, and anything can be
found and recalled from history. Blocks live on hosts — this Mac, a dev
box, a server — and one window shows blocks from several at once.

This document describes where Manifold is going. The app as it stands
(README.md) is the first sketch of it: sheets that are cheap and put
themselves away, state on a server, the UI only a renderer.

It borrows heavily from apex (~/src/apex/DESIGN.md, sections cited as
apex §n): its replicated logs, leases, exec entries and wire protocol. What
differs is the shape of the thing: apex is one session per host with acme's
windows; Manifold is blocks from many hosts, linked, in arrangements.

---

## 1. Principles

- **Nothing is closed; nothing is lost.** Taking something off the desk
  only takes it out of view. Every block keeps its history, and anything
  set aside is recallable.
- **What can't be rebuilt is held.** A block with unsaved changes, a
  running job, or anything else not reconstructible from its log is never
  collected. Everything else may be.
- **Everything is linked.** Actions leave links behind (this terminal opened
  that file; this search found that line), so recall can walk from one
  thing to what was around it.
- **State on hosts, rendering on the client.** A host runs a server that
  owns its blocks' effects (files, processes) and their logs. The client
  mirrors what it shows and leads what you edit, so typing never waits on a
  network (apex §1, §4).
- **Few primitives.** Everything in the UI is built from the nouns in §2.
  A new kind of thing is a block kind and a lens, not a new subsystem.

---

## 2. Model

### 2.1 Nouns

| noun | what it is |
|---|---|
| **Log** | an append-only sequence of entries, with snapshots that are a pure function of a prefix |
| **Block** | a thing with identity: an id, a kind, and a deterministic `apply` from its log to its state |
| **Exec** | an entry that asks for an effect, naming who performs it; the outcome returns as entries |
| **Link** | a typed edge from one block to another, possibly across hosts |
| **Arrangement** | a block whose content is placements of other blocks, laid out |
| **Lens** | a way of rendering a block (an editor or a preview of one text block) |
| **Host** | a server owning blocks: their logs, files and processes |
| **Attachment** | a client's standing with a host, holding leases on the shards it leads |

A **placement** is one appearance of a block in an arrangement: its own id,
the block it shows, the lens, and where it sits. A block may be placed in
many arrangements, and more than once in one; an edit shows in all of them.

### 2.2 Identity

A block's id is `host/ulid`: the host it lives on, and a ULID (time-sorted,
made without coordination). Ids never change; a file block keeps its id
through renames and moves, its path being an attribute, so links to it
survive. Hosts are named when first attached (`local`, `devbox`) and carry
a stable key so a rename of the machine doesn't orphan anything.

Every entry carries its host's hybrid logical clock: a timestamp that is
close to wall time but never runs backwards and orders causally related
entries. Within a host this orders everything exactly; across hosts it
lines logs up to within clock skew, which is what scrubbing across hosts
needs (§3.4).

### 2.3 Block kinds

| kind | state | effects (host) | held when |
|---|---|---|---|
| `text` | rope, encoding, line endings, clean version; a file's path, or none for a note | read, write, watch the file | version ≠ clean version |
| `terminal` | grid rows, cursor, modes, cwd, title; transcript on disk | the pty and its processes | a job other than the idle shell is running |
| `directory` | path, entries, sort | list, watch, rename, move, trash | never |
| `web` | url, back/forward list, title | none (the client loads it; §7.6) | a form being filled in |
| `image`, `pdf` | path, page, zoom | read | never |
| `search` | query, scope, results | run the search | while running |
| `diff` | two sides: blocks, or one block at two points | none | never |
| `git` | repository path; status, log, blame | run git | while running |
| `process` | the host's processes | list, signal | never |
| `agent` | the transcript, the turn in progress | the agent process | a turn is in progress |
| `arrangement` | placements, layout, lens, title | none | never (but see §3.3) |

A Markdown preview is not a kind: it is the `preview` lens on a `text`
block. A note is a `text` block with no path, its log its storage.

### 2.4 Shards

As in apex (§3.2), state is split into **shards**, each with its own log
and lease. Here the unit is simply the block, plus a few per host.

| shard | one per | leader |
|---|---|---|
| block | block | leasable: the client editing it, else the host; terminals are **pinned** to their host |
| `links` | host | host: the links whose source lives there |
| `registry` | host | host: which blocks exist, their kind, title, created, last seen, state (§4) |
| `metalog` | host | host, pinned: shards, attachments, leases, fencing (apex §4) |

Selections and scroll positions live in the block's own log, keyed by
placement: an edit must adjust every selection on the text in one order on
every replica (apex §3.2). An arrangement records where a placement is; the
block records what the placement has selected.

`apply` is pure: no clock reads, no randomness, no I/O. Anything with an
effect is an exec (§5).

---

## 3. Arrangements

### 3.1 Layout

An arrangement's content is an ordered list of **columns**, each an ordered
list of placements with sizes. That one structure is shown by three lenses:

- **Stacks** — today's Manifold. Each column shows its last placement; the
  ones before it are sheets beneath, their edges peeking out. ⌘E files
  through them.
- **Tiling** — acme's, as apex has it (apex §11, *Tiling, as built*). Every
  placement in a column is visible, stacked vertically. A new one takes the
  biggest empty space, else half of the biggest placement. Placements grow,
  maximize within their column, and columns collapse to strips at the
  edges. Placement is automatic; you nudge, not lay out.
- **List** — one row per placement: kind, title, host, state, last seen.
  A row opens in place, live, to its block; the list is also the
  arrangement's table of contents.

Switching lens changes nothing in the arrangement. Sizes are kept per lens
(stacks need none; tiling needs heights), so going back and forth is
lossless. The arrangement's log holds placement and layout entries:
`Place{placement, block, lens, column, at}`, `Move`, `Resize`, `Focus`,
`Remove{placement}`, `Lens{arrangement lens}`, `Title`.

### 3.2 Names and the desk

An arrangement has a title and nothing else to find it by: recall is by
search (§6), not a path. The **desk** is what's in the sidebar: the
arrangements in use, most recently settled on first, the named ones that
you've kept there. Taking an arrangement off the desk doesn't end it.

An arrangement can be shown in a window of its own or as one of the desk's
tabs in a window, as Safari has both: drag a tab out for a window, a window
in for a tab. Several windows may show the desk; each OS window shows one
arrangement at a time.

Arrangements nest: a placement may show another arrangement, as a card (its
title and a small live picture of it) or opened in place. A project is an
arrangement of arrangements; nothing more is needed for folders.

### 3.3 Naming is keeping

An **unnamed** arrangement is scratch: placements not seen for a while are
collected out of it (§4), and it drifts off the desk when unused. Naming
one makes it a place: its placements stay put however long they go unseen,
though the blocks behind them may go dormant to free their resources and
come back when the arrangement is recalled.

### 3.4 Scrubbing

Every arrangement can be scrubbed through its history, in two ways:

- **The layout then, the contents now** — what was on this desk last
  Tuesday, shown live. Cheap: one log.
- **Everything as it was** — each placed block rewound to the same moment,
  by clock (§2.2). Exact within a host, within clock skew across hosts.

Either is read-only. *Restore* appends a new version that makes the
arrangement so; nothing is reverted destructively. A single block can be
scrubbed the same way, and two points of it compared in a `diff` block.

### 3.5 Cards, and what shows on hover

What Prism (reflect-mac) does with a column of notes is worth taking
whole, because its nouns are already ours. A Prism *sheet* is what a
column showed, where it was scrolled, a picture of it when it was left,
whether it is pinned, and when it was last seen; a column's stack of
sheets is its history, and it is *visible*: bunched in the title bar,
dealt out across the top when hovered, each shown as it was while the
pointer passes over it, live while ⌥ is held, gone back to when clicked,
yellowing as it ages. A note's backlinks are bunched at its foot the same
way and dealt out upward, each with the words around the link. A note
shown among others is a *card* — full, a summary (cover, headline, a
snippet), or collapsed to its name — and sits in as many views as it is
placed in. Rows shown away from their note (tasks, the rows links are in)
are editors, and what is typed goes back where it came from. And resting
the pointer on a link shows the target as it reads, in a floating card
with its actions.

A Manifold placement is nearly a sheet already: the text block's log
keeps each placement's selection and scroll, the registry keeps when a
block was last seen, and named and held stand in for pinned. The links
shard records what opened what. What is missing is a **picture of each
placement, taken when it is covered or put away**, kept outside the logs
(a cache by placement id, as Prism keeps snapshots in app state, never in
the notes), and a **card** that can show any block small. With those,
every "as it was, on hover" falls out — and, since every block has a log,
a card can show a block *as it was when the link was made* beside *as it
is now*, which Prism cannot.

What that gives, in the order they build on each other:

1. **A card for any block reference.** One floating panel (Prism's
   `LinkCard`: non-activating, kept while the pointer is on the reference
   or on the card), shown wherever a block is named — finder rows, sidebar
   rows, the strips under a stack, related items, search hits, git
   changes, diff file headers, the links at a block's foot. Text blocks
   as a read-only `TextView`; terminals as their last screen, from the
   transcript the host keeps; folders as a short listing; web as icon,
   title and address; a search as its count line; a git block as its
   branch and changes. Actions: Open, Open Beside, Recall Here; and, where
   the reference carries a stamp, *as it was then*.
2. **Stack strips that deal out.** Hovering the strips under a stack fans
   the sheets beneath out as cards — name, snapshot, age tint from
   `lastSeen` — the column previews the one under the pointer, ⌥ peeks it
   live, a click brings it up. The ⌘E cards drawn the same way, so the two
   are one thing seen from two sides.
3. **Links at a block's foot.** "Opened from · 3" and "opened here · 5",
   bunched where Prism puts backlinks, dealt out on hover with context
   (the terminal line a path was ⌘-clicked on; the editor line that named
   it; the search hit), recorded on the link entry when it is made.
   Clicked, the block is recalled beside. The links shard, made visible
   where it matters.
4. **The card lens for every block.** Collapsed, summary, full, as
   `NoteCardBlock` has them, remembered per block. A text block's summary
   is its first heading and lines (its cover, for a note with a picture);
   a terminal's, its cwd and last command; a search's, its count; a git
   block's, its branch and change count. An arrangement in the list lens
   is then a page of cards, and a note placed in several arrangements is a
   note in several views.
5. **Slices edited where they are.** A search hit's line, a diff's new
   side, the context line of a link: each a byte range of a text block,
   each an editor whose typing is an `.edit` entry on the block, as
   Prism's `TaskEditor` writes a task back to its note. The log makes
   this nearly free, and it is the same undo and the same history.
6. **A scrubber down the editor**, Prism's `ScrubMark`s fed by the
   language server's document symbols (functions and types; headings for
   Markdown): ticks down the left edge, a tip on hover, a click to go.
7. **The desk's own history.** The desk shard scrubbed as an arrangement
   is: which arrangements were on the desk, and which was selected, at a
   moment — everything-as-it-was one level up; and a timeline lens that
   lists blocks by the day they were made or last seen, the empty days
   folded to "⋯ Sep 21–25 · 5 days" as Prism's `GapView` folds them.

Two smaller touches to take as they are: **aging** — strips and cards
yellow as a block goes unseen, which is the collection ladder (§4) made
visible — and **⌥ to peek live** against hover to peek the picture.

---

## 4. Lifecycle and collection

Every block is in one of four states, recorded in its host's registry:

| state | meaning |
|---|---|
| **live** | placed in an arrangement on screen |
| **warm** | off screen, its resources kept: a process running, a file watched, text in memory |
| **dormant** | only its log and last snapshot; resources rebuilt on recall |
| **held** | not reconstructible (§2.3, *held when*); never collected, whatever else |

Collection moves blocks down the ladder and placements out of unnamed
arrangements; it never deletes a block. Policy, per host:

- A placement unseen for an hour (as now, configurable) leaves an unnamed
  arrangement, unless its block is held.
- A block off screen goes from warm to dormant after a while depending on
  its kind; a terminal whose shell is idle goes dormant by keeping its
  transcript and cwd and ending the shell, and on recall starts a new shell
  there under the old transcript (what Manifold does today after a server
  restart). That loses what lived only in the shell — its environment,
  shell variables, history not yet written — so it is never silent: a
  terminal brought back this way says so where its old session ends (a
  rule across the transcript, "new shell — the last one ended after 3 h
  idle"), and its placement and finder entry show a dormant terminal as
  such before you go to it.
- Logs are compacted to snapshots at intervals. How far back history is
  kept at full resolution, how coarse it gets after, and how much undo a
  block keeps are retention settings, per block kind, overridable per block
  and per arrangement (a named arrangement may keep its blocks' history
  longer). The defaults are a starting point to be tuned with use: text
  logs kept in full (they are small), terminal rows thinned after a while
  (they add up), undo as deep as the text's history.

Every number in this section — idle times, retention, thinning — is a
setting the core reads, never a constant in it, so policy can be tuned
without touching the model.

---

## 5. Exec and proposals

Unchanged from apex §5. The leader of a shard appends entries; an effect
is an `Exec{what, handler}` entry, performed once, live, by the node
matching its handler (the client, the block's host, or a tool), whose
outcome comes back as entries or as a **proposal** the leader lowers into
entries. Intents (`SetContent`, `ReplaceRange{version}`, `Place`) are
evaluated by the leader against its live state, so there is no base-version
race. Saving a file is the client leading `Exec{Save, host}`; the host
writes and proposes `Clean{version}`.

Cross-host operations are ordinary execs: ⌘-clicking `main.go` in a
terminal on `devbox` asks devbox to resolve it, and the answer is a
proposal to the arrangement (which may live on `local`) to place
`devbox/<id>` beside the terminal, plus a `Link` on devbox.

---

## 6. Links and recall

### 6.1 Links

A link is `Link{from, to, kind, at}` in the `links` shard of the host the
`from` block lives on. Kinds:

| kind | made by |
|---|---|
| `opened` | ⌘-click, Open, a link followed |
| `found` | a search result, grep output followed |
| `output` | a command's output (a terminal, an agent) naming a file |
| `cwd` | a terminal's working directory (to the directory block) |
| `source` | a preview, a diff side |
| `mention` | `[[title]]` or a block URL in text |
| `placed` | placed next to each other in an arrangement, by you |

Each host indexes the links pointing at its blocks; a client merges the
indexes of every host it is attached to, so backlinks cross hosts.

### 6.2 Recall

One finder (⌘O, ⌘P) over everything every attached host knows: block
titles and paths, note and transcript text, arrangement titles, recent
searches. It ranks by frecency and text, and shows each result's state,
host, and where it was last placed. Alongside it:

- **Back and forward** through what you settled on, across arrangements.
- **Related** — a panel for the focused block: its links both ways, the
  arrangements it appears in, what was placed beside it.
- **Timeline** — what you settled on, across everything, by time; the
  long version of ⌃⇥'s order.

---

## 7. Lenses

A lens names the block kinds it renders, makes an `NSView` for a placement,
and keeps its placement state (selection, scroll, folds) in the block's
log. Lenses run on the client; they read mirrored state and append entries.

### 7.1 Editor

Manifold's own text view, not TextKit: a rope (UTF-8 chunks in a B-tree,
with UTF-16 and line indexes for AppKit and Core Text), laid out a visible
line at a time with Core Text and cached per line. Owning the model is what
lets every edit be a log entry from a remote leader or a local key, and
makes multiple cursors and very large files tractable.

What it is to use, modelled on Panic's Nova, without syntax highlighting:

- Proportional (Mona Sans) or fixed-width text from the theme, as now.
- Multiple cursors and selections; select next occurrence; column
  selection with ⌥-drag.
- Line operations: move, duplicate, delete, join, sort; indent and
  outdent; comment toggling from a small per-language table.
- Bracket and quote pairing; indent guides; invisibles; soft wrap.
- Find and replace in the file (regex, case, whole word), and across files
  as a `search` block.
- Folding by indentation; go to line; go back and forth through edits.
- A git gutter (changed, added, deleted against HEAD), from the `git`
  host service.
- Encoding, line endings and permissions kept; reload on change with
  unsaved changes kept and offered, as now.
- The whole Mac text system: `NSTextInputClient` (marked text, IME),
  services, dictation, spelling on request, accessibility.

Language servers run on the file's host (§8), one process per language and
workspace root, configured in the settings (language, extensions, command,
root markers, on or off): the host feeds each the text of the blocks
placed in editors as it changes (whole, a moment after the last edit), and
answers the editor's questions — definition, references, hover, rename,
formatting, completion — in byte offsets of the block's text, mapping the
server's paths back to the blocks open on them. Diagnostics go to every
client. The app sends every host the same table, and the set of blocks
placed, so a server knows what's open after either side restarts.

### 7.2 Preview

Markdown rendered by cmark-gfm into a web view, as now, on a `text` block.

### 7.3 Terminal

Ghostty, as now. Its grid rows are the terminal block's entries (apex
§3.3: the emulator has no serialisable state, so rows, not bytes), mirrored
to the client; input is sent to the pinned host. A terminal recalled from
dormancy marks the seam between its old shell and the new one (§4).

*As built.* The grid isn't logged yet: the host keeps each terminal's raw
output in a replay buffer (and on disk in `history/`), and a terminal
attaches to its shell through `manifoldd attach`, as before blocks. The
block's log holds its working directory, title, and shell starts, ends
and dormancy. Rows as entries wait on a server-side emulator, which
remote hosts (§8) will need.

### 7.4 Directory

Finder's, in the content area: list (sortable columns: name, date, size,
kind), column, and icon views; inline rename; Quick Look; drag to and from
Finder and other placements; git status badges; works the same on a remote
host. Opening an entry places its block beside the listing and links it.

### 7.5 Image, PDF, diff, git, search, process, agent

Each its kind's natural view: PDFKit and an image view (zoom, pages); a
side-by-side and inline diff; git status, log and blame as lists that open
diffs and files; search results grouped by file with context, live while
running; a process list (sort, filter, signal); an agent's transcript with
its tool calls folded.

### 7.6 Web

An embedded browser (WKWebView) on the client: address bar, back and
forward, find, a reader view. Where a page is loaded from is the block's
choice, shown in its address bar and switchable at any time:

- **From here** — the client's own network, as any browser.
- **From its host** — through a port forwarded over the attachment's
  connection, so `localhost:3000` in a web block on `devbox` is devbox's
  dev server, and a host's private network is reachable as it is there.

A web block made from a remote block (a URL ⌘-clicked in a terminal on
devbox) starts out loading from its host; one made here, from here. A web
block's history is its log; scrubbing it walks the pages it showed.

---

## 8. Hosts, attachments and the wire

### 8.1 Processes

- **`manifoldd`**, one per host per user: the logs, the registry and links,
  ptys, the file system, the search and git services.
- **The app**, attached to any number of hosts at once, one connection
  each. It mirrors the shards its placements show and leads the ones you
  edit.
- **Tools**: the `manifold` command and scripts, speaking the control side
  of the same protocol (open, find, place, link, read a block).

The local host's server starts with the app, as now. A remote one is
reached through a provider, as apex does it: `ssh` built in, or a
`manifold-remote-<provider>` command given a destination and a command to
run there. The app probes the host (`uname -sm`, the sha256 of
`~/.manifold/bin/manifoldd`), uploads the bundled server for that platform
if it differs, and runs `manifoldd bridge --name NAME` there, which starts
the host's server if need be and pumps the same frames between its stdio
and the host's socket; nothing listens on the network. Shells on any host
get `$EDITOR` set to open files in the app, beside the terminal, waiting
until they're taken off.

### 8.2 Leadership

*As built.* One host (the local one) and one attachment: the app leads
text, web, arrangement and desk shards, the host the rest; the host
checks that an append continues its log and, if not, sends the shard back
whole. Epochs, fencing and resuming an attachment are not implemented;
`manifoldd attach --stdio` and several hosts in one window are the next
milestone.

Apex §4 as is: attachments are explicit and survive reconnects; leases are
per shard and granted to attachments; fencing by epoch; a new attachment
reclaims leases from a stale one. Several attachments to one host, from
several machines or several people, are therefore possible in the model;
for now there is one user, and a host gives everything to its newest
attachment. Sharing (two people on one block, presence, permissions) is
left open, and nothing here should rule it out. A client that loses a host keeps showing
that host's placements from their last snapshots, greyed and read-only,
and resumes from its last acknowledged sequence when the host is back.

### 8.3 Frames

Length-prefixed binary frames (`u32` length; a compact binary encoding of
the same `Codable` types the logs use, in place of today's JSON). Client to
host:

```
Hello{host key, attachment?}         attach, or resume
Append{shard, epoch, entries}        entries this client leads
Propose{shard, proposal}             for shards it doesn't lead
Mirror{shards} · Unmirror{shards}    start or stop following shards (snapshot + tail)
Page{shard, range}                   scrollback, large texts
TermKey · TermPaste · TermResize     terminal input to the pinned host
Find{query} · Related{block}         recall, answered from the host's indexes
Forward{port}                        a web block's tunnel
Ack{shard, seq}
```

Host to client:

```
Welcome{attachment, registry snapshot}
Snapshot{shard, seq, state} · Entries{shard, from, entries}
Grant · Fenced{reason}
Propose{shard, proposal}             the host asking the leader to apply
Results{query, hits}
Ack{shard, seq}
```

Frames are coalesced per display refresh; nothing is sent per keystroke
(apex §6.1).

### 8.4 Storage

Each host keeps its logs and snapshots in `~/Library/Application
Support/Manifold` (or `$XDG_STATE_HOME/manifold`): one append-only file per
shard, snapshots beside them, compacted by the retention policy. Files stay
files on disk: a file block's log records edits and saves, and its snapshot
is not the file's truth, the disk is. Notes are stored only in the log;
they can be exported, or given a path, which makes them files.

---

## 8.5 As built, in short

Milestones 1, 2 and the first parts of 3, 5 and 6 (§9) are in:

- `ManifoldCore`: `Rope`, `Block` and the per-kind states, `Event` and
  `Entry`, `ArrangementState` with its intents, `Node` (a replica of
  shards), `LogStore` (one file per shard, snapshots with log offsets),
  `Migration` from `state.json`, the protocol (binary plist frames).
- `manifoldd`: `Server` on a `Node` and a `LogStore`; the registry and
  links kept in step; proposals for terminals, files, folders, `seen`,
  links and history; file watching; terminal dormancy with the seam.
- The app: `HostClient` (the replica, leading and proposing),
  `MainWindowController` over arrangements and placements, the three
  lenses (`TabContentView`, `TilingView`, `ListLensView` in an
  `ArrangementView`), the desk in the sidebar, the finder, collection,
  the history view, and the lenses: terminal, editor (`TextView`),
  preview, directory, web.

- Remote hosts (§8.1): providers, the bootstrap, the bridge, `Hosts` in
  the app over any number of `HostClient`s; Linux servers from the static
  SDK; `$EDITOR` through `manifold --wait` and `manifoldd open --wait`.
- Language servers (§7.1): `LanguageServers` in `manifoldd`, JSON-RPC over
  the server's stdio; the editor's diagnostics, completion popup and Code
  menu; the Language Servers… table.
- Search blocks (§7.5): the query and hits as entries, host-led; `rg` or
  `grep` on the host, read in batches; the search lens.
- Git and diff blocks (§7.5): `Git` on the host runs git or Sapling by
  the nearest `.sl` or `.git` (`VCS` in the core: the commands and their
  parsing; status, log, `show`/`cat`),
  `LineDiff` (Myers) and `DiffRows` in the core, shared by the diff lens
  and the editor's gutter (marks sent like diagnostics); the git lens.
- Scrubbing (§3.4): `Block.replaying(_:upTo:)` rebuilds any block from its
  log at a moment; the history view scrubs text blocks as well as
  arrangements, "everything as it was" rewinds each placed file by its own
  log to the arrangement's moment, and a diff block can compare a text
  block at two moments (`DiffSubject.versions`).

- The image, PDF, process and agent lenses (§7.5): bytes read on the
  host; `ps` as entries; an agent is a terminal block with a command.
- Retention (§4): `LogStore.compact` folds entries before a cutoff into a
  `.base` beside the log; history carries the base; transcripts of long
  dormant terminals go; the editor's undo depth is a setting.

Still open: sharing (§10), and the finer points listed there.

## 9. From here to there

Today's pieces map directly:

| now | becomes |
|---|---|
| `Pane` | a placement |
| `PaneKind` | a block kind and a lens |
| `Tab` | an unnamed arrangement on the desk |
| `Column` (a stack) | a column, shown by the stacks lens |
| put-away timer | collection (§4) |
| ⌃⇥'s settled order | the timeline |
| `state.json` and JSON commands | per-shard logs and entries |
| editor drafts in `editors/` | the text block's log |

Milestones, each usable on its own:

1. **The model under the current UI.** Logs, blocks, placements and
   arrangements in `ManifoldCore`, shared by server and app; `manifoldd`
   keeps logs instead of `state.json`; the app mirrors and leads. Local
   only, stacks lens only. Collection as §4.
2. **The text engine and editor** (§7.1), replacing the TextKit editor.
3. **Recall:** the registry and links indexes, the finder over everything,
   back and forward, the related panel; naming arrangements; the desk.
4. **Remote hosts:** `--stdio` attach, several hosts in one window, leases
   and fencing, the offline state.
5. **Tiling and list lenses; scrubbing** and restore; the timeline.
6. **The other lenses:** directory, web, image and PDF, diff, git, search,
   process, agent.

All six are in (§8.5). What comes next is §3.5, in steps that each stand
on their own:

7. **Pictures and the card panel.** A snapshot of each placement when it
   is covered or put away, cached by placement id outside the logs; the
   `BlockCard` panel with its renderings and actions; shown first from
   the finder and the sidebar, where a reference is already a row.
8. **Stacks and links that deal out.** The strips under a stack fanned
   on hover with previews and ⌥-peek; "opened from" and "opened here"
   bunched at a block's foot, with the context recorded on the link entry
   from now on (a `context` field on `Link`; old links show without one).
9. **The card lens** for blocks, with its three modes kept per block in
   the registry entry; the list lens as a page of cards.
10. **Slices**: search hits and link context lines editable in place,
    then the new side of a diff.
11. **The editor's scrubber** from document symbols; **the desk's
    history** and the timeline lens; aging on strips and cards.

---

## 10. Open questions

- **Language servers** run per host now (§7.1); what's open is whether
  their diagnostics and edits should also be entries, so they scrub.
- **Tuning.** The defaults of §4 — when a placement leaves an unnamed
  arrangement, when a terminal goes dormant, how long history stays at full
  resolution — are guesses until used.
- **Sharing**, when it comes (§8.2).
