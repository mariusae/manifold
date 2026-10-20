# Manifold — design

Manifold is a desk, not a set of windows. Terminals, files, notes, folders,
web pages and searches are **blocks**; you arrange blocks to work, and an
workspace is itself a block you can name and come back to. Nothing is
closed. What isn't in use is collected out of the way, and anything can be
found and recalled from history. Blocks live on hosts — this Mac, a dev
box, a server — and one window shows blocks from several at once.

This document describes where Manifold is going. The app as it stands
(README.md) is the first sketch of it: sheets that are cheap and put
themselves away, state on a server, the UI only a renderer.

It borrows heavily from apex (~/src/apex/DESIGN.md, sections cited as
apex §n): its replicated logs, leases, exec entries and wire protocol. What
differs is the shape of the thing: apex is one session per host with acme's
windows; Manifold is blocks from many hosts, linked, in workspaces.

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
| **Workspace** | a block whose content is placements of other blocks, laid out |
| **Lens** | a way of rendering a block (an editor or a preview of one text block) |
| **Host** | a server owning blocks: their logs, files and processes |
| **Attachment** | a client's standing with a host, holding leases on the shards it leads |

A **placement** is one appearance of a block in a workspace: its own id,
the block it shows, the lens, and where it sits. A block may be placed in
many workspaces, and more than once in one; an edit shows in all of them.

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
every replica (apex §3.2). A workspace records where a placement is; the
block records what the placement has selected.

`apply` is pure: no clock reads, no randomness, no I/O. Anything with an
effect is an exec (§5).

---

## 3. Workspaces

### 3.1 The surface

A workspace is **human-constructed**: what is in it is what you put
there, and it stays until you take it off. Nothing in it is tidied
away, nothing hides beneath anything, and nothing is placed for you by
a heuristic except where in the grid a new tile lands.

