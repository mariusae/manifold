# Manifold — design

Manifold is a wiki, not a set of windows. Terminals, files, notes,
folders, web pages and searches are **blocks**, and everything is linked:
a workspace links the blocks it shows, a note the blocks it mentions, and
what you do leaves links behind — this terminal opened that file, this
search found that line. It is all one graph, and the graph is what keeps
things: a block stays alive as long as it is reachable, from a workspace,
a name, a Keep or a link by hand, and what nothing reaches any more is
collected. Nothing is filed or put away; you link, and you follow links
back. A workspace, the blocks you've arranged to work in, is itself a block
you can name and come back to. Blocks live on hosts — this Mac, a dev box,
a server — and one window shows, and links, blocks from several at once.

This document describes where Manifold is going. The app as it stands
(README.md) is the first sketch of it: sheets that are cheap and put
themselves away, state on a server, the UI only a renderer.

It borrows heavily from apex (~/src/apex/DESIGN.md, sections cited as
apex §n): its replicated logs, leases, exec entries and wire protocol. What
differs is the shape of the thing: apex is one session per host with acme's
windows; Manifold is a graph of blocks from many hosts, kept alive by what
links to them, and arranged in workspaces.

---

## 1. Principles

- **Everything is linked.** Actions leave links behind (this terminal opened
  that file; this search found that line), so recall can walk from one
  thing to what was around it. The links you make — a workspace placing a
  block, a link by hand — are what keep things (§3.4); the ones actions
  leave are history and keep nothing.
