# Manifold — design

Manifold is a wiki, not a set of windows. Terminals, files, notes,
folders, web pages and searches are **blocks**, and everything is linked:
a space links the blocks it shows, a note the blocks it mentions, and
what you do leaves links behind — this terminal opened that file, this
search found that line. It is all one graph, and the graph is what keeps
things: a block stays alive as long as a space reaches it — shows it,
pins it, or reaches it through a link by hand — and what nothing reaches
any more is collected. Nothing is filed or put away; you link, and you
follow links back. A space, the blocks you've arranged to work in, is
itself a block, and stays until you remove it. Blocks live on hosts — this Mac, a dev box,
a server — and one window shows, and links, blocks from several at once.

This document describes where Manifold is going. The app as it stands
(README.md) is the first sketch of it: sheets that are cheap and put
themselves away, state on a server, the UI only a renderer.

It borrows heavily from apex (~/src/apex/DESIGN.md, sections cited as
apex §n): its replicated logs, leases, exec entries and wire protocol. What
differs is the shape of the thing: apex is one session per host with acme's
windows; Manifold is a graph of blocks from many hosts, kept alive by what
links to them, and arranged in spaces.

---

## 1. Principles

- **Everything is linked.** Actions leave links behind (this terminal opened
  that file; this search found that line), so recall can walk from one
  thing to what was around it. The links you make — a space placing or
  pinning a block, a link by hand — are what keep things (§3.4); the
  ones actions leave are history and keep nothing.
- **What nothing refers to goes.** A block is kept while a space
  reaches it (§4); closed everywhere, it waits half an hour to be
  brought back, then is collected. A space itself goes only when you
  remove it. The graph holds what you're using, not everything you ever
  touched.
- **Losing something is said, never silent.** Closing the last reference
  to a block with unsaved edits or a running job goes through, and a
  toast says what was closed, with Restore (⇧⌘T) beside it.
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
| **Space** | a block (of kind `arrangement`) whose content is placements of other blocks, laid out |
| **Lens** | a way of rendering a block (an editor or a preview of one text block) |
| **Host** | a server owning blocks: their logs, files and processes |
| **Attachment** | a client's standing with a host, holding leases on the shards it leads |

A **placement** is one appearance of a block in a space — a **tile**: its
own id, the block it shows, the lens, and where it sits. A block may be
placed in many spaces, and more than once in one; an edit shows in all
of them.

### 2.2 Identity

A block's id is `host/ulid`: the host it lives on, and a ULID (time-sorted,
made without coordination). Ids never change; a file block keeps its id
through renames and moves, its path being an attribute, so links to it
survive. Hosts are named when first attached (`local`, `devbox`) and carry
a stable key so a rename of the machine doesn't orphan anything.

Every entry carries its host's hybrid logical clock: a timestamp that is
close to wall time but never runs backwards and orders causally related
entries. Within a host this orders everything exactly; across hosts it
lines logs up to within clock skew.

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
| `arrangement` | placements, layout, lens, title | none | never — a space is a root (§3.3) |

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
every replica (apex §3.2). A space records where a placement is; the
block records what the placement has selected.

`apply` is pure: no clock reads, no randomness, no I/O. Anything with an
effect is an exec (§5).

---

## 3. Spaces

### 3.1 The surface

A space is **human-constructed**: what is in it is what you put there,
and it stays until you take it off. Nothing in it is tidied away,
nothing hides beneath anything but what you stacked, and nothing is
placed for you by a heuristic except where in the grid a new tile lands.

A space is a **grid**, apex's tiling (apex §11, *Tiling, as built*),
which is acme's: columns, each a stack of **tiles** top to bottom,
every tile a block, all of them visible. A new tile lands in the
biggest empty space, else takes the lower half of the biggest tile in
the active column (acme's `makenewwindow`); a tile grows by a few
lines, as big as can be, or to the whole column; the divider between
columns sets widths; a tile closed gives its height to its neighbor.
Each tile has a **bar** across its top: the block's symbol and its
**title** (a dot after it while edited and unsaved), where it is, its
host in a chip after the title (a server's symbol and the host's name,
in the accent) when that isn't the space's host — the last thing the
bar gives up as it narrows — its **links** (the linked blocks' faces,
stacked), its status
glyph (§3.7, the program it names in the tooltip), and maximize and
close; tiles stacked behind it show as its sheets. The bar is the
tile's handle to drag, grows the tile a step when clicked (⌘-click
fills its column, ⌃-click or the symbol opens its menu), and as a tile narrows
gives things up in order, so the symbol and some of the title always
show: the place goes first, then maximize, then the links; close and
the status glyph stay, and last the title is cut.

A tile **shrinks along one ladder**, by the room it has, not by a state:
its content; then, under a few lines' room, its **summary card** (the
block in a few lines, §3.5, shaped as the tile, joined to its bar); then
its bar alone, rounded all round; then stashed behind its neighbour.
Shrink to Summary (⇧⌘M) only sets a height on that ladder, and every
step comes back by resizing; Maximize stands apart. The content runs
beneath the bar, never under it, with room between tiles and the
window's wash — a few pools of colour placed afresh each day over
what's behind the window, blurred — showing through.

Two verbs, and no others, put a block in front of you:

| verb | what it does |
|---|---|
| **Go to** | the block where it already is: the space it is in (this one if it is here, else the one most recently gone to) is selected and the tile focused |
| **Bring here** | a tile of it in this space, by the grid's rule; if it is here already, that tile is focused |