A workspace is a **grid**, apex's tiling (apex §11, *Tiling, as
built*), which is acme's: columns, each a stack of **tiles** top to
bottom, every tile a block, all of them visible. A new tile lands in
the biggest empty space, else takes the lower half of the biggest tile
in the active column (acme's `makenewwindow`); a tile grows by a few
lines, as big as can be, or to the whole column; the divider between
columns sets widths; a tile closed gives its height to its neighbor.
Each tile is a **card** with a **bar** across its top: the block's
symbol and name, where it is, a count of the stack behind it, its
links, its status glyph (§3.7), and maximize and close; the bar is the
tile's handle to drag, grows the tile a step when clicked, and holds
its menu behind the symbol. The content runs beneath the bar, never under it,
with room between cards and the window's wash — a few pools of colour
placed afresh each day over what's behind the window, blurred — showing
through. A stack's sheets peek out above its card, rounded, as paper.
(Once a glass pill floating over the tile, as Prism names a column.)

Two verbs, and no others, put a block in front of you:

| verb | what it does |
|---|---|
| **Go to** | the block where it already is: the workspace it is in (this one if it is here, else the one most recently settled on) is selected and the tile focused |
| **Bring here** | a tile of it in this workspace, by the grid's rule; if it is here already, that tile is focused |

A row clicked in the sidebar, or chosen in the finder, *goes to* the
block if it is placed anywhere, else *brings it here*; ⌘-click and a
drag onto the surface always bring. Anything opened from inside a block
— a path ⌘-clicked in a terminal, a link followed, a search hit, a
change in a git block, a definition — is brought here, into the opener's
column (acme's `activecol`), and linked to the opener. New things (a
terminal, a note, a search) are brought here. Go Back and Go Forward
(⌘[ ⌘]) walk the trail across tiles and workspaces.

The workspace's log holds `Place{placement, column, at}`, `Move`,
`Remove`, `Focus`, `Fractions`, `Heights`, `MoveColumn` and `Title`.

**Retired:** the stacks (sheets beneath a column's top, strips, ⌘E, the
foot), tiling as a second lens, the list lens, and, since October 2026,
the column's past of §3.1's first simplification: a column of one with
a hidden history was still something hidden. Collection of placements
(§4) is retired with it: a workspace is what you made it.

#**Undo** is the workspace put back as it was. Logs only grow (§2), so
nothing is rewound: before each change a client makes to a workspace,
it keeps the state; ⌘Z appends that state as one `restore` entry, ⇧⌘Z
the state before the undo. History keeps both the change and its undoing.
An editor's text has its own undo; the workspace's takes ⌘Z when no view
does.

## 3.2 Names and the desk

A workspace has a title and nothing else to find it by: recall is by
search (§6), not a path. The **desk** is what's in the sidebar: the
workspaces in use, most recently settled on first, the named ones that
you've kept there. Taking a workspace off the desk doesn't end it.

A workspace can be shown in a window of its own or as one of the desk's
tabs in a window, as Safari has both: drag a tab out for a window, a window
in for a tab. Several windows may show the desk; each OS window shows one
workspace at a time.

Workspaces nest: a placement may show another workspace, as a card (its
title and a small live picture of it) or opened in place. A project is an
workspace of workspaces; nothing more is needed for folders.

### 3.3 Naming is keeping

An **unnamed** workspace is scratch: placements not seen for a while are
collected out of it (§4), and it drifts off the desk when unused. Naming
one makes it a place: its columns and their pasts stay however long they
go unseen, though the blocks behind them may go dormant to free their
resources and come back when the workspace is recalled.

### 3.4 Scrubbing

Every workspace can be scrubbed through its history, in two ways:

- **The layout then, the contents now** — what was on this desk last
  Tuesday, shown live. Cheap: one log.
- **Everything as it was** — each placed block rewound to the same moment,
  by clock (§2.2). Exact within a host, within clock skew across hosts.

Either is read-only. *Restore* appends a new version that makes the
workspace so; nothing is reverted destructively. A single block can be
scrubbed the same way, and two points of it compared in a `diff` block.

### 3.5 Navigation is contextual: the graph

What Prism (reflect-mac) gets right about a column of notes is that
navigation is *contextual*: where you can go next is shown where you are.
Backlinks are bunched at a note's foot and dealt out on hover, each with
the words around the link; a column's history is its stack of sheets,
bunched in the title bar, dealt out across the top, each shown as it was
while the pointer passes and live while ⌥ is held. Those are two edge
kinds — spatial and temporal — of one graph, surfaced at the point of use
rather than drawn as a map. Manifold's version is that graph, in whole.

**Nodes** are blocks. Workspaces are blocks already (§2.3), so they are
nodes with nothing special about them; that is what makes the graph
worth having. A node *at a time* is a block and a stamp, and every
block's log is what makes that real.

**Edges** carry a stamp and the block that made them. Nearly all of them
are in the data now and only want indexing:

| edge | from → to | where it comes from |
|---|---|---|
| **placed in** (spatial, present) | workspace → block | the workspace's log, `place` to `remove`: an interval, so "where was this last week" is the same query at another stamp |
| **opened** (spatial, causal) | block → block | the links shard (§6.1), with a `context`: the terminal line a path was ⌘-clicked on, the editor line that named it, the search hit |
| **derived from** (provenance) | block → block | a diff from the file it compares, a search from the files it found, a git block from the files in its changes, a versions diff from its block; written by whoever makes the block |
| **before / after** (temporal, across blocks) | block → block | the registry's `seen` entries, kept as a bounded *trail* per host; the desk's `settled` order, for workspaces |
| **version** (temporal, within a block) | (block, t₁) → (block, t₂) | the log; for a workspace, "everything as it was" (§3.4) |
| **same as** | block ↔ block | a note that became a file (`path`), the same path on two hosts |

Prism's backlinks are `opened` in-edges; its sheet stack is `before /
after` within one column; a `[[link]]` is an `opened` out-edge; a note in
many views is `placed in` in-edges. Workspaces as nodes give the two-hop
questions that matter most — *the other times I had this file open, and
what was beside it then* — as `placed in` in-edges, their neighbors, cut
at the stamp.

**Affordances.** The graph shows itself in the margins, never as a
destination:

1. **Links, in the sidebar, follows focus** (§3.6): the focused block's
   neighborhood, bunched by edge kind — *opened here*, *mentions*,
   *also in*, *before · after* — each row with context and age, a card
   on hover; clicked, the block is shown here; ⌘-clicked, beside. One
   view, given an edge kind; a workspace's row shows the same for its
   node — its columns, the workspaces that share blocks with it, the
   ones before and after it on the desk. (This was the foot under every
   sheet until the surface was simplified, §3.1; the sidebar is where it
   lives now, so there is one place to look.)
2. **Back and forward in a column** (⌘[ ⌘]) walk the column's past
   (§3.1); Go Back and Go Forward (⌃⌘[ ⌃⌘]) walk the trail across
   columns and workspaces, each step previewed as it was on hover,
   live with ⌥ — Prism's stack, but derived from the log, so it survives
   restarts and crosses hosts.
3. **The finder (⌘O) is ranked by the graph.** With nothing typed, the
   focused block's neighborhood, nearest first; typed, matches weighted
   by distance from where you are. Context is the ranking.
4. **Cards** are how a node renders small, at any stamp: a hover panel
   (Prism's `LinkCard`, non-activating, kept while the pointer is on the
   reference or the card), a sidebar row, a finder row. Text as a read-only `TextView`; a terminal as its last
   screen, from the transcript the host keeps; a folder as a short
   listing; web as icon, title and address; a search as its count; a git
   block as its branch and changes; a workspace as its diagram. Modes
   as Prism's note cards have them — collapsed, summary, full —
   remembered per block. With a stamp, the card shows the node *as it was
   then*, which Prism cannot.
5. **Time is a dimension of every query.** `neighbors(of:kinds:at:)`
   takes a stamp; the slider that scrubs a workspace (§3.4) scrubs a
   block's foot the same way — who opened it *then*. A map lens of nodes
   and edges is possible and comes last.
6. **Slices edited where they are.** A search hit's line, a link's
   context line, the new side of a diff: each a byte range of a text
   block, each an editor whose typing is an `.edit` entry on the block
   (Prism's `TaskEditor` writing a task back to its note). Same undo,
   same history.
7. **Pictures.** A snapshot of each placement when it leaves a column's
   top, cached by placement id outside the logs (as Prism keeps them in
   app state, never in the notes): what the cards show for a block in a
   column's past, and what previewing a step back shows.

Two touches to take as they are: **aging** — rows and cards yellow as a
block goes unseen, the collection ladder (§4) made visible — and **⌥ to
peek live** against hover to peek the picture.

**What changes in the data** is small: a `context` on `Link`; a bounded
`trail` in the registry state (the run of `seen` events, deduped), so
temporal edges need no replay; `derived` links written by the host when
it makes a diff, search or git block; and a `Graph` query layer in
`ManifoldCore` over the replica — the app mirrors every host's registry,
links and workspace shards already, so neighborhoods are computed
locally, and asked of the host only for a stamp its logs must be
replayed for. A scrubber down the editor (Prism's `ScrubMark`s, from the
language server's document symbols) and the desk's own history (the desk
shard scrubbed as a workspace is; a timeline lens with empty days
folded to "⋯ Sep 21–25 · 5 days") sit beside this rather than in it.

### 3.7 Status: what every block is doing

Every block has a **status**, in the schema of OSC 7501 (Mitchell
Hashimoto's program status protocol): a set of records keyed by a
hierarchical id, the root record the block's own, each record a
`state` — `idle`, `working` (with a `progress` 0–100, or none for
indeterminate), `done` (finished, the result not yet attended to),
`blocked` (needs you: `kind` permission, question or auth) or `error`
— with an optional `app`, `title` and one-line `msg`. A report replaces
its record whole; `clear` removes a record and its children. The
record's stamp says when it was last reported.

Where it comes from:

- **Terminals and agents**: the program says, with OSC 7501, parsed by
  the host from the byte stream it owns (so remote hosts work the same
  and every client agrees). OSC 9;4 progress maps to the root record
  until a 7501 report arrives. A new prompt (OSC 133 A) or the process
  ending drops `working` and `blocked` records; `done` and `error`
  survive them. Nothing is inferred: a terminal that is busy and says
  nothing has no status — the program is the source of truth, not the
  process tree. A program that asks whether 7501 is spoken
  (`OSC 7501 ; ? ST`) is answered by the host at once, on its input,
  with the states and kinds taken, ahead of any device-attributes reply
  it raced against it.
- **Searches, git and diff blocks**: the host reports as it works —
  `working` while looking, `done` when the hits or the changes arrive,
  `error` when it fails.
- **Text blocks**: `working` while a save is in flight, `error` when it
  fails; the editor's own dirtiness is held separately (§2.3).

`done` and `error` are dismissed when the block is **attended**: it
becomes the focused tile while the window is key. The host does the
dismissing for the blocks it leads, on the client's `attend` proposal.

**Indicators**, as apex's handle says what a window waits for: one
glyph, drawn wherever a block's name is — its pill, its sidebar row, a
finder row, a card. `working` is an open ring, three quarters of it
turning while the program does not say how far and filled clockwise
from the top as far as it does (OSC 9;4 progress counts); `blocked` an
amber ring with a dot, its tooltip the kind and the message; `done` a
filled disc with a check until attended to, then a plain check;
`error` the same in red; `idle` nothing. In a tile's bar and a
sidebar row the glyph sits at the right edge, in the sidebar with how
long ago the status was reported before it, and what it said on the
line beneath the name. The Dock badge counts the blocks blocked and
done.

**⌥ with a click** that opens something means *over*: the block goes
over the tile clicked in, which is stashed behind it (`showOver`), as
⌥-drag stacks a tile over another. One `Where.over` case carries it,
read off the click wherever a view opens (a note's link or pill, a
badge, the sidebar, a listing, a scrubber, a terminal's link — ghostty
wants ⌘ alone for a link, so the terminal keeps ⌥ back and remembers
it — a page's link).

### 3.10 Links by hand, and notes about blocks

A block ⇧-dragged onto any tile is *linked* to the tile's block: one
`linked` edge (§3.5), from the dragged block to the target, read both
ways — the source *links*, the target is *linked from*. Both tiles
wear a badge at the upper right, fanning down when hovered: each link
with an arrow for its direction, clicked to go to, and an × that ends
the edge (`unlink`), so in both readings at once. Links lists them
under *links* (outbound) and *linked from* (inbound). A note made
with a block focused (⇧⌘N) is the same edge, from the block to the
note, as if the block had been ⇧-dragged into it. Into a note the
block also lands as a Markdown link, `[title](manifold:host/ulid)`,
hence a `mention` edge too; the editor draws such a link as the
block's pill — symbol, name and status as the tile's pill has them,
redrawn as they change — and the preview as a small pill, either
clicked to go to the block. Annotation is thus the graph again:
nothing new is stored but edges and the note's own text.

### 3.9 Hosts that come and go

A remote host is a client the app keeps whether or not it can reach it
(§8): `HostClient.link` is connecting, connected, or unreachable with a
reason. A remembered host is made at launch in the connecting state,
bootstrapped in the background, and tried again while unreachable with
the wait doubling from two seconds to two minutes (reset once it
answers; Try Again Now hurries it); a connected bridge is pinged every
fifteen seconds and dropped (to be made again) when a pong doesn't
come, and three bridges in a row that close before the welcome mean the
server there is gone: the host is bootstrapped again. A welcome in
another protocol version means the server still running is the old
one (the bootstrap installed ours beside it, by hash): it is sent
`shutdown`, once per version seen, and the bridge the client comes
back through a second later starts the installed one. The mirrored
node stays as last seen: tiles of its blocks wear the offline glyph,
editors there take no edits, appends go nowhere. The sidebar's host row
shows the state and opens the host's home (the welcome carries it).

**Archived and inbox** (as built). Two flags on a block, in its log:
`archived` — put away as it is (`archive` proposal; the shell's own
exit sets it on a terminal), its tiles withdrawn, no shell started on
attach (the host replays the transcript and keeps the connection,
taking no input), listed under Archived in the Workspaces sidebar and
nowhere else; `inbox` — set when a status record comes to want
attention (done, error, blocked), cleared by hand (`inbox` proposal) or
with the status, listed by the Inbox organization by host and
workspace.

### 3.8 The scrubber: a terminal's outline

A terminal's scroll bar is a scrubber (§3.1, as Prism's): the strip's
length is the screen and its history, the knob the viewport, and the
ticks the shell's commands — its outline. It comes and goes as an
overlay scroll bar does — shown while the content scrolls or grows and
while the pointer is on it, fading a second after — unless the system's
scroll bars are set to stay. The shells Manifold starts
carry a hook (zsh's `preexec`, fish's `fish_preexec`, bash's DEBUG trap)
that writes the command line as `OSC 7502 ; line ST` before running it;
the host's status scanner (§3.7) sees it beside the OSC 133 marks and
appends `ran` to the block, then `exited` with the status at `133 D`.
The block keeps the last thousand. Where each is on the screen is the
app's to find: Ghostty is asked for the rows' text (screen coordinates,
through a patch that lets `read_text` reach the history) and each
command is matched, in order, to the first row after the one before
that ends in its line (or begins with it, wrapped). A row found stays
found until the screen is cleared or trimmed under it, when all are
found again. A tick clicked scrolls to its row (`scroll_to_row`); opened,
the rows from it to the next command's become a note, titled with the
command, linked from the terminal as `opened`.

### 3.6 Organizations: views over the graph

The graph is the representation; how it is *organized* is a view over it,
chosen as fits the task, and the organizations keep no state of their
own. A folder being open or a day being shown is view state; nothing
about the data changes when you look at it another way. The rule is that
the graph has to capture everything any organization needs:

| organization | a view of | roots |
|---|---|---|
| **Desk** | workspaces and what they place (§3) | named workspaces |
| **Files** | blocks with paths, folded into their folders, across hosts; a sparse tree, runs of single folders one row, counts and recency aggregated beneath | hosts → repositories (git or Sapling roots) → `~` → `/` |
| **Links** | the neighborhood of a block by edge kind (§3.5), one more step on opening a row | the focused block, or one looked at |
| **Time** | blocks by the day they were last seen or made | days |
| **Status** | blocks by what they are doing (§3.7): blocked, working, done, error, idle; a group opened in the surface as a **state view** | the states |

Two edges make the first two possible. **`contains`** (folder → file or
folder) is read off the paths: every block with a path is under the
folder blocks (listings, repositories) whose path is its parent, and the
file tree is the trie of all paths on a host. **`mention`** is kept
*complete*: the host parses `[[titles]]` and `[words](paths)` out of a
text block as it changes and brings its mention links to match — making
a block for a file a link names before anyone opens it — so backlinks
are whole without anyone having followed them, as a wiki's are.

The sidebar is the one browser for all of them, and the **spine** of the
window: pinned beside the surface (it can still be set to slide out
over it), a chooser (Desk · Files · Links · Time), a filter, and the same
row — symbol, name, a count, a detail, fading with age — with the same
gestures everywhere: click to show here, ⌘-click to show beside (§3.1), a
card on hover, Links Around This in the menu. Under Desk, a workspace
expands to its columns, in order, the focused one marked, so the sidebar
is the table of contents of the screen; clicking a column row focuses
it, and a block dragged onto one is shown there. Links follows focus.
The workspace stays the working surface; organizations are how you
reach blocks, never where they live. One exception is on purpose: a
**state view** shows a status group's blocks themselves in the surface,
live, in one of two ways — a **list**, the blocks stacked down one
scrolling column as Prism's column of notes is, each under its pill; or
an **overview**, all of them laid out in one grid at once, as Mission
Control lays out windows — so what is blocked, or done, can be looked at
without placing any of it. A block clicked in a state view is gone to;
⌘-clicked, brought to the workspace last shown. A state view is not
a workspace: nothing is placed, nothing is logged. The neighborhood map stays in the
palette as a picture of the Links organization; ⌘O stays the quick way
in.

---

## 4. Lifecycle and collection

Every block is in one of four states, recorded in its host's registry:

| state | meaning |
|---|---|
| **live** | placed in a workspace on screen |
| **warm** | off screen, its resources kept: a process running, a file watched, text in memory |
| **dormant** | only its log and last snapshot; resources rebuilt on recall |
| **held** | not reconstructible (§2.3, *held when*); never collected, whatever else |

Collection moves blocks down the ladder and placements out of unnamed
workspaces; it never deletes a block. Policy, per host:

- A column's past is trimmed: a placement that has been off the top of
  its column for an hour (configurable) leaves an unnamed workspace,
  unless its block is held. What a column shows is never collected, and a
  named workspace keeps its columns' pasts whole.
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
  and per workspace (a named workspace may keep its blocks' history
  longer). The defaults are a starting point to be tuned with use: text
  logs kept in full (they are small), terminal rows thinned after a while
  (they add up), undo as deep as the text's history. A git block's
  refreshes only replace one another, so they are no history at all: one
  is logged only when the repository changed, and the block's log is
  folded into its base whole whenever retention runs.

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
proposal to the workspace (which may live on `local`) to place
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
| `linked` | a block ⇧-dragged onto a tile; a note made about a block (block → note) |
| `placed` | placed next to each other in a workspace, by you |

Each host indexes the links pointing at its blocks; a client merges the
indexes of every host it is attached to, so backlinks cross hosts.

### 6.2 Recall

One finder (⌘O, ⌘P) over everything every attached host knows: block
titles and paths, note and transcript text, workspace titles, recent
searches. It ranks by frecency and text, and shows each result's state,
host, and where it was last placed. Alongside it:

- **Back and forward** through what you settled on, across workspaces.
- **Related** — a panel for the focused block: its links both ways, the
  workspaces it appears in, what was placed beside it.
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

- Proportional (SF Pro with its single-story a, as Notes has it; Tiempos
  Text; or Mona Sans) or fixed-width text from the theme, as now.
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
running; a process list (sort, filter, select many, signal); an agent's transcript with
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

A host's server is a **session**, and it names itself: an id minted once
(`h` and ten characters of base32), kept in its data directory, that every
block made there carries (`session/ulid`). So a block's id means the same
thing from every machine, and an edge whose other end is on a session a
client is not attached to is just an edge it cannot follow yet: the tile
is a placeholder with the host's label and a way to attach. What people
call a host is a **label**: what the host says of itself (given with
`bridge --name` the first time), kept by each client in its hosts file
beside the destination, keyed by session. A server from before sessions,
named `local` or by its first client, mints its id on first start and
rewrites its logs to it, the old name becoming its label.

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

*As built.* Every host-side shard but the blocks a client edits has one
writer, the host: the registry, the links, and the **desk**, a host's
metalog of its workspaces — which exist, in order — and its settings;
clients propose (`workspaces`, `settings`). What is a client's alone —
the workspace it shows, the order it settled on them, its window, its
appearance — is `ClientState`, in a file beside its hosts file, so two
machines attached to one host see the same workspaces and each its own
selection. The blocks a client may lead — text, web, workspaces — have **one owner
at a time**, by focus: the host hands a block's pen to whichever
attachment last focused it (`own`), tells the one that held it it is
fenced (`fenced`), and refuses appends from any other, sending the shard
back whole; a shard no one owns goes to the first to append. One user on
two machines never contends; two people on one note get last-focus-wins,
honest and visible. That is apex §4 cut down to the one event that
matters; epochs and leases are not needed.

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
  `MainWindowController` over workspaces and placements, the surface
  (`ColumnsView`), the sidebar, the finder, collection, the history
  view, and the lenses: terminal, editor (`TextView`), preview,
  directory, web.

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
- The graph (§3.5): `Graph` in the core, kept in step by `Node` with every
  entry — `placed` intervals from workspace logs, the link kinds from
  the links shards (with `context`), the trail from `focus` and `select` —
  indexed by block and kind both ways with live counts, every edge
  stamped (a placement keeps its stamp in the state, so a snapshot keeps
  it too) and every list newest first; the trail kept
  in the registry (the host turns clients' `focus` and `select` into
  `step` entries, so it survives snapshots and restarts) and indexed by
  block; `neighborhood(of:at:)`, `distances(from:)`,
  `step(from:offset:)`; `Hosts` merges every host's. Rebuilt from states
  and kept entries after a snapshot.
- Organizations (§3.6): `contains` edges and the file tree in `Graph`
  (paths indexed per host; `fileTree(host:home:)`), mentions parsed in
  the core (`Mention.find`) and kept as links by the host (`Mentions`);
  the sidebar's chooser, filter and `OrganizationView` over `OrgNode`
  trees built by the controller; `HoverCard`.
- The neighborhood (§3.5): Links in the sidebar, following the focus,
  from the same bunches per edge kind (`footBunches`); Go Back and Go
  Forward (⌃⌘[ ⌃⌘]) walk the trail; the finder ranked by graph
  distance; `NeighborhoodView`, the neighborhood to distance 2 in graph
  form, walked by re-centering, from the palette.
- The surface (§3.1, milestones 14–18): `ArrangementState` as acme's
  tiling — columns of tiles with `heights`, a new tile taking the lower
  half of the column's biggest (`bringing(_:lens:inColumn:below:)`),
  `growing(_:step:whole:)` for colgrow, a removed tile's height to its
  neighbor; a share of 0 is a stashed tile, bunched as a pill under
  the column's top pill and fanned out on hover (`stashing`,
  `unstashing`); `full` a tile maximized over the workspace;
  `GridView` with `TilePill` (one width, opaque; symbol, name, status
  glyph, a maximize corner; drag to move, click for the menu),
  dividers, drops between tiles and beside columns; `goTo(_:)` and `show(_:lens:_:)` (Bring
  here) as the two verbs, in the controller, the sidebar, the finder
  and every opener; collection of placements retired; the sidebar as
  spine: `OrganizationView` for every organization including the desk
  (`deskTree`, a row per tile), rows that drag and take drops
  (`OrgDragItem`), New and ⋯ in its header, pinned by default.
- Status (§3.7, milestone 17): `StatusRecord` and `Block.status`,
  `.status` entries, `StatusScanner` for OSC 7501, 9;4 and 133 fed by
  each session on the host, the host reporting for searches, git and
  diffs, `attend` marking done and error read; `StatusGlyph` in pills,
  rows and the finder; the Status organization; the Dock badge.
- State views (§3.6, milestone 19): `StateView` over the surface for a
  status group's blocks, live, as a list or an overview, from the
  group's row in the Status organization; the blocks' views under
  `state:` placement ids, kept while it's up; ⎋ leaves it.
- Scrubbing (§3.4): `Block.replaying(_:upTo:)` rebuilds any block from its
  log at a moment; the history view scrubs text blocks as well as
  workspaces, "everything as it was" rewinds each placed file by its own
  log to the workspace's moment, and a diff block can compare a text
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
| `Tab` | an unnamed workspace on the desk |
| `Column` (a stack) | a column, shown by the stacks lens |
| put-away timer | collection (§4) |
| ⌃⇥'s settled order | the timeline |
| `state.json` and JSON commands | per-shard logs and entries |
| editor drafts in `editors/` | the text block's log |

Milestones, each usable on its own:

1. **The model under the current UI.** Logs, blocks, placements and
   workspaces in `ManifoldCore`, shared by server and app; `manifoldd`
   keeps logs instead of `state.json`; the app mirrors and leads. Local
   only, stacks lens only. Collection as §4.
2. **The text engine and editor** (§7.1), replacing the TextKit editor.
3. **Recall:** the registry and links indexes, the finder over everything,
   back and forward, the related panel; naming workspaces; the desk.
4. **Remote hosts:** `--stdio` attach, several hosts in one window, leases
   and fencing, the offline state.
5. **Tiling and list lenses; scrubbing** and restore; the timeline.
6. **The other lenses:** directory, web, image and PDF, diff, git, search,
   process, agent.

All six are in (§8.5). What comes next is §3.5, in steps that each stand
on their own:

7. **The graph index.** `Graph` in `ManifoldCore` over the replica:
   `placed in` from workspace logs, `opened` and `derived` from links,
   `before / after` from a new bounded `trail` in the registry state,
   `same as` from paths; `neighbors(of:kinds:at:)`. `context` on `Link`,
   recorded from now on by terminals, editors and search hits; `derived`
   links written by the host for diff, search and git blocks. Tests over
   a made-up replica.
8. **The foot of a block.** The `Neighborhood` view bunched per edge
   kind, dealt out on hover with context and age, click to recall beside;
   first on text blocks and terminals, then on workspaces (their foot
   in the sidebar row and the ⌘E card).
9. **Pictures and the card panel.** Placement snapshots cached by id; the
   `BlockCard` panel and its renderings, with *as it was then*; shown
   from the neighborhoods, the finder and the sidebar; the finder ranked
   by graph distance.
10. **Back and forward in a column** from the trail, with previews and
    ⌥-peek; the strips under a stack dealt out the same way.
11. **The card lens** for blocks, three modes kept per block; the list
    lens as a page of cards.
12. **Slices** edited in place: search hits and link context lines, then
    the new side of a diff.
13. **The editor's scrubber** from document symbols; the desk's history
    and the timeline lens; aging on rows and cards; a map lens, if it
    earns its place.

Then the surface, simplified (§3.1), which comes before the rest of
these are built on it:

14. **Columns of one.** `shown` per column in `ArrangementState`, kept
    by `Focus`; `ColumnsView` draws one block per column and nothing of
    the past; ⌘[ ⌘] and ⌘W walk it; tiling, the list lens, strips, the
    stack list, ⌘E and the foot removed, their log entries still decoded
    and ignored. Existing workspaces need no migration: a stack's top
    is the shown entry.
15. **The one open rule.** `show(here:)`, `show(beside:)` and
    `show(besideOpener:)` as the only three ways anything is placed; the
    palette, finder, sidebar, terminals, previews, search, git, diff,
    LSP and the `manifold` command all through them.
16. **The sidebar as spine.** Pinned by default; Desk rows expand to
    columns and follow focus; drag onto a column; Links follows focus
    with context lines; the history view's diagram draws columns.

Then, putting the model to use (§3.7, §3.1 as a grid, state views):

17. **Status.** `StatusRecord` and `Block.status`, `.status` entries;
    `StatusScanner` in the core for OSC 7501, 9;4 and 133; the host
    feeding it from each session, reporting for searches, git and
    diffs, and dismissing on `attend`; the glyph (`StatusGlyph`) in
    sidebar rows, the finder and cards; the Status organization; the
    Dock badge.
18. **Grids.** `ArrangementState` as acme's tiling (columns of tiles
    with heights, `Heights` back in the log); `GridView` with pills
    (`TilePill`) for tiles; placement by acme's rule; Go to and Bring
    here as the two verbs everywhere; collection of placements retired.
19. **State views.** `StateView` in the surface for a status group,
    as a list or an overview; from the Status organization.

---

## 10. Open questions

- **Language servers** run per host now (§7.1); what's open is whether
  their diagnostics and edits should also be entries, so they scrub.
- **Tuning.** The defaults of §4 — when a placement leaves an unnamed
  workspace, when a terminal goes dormant, how long history stays at full
  resolution — are guesses until used.
- **Sharing**, when it comes (§8.2).