- **What nothing refers to goes.** A block is kept while a workspace, a
  named workspace, a Keep, or a link by hand reaches it (§4);
  closed everywhere, it waits half an hour to be brought back, then is
  collected. The graph holds what you're using, not everything you ever
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
symbol and name (a dot after it while edited and unsaved), where it
is, its host in a pill after the name (a server's symbol and the
host's name, in the accent) when that isn't the workspace's host — the
last thing the bar gives up as it narrows — its links, its status glyph (§3.7, the program it names in the
tooltip), and maximize and close; the stack behind it shows as its
sheets. The bar is the tile's handle to drag, grows the tile a step
when clicked, and holds its menu behind the symbol. As a tile narrows
the bar gives things up in order, so the symbol and some of the name
always show: the place goes first, then the links' pill shrinks to its
arrow and symbol, then to its arrow alone, then maximize goes, then
the pill altogether; close and the status glyph
stay, and last the name is cut. A tile grown down to less than a line
of content collapses to its bar alone, rounded all round, a pill, its
content out of sight. The content runs beneath the bar, never under it,
with room between cards and the window's wash — a few pools of colour
placed afresh each day over what's behind the window, blurred — showing
through. A stack's sheets peek out above its card, rounded, as paper.
(Once a glass pill floating over the tile, as Prism names a column.)

Two verbs, and no others, put a block in front of you:

| verb | what it does |
|---|---|
| **Go to** | the block where it already is: the workspace it is in (this one if it is here, else the one most recently gone to) is selected and the tile focused |
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
workspaces in use, in the order you arranged them, the named ones
that you've kept there. Taking a workspace off the desk doesn't end it
at once (§4). An unnamed workspace is named by what it holds — the
folder most of its blocks are at, with the repository's branch when a
git block is there, else the focused block — so the sidebar never says
"Untitled" twice.

A workspace can be shown in a window of its own or as one of the desk's
tabs in a window, as Safari has both: drag a tab out for a window, a window
in for a tab. Several windows may show the desk; each OS window shows one
workspace at a time.

Workspaces nest: a placement may show another workspace, as a card (its
title and a small live picture of it) or opened in place. A project is an
workspace of workspaces; nothing more is needed for folders.

### 3.3 Naming is keeping

An **unnamed** workspace is scratch: taken off the desk, it is a root no
longer, and it and whatever only it held are collected after the grace
(§4). Naming one makes it a place: a root whether or not it is on the
desk, its columns kept however long they go unseen, though the blocks
behind them may go dormant to free their resources and come back when
the workspace is recalled.

### 3.4 Strong and weak edges

Of the graph's edges (§3.5), two kinds are **strong**: a workspace's
placement of a block, and a link made by hand (`linked`). A strong edge
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
| **before / after** (temporal, across blocks) | block → block | the registry's *trail*, bounded, per host: each focus of a tile, each workspace seen — the one history, which back and forward walk and ⌃⇥ orders by |
| **version** (temporal, within a block) | (block, t₁) → (block, t₂) | the log |
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
3. **The finder (⌘O) is ranked by the graph.** Only what is kept (§4)
   is found. With nothing typed, the focused block's neighborhood,
   nearest first; typed, what the query names best first, and among
   equals the nearest to where you are over the graph's edges, strong
   and weak alike. What was closed and not yet collected comes last,
   marked *recent*: choosing it brings it back.
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
   takes a stamp — who opened it *then*. A map lens of nodes and edges
   is possible and comes last.
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
language server's document symbols) sits beside this rather than in it.

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

**One rule for the modifiers**, wherever a click opens a block — a
sidebar row, a note's link or pill, a badge, a listing's entry, a
scrubber's command, a finder row chosen with ⏎: plain **goes to** it
where it is (here, if nowhere); **⌥ means over** — the block goes over
the tile clicked in, which is stashed behind it (`showOver`), as
⌥-drag stacks a tile over another; **⌘ means beside** — below the tile
clicked in, taking its lower half. ⇧ is about the path: ⇧-click a bar
for where the block is, ⇧-drag a bar to link. One `Where` case carries
each, read off the click wherever a view opens (a terminal's link needs
⌘ to be a link at all, so there ⌘⌥ is over and ⌘ alone beside; the
terminal keeps ⌥ back and remembers it).

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

**The Inbox** is a derivation, not a flag: the blocks whose root
status wants attention — done or failed and not yet read, or needing
you — by host and workspace. Reading a block (focusing it) takes it
out; nothing is set or cleared by hand. (Keeping a block is a separate
thing, §4.)

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

### 3.6 Organizations: views over the graph

The graph is the representation; how it is *organized* is a view over it,
chosen as fits the task, and the organizations keep no state of their
own. A folder being open or a day being shown is view state; nothing
about the data changes when you look at it another way. The rule is that
the graph has to capture everything any organization needs:

| organization | a view of | roots |
|---|---|---|
| **Desk** | workspaces and what they place (§3): one shape, nothing folding by itself, the current workspace barred at its left, a workspace closed by its chevron staying closed | the desk's workspaces |
| **Files** | blocks with paths, folded into their folders, across hosts; a sparse tree, runs of single folders one row, counts and recency aggregated beneath | hosts → repositories (git or Sapling roots) → `~` → `/` |
| **Inbox** | the blocks whose status wants attention (§3.7), by host and workspace | hosts |
| **Search** | the words typed, in the contents of every kept block — a text's lines, a terminal's commands, names, places, addresses — each block with its matches beneath, pushed over the tree as Kept is | blocks |

Three, and Search beside them. The links live on the tile's badge and its fan, and in
the neighborhood map (⌥⌘N, or the badge's menu) as the one big view
of them; what's working, done or needing you is the counts in the
sidebar's bar, which open the Inbox, and the state views; and time is
⌘O with nothing typed, which is the trail.

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
over it), a filter, a bar at the foot (search, by workspace or by file,
the inbox, the counts), and the same row — symbol, name, a count, a
detail, fading with age — with the same gestures everywhere (the one
rule: click to go to, ⌘-click to show beside, ⌥-click to show over,
§3.1), a card on hover (with a picture of the block's tile when one is
on screen), the Neighborhood Map in the menu. Under Desk, every
workspace shows its tiles, in order, the focused one marked, so the
sidebar is the table of contents of the screen; clicking a tile row
focuses it, and a block dragged onto a workspace is shown there. Two
rows at the foot, Kept and Recently Closed (§4), each push their list
over the tree, with a back button and the list's name in the header.
The workspace stays the working surface; organizations are how you
reach blocks, never where they live. One exception is on purpose: a
**state view** shows a status group's blocks themselves in the surface,
live, in one of two ways — a **list**, the blocks stacked down one
scrolling column as Prism's column of notes is, each under its pill; or
an **overview**, all of them laid out in one grid at once, as Mission
Control lays out windows — so what is blocked, or done, can be looked at
without placing any of it. A block clicked in a state view is gone to;
⌘-clicked, brought to the workspace last shown. A state view is not
a workspace: nothing is placed, nothing is logged. ⌘O stays the quick
way in.

---

## 4. Keeping and collection

What keeps a block is being **reachable**: a path of strong edges (§3.4)
from a **root** to it. The roots on a host are

| root | why |
|---|---|
| a workspace on a desk | what is in front of you |
| a named workspace | naming is keeping (§3.3), on the desk or off |
| a kept block | Keep, by hand: a root whatever refers to it; Keep and Close (⇧⌘W) keeps it and takes its tiles off |
| a **hold** | another host's standing reference (below) |

and every block a root places, links by hand, or reaches through what it
places and links, is kept. The host is the collector: once a minute it
walks its own shards from its roots, notes each block nothing reaches
with the moment that began, and **collects** any that has been so for
the grace (`collectAfterMinutes`, 30 by default, a setting): its
session ended, its file unwatched, its links gone, its log deleted, the
registry told, and every replica following. A block reached again
within the grace is simply kept, its mark forgotten.

Closing is what makes things unreachable. ⌘W takes a tile off its
workspace; an unnamed workspace left empty leaves the desk; ⌥⇧⌘W takes
one off whole; and an unnamed workspace unseen for some days
(`workspaceDriftDays`, 3 by default) drifts off the desk by itself. The app keeps what it closed on a stack, and **⇧⌘T**
puts the last thing back where it was — a tile at its old column and
place (here, if that workspace has gone), a workspace onto the desk —
skipping whatever has been collected meanwhile. **Recently Closed**, a
row at the sidebar's foot with a count, lists what exists and nothing
reaches, and the finder marks it *recent*; either brings it back by a
click. **Kept**, the row beside it, lists kept blocks on no workspace
of the desk and named workspaces off it. Neither is in the tree: the
tree is only what's on the desk.

Collection is never refused and never silent. Closing takes with it
everything the closed block alone reached — what it placed, what it
linked by hand, and onward — so the app compares what was reachable
before and after, and when something on its way out would lose
something — a text with unsaved edits, a terminal with a job running,
which collection will end — a toast at the foot of the window names
each of them and offers Restore, which reopens what was closed and so
reaches them all again.

**Holds, across hosts.** A host sees only its own shards, so a reference
from another host — a workspace there placing a block here, a link by
hand there to a block here, a desk there listing a workspace of this
host — would be invisible to its collector. The client that holds both
sides tells the target host: a `Hold{id, block, holder}` in the target's
registry, keyed by the edge it stands for (the placement's or link's
id, or `desk:<holder>:<workspace>`), proposed when the edge exists and
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
| `linked` | a block ⇧-dragged onto a tile; a note made about a block (block → note); the one strong link kind (§3.4) |
| `placed` | placed next to each other in a workspace, by you |

Each host indexes the links pointing at its blocks; a client merges the
indexes of every host it is attached to, so backlinks cross hosts.

### 6.2 Recall

One box, two ways in. **⌘T** over the graph: blocks by title and path,
workspaces by name — and the verbs (new terminal, new note, attach a
host, launch an agent), found by name among them, marked *do*. **⌘O**
over the same blocks and the files in the focused block's folder. It
ranks as §3.5 says, and shows each result's state, host, and where it
is. A block an agent works in answers to the agent's names (its
command, its product name, from the block's command, its status hooks,
or a command running in it) as surely as to its title.