Anything clicked that names a block — a sidebar row, an Open Quickly
row, a link, a path, a search hit, a change in a git block — *goes to*
it if a tile shows it anywhere, else *brings it* below the tile clicked
in (acme's `activecol`), linked to it; ⌘ always brings it, beside, ⌥
over (the one rule, §3.7). New things (a terminal, a note, a search) are
brought here. Go Back and Go Forward (⌃- ⌃⇧-) walk the trail across
tiles and spaces; ⌘[ ⌘] a tile's own, for the views that go on in place.

The space's log holds `Place{placement, column, at}`, `Move`, `Remove`,
`Focus`, `Fractions`, `Heights`, `MoveColumn`, `Stash`, `Full` and
`Title`.

**Retired:** the column's past of §3.1's first simplification (a column
of one with a hidden history was still something hidden), tiling as a
second lens, the list lens, collection of placements, and — in October
2026 — the desk, Keep, and naming as keeping (§3.3).

**Undo** is the space put back as it was. Logs only grow (§2), so
nothing is rewound: before each change a client makes to a space, it
keeps the state; ⌘Z appends that state as one `restore` entry, ⇧⌘Z the
state before the undo. History keeps both the change and its undoing.
An editor's text has its own undo; the space's takes ⌘Z when no view
does.

### 3.2 Names

A space has a title and nothing else to find it by: recall is by
search (§6), not a path. The sidebar lists every space, in the order you
arranged them. An unnamed space is named by what it holds — the folder
most of its blocks are at, with the repository's branch when a git
block is there, else the focused block — and two called the same are
told apart by what each is on, so the sidebar never says "Untitled"
twice.

A space could be shown in a window of its own or as one of a window's
tabs, as Safari has both; each OS window shows one space at a time.

Spaces nest: a placement may show another space, as a card (its title
and a small live picture of it) or opened in place. A project is a
space of spaces; nothing more is needed for folders.

### 3.3 Spaces are the roots

A space is a root, named or not, emptied or not, until you remove it
(⌥⇧⌘W, or its row's menu) or drop it on another; nothing removes one
for you. What it reaches is kept: what it places, what it **pins** (Pin
in Space: a strong link from the space, so a block can stay without a
tile), and what those link to by hand. Naming a space names it and
nothing more. The blocks behind a space unseen for long may go dormant
to free their resources, and come back when it's gone to.

Once there were three rules: an unnamed space was scratch, drifting off
a **desk** after some days unseen; naming one kept it; and Keep made
any block a root. One rule replaced them (§12).

### 3.4 Strong and weak edges

Of the graph's edges (§3.5), three kinds are **strong**: a space's
placement of a block, its pin of one (`pinned`), and a link made by
hand (`linked`). A strong edge
keeps what it points at (§4). Every other edge is **weak** — what a
terminal opened, what a search found, what a folder contains, the trail
of where you went — history and happenstance, which keep nothing alive
and say nothing about what you mean to keep. Strong edges are followed
in their direction: a block that links by hand to a kept block is not
itself kept by that.

### 3.5 Navigation is contextual: the graph

What Prism (reflect-mac) gets right about a column of notes is that
navigation is *contextual*: where you can go next is shown where you are.
Backlinks are bunched at a note's foot and dealt out on hover, each with
the words around the link; a column's history is its stack of sheets,
bunched in the title bar, dealt out across the top, each shown as it was
while the pointer passes and live while ⌥ is held. Those are two edge
kinds — spatial and temporal — of one graph, surfaced at the point of use
rather than drawn as a map. Manifold's version is that graph, in whole.

**Nodes** are blocks. Spaces are blocks already (§2.3), so they are
nodes with nothing special about them; that is what makes the graph
worth having. A node *at a time* is a block and a stamp, and every
block's log is what makes that real.

**Edges** carry a stamp and the block that made them. Nearly all of them
are in the data now and only want indexing:

| edge | from → to | where it comes from |
|---|---|---|
| **placed in** (spatial, present) | space → block | the space's log, `place` to `remove`: an interval, so "where was this last week" is the same query at another stamp |
| **opened** (spatial, causal) | block → block | the links shard (§6.1), with a `context`: the terminal line a path was ⌘-clicked on, the editor line that named it, the search hit |
| **derived from** (provenance) | block → block | a diff from the file it compares, a search from the files it found, a git block from the files in its changes, a versions diff from its block; written by whoever makes the block |
| **before / after** (temporal, across blocks) | block → block | the registry's *trail*, bounded, per host: each focus of a tile, each space seen — the one history, which back and forward walk and ⌃⇥ orders by |
| **version** (temporal, within a block) | (block, t₁) → (block, t₂) | the log |
| **same as** | block ↔ block | a note that became a file (`path`), the same path on two hosts |

Prism's backlinks are `opened` in-edges; its sheet stack is `before /
after` within one column; a `[[link]]` is an `opened` out-edge; a note in
many views is `placed in` in-edges. Spaces as nodes give the two-hop
questions that matter most — *the other times I had this file open, and
what was beside it then* — as `placed in` in-edges, their neighbors, cut
at the stamp.

**Affordances.** The graph shows itself in the margins, never as a
destination:

1. **A tile's links**, on its bar: each linked block's face, a chevron
   in it for the direction (› to, ‹ from), stacked most recent first; the
   pointer fans them out along the bar (the title fading out before the
   first), and resting on one shows its summary card beneath — one card
   at a time, so many links cost no room. More than fit, the last is a
   stack of the rest, scrubbed through by the pointer across the title.
   Clicked by the one rule; and the **neighborhood map** (⌥⌘M) as the one big view of the
   focused block's surroundings, two steps out. (This was a Links
   organization in the sidebar, and before it the foot under every
   sheet.)
2. **Back and forward**: Go Back and Go Forward (⌃- ⌃⇧-) walk the trail
   across tiles and spaces — derived from the log, so it survives
   restarts and crosses hosts; ⌘[ ⌘] walk a tile's own, where it goes on
   in place (a page, a preview, a listing).
3. **Open Quickly (⌘O) is ranked by the graph.** Only what is kept (§4)
   is found. With nothing typed, the focused block's neighborhood,
   nearest first; typed, what the query names best first — its title,
   its place, its summary — and among equals the nearest to where you
   are over the graph's edges, strong and weak alike. What was closed
   and not yet collected comes last, marked *recent*: choosing it brings
   it back.
4. **Summaries** are how a node renders small: a few lines saying what's
   worth knowing of it at a glance — a terminal its last command and how
   it ended, a note its first lines, a diff its files and lines changed
   (`BlockSummary`, from its state alone, so a block off screen or on
   another host has one too). A tile short of room shows its summary
   card; so do Open Quickly's rows, a stack fanned out, a link's face
   rested on, Overview past ten blocks, `mani ls`. A sidebar row's hover card is a picture of the tile,
   never the live view. With a stamp, a summary could show the node *as
   it was then*, which Prism cannot.
5. **Time is a dimension of every query.** `neighbors(of:kinds:at:)`
   takes a stamp — who opened it *then*. A map lens of nodes and edges
   is possible and comes last.
6. **Slices edited where they are.** A search hit's line, a link's
   context line, the new side of a diff: each a byte range of a text
   block, each an editor whose typing is an `.edit` entry on the block
   (Prism's `TaskEditor` writing a task back to its note). Same undo,
   same history.
7. **Pictures.** A snapshot of each placement when it goes behind
   another, cached by placement id outside the logs (as Prism keeps them
   in app state, never in the notes): what the hover cards show.

Two touches to take as they are: **aging** — rows and cards yellow as a
block goes unseen, the collection ladder (§4) made visible — and **⌥ to
peek live** against hover to peek the picture.

**What changes in the data** is small: a `context` on `Link`; a bounded
`trail` in the registry state (the run of `seen` events, deduped), so
temporal edges need no replay; `derived` links written by the host when
it makes a diff, search or git block; and a `Graph` query layer in
`ManifoldCore` over the replica — the app mirrors every host's registry,
links and space shards already, so neighborhoods are computed
locally, and asked of the host only for a stamp its logs must be
replayed for. A tile's outline (Prism's `ScrubMark`s, from the language
server's document symbols) sits beside this rather than in it.

### 3.6 Organizations: views over the graph

The graph is the representation; how it is *organized* is a view over it,
chosen as fits the task, and the organizations keep no state of their
own. A folder being open or a day being shown is view state; nothing
about the data changes when you look at it another way. The rule is that
the graph has to capture everything any organization needs:

| organization | a view of | roots |
|---|---|---|
| **Spaces** | spaces and what they place and pin (§3): one shape, nothing folding by itself, the current space barred at its left, a space closed by its chevron staying closed, a stack's tiles in a dotted outline | the spaces |
| **Files** | blocks with paths, folded into their folders, across hosts; a sparse tree, runs of single folders one row, counts and recency aggregated beneath | hosts → repositories (git or Sapling roots) → `~` → `/` |

Two, and a filter over either (`SidebarFilter`, ⌘., the lighthouse at
the foot): a test of each block — the first, blocks with a status,
working, needing you, done or failed — that keeps the rows it admits
and the way to each (`OrgNode.filtered`: a row stays if it or anything
under it is admitted; a tile behind in a stack keeps its stack's top,
the two outlined as the stack is; counts are of what's admitted), every
row on the way open, what was open and closed by hand kept aside and
put back. It knows nothing of the trees, so a filter more is a case
more. The links live on the tile's bar and in the neighborhood map
(⌥⌘M, or a link's menu) as the one big view of them; what's working,
done or needing you is the counts at the sidebar's foot, which turn the
filter on, and Overview; and time is ⌘O with nothing typed, which is the
trail.

Two edges make the first two possible. **`contains`** (folder → file or
folder) is read off the paths: every block with a path is under the
folder blocks (listings, repositories) whose path is its parent, and the
file tree is the trie of all paths on a host. **`mention`** is kept
*complete*: the host parses `[[titles]]` and `[words](paths)` out of a
text block as it changes and brings its mention links to match — making
a block for a file a link names before anyone opens it — so backlinks
are whole without anyone having followed them, as a wiki's are.

The sidebar is the one browser for all of them, and the **spine** of the
window: kept beside the surface (it can be let slide out over it
instead), a filter, a row at the foot (by space, by file, the inbox,
the counts), and the same row — symbol, title, a count, a detail,
fading with age — with the same gestures everywhere (the one rule,
§3.7), a picture of the tile on hover, the Neighborhood Map in the menu.
Under Spaces, every space shows its tiles, in order, the focused one
marked, so the sidebar is the table of contents of the screen; clicking
a tile row focuses it, and a block dragged onto a space is shown there.
Recently Closed (§4), a row at the foot, pushes its list over the tree,
with a back button and the list's name in the header. The space stays
the working surface; organizations are how you reach blocks, never
where they live.

One exception is on purpose: **Overview** (⌘') shows a space's blocks
themselves in the surface — or, filtered, every agent's on every host
(⌃⌘A) — in one of three ways: a **list**, stacked down one scrolling
column as Prism's column of notes is, each under its bar; an
**overview**, all of them laid out in one grid at once, as Mission
Control lays out windows; or **summaries**, a summary card each, what
it shows by itself past ten blocks. A block clicked there goes by the
one rule — gone to, ⌘ beside the tile you were on, ⌥ over. Overview is
not a space: nothing is placed, nothing is logged.

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
glyph, drawn wherever a block's title is — its bar, its sidebar row, an
Open Quickly row, a summary card. `working` is an open ring, three quarters of it
turning while the program does not say how far and filled clockwise
from the top as far as it does (OSC 9;4 progress counts); `blocked` an
amber ring with a dot, its tooltip the kind and the message; `done` a
filled disc with a check until attended to, then a plain check;
`error` the same in red; `idle` nothing. In a tile's bar and a
sidebar row the glyph sits at the right edge, in the sidebar with how
long ago the status was reported before it, and what it said on the
line beneath the name. The Dock badge counts the blocks blocked and
done.

**One rule for the modifiers**, wherever a click opens a block — a
sidebar row, a link or a block's link in a note, a tile's links, a
path, a search or git hit, a listing's entry, an outline's command, a
card in Overview, an Open Quickly row chosen with ⏎: plain **goes to**
it where a tile shows it, in any space (beside, if none does); **⌘
means beside** — below the tile clicked in, taking its lower half; **⌥
means over** — the block goes over the tile clicked in, which is
stashed behind it (`showOver`), as ⌥-drag stacks a tile over another;
**⇧⌘** gives it to the system's app. ⇧ alone is about the path: ⇧-click
a bar for where the block is, ⇧-drag a bar to link. One `Disposition`
carries each, read off the click (or ⏎) wherever a view opens, and
`follow` does it (a terminal's link needs ⌘ to be a link at all, so
there ⌘⌥ is over and ⌘ alone beside).

### 3.8 A terminal's outline

(Insert Path, ⌃⌘I, is a terminal's too: a menu over its cursor of the
paths under where its shell is — listed on its host, a folder at a
time (`listFolder`), so a remote's are the remote's — the last three
put in on the host at its foot (kept per host), a field that ranks
what's found as Open Quickly ranks names. It never waits: `PathCrawl`
lists the folder, and only once something's typed goes on, a level at
a time, several folders in flight — as far as a ranking says it helps
(a screenful of strong matches, which nothing further can come before;
another for each ↑ past the top), in allowances it spends and waits to
be given again, so a fast host can't outrun being told to stop; a
folder gone into, alone. The ranking is off the main thread, again as
more comes. Crawls are kept
two minutes by host and folder. The one chosen is typed as the shell would have
it, relative where it can be. Styled as a menu, not the finder: the
system's frosted ground, the Finder's icons, the accent under the
chosen row.)

A terminal's scroll bar carries its outline (as Prism's scrubber): the strip's
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
found again. A tick clicked scrolls to its row (`scroll_to_row`).

Opened — a tick's, or an outline entry's — a command's output becomes
an `output` block, titled with the command and linked from the terminal
as `opened` (context `command N`, so it is found again rather than made
twice). The host keeps it: the session notes where in its replay buffer
each `7502` mark began and where the next `133 D` ended, and asked
(`captureOutput`), the block gets those bytes, escapes and all — the
last megabyte at most, less zsh's partial-line mark at the end, which
the prompt draws over. A command whose bytes have left the buffer, or
that ran before the host kept marks, takes the screen's rows the app
sends along instead, marked as such. The app draws it as the terminal
did — SGR colours (16, 256, true) and faces in the terminal's palette,
carriage returns and backspaces overwriting, erased lines erased — with
the command line and its outcome above, read-only, Copy putting the
command and the text on the clipboard and Show in Terminal going back
to the command.

A command keeps where the shell was as it ran (`cwd`, taken from the
block's as `ran` is applied; a shell that doesn't send OSC 7 has its
process asked first), and the names on a row are from there: the
command's whose row is at or above it, or, below the last command once
it has ended, where the shell is now. So ⌘ held after `ls` and `cd sub`
still links the names `ls` printed, to the folder it listed, here and on
another host alike; a link's target is made absolute from that
directory before it is opened.

The terminal finds its links by reading the viewport's rows with ⌘ held
(`TerminalLinks`), and a file's link is only as sure as its path can be
looked at. On this Mac each is looked at as the rows are read, so every
link is `sure`. On another host it can't be, in the time a pointer
moves, so a link is `likely` (it looks like a path: `/x`, `./x`, `a/b.md`,
`main.c:12`) or `possible` (a bare name), and the host is asked: as ⌘
goes down, before the links are drawn, the app sends `lookUpPaths` with
the absolute paths it couldn't tell of, and the host answers each as a
file, a folder or nothing (`pathKinds`; fewer than asked if it ran out
of a second and a half, the rest left as they were). Answered, the
links are read again: those found are `sure`, those not there are gone,
and bare names found appear. `sure` links glow; `likely` ones are drawn
in the link colour without the glow; `possible` ones aren't drawn. The
answers are kept until a command starts or ends. A click on a link not
answered for yet waits for the answer (a second at most: then a `likely`
one opens on its look, a `possible` one doesn't). A server from before
`lookUpPaths` ignores it, and links are as their look says.

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

**The Inbox** is a derivation, not a flag: the blocks whose root
status wants attention — done or failed and not yet read, or needing
you — by host and space, gone through with ⌘J and counted on the Dock
(no list of its own: the sidebar's filter shows them, with the rest
that have a status). Reading a block (focusing it) takes it
out; nothing is set or cleared by hand. (Keeping a block is a separate
thing, §4.)

### 3.10 Links by hand, and notes about blocks

A block ⇧-dragged onto any tile is *linked* to the tile's block: one
`linked` edge (§3.5), from the dragged block to the target, read both
ways — the source *links*, the target is *linked from*. Both tiles
show it among their links on the bar: the other block's face, a chevron
in it for the direction, its summary card on a rest, clicked as any link is;
its menu's Remove Link ends the edge (`unlink`), in both readings at
once. A note made
with a block focused (⇧⌘N) is the same edge, from the block to the
note, as if the block had been ⇧-dragged into it. Into a note the
block also lands as a Markdown link, `[title](manifold:host/ulid)`,
hence a `mention` edge too; the editor draws such a link as a capsule
— symbol, title and status as the tile's bar has them, redrawn as they
change — and the preview as a small one, either clicked as any link. Annotation is thus the graph again:
nothing new is stored but edges and the note's own text.

---

## 4. Keeping and collection

What keeps a block is being **reachable**: a path of strong edges (§3.4)
from a **root** to it. The roots on a host are

| root | why |
|---|---|
| a space | what you made; removed only by hand (§3.3) |
| a **hold** | another host's standing reference (below) |

and every block a root places, pins, links by hand, or reaches through
what it places and links, is kept. The host is the collector: once a
minute it walks its own shards from its roots, notes each block nothing
reaches with the moment that began, and **collects** any that has been
so for the grace (`collectAfterMinutes`, 30 by default, a setting): its
session ended, its file unwatched, its links gone, its log deleted, the
registry told, and every replica following. A block reached again
within the grace is simply kept, its mark forgotten.

Closing is what makes things unreachable. ⌘W takes a tile off its
space — when it was the last tile of a block nothing else reaches, a
toast says so; ⌥⇧⌘W removes a space whole. **Deleting** (⇧⌘W) is the
one way a block goes at once: its tiles taken off everywhere, its links
both ways broken on every host (`unlink`), and the host discarding it
(`discard`: its session ended, its log deleted, unregistered). What only
it reached is left to the collector like anything closed — in Recently
Closed for the grace, not deleted with it. The app keeps what it closed
on a stack, and **⇧⌘T** puts the last thing back where it was — a tile
at its old column and place (here, if that space has gone), a space
back in the sidebar — skipping whatever has been collected meanwhile.
**Recently Closed**, a row at the sidebar's foot with a count, lists
what exists and nothing reaches, and Open Quickly marks it *recent*;
either brings it back by a click. It isn't in the tree: the tree is the
spaces.

Collection is never refused and never silent. Closing takes with it
everything the closed block alone reached — what it placed, what it
linked by hand, and onward — so the app compares what was reachable
before and after, and when something on its way out would lose
something — a text with unsaved edits, a terminal with a job running,
which collection will end — a toast at the foot of the window names
each of them and offers Restore, which reopens what was closed and so
reaches them all again.

**Holds, across hosts.** A host sees only its own shards, so a reference
from another host — a space there placing a block here, a link by
hand there to a block here, the window's list of spaces naming a space
of this host — would be invisible to its collector. The client that holds both
sides tells the target host: a `Hold{id, block, holder}` in the target's
registry, keyed by the edge it stands for (the placement's or link's
id, or `desk:<holder>:<space>`, after the list's old name), proposed when the edge exists and
released when it goes or its source is no longer reached. Holds are
roots. A client reconciles the holds of the hosts it has whenever its
shards settle, so a hold is not lost to a moment offline: the next
reconcile makes it good. A hold whose holder never returns stays, which
leaks a little rather than losing anything. Collecting a block drops the
holds on it.

Dormancy is separate from keeping: a kept terminal off screen with an
idle shell goes dormant (`terminalDormantAfterHours`), its transcript and
cwd kept and a new shell started under the old transcript on recall,
which is never silent (a rule across the transcript says so). Logs are
compacted to snapshots at intervals; retention settings per block kind
say how far back history is kept whole. Every number in this section is
a setting the core reads, never a constant in it.

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
terminal on `devbox` asks devbox whether it's there (§3.8) and to resolve it, and the answer is a
proposal to the space (which may live on `local`) to place
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
| `linked` | a block ⇧-dragged onto a tile; a note made about a block (block → note); strong (§3.4) |
| `pinned` | Pin in Space (space → block); strong, keeping a block without a tile |
| `placed` | placed next to each other in a space, by you |

Each host indexes the links pointing at its blocks; a client merges the
indexes of every host it is attached to, so backlinks cross hosts.

### 6.2 Recall

**Making** is one table too (`BlockKinds`): each kind of block, its
symbol, what it takes after its name (a command, an address, words, a
path) and a line on it. File ▸ New's items, the New Block picker (⌥⌘N,
the kind's name then what it takes, placed by the one rule's keys) and
`mani new <kind> [what]` with its help are all made from it, and all go
through one maker in the controller (`makeBlock`), so a kind is added in
one place. Finding and making stay apart: Open Quickly finds what
exists; the picker makes.

One box: **Open Quickly** (⌘O), over the graph — blocks by title, place
and summary, each row the block's summary card; spaces by name. Find in
Blocks (⇧⌘O) is the same box over what's in the blocks: every outline
first (§7.5) — a terminal's commands and a Markdown text's headings read
from the block itself, so every one is found, shown or not; a tile's
own for what only it knows (symbols, a PDF's contents) — each row going
to the place, through a link to it (`#command=`, `#line=`, `#page=`)
or, without one, by picking it in its tile; then the blocks' texts,
line by line; then agents' turns. Each key switches
the open box to its scope, the query kept. Both narrow to kinds
(`FindKinds`, a table beside BlockKinds, of what's found rather than
made: files, spaces, turns too): a kind's start then ⇥ is a chip, ⇥
again the next kind it begins, ⌫ at the start takes it back; the foot
counts each kind's matches before the chips narrow them, and a count
clicked is a chip. Files are Find in Files' (⇧⌘F), not its; the
verbs are the menus'. It ranks as §3.5 says, and shows each result's
state, host, and where it is. A block an agent works in answers to the
agent's names (its command, its product name, from the block's command,
its status hooks, or a command running in it) as surely as to its
title. ⌘P is its sibling over the focused tile's outline, ⇥ widening
it to the space's.

It must never stutter. What can be found is taken once as it opens (a
snapshot of the blocks, a millisecond or so), and every keystroke ranks
the snapshot off the main thread, giving up on the keystroke before;
the main thread only ever fills sixty rows, laid out by hand. The panel
grows to fit and never shrinks under the pointer while open. Alongside
it:

- **Back and forward** along the trail, across spaces (§3.5).
- **The neighborhood map** for the focused block: its links both ways,
  the spaces it appears in, what was placed beside it.

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

- Proportional (the theme's editing font) or fixed-width text from the
  theme, as now.
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

One tree, as Claude Code's file panel has it, in the content area: an
outline (folders on top, by name), flat, each folder opening in place
into the tree under it, files marked by a small symbol in their type's
colour; the file chosen previewed at the right (`DirectoryTreeMode`, a
split the tile keeps) when the tile is wide enough. The preview is Quick
Look's (`QLPreviewView`) over the name, kind, size and date; a remote file
is fetched first (`readPath`, 20 MB at most) into a folder by host and
path. Over them, the way up (an arrow, ⌘↑) and a filter: typed, it lists
the tree's files matching it, ranked as Open Quickly ranks (`FileFinder`),
the letters matched shown; "?" and words search the files' contents, in a
search block (§7.5) beside.

The host lists (§4): a folder's entries come with `isIgnored` set from
the repository it's in (`git check-ignore`, or for Sapling whatever isn't
in `sl files` or `sl status -u`), and the tree under a folder (`listTree`,
20,000 files at most) is git's tracked and unignored files, Sapling's, or
a walk that skips hidden and dependency folders. Ignored and hidden
entries are left out unless ⇧⌘. shows them. The listing's own entries are
the block's (`listDirectory`, written to its log only when they change);
the folders opened under it are asked for as they open (`listFolder`),
answered and not logged. While it's on screen and the app is in use, the
view asks again every few seconds for what it shows, and a folder whose
entries changed is reloaded keeping the selection. The filter takes the
tree once (again after thirty seconds) and shows, in every mode, the
entries whose path holds each word (the last in the name), the folders on
the way to them, and all of a folder that matched. The mode, the
selection (a path, shared by the modes), the open folders, the sort, the
filter and whether hidden files show are the placement's view state
(§3.5). Opening an entry places its block beside the listing and links it;
a folder replaces the listing in its tile. Still to come: inline rename, drag to and from the
Finder and other placements, and git status badges.

### 7.5 Image, PDF, diff, git, search, process, agent

Each its kind's natural view: PDFKit and an image view (zoom, pages); a
PDF with Preview's controls (the page of how many, back and forward, the
zoom, the layout, find) and its sidebar, the table of contents and the
pages, as a Markdown text has its headings (a tile's own sidebar, at its
left, the bar's button showing it, kept with the tile); a
side-by-side and inline diff; git status, log and blame as lists that open
diffs and files; search results grouped by file with context, live while
running; a process list (sort, filter, select many, signal); an agent's transcript with
its tool calls folded.

The process lens has two modes. **Blocks** lists the trees under the
host's terminals and agents (`ps`, from their shells), each block on a
panel of its own, air between them: its summary card (§3.1) at the top,
what it's doing beside what runs, and its processes on it, set in under
the card's words. **Machine** is the
whole machine, as btop shows it but drawn: CPU (busy and the kernel's
part over five minutes, each core a cell deeper the busier, load, the
processor and uptime), memory (used, cached and free as one bar, swap,
its history), network (in above the middle, out below, on one scale) and
disks (each filesystem's fullness, reading above and writing below),
over every process on the host, the busiest first or as a header sorts
them, those under one of the host's blocks marked and gone to by a
double-click. The pointer reads a graph at its moment, or a core. The
panels flow into as many columns as fit, shrink to a band of small ones
in a short tile and go in a shorter one. The server reads the cheap part
(`MachinePoint`: cores, memory, network and disk counters) every two
seconds whether or not anyone is looking — a few small reads, under a
millisecond — and keeps five minutes of it, so a graph shows its past as
soon as it's opened; the processes are read only when asked (`machine`,
with a sort, a filter, how many and which to keep), their CPU over the
time since the last reading, every two seconds while shown. macOS's
readings are the kernel's (`host_processor_info`, `host_statistics64`,
the interfaces' 64-bit counters, IOKit's block-storage statistics,
`libproc`, with `ps` for other users' processes, which `libproc` won't
time for a user); Linux's are /proc's, parsed in ManifoldCore
(`LinuxProc`) and tested there. A host's card in the sidebar (§3.1) shows
the same panels, its five busiest processes among them, under a remote's
link (its ping times over the same five minutes): the whole host at a
glance, live while it's shown.