It must never stutter. What can be found is taken once as it opens (a
snapshot of the blocks, a millisecond or so), files are listed in the
background and kept per folder, and every keystroke ranks the snapshot
off the main thread, giving up on the keystroke before; the main thread
only ever fills sixty rows, laid out by hand. The panel grows to fit
and never shrinks under the pointer while open. Alongside it:

- **Back and forward** along the trail, across workspaces (§3.5).
- **The neighborhood map** for the focused block: its links both ways,
  the workspaces it appears in, what was placed beside it.

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
the tree's files matching it, ranked as the finder ranks (`FileFinder`),
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
writer, the host: the registry, the links, and the **desk**, a host's
metalog of its workspaces — which exist, in order — and its settings;
clients propose (`workspaces`, `settings`). What is a client's alone —
the workspace it shows, its window, its appearance — is `ClientState`,
in a file beside its hosts file, so two
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
  `unstashing`; `revealing`, what going to a tile does, brings a
  stashed one to the top of its stack, `toppingStack`, and a new tile
  goes after its anchor's stack, never inside it); `full` a tile
  maximized over the workspace;
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
  rows and the finder; the Inbox; the Dock badge.
- State views (§3.6, milestone 19): `StateView` over the surface for a
  workspace's blocks, live, as a list or an overview (⌘'); the blocks'
  views under `state:` placement ids, kept while it's up; ⎋ leaves it.
- History of a text: `Block.replaying(_:upTo:)` rebuilds a block from its
  log at a moment; the history view (⌥⌘Y) scrubs a text block through
  its changes, and a diff block can compare a text block at two moments
  (`DiffSubject.versions`). (Workspaces were scrubbed the same way once;
  that went unused and was taken out with keeping by reachability, §4.)
- Keeping (§4): `EdgeKind.isStrong`, `Graph.reachable`, `Node.roots(on:)`
  and `Node.reachable(on:)` in the core; the host's `collect` once a
  minute, `discard` for what goes; `Hold` in the registry with the
  `hold`/`release` events and proposals, `Hosts.reconcileHolds` in the
  app; `pinned` on a block; the app's closed stack, ⇧⌘T and the toast.

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
| ⌃⇥'s settled order | the trail (§3.5) |
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
    sidebar rows, the finder and cards; the Inbox; the Dock badge.
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
- **Tuning.** The defaults of §4 — when a placement leaves an unnamed
  workspace, when a terminal goes dormant, how long history stays at full
  resolution — are guesses until used.
- **Sharing**, when it comes (§8.2).