A search's hit is previewed beside the results (beneath them on a tall,
narrow tile), as the column browser previews a file (§7.4): the file read
from the search's host (`readPath`, 4 MB at most, not a binary one),
read-only in the code face with a gutter of line numbers, scrolled so the
hit's line sits in the middle — lit as the editor lights its line, its
match boxed and filled stronger than the other matches, all of which are
marked as the query finds them (text or a regular expression, with or
without case). A file is read once per run of the search.

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

### 7.7 Shell notebook

Jupyter's notebook for a shell: a block of cells, each a command and
what its last run printed, run in one shell that lives on between runs.
The block is the host's to write (§8.2): the app proposes each edit
(`editNotebook`: insert, remove, move, a cell's text, clearing) and the
runs (`runCells`, `interruptNotebook`, `restartNotebook`), so edits and
runs never race in the log.

The host keeps a shell per notebook (`NotebookShell`): the user's zsh or
bash (another shell's notebook gets zsh), started as a terminal's is,
with its rc files, on a pty of its own with `TERM=dumb` and pagers set
to `cat`. Once it has started, a line quiets it — no echo, no prompt, no
line editor, no hooks but one — and sets its prompt hook to write `OSC
7503;E;status;pwd`; the line ends writing `OSC 7503;R`, and the shell is
ready. A cell runs as one line: `OSC 7503;B`, then `eval` of a file
holding the cell's text, so whatever the cell sets stays set and an
error reads as it would at a prompt. What comes between B and the next E
is the cell's output; the E, from the prompt hook, comes after a ^C as
after anything else, with the status (130) and where the shell is now
(written as the block's `cwd`, so a relative path ⌘-clicked in an output
is found from there). An E with no B before it (a prompt from the
shell's start) is passed over, unless the run was interrupted.

While a cell runs, what it has printed is sent to the clients as it
comes (`notebookLive`, a tenth of a second at most apart, its last
256 KB), not written; when it ends its output is written to the cell
(the last megabyte), with its status and when. One cell runs at a time;
the rest wait in the block's queue, run in order; a failure empties it,
as an interrupt does. A second interrupt within ten seconds kills the
foreground program's group. A notebook reports its status as a terminal
does (§3.7): working while a cell runs, done when the queue empties,
failed with the cell's exit. The shell ends with the server (or the
block); the cells and their outputs stay, and the next run starts a new
shell.

### 7.8 Panels

A block of widgets an agent (or a script) describes, for what a terminal
can't do well: a form to fill, a choice to make among rows, a slider
to steer by, progress to watch. `mani ui new` makes one from JSON — a
title and items, each `{"type", "id", …}`: labels and Markdown, buttons,
fields and text, checkboxes, selects, sliders, progress, tables and
lists, images, rows and groups of these, dividers — drawn with the
system's controls (`PanelView`), in a column. What the native set can't
do goes in an `html` widget: a page, with `mani.emit(name, value)` to say
what's done in it.

The block holds the JSON whole (`uiSpec`) and the widgets' values by id
(`uiValues`, each JSON): what's set from the shell (`mani ui set id=…`)
and what's changed by hand alike, so a panel comes back as it was after
a restart, and on another Mac. `mani ui set id.property=…` changes a
widget (its label, its rows) by changing the JSON.

What's done in a panel — a click, a change, an emit — is an event: the
widget's id, its value, and all the panel's values. It goes to a `mani ui
wait` on the panel, or waits in the app for the next one (so a loop of
waits misses nothing), and to `mani watch`. A widget with `run` runs that
command on the panel's host, by sh in the panel's folder, with the event
in its environment (`MANI_EVENT`, `MANI_VALUE`) and the panel as
`MANIFOLD_BLOCK`, so `mani ui set @here …` answers in the panel itself;
nothing asks first, but the widget's tooltip says what it runs.

---

## 8. Hosts, attachments and the wire

### 8.1 Processes

- **`manifoldd`**, one per host per user: the logs, the registry and links,
  ptys, the file system, the search and git services.
- **The app**, attached to any number of hosts at once, one connection
  each. It mirrors the shards its placements show and leads the ones you
  edit.
- **Tools**: the `mani` command and scripts, speaking the control side
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
writer, the host: the registry, the links, and the **desk** — the
code's name for a host's list of its spaces, which exist, in order —
and its settings; clients propose (`workspaces`, `settings`). What is a
client's alone — the space it shows, its window, its appearance — is
`ClientState`, in a file beside its hosts file, so two machines attached
to one host see the same spaces and each its own selection. The blocks
a client may lead — text, web, spaces — have **one owner
at a time**, by focus: the host hands a block's pen to whichever
attachment last focused it (`own`), tells the one that held it it is
fenced (`fenced`, with the taker's machine), and refuses appends from any
other, sending the shard back whole; a shard no one owns goes to the
first to append. A fenced client is **watching** that host, as apex's
window does (apex §4, its standing banner): nothing it does to what was
taken takes, and focusing no longer takes a pen there — two clients each
taking it back by focus would trade it between them for as long as both
were used. It says so in a toast naming the other machine, with **Take
Over**, again (every few seconds at most) when something done there
didn't take, and by an eye on the host's row (in the tint: looking on,
not a fault), whose card says who took it and whose menu has Take Over
too. Only Take Over takes back: every shard taken, and the space
and block focused, whose holder is fenced and asked in turn. Watching
lasts through reconnections and whoever holds the pens now — the other
client gone, a server restarted — and ends with the app (a launch starts
leading). A connection is an attachment, but the app's `hello` names its
launch (`instance`): a link made again — its old connection maybe not yet
seen to close — keeps the pens the old one held, so a client is never
fenced by its own ghost. Terminals aren't fenced: what's typed goes to
the shell from any client. That is apex §4 cut down to the one event that
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

### 8.5 As built, in short

Milestones 1, 2 and the first parts of 3, 5 and 6 (§9) are in:

- `ManifoldCore`: `Rope`, `Block` and the per-kind states, `Event` and
  `Entry`, `ArrangementState` with its intents, `Node` (a replica of
  shards), `LogStore` (one file per shard, snapshots with log offsets),
  `Migration` from `state.json`, the protocol (binary plist frames).
- `manifoldd`: `Server` on a `Node` and a `LogStore`; the registry and
  links kept in step; proposals for terminals, files, folders, `seen`,
  links and history; file watching; terminal dormancy with the seam.
- The app: `HostClient` (the replica, leading and proposing),
  `MainWindowController` over spaces and placements, the surface
  (`GridView`), the sidebar, Open Quickly, collection, the history
  view, and the lenses: terminal, editor (`TextView`), preview,
  directory, web.

- Remote hosts (§8.1): providers, the bootstrap, the bridge, `Hosts` in
  the app over any number of `HostClient`s; Linux servers from the static
  SDK; `$EDITOR` through `mani open --wait` and `manifoldd mani open --wait`.
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
  entry — `placed` intervals from space logs, the link kinds from
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
- The neighborhood (§3.5): a tile's links on its bar (`LinkBadge`);
  Go Back and Go Forward (⌃- ⌃⇧-) walk the trail; Open Quickly ranked by
  graph distance; `NeighborhoodView`, the neighborhood to distance 2 in
  graph form, walked by re-centering (⌥⌘M).
- The surface (§3.1, milestones 14–18): `ArrangementState` as acme's
  tiling — columns of tiles with `heights`, a new tile taking the lower
  half of the column's biggest (`bringing(_:lens:inColumn:below:)`),
  `growing(_:step:whole:)` for colgrow, a removed tile's height to its
  neighbor; a share of 0 is a stashed tile, a sheet behind its
  stack's top, fanned out from the stack button (`stashing`,
  `unstashing`; `revealing`, what going to a tile does, brings a
  stashed one to the top of its stack, `toppingStack`, and a new tile
  goes after its anchor's stack, never inside it); `full` a tile
  maximized over the space;
  `GridView` with each tile's bar (`TilePill`: symbol, title, place,
  links, status glyph, maximize and close; drag to move, click to grow),
  dividers, drops between tiles and beside columns; `goTo(_:)` and `show(_:lens:_:)` (Bring
  here) as the two verbs, and `follow` by the one rule, in the
  controller, the sidebar, Open Quickly and every opener; collection of
  placements retired; the sidebar as spine: `OrganizationView` for
  every organization including Spaces
  (`deskTree`, a row per tile), rows that drag and take drops
  (`OrgDragItem`), New and ⋯ in its header, pinned by default.
- Status (§3.7, milestone 17): `StatusRecord` and `Block.status`,
  `.status` entries, `StatusScanner` for OSC 7501, 9;4 and 133 fed by
  each session on the host, the host reporting for searches, git and
  diffs, `attend` marking done and error read; `StatusGlyph` in bars,
  rows and Open Quickly; the Inbox (⌘J) and the sidebar's filter; the Dock badge.
- Overview (§3.6, milestone 19): `StateView` over the surface for a
  space's blocks, or every agent's (⌘', ⌃⌘A), as a list, an overview or
  summaries; the blocks' views under `state:` placement ids, kept while
  it's up; ⎋ leaves it.
- Summaries (§3.5): `BlockSummary` in the core; `SummaryCard` for a
  tile short of room, a fanned stack, Open Quickly's rows, Overview.
- History of a text: `Block.replaying(_:upTo:)` rebuilds a block from its
  log at a moment; the history view (⌥⌘Y) scrubs a text block through
  its changes, and a diff block can compare a text block at two moments
  (`DiffSubject.versions`). (Spaces were scrubbed the same way once;
  that went unused and was taken out with keeping by reachability, §4.)
- Keeping (§4): `EdgeKind.isStrong`, `Graph.reachable`, `Node.roots(on:)`
  (the spaces, and holds) and `Node.reachable(on:)` in the core; the
  host's `collect` once a minute, `discard` for what goes; `Hold` in the
  registry with the `hold`/`release` events and proposals,
  `Hosts.reconcileHolds` in the app; `pinned` links from a space; the
  app's closed stack, ⇧⌘T and the toast.

- The image, PDF, process and agent lenses (§7.5): bytes read on the
  host; `ps` as entries; an agent is a terminal block with a command.
- Retention (§4): `LogStore.compact` folds entries before a cutoff into a
  `.base` beside the log; history carries the base; transcripts of long
  dormant terminals go; the editor's undo depth is a setting.

Still open: sharing (§10), and the finer points listed there.

## 9. From here to there

*A record of the steps as they were taken, in the names of their time —
workspaces, the desk, the finder.*

Today's pieces map directly:

| now | becomes |
|---|---|
| `Pane` | a placement |
| `PaneKind` | a block kind and a lens |
| `Tab` | an unnamed workspace on the desk |
| `Column` (a stack) | a column, shown by the stacks lens |
| put-away timer | collection (§4) |
| ⌘`'s settled order | the trail (§3.5) |
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
    LSP and the `mani` command all through them.
16. **The sidebar as spine.** Pinned by default; Desk rows expand to
    columns and follow focus; drag onto a column; Links follows focus
    with context lines; the history view's diagram draws columns.

Then, putting the model to use (§3.7, §3.1 as a grid, state views):

17. **Status.** `StatusRecord` and `Block.status`, `.status` entries;
    `StatusScanner` in the core for OSC 7501, 9;4 and 133; the host
    feeding it from each session, reporting for searches, git and
    diffs, and dismissing on `attend`; the glyph (`StatusGlyph`) in
    sidebar rows, the finder and cards; the Inbox (⌘J) and the sidebar's
    filter; the Dock badge.
18. **Grids.** `ArrangementState` as acme's tiling (columns of tiles
    with heights, `Heights` back in the log); `GridView` with pills
    (`TilePill`) for tiles; placement by acme's rule; Go to and Bring
    here as the two verbs everywhere; collection of placements retired.
19. **State views.** `StateView` in the surface for a workspace's
    blocks, as a list or an overview (⌘').

---

## 10. Open questions

- **Language servers** run per host now (§7.1); what's open is whether
  their diagnostics and edits should also be entries, so they scrub.
- **Tuning.** The defaults of §4 — how long a closed block waits, when a
  terminal goes dormant, how long history stays at full resolution — are
  guesses until used.
- **Sharing**, when it comes (§8.2).

## 11. Engineering notes

What the README said once of how things work under what you see, kept here.

### Terminals over the wire

- **Terminals** are streams of their host's one connection, attached to a
  shell the server owns, so quitting and reopening the app brings every
  terminal back with the same processes still running. Ghostty runs in
  the app with no pty or process of its own: what the shell prints goes
  straight into it, off the main thread, and what's typed goes up the
  stream. A terminal whose host goes away keeps what it showed, and
  picks up where it was when the host is back — its history, scroll and
  selection kept, caught up with the screen; a remote host is one ssh session
  however many terminals it has. By each remote host's name in the sidebar,
  a sparkline of its ping times over the last five minutes, relative to
  their median, which sits at the middle — a settled link is a line across
  it, slower above, faster below (amber when the latest is well above the
  rest, a red band where pings went unanswered);
  resting the pointer on the host shows its link's dashboard: those times
  plotted with their numbers (now, median, 95th percentile, best), where
  links were given up on, how it stands and since when, the links that went
  in the last hour and why, and how its link is paced and what compression
  saves. A host that's gone quiet (a ping every two
  seconds, one unanswered with nothing else heard for three) shows a broken
  amber ring by its name in the sidebar, which on hover says how long since
  it was last heard from; quiet for six (or four round trips), its link is
  taken for dead and made again at once, as it is when the Mac wakes or
  moves to another network (a spinner there then). What's typed into a dying
  link or while it's away isn't lost: a terminal attaching again sends its
  last 15 seconds of input, and the host writes only what it hadn't taken —
  a keystroke the host had already isn't written twice. The host keeps each terminal itself, in
  the same emulator (Ghostty's, built into the server): a terminal
  attaching is sent a snapshot of it — screen, modes, cursor, a full-
  screen program on its own screen — not the output that made it; and
  one that falls behind (a flood of output on a slow link) skips to the
  screen as it is now, as mosh does, instead of draining all it missed.
  Either way the screen comes at once, and the history it hasn't got
  comes after, behind everything else of the terminal's: the host numbers
  each line as it scrolls off, the app says how far it has them, and what's
  missing is sent newest first and put into the scrollback above the
  lines already there (a line wrapped over rows still one line), without
  moving what you're looking at. Up to 5,000 lines for a terminal opened
  anew, and up to 10,000 of what a terminal missed (after a break, or
  behind a flood), past which an “earlier output not kept” line marks the
  hole; a break while history is still coming sends the rest after it.
  On a link slow enough to feel (a keystroke's echo taking 30 ms or more),
  what's typed shows at once, as mosh's does: characters, backspaces and
  ← on the cursor's row are drawn over the screen before the host echoes
  them — never put in the terminal — and, from 80 ms on, glow softly until
  the host's echo takes their place. A guess shows only once the host has
  echoed one as guessed since the last miss, so a program that takes keys
  for commands (vi's normal mode) shows none; a password the host's pty
  reads without echoing isn't guessed at all (the host says how its pty
  takes what's typed), and anything else typed (a return, a tab, a paste)
  waits for the screen's answer.
  Terminals are paced to the link as files are, but ahead of them, and
  over a link to another host go compressed (zstd, built from its sources
  in Sources/CZstd), each stream's output against what it sent before:
  history after a break comes in a fraction of a second, not seconds. A
  terminal's menu (right-click) has, under Copy, Paste and Clear, the tree
  of what runs under its shell, the shell first, each process a submenu of
  End, Force End and what runs under it.

### Copies between hosts

  A copy between two
  hosts goes straight from the one to the other through this Mac, never
  onto its disk; a copy within a host is made by the host. Each copy is
  a stream of its own in the host's one connection — a whole folder
  one stream, its files' permissions, times and links kept — paced to
  what the link can take: the round trips it measures as it goes show
  how long what's sent waits in queues on the way, and how much may be on
  its way at once is steered to keep that wait small (15 ms, or a fifth
  of the round trip on a long link), following a link that slows within
  round trips; files go in pieces of half that, so a file on its way — an
  image or a PDF opening too — leaves a keystroke, an edit or an answer
  behind little of it, on a slow link or a fast one. A terminal's small
  frames (a keystroke, its echo) go as soon as it's their turn, held for
  nothing else; and its output waits to go no more than the link holds
  before it's behind, and skips to the screen as it is. To and from
  another host a copy goes compressed, as terminals do (one that doesn't
  get smaller — an image, an archive — soon goes as it is), but not on a
  link fast enough not to gain. The host reads
  and writes them aside from its terminals and other clients, and a
  file being replaced is only put in place once all of it has come.

### Forwarded ports

  Each forwarded connection is a stream of the host's
  connection, paced as files are (not compressed: what goes through a
  port is mostly compressed already, or encrypted, and its size could
  tell what it holds), and keeps no more than a megabyte on
  the way each way, so a fast server and a slow reader (or the other
  way round) fill nothing but themselves; and one side done sending
  still hears the other's answer.

  Lines are 1.45 to edit, 1.3
  for code, and to read 1.45 (SF), 1.5 (New York), 1.55 (Chronicle).

### Fonts in each role

  Each role's size scales everything set in it, and all
  of it reaches everywhere the role is used: editors and notes (the
  editor's lines and letters too; a file viewed has lines of 1.4 at
  least), previews (as CSS), and terminals (as Ghostty's font family,
  style, size and features, its cells' height and width giving the line
  height and spacing).

### Contrast correction

Programs pick their colors for dark terminals, so on light paper `fd`'s greens
or an `ls`'s yellows can't be read. Manifold checks each cell's text against
its background as it's drawn and, where they don't reach WCAG AA (4.5:1),
moves the text's color in Oklab lightness until they do. Its hue and chroma
are kept, and nudged toward the nearest theme color. With deuteranopia
correction (the default), the text must also read as a deuteranope sees it.
**Settings ▸ Appearance ▸ Contrast** switches between that, typical vision only,
and off. This is a port of apex's `contrast.rs`, in [the Ghostty
patch](patches/ghostty.patch). Its Appearance follows the system, or
keeps to light or dark.

### The memory watchdog

- **A memory watchdog** keeps an eye on the app's own footprint from a
  thread of its own: past 6 GB it has the system sample the process
  (every thread's stack) into `logs/memory-sample.txt` in the data
  folder, once, for finding what runs away; past 24 GB it ends the
  app — a renderer; the server keeps everything — rather than take the
  machine down, and says so in the log.

### Design measures

The app's own chrome is drawn from a few named measures (Design.swift),
not literals: **Radius** — hair 1.5, inline 4, control 6, surface 10,
capsule (half the height); **UIType** — display 22, heading 15 semibold,
title 13 semibold, row 13, body 12, detail 11.5, caption 11 medium,
count 10.5 (figures of one width), label 12 medium (a lens's header),
footnote 11, a block's symbol 13; **Elevation** —
resting (a sheet, a tab, a card: 0.18, blur 3, a point below), tile (in
the light: 0.10, 10, four below), float (a panel: Flat.shadow);
**Motion** — fast 0.12 s, base 0.16, spatial 0.24, easing out to appear
and in to go, one curve to travel and one that overshoots to settle;
**EdgeColor** — hairline, subtle, strong, control (a checkbox, a
knob, a badge, a sheet or tab behind a tile, darker hovered), and the
tint strong (what has the keyboard, is chosen or targeted) and soft
(what's on, or focused within); **Status** — running (the
accent), done, attention, failed, offline, each its own in light and
dark and darker in the light to read as text; the tint as text
(`Tints.accentText`, darkened or lightened until it reads on a panel)
and behind white (`Tints.accentFill`, darkened until white on it reads);
a **Pill** for counts and
ages; one row band (Flat.rowBand) for every list. Text is at least 4.5:1
on a panel or a card in either appearance.

---

## 12. Deliberate departures

Where Manifold parts from macOS's conventions, or from its own rules, on
purpose — set down so a later audit reads them as choices, not slips.

### The model

- **Spaces, though macOS has Spaces.** Manifold's are inside the window
  and never touch Mission Control; the word is short and the same
  everywhere — the Spaces organization, the Space menu, the Dock menu,
  `@space` in `mani`.
- **Spaces are the only roots, and only you remove one.** No Keep, no
  favourites: a block lives while a space reaches it — shows it, pins it,
  or reaches it through a link by hand — and a space stays, named or
  not, emptied or not, until it's removed (⌥⇧⌘W, its row's menu) or
  dropped on another. One rule for what lasts. Pin in Space is how a
  block stays without a tile.
- **Closing can lose a block.** ⌘W on the last tile showing a block lets
  it go after half an hour, where macOS's closing never deletes. It's
  said, not silent: a toast with Restore, ⇧⌘T, Recently Closed, and
  Open Quickly's *recent* rows.
- **Size is presentation, not state.** A tile shrinks along one ladder —
  content, summary card, bar, stashed — by the room it has; there is no
  minimized or collapsed state to get stuck in, and every step comes
  back by resizing. Shrink to Summary (⇧⌘M) only sets a height.
  Maximize stands apart, a layout of its own.
- **Overview is the one view across spaces.** Agents is a filter of it
  (⌃⌘A), and past ten blocks it shows summaries rather than live tiles.
  The Inbox marks a block read when it's focused; there's nothing to
  clear.
- **Hover cards are pictures, not live views,** so hovering never
  moves a view out of its tile.

### Words

- **A tile's bar, its title, its links (faces, stacked), a summary
  card;** a block's link in a note's text is a capsule. Not
  title bar, header or chip. *Pill* is only for a count or an age.
  A *chip* is a host's mark after a title, or a kind a find is narrowed
  to, before its query.

### Keys

- **⌘O is Open Quickly** — blocks and spaces, not files; ⇧⌘O the same
  over what's in them; Open Folder… is
  ⌥⌘O, and file contents are Find in Files (⇧⌘F), after Xcode and VS
  Code. There's no ⌘T.
- **⌘P is the outline, not Print.** Scoped to the focused tile, ⇥ widens
  it to the space; ⇧⌘P filters the tile's own outline and doesn't forget
  its filter, and pressed again leaves it. Print stays in the File menu,
  keyless: rare in a tiling tool.
- **⌘M is Stash,** the app's own minimize; ⇧⌘M, Shrink to Summary, is
  the step above it. Minimize stays in the Window menu, keyless.
- **⌥⌘M is the map,** taking macOS's Minimize All.
- **⇧⌘W deletes a block,** where the Mac closes a window: Manifold's
  windows are its spaces, removed with ⌥⇧⌘W, and ⌘W on Settings
  closes it.
- **⌥⌘W saves and closes** an editor (vim's `:wq`, an `$EDITOR`'s done),
  where the Mac closes all windows.
- **⌃⌘T pins,** the Finder's Add to Sidebar: a pin keeps a block in its
  space's part of the sidebar, with a tile or without.
- **⌘` walks spaces,** the app's windows; with one space it walks
  windows.
- **⌃⇥ walks a stack** as a browser's tabs, in every view, a terminal's
  too; a quick release switches without showing cards, as ⌘⇥ does.
- **⌃- and ⌃⇧- are Back and Forward, except in a terminal,** where ⌃-
  stays readline's and Emacs's undo; the mouse's back and forward buttons
  work there. **⌘[ ⌘]** are a tile's own history.
- **⌃Space is Complete,** though it's the system's input-source switch
  for anyone with two keyboards — the editors' key; ⌥⎋ completes too.
- **⌃⌘R Rename Symbol, ⌃⇧⌘R Find References, ⇧⌘K Delete Line,**
  near Xcode's and VS Code's; **⌥⇧⌘D Compare with Last Commit**, as
  ⌥⌘D hides the Dock.
- **Escape:** a picker that comes and goes (Open Quickly, ⌘P, the find
  pill, a walk) closes on the first press; a filter that's part of a
  view (⇧⌘P, a listing's) clears first, then leaves, as a search field
  does. Maximize isn't a mode and Escape doesn't undo it.

### The pointer

- **One rule for opening anything** — a link, a link's face, a sidebar row, a
  ⌘O row: plain goes to it, ⌘ opens it beside, ⌥⌘ over, ⇧⌘ in the
  system's app or browser. In a terminal ⌘ is what makes a click a link
  click, so ⌥⌘ is over there.
- **Three views go on in place,** as a browser does: a page's link, a
  preview's link to another Markdown file, a listing's folder, each on
  a plain click — the tile keeps a trail, ⌘[ ⌘] along it. ⌘ still
  opens beside.
- **The bar:** a click grows the tile a step (acme's colgrow — clicks
  build up; no double-click), ⌘-click fills the column, ⌃-click or the icon
  opens the tile's menu, ⇧-click the path menu.
- **In a stack** a click brings a tile to the top and ⌘-click takes it
  out, as ⌘-drag takes the top alone.
- **The map** is a graph browser: a click re-centres, double-click or ↩
  goes.
- **Reset Graph is only on the host's own row,** not in every menu as
  Reset Server is: it can't be undone, and the friction is the point.

### Look

- **Open Quickly's field is 22 points,** the one big field; the stack
  button's count is 8-point bold on a 5-point radius, a badge on a
  button.
- **Colours that say something keep their own:** the diff's, a find
  match's, the terminal's palette, the code page's (go.dev's), a remote
  host's chip in the accent, the summary card's fill lifted above the
  panel in the dark.
- **Motion that isn't a transition** keeps its own time: the status
  spinner's 2 s loop, the backdrop's 0.6 s wash, the scroller's fade
  after a second (as the system's), predicted echo's glow.
- **Printing is black on white;** a system alert's accessory takes the
  system's label colours; content — editor, terminal, diff, notebook —
  takes the font themes, not the chrome's UIType.
