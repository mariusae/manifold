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
  toast says what was closed, with Undo beside it while its countdown
  runs (⇧⌘T after); deleting is undone the same way, not asked first.
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
| **Link** | a typed edge from one block (or a place in it) to another (or a place in it), possibly across hosts |
| **Place** | a part of a block that can be named: a declaration, a heading, a command, a page, a hunk (§2.5) |
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

### 2.5 Places, and edges between them

Everything is the graph: blocks are its nodes, links its edges, and what
the screen shows of them is a projection of it. Finer than a block, a
**place** in it can be named, and named the same way whatever it's in.

**Anchors.** A reference names a block and, optionally, a place in it
by an **anchor**: `manifold:host/ulid#k7q2m`, an id the block made, opaque
to everything else — nothing in a reference to parse. Referring to a
place mints its anchor in the target block's own log (a proposal to its
host), or finds the one there for that place; the block alone says
what an anchor is and where it is now. So an anchor put right is put
right once, for every reference to it, and it has a home for what a
place has: its name, where it was last found, whether it's gone. An
anchor lasts as long as its block — references are pasted where no edge
follows them (a commit's message, a chat) — and the few legible places
written before anchors (`#line=12`, `#command=7`, `#page=3`) still
lead where they say, as do those a person or an agent writes by hand
(`#lines=3-7`, `#cell=k2x9`).

A place is made one way, whatever it's in. Every view says what's
**here** — its selection, else where it's at: a text's caret line, a
terminal's command, a PDF's page, a diff's rows, a notebook's cell, the
command an output came from — and every outline's item, search hit and
changed line is a place too: a block (or a file on a host not opened
yet), where in it, and what it's called. A reference to a place, a drag
of it, a link copied to it and a thread about it are all made from that
one description, anchored the same way: a file's place (a hit's line, a
diff's lines) when it's dropped, its text read first, so it keeps
leading there and doesn't drift with the line numbers.

An anchor holds what it's at, the way its kind knows the block's
structure — a declaration's path (`Type.method`, by its language's
grammar), a symbol's global name (`scip`, where an index has one), a
heading's path, a command, a page, a hunk, a cell, an element's id, a
time — and what finds it again: a text's anchor has a range, moved
through every edit as the block moves its selections (§2.4), in one order
on every replica, so it holds even where nothing knows the language;
and an excerpt, for when the text changed where no edit said (the file
written by another program): the block finds it again by what it's
at, else by the excerpt, else says it's gone, kept to be put right.

| kind | what an anchor is at |
|---|---|
| `text`, code | a declaration (its path by the grammar; its `scip` name where indexed), or a range |
| `text`, Markdown | a heading (its path), an item, or a range |
| `terminal`, `agent` | a command (one command and its output), a turn |
| `pdf` | a page |
| `diff` | a file, a hunk (a file and its hunk's heading) |
| notebook | a cell |
| `web` | an element (its id) |
| media | a time |

Each kind says, of its places:

- **what they are**, in order: its outline is one such list, not the only
  one (a file's declarations, its headings, a terminal's commands);
- **which is at** a location, the most lasting it can say — what dragging
  from there anchors;
- **where an anchor is** in the content as it is now, or that it's gone;
- **what it's called**, and its summary: a pill's title, a card's face (a
  declaration's signature and doc comment, a command and how it ended).

Agents make references through `mani` (a file's declarations listed, a
reference to one printed), never by spelling an anchor.

**Edges between places.** A link has an anchor at either end, or none:
`Link{from, fromAnchor, to, toAnchor, kind, relation, at}` — from a
note's paragraph to a declaration in a file, from a hunk to the heading
that explains it. Read both ways, as every link is (§3.10): a place
lists what links to it, as a block does — a declaration marked as
written about, in its gutter and its outline, its links there.

**Relations.** An edge's kind says how it was made and whether it keeps
(§3.4, §6.1); its **relation** says what it means: an open word, as a
scheme is. Some Manifold knows how to show — `describes` (a summary, a
function's pseudocode), `annotates` (a remark on it), `explains`, `step`
(one of a walk through code) — and any other is a link like the rest.

**Presentation is a projection.** Nothing is stored about how an edge
shows; the lens decides, and you choose per tile. A note that
`describes` a function may show in the function's place, its body folded
under its description (in the technical font, §7.1); in the margin;
as a card on a rest; or only among the links. A walk through code is a
note whose references, in its text's order, are its steps — its edges
ordered by their places in it — followed one beside the other. So an
agent adds nodes (notes, panels) and edges, through `mani`, and how they
appear is Manifold's; and you organize them by hand the same way.

**Uniform.** A reference with a place is a reference like any other: it
drags, drops, shows as a pill and a card, is followed, is listed among
links both ways, and says why when it leads nowhere — the block gone
(§3.9's `whyMissing`), or the place: "`layout(line:)` is no longer in
TextView.swift", the edge kept until it's put right (re-anchored) or
removed. Keeping is per block: a place changes nothing of what keeps what
(§4).

As built: `Anchor` in the block's state (`Block.anchors`, by the `anchor`
event), a text's ranges moved by `edit`, and by what changed between
the old text and the new on `content` (anchors in the change marked
unsure); the app makes and finds them (`Anchoring`): a declaration by
the language's declarations query (`SyntaxLanguage.declarationQuery`,
its `@decl` and `@name`, nested into paths), a heading by its path, a
line by its words — found again nearest where it was. `Link` and the
graph's edges carry `fromAnchor`, `toAnchor` and `relation`; one link of
a kind per pair of places; a mention of `manifold:…#anchor` in a text is
a link to the place. An outline's `line=` place, dragged or copied,
becomes its anchor, as a line dragged from the editor's gutter does;
`mani symbols`, `mani ref`, `mani link --as`, `mani read` of an anchor
and `mani info`'s places give agents the same. The editor shows a text's
places (`TextView.Place`, from `editorPlaces`): a mark in the gutter
for one with links (its links, clicked), and a note that `describes`
(else `annotates`, `explains`) it under its line — the first
presentation by relation; folding (by declarations, or a Markdown note's
sections) hides a body, leaving the description in its place. A note's
references, in order, are a walk, stepped beside it (⌃⌘]). A
terminal's command and a PDF's page are anchored too — referred to (an
outline's item dragged, Copy Link, a link made through `mani`), `command=`
and `page=` become anchors at them, read and gone to as those places
are; a selection dragged out of a text refers to the declaration it
names, else to its stretch (`Anchoring.anchor(range:)`). Describe,
Explain and Walk Through with an Agent hand an agent a place and what to
make of it — notes and links by relation, through `mani` — the
presentation left to Manifold: nothing of it is built in but the asking
(`Anchor.legibleFragment` for commands and pages). SCIP: each host runs a project's
indexer when asked (`SCIPService`, in the user's login shell, the index
kept by root's hash in its folder, read once and again when made anew);
`SCIPIndex` reads Sourcegraph's protobuf (documents, occurrences with
their roles, symbols' information) and answers the symbol at a place
(columns counted as the document says), its definitions, its uses, and
what a file defines; `SCIPRequest`/`SCIPResult` carry them over the
wire as LSP's do. `mani index`, `mani refs` and Find References' fallback
use it; a declaration's anchor keeps its `scip` name, followed to
another file when it's gone from its own. A file saved indexes its
project again (a while after the last save) if it has an index.
Callers (`mani callers`, Show Callers) are the index's uses grouped by
the declaration each is in, by the file's grammar, recursively — a
note of references, so a tree of calls is a walk like any other. To
come: anchors in diffs (made again from their sources); indexers'
settings per host (as language servers' are); notes in the margin.
Peek (`PeekTip`) asks the language server's hover and the index at once,
the index's answer shown first and the server's in its place when it
comes. The tip watches for its own going — the pointer off the name, a
key or a button down, a scroll, its window no longer key — rather than
leave it to the text it came from (which heard nothing once the pointer
was over another tile, and the tip stayed till the app quit); it takes
no clicks, they go through it. Pinned highlights (⌃⌘E) and the caret's tint are the one
symbol's uses, as the language server highlights them
(`documentHighlight`, `LSPRequest.highlights`) — a parameter's, not a
property's spelled the same — asked again a moment after the text
changes, moved through edits meanwhile; with no server (or no answer),
the name's whole words not in comments. A fold's hidden lines draw
nothing, tints included. A reference to an anchor its block hasn't got
— made while a server from before anchors (protocol 61) dropped it — is
found again, when followed, by the words of the link to it in the text
it's followed from (a declaration's path, a heading, else the line
with those words) and minted under the same id (`recoverAnchor`). The
Markdown preview shows a note about a place under the element its line
starts (`placesFor`, the page's `data-sourcepos`); a git tile shows its
project's index's state; the host takes one spelling of a path (/tmp is
/private/tmp) for a project's root.

### 2.6 Projects

A project is a folder made one by hand (`Project`): its root, kept in
its host's desk (`DeskState.projects`, `.project`/`.unproject` events,
proposed by a client), so the host and every client attached find the
same one, and the project of a path is the nearest root at or above it
(`Project.holding`). The root is kept as the folder's tile names it,
the host's own spelling beside it (`alias`) where links make them
differ. What's under the root is the project's, whatever the
repository around it: a git block can be scoped to it
(`GitState.scope`, the project's folder in the repository, proposed as
`projectGit`) — `git status`/`log` (`sl` alike) given it as a path, so
its changes and commits are the project's alone. Made, a project is
indexed at once (§2.5). It's a folder still: its tile (§7.4) shows the
homepage round its files. Nothing is guessed where no project is made:
a path outside every project finds its repository and indexer as it
did, by their markers.

A project is searched as one: a search block's query can ask for
symbols and files by name besides the text (`SearchQuery.kinds`), and
the host fills them in beside the hits (`SearchState.symbols`, `files`;
`.searchSymbols`, `.searchFiles`) — symbols from the project's index
(`SCIPService.search`: each defined symbol's name, what it's in and its
kind by its last descriptor, made once an index is read, scored as
⌘P scores titles) at once, then merged with the language servers'
running there (`workspace/symbol`, three seconds at most; one place
once, the index's kept), files ranked from the project's file list
(kept half a minute, for the next keystroke's). What's said comes
marked by who said it (`SymbolHit.source`), so a hit from the index and
one from a server can be told apart.

A project is the scope of what's done in it. Its index is at its root,
made by the indexer its settings choose (`Project.indexer`, `indexCommand`;
"none" for none), else the one whose marker is at its root, else its
files' language's (`Project.indexer(among:)`, `SCIPService.locate`); a
path outside every project finds its index as before. Its repository is
watched from the host's start, and when the working copy's commit moves
(`VCS.headArguments`, looked at as the repository's state file changes)
a project that wants it (`reindexOnCheckout`, yes unless said) is
indexed again, as a save does. The state file is taken as changed only
when its time, size or inode is (each `git status` reads git's index,
and its time read changing came as a change: a refresh a second, for
every repository watched). Source Control for This Project, in one,
is its scoped git block; a search under one widens to it
(`SearchQuery.project`). `mani project` says a folder's project, makes
one, or takes it back.

The finders rank the focused block's project first (`focusedProject`,
`MainWindowController.block(_:isIn:)`, a block's place under its root on
its host): in ⌘O's distances, its blocks in the space before the rest of
the space's (0 against 1), its others before what's elsewhere (2, with
the spaces); its files not yet blocks listed from its host
(`FinderFiles`: `listTree`, kept by host and root) at the same 2, behind
its blocks by recency; in ⌘P's whole-space outline, a tie between
places named as well goes to the project's tile.

An index behind its code says so: the host counts the project's code
files changed after it was made (`SCIPStatus.changed`; off its queue, at
most every ten seconds a root, the last count meanwhile), and the
homepage's strip and `mani project` say how many. The sidebar's
languages are counted on its host as GitHub's Linguist counts them
(`Linguist`, asked as `languages`, kept a minute): the bytes of each
programming or markup language (`CodeLanguage.countsAsCode`), less
what's vendored, documentation or generated by Linguist's own path
patterns (vendor.yml, documentation.yml, generated.rb's names), by what
a code file's first 4 KB say (a generated mark, or minified: lines 110
characters long on average), and as the project's `.gitattributes`
files say otherwise, read as git reads them (a deeper file's and a
later line's over the rest's; a folder's pattern matching nothing) — a
docs/ of generated pages, megabytes each, had made a Rust project 86%
HTML. They're drawn as shares (`LanguageShare`, a language's colour as code
hosts colour it), and its Here Now the client's own reading of the
host's blocks (`Presence`): terminals and agents whose directory is in
it, notes linked to a file of it — each as its card (`SummaryCard`), those placed in the space shown first and the rest
under Other spaces. A project's root's other spelling is
the file system's (`realpath`: /private/tmp), not Foundation's, which
gives /tmp back — a terminal's directory says the former.

---

## 3. Spaces

### 3.1 The surface

A space is **human-constructed**: what is in it is what you put there,
and it stays until you take it off. Nothing in it is tidied away,
nothing is out of sight but what you docked, and nothing is placed for
you by a heuristic except where in the grid a new tile lands.

A space is a **grid**, apex's tiling (apex §11, *Tiling, as built*),
which is acme's: columns, each a stack of **tiles** top to bottom,
every tile a block, all of them visible. A new tile lands in the
biggest empty space, else takes the lower half of the biggest tile in
the active column (acme's `makenewwindow`); a tile grows by a few
lines, as big as can be, or to the whole column; the divider between
columns sets widths. **Room goes back where it came from**: a tile
keeps what it borrowed as it came — opened, or moved in — from the
tiles that made room for it (`ArrangementState.loans`: each lender and
how much), and as it goes — closed, moved away, docked — pays each
back that's still beside it, so a tile opened and closed again leaves
its column as it was, and one moved elsewhere and closed there leaves
both as they were. A height set by hand (a divider dragged, a tile
grown) forgives the loans of the tiles it sets; what isn't owed goes to
the tile above, else below — where a new tile would have taken it from.
A tile covered by one dragged over it (docked under it) hands that one
its room and its debt, and has them back when that one's taken off.
Columns likewise: a new column
takes a fair share of the width from every column in proportion, and
gives it back in proportion when it goes — the widths as they were, not
made equal. Every copy of the space works the loans out alike from the
same events.
Each tile has a **bar** across its top: the block's symbol and its
**title** (a dot after it while edited and unsaved), where it is, its
host in a chip after the title (a server's symbol and the host's name,
in the accent) when that isn't the space's host — the last thing the
bar gives up as it narrows — its **links** (the linked blocks' faces,
stacked), its status's
pill (§3.7, the program it names in the tooltip), and maximize and
close. The bar is the
tile's handle to drag, grows the tile a step when clicked (⌘-click
fills its column, docking the others; ⌥-click fills all of it but the
others' bars, which stay in the grid, each down to its bar — Tile ▸
Fill the Column, Keeping Bars, ⌃⌥⌘=; after either, a click on its bar
puts the column back as it was, those docked back where they were and
every share as it was — as acme's — if nothing's changed it since;
⌃-click or the symbol opens its menu), and as a tile narrows
gives things up in order, so the symbol and some of the title always
show: the place goes first, then maximize, then the links, and the
status's word becomes a dot; close and the status stay, and last the
title is cut.

A tile **shrinks along one ladder**, by the room it has, not by a state:
its content; then, under a few lines' room, its **summary card** (the
block in a few lines, §3.5, shaped as the tile, joined to its bar); then
its bar alone, rounded all round; pushed past that (a divider dragged
over it), docked. Shrink to Summary (⇧⌘M) only sets a height on that
ladder, and every step comes back by resizing; Maximize stands apart.
The content runs beneath the bar, never under it, with room between
tiles and the window's wash — a few pools of colour placed afresh each
day over what's behind the window, blurred — showing through.

A tile is **docked** (⌘M) to be out of the way and kept going: out of
the grid, its room back where it came from, still in its space (and
running) — listed in the sidebar under the space's Docked, the latest
docked first, and among ⌃⇥'s cards. Gone to again (⌃⇥, its row,
a link, ⌘O), it goes back where it was: under the tile it was under
(else over the one it was over, else a column of its own where its
was, as wide), its room taken back from the tiles that took it
(`DockedTile`: its column, its neighbours, its share, who took it). A
tile opened over another (⌥, an `$EDITOR` over the terminal that ran
it) or ⌥-dropped on it takes its place and docks it *under* itself:
taken off, the one under comes back in its place and room. Docking is
not pinning: a pin keeps a block in the space for good and says where
it sits among the space's rows; a docked tile is only out of the grid
for now. Docking flies the tile into its row in the sidebar (if the
sidebar's showing), its picture shrinking into the row; undocking, back
out of it into the tile, so where it went is seen. (A shelf of docked
tiles along the grid's foot was tried as a view option, and left: the
sidebar's list does the job.)
(Docking took the place of stacks — tiles stashed behind
another in its column, shown as sheets over its bar and fanned out —
which were used only to put a tile away for a while. Older logs' stacks
replay as docked: a share of 0, a `stash`.)

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

**Keys** mean one thing each, wherever they're pressed, and every one
is in a menu (Rex's discipline). ⇧ is the bigger thing or the way back
(⌘W a tile, ⇧⌘W a space; ⌘F here, ⇧⌘F in files; ⌘/ the tile's sidebar,
⇧⌘/ the window's; ⌘G, ⇧⌘G). Brackets walk a sequence, the modifier
naming which (⌘ a tile's history, ⌥⌘ the tiles, ⇧⌘ the spaces). ⌥⌘ and
an arrow moves the focus that way, as `mani`'s @left and @below name
tiles (`ManiLayout`); ⌥⇧⌘ and an arrow moves the tile a step that way
(`ArrangementState.nudging`: up or down past the tile beside it, left
or right into the next column about as far down,
a column of its own at the edge). ⌃⌘↑ ⌃⌘↓ moves the item you're on — a
line, an outline's row, a notebook's cell. ↩ is how the tile shows: ⌘↩
its own action (Edit or View, Run Cell, Toggle Checkbox — the Tile
menu's item titled by the tile), ⌥⌘↩ as an outline, ⌃⌘↩ the other mode
beside, ⇧⌘↩ maximized. ⌘. is cancel. A menu keeps a key for one item
only (AppKit clears it from the next), so no two commands share one,
even where they'd never both apply; `menukeys` (debug) lists them all.

The space's log holds `Place{placement, column, at}`, `Move`, `Remove`,
`Focus`, `Fractions`, `Heights`, `MoveColumn`, `Dock`, `Undock`, `Full`
and `Title`.

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
(⇧⌘W, or its row's menu) or drop it on another; nothing removes one
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
| **before / after** (temporal, across blocks) | block → block | the registry's *trail*, bounded, per host: each focus of a tile, each space seen (not those a switcher only passes, whose order is the window's own places settled on first, then the trail's) — the one history, which back and forward walk and each switcher walks at its own scale (below) |
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
   Clicked by the one rule; and the **neighborhood map** (⇧⌥⌘M) as the one big view of the
   focused block's surroundings, two steps out. (This was a Links
   organization in the sidebar, and before it the foot under every
   sheet.)
2. **Back and forward**: Go Back and Go Forward (⌃- ⌃⇧-) walk the trail
   across tiles and spaces — derived from the log, so it survives
   restarts and crosses hosts; ⌘[ ⌘] walk a tile's own, where it goes on
   in place (a page, a preview, a listing).
3. **The switchers are the trail at three scales**, as ⌘⇥ and ⌘` are
   the Mac's at two: ⌘` walks its spaces, ⌥⇥ its tiles in every space,
   ⌃⇥ this space's — its docked tiles too, a card each (out of its row
   in the sidebar, and back), one settled on going back where it was.
   Each walks while its modifier is held and
   settles where it's let go, so a tap goes back and forth between two;
   only what's settled on goes on the trail, and settling on a tile
   settles its space. Back and forward are the other reading of the same
   history: a stack of every place, within blocks too, walked a step at
   a time, a tap going further back rather than back and forth. What
   the window settled on comes first, ahead of the hosts' trail, so a
   switch doesn't wait on a host to hear of it.
   ⌃⇥ or ⌥⇥ held, its cards are in place 270 ms after the
   press: made out of sight as it's pressed (some 25 ms), shown 120 ms on
   and unfolding in the 150 ms left — long enough to be seen coming out
   of where they are, which says what they are (an earlier 150 ms, shown
   at 60, was over before it was seen), and late enough that a quick tap
   sees nothing (shown at 30, most taps caught them). Let go before they show, it was a
   tap: nothing's seen, the tile behind comes up; let go as they unfold,
   they fold back the way they came, four times as fast (from where
   they've got to, no jump), then it comes up. ⇥ again before they show
   is no tap, and they come at once, in place 60 ms on; ⇥ while they
   unfold sends them the rest of the way four times as fast.
4. **Open Quickly (⌘O) is ranked by the graph.** Only what is kept (§4)
   is found. With nothing typed, the focused block's neighborhood,
   nearest first; typed, what the query names best first — its title,
   its place, its summary — and among equals the nearest to where you
   are over the graph's edges, strong and weak alike. What was closed
   and not yet collected comes last, marked *recent*: choosing it brings
   it back.
   **The openers have one ladder of reach**: the tile, the space, all
   spaces. Each begins at its nearest — ⌘P (places) at the focused tile,
   ⌘O (names) and ⇧⌘O (what blocks say) at the space shown — and its own
   key pressed again goes a step wider, from the widest back to the
   nearest, as JetBrains' Go to File takes in what's outside the project
   pressed twice; ⌘P stops at the space. Where it looks is always shown,
   at the field's end: the reaches as words, the one it's at on the
   accent's pill (a click goes to another). The space's is its tiles
   (docked ones too), its pins, what was closed from it, its agents'
   turns, the files of every project its tiles are in, and the desk's
   other spaces themselves — places to go, found by name only (whole,
   its start, a word's), not what they hold; all spaces is
   everything kept, a row in another space saying which, the other
   spaces' projects' files listed only once it's widened. Nothing found
   as far as it looks, one row says how much a step wider finds, and ↩
   on it goes there (the query kept). What choosing does is the one rule
   (§3.7): ↩ goes to a block where a tile shows it, in any space, ⌘↩
   brings it beside here.
5. **Summaries** are how a node renders small: a few lines saying what's
   worth knowing of it at a glance — a terminal its last command and how
   it ended, a note its first lines, a diff its files and lines changed
   (`BlockSummary`, from its state alone, so a block off screen or on
   another host has one too). A tile short of room shows its summary
   card; so do Open Quickly's rows, ⌃⇥'s cards, a link's face
   rested on, Overview past ten blocks, `mani ls`. A sidebar row's hover card is a picture of the tile,
   never the live view. With a stamp, a summary could show the node *as
   it was then*, which Prism cannot.
6. **Time is a dimension of every query.** `neighbors(of:kinds:at:)`
   takes a stamp — who opened it *then*. A map lens of nodes and edges
   is possible and comes last.
7. **Slices edited where they are.** A search hit's line, a link's
   context line, the new side of a diff: each a byte range of a text
   block, each an editor whose typing is an `.edit` entry on the block
   (Prism's `TaskEditor` writing a task back to its note). Same undo,
   same history.
8. **Pictures.** A snapshot of each placement when it goes behind
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


**The inspector** (⌥⌘I) is a window of its own (`InspectorPanel`), a
floating, non-activating utility panel — over every window, Manifold's
and other apps', not hidden when Manifold isn't in front, never taking
the keyboard — not one of the sidebar's views (a saved sidebar showing
it opens on the desk now). It follows the focus, made again a moment
after any change, and it's as compact as the Finder's Get Info
(`InspectorList`): a section's heading with a disclosure triangle, a
folded one with how many rows it holds; a row a line, its label
capitalized and right-aligned in a column with a colon, its value after
it middle-truncated, the whole in its tip; a row that does something
lit under the pointer, a click doing it or going where it names. Only
what it is (About) and its kind's section are open at first; what the
reader folds or opens stays so, by section, for every block. Its
annotations show under its name, as Get Info's tags. It's meant to show everything there is to know
about a tile, for a person or for checking what a tool sees: its ids and
annotations for tools, its status record whole, the tile's own state
(lens, place, size, what the lens keeps), its kind's state field by
field, its log — its length, and its latest changes by kind and age,
asked of its host once a block, since a replica holds only what came
after it connected — and the tile's trail back and forward.

**Annotations.** A block — a space too, which is one — keeps keys and
values for tools (`Block.annotations`, set by `.annotate`, an empty
value taking a key away): a handle a script or an agent's tool gives it
— a task's id, a role — that stays whatever its title becomes, so
nothing has to keep a name stable to find it again. `mani annotate`
sets and prints them; any name mani takes may be one (`key=value`, or
`'key=*'` for any value), the block with it — in the space shown, if
more than one has it anywhere — and `--space` takes one for a space;
more than one is an error naming them, as a position is. `ls` prints
them, `info` and `ls --json` carry them, the inspector shows them. Keys
are words (a letter or `_`, then letters, digits, `_ . : -`), so a path
with an `=` in it is never taken for one.

### 3.6 Organizations: views over the graph

The graph is the representation; how it is *organized* is a view over it,
chosen as fits the task, and the organizations keep no state of their
own. A folder being open or a day being shown is view state; nothing
about the data changes when you look at it another way. The rule is that
the graph has to capture everything any organization needs:

| organization | a view of | roots |
|---|---|---|
| **Spaces** | the space shown and what it places and pins (§3), one space at a time: its pinned blocks, what's on screen as the grid has it (column by column, a hairline between), its docked tiles — nothing nested, nothing folding | the space shown; the others in the strip at the foot |
| **Files** | blocks with paths, folded into their folders, across hosts; a sparse tree, runs of single folders one row, counts and recency aggregated beneath | hosts → repositories (git or Sapling roots) → `~` → `/` |

Two — and the space's threads (§3.12), which are other things than
blocks in a tree: the three are icons along the sidebar's top, by its pin, the one
shown on a band, Threads with a count of those with something not seen.
(A filter over either tree, to blocks with a status — the lighthouse
beside them, ⌥⌘. — was tried and left: what needs you, always at the
foot, does what it was mostly for.) The links live on the tile's bar and in the neighborhood map
(⇧⌥⌘M, or a link's menu) as the one big view of them; what's working,
done or needing you is the counts at the sidebar's foot, what needs
you over the strip, and Overview; and time is ⌘O with nothing typed, which is the
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
Under Spaces, **one space at a time**: its name heads the list (with
how many tiles are on screen and docked, and its host when there's more
than one), then its tiles in sections that don't fold — Pinned, in the
order pinned; On Screen, as the grid has them, column by column, a
hairline between columns; Docked, the latest first — the focused one
marked, so the sidebar is the table of contents of the screen; clicking
a tile row focuses it (a docked one comes back where it was). The other
spaces are **the strip** along the very bottom, as Arc's spaces are
(`SpaceStripView`): a small square each in its colour, its letter or a
symbol in it (both chosen from its menu, kept on it as annotations,
`space.color` and `space.symbol`; unchosen, a colour by its id and its
name's first letter); the one shown outlined; a dot at a corner for
what most wants you in it; a hairline between one host's and the
next's; after them a + (a new space on the shown one's host; the
pointer on it, with more than one host, a list of them over it —
`HostPickerView` — to make it on another, each with whether it's
connected and how many spaces it has). Clicked, a space is gone to; the pointer on one shows a card of
its tiles, what wants you first; a two-finger swipe across the sidebar
goes to the next, or the one before, and the grid slides sideways as
the strip has them, the sidebar's list sliding with it. A tile, or a
row, dropped on a square goes to that space docked (⌥, a copy there
too), flying into the square, and the window stays; held over it a
moment, the space opens, for the drop to land where it's wanted. Over
the strip, always there, is what **needs you** in every space
(`NeedsYouView`): a row each, its space's square, its symbol and name,
what it needs in a pill; clicked, gone to in its space; five at most,
then how many more, which shows them all (and "Fewer" again); none,
not there at all. Squares too many for a row wrap onto another, the
strip as tall as it takes. A square's menu shows its colours and
symbols as they'll look.
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

Under Files, a host's heading stays at the top of the list while its rows are
scrolled past it (`OrganizationView.updateStickyHost`): a copy of its
row (`StickyHostView`) over the list, pushed up by the next host's
heading as it arrives — not the outline's floating group rows, which
would make hosts group rows, styled and clicked otherwise. The sidebar
may be clear over the window's backdrop, so the heading can't cover the
rows under it: they fade out there instead, by a gradient mask on the
list as deep as the heading shows (the list's layer is flipped; the
mask runs from its y 0). The pointer on the heading is on its host's
row: the band, and the host's card (its machine, its link's dashboard),
not the card of the row scrolled under it.

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

**Indicators** (`StatusMark`), wherever a block's title is — its bar,
its sidebar row, a summary card (the Overview's) — add ink only when
the block needs you. `working`: the title **shimmers** (`Shimmer`: its
layer masked so a wide band — about 40% of the title, 60 to 160
points — faded to 30% sweeps across it in 2 s every 3 s, the title at
full strength between, by the clock, so every working title moves in
step and many read as one rhythm; a narrow bright band on a dimmed
title was too subtle), the percent beside it in grey when the program says
how far (OSC 9;4 counts); with Reduce motion the title holds at 75%
and a still dot sits beside it. `blocked`, and `done` and `error` until
attended to, are a word in a **pill** at the right edge (`StatusPill`):
the kind — Permission, Question, Sign in, else Needs you — in amber,
Done in grey, Failed in red; a pill shows exactly while the block is
in the inbox (⌘J), and once attended to there's nothing. Short of
room, a bar's pill is a dot in its color before the title is cut. In
a bar it's left of everything else at the right — the links' pill, the
buttons — just after the title, so a status coming or going moves
nothing else; the grid places the links' pill again whenever the bar's
buttons or the links' room change, not only when it lays out. An
inactive terminal's title is dimmed; `idle` nothing. A host's states
(connecting, offline, quiet, watching) keep their glyphs, and a
notebook's cells their own, beside their run's time and exit status.
In the sidebar the pill comes after how long ago the status was
reported, and what it said (its title, its message) is on the line
beneath the name. The Dock badge counts the blocks blocked and done.
(It was one glyph — a turning ring, an amber ring, a filled check —
until October 2026: every row wore one, and a code had to be learned.)

**One rule for the modifiers**, wherever a click opens a block — a
sidebar row, a link or a block's link in a note, a tile's links, a
path, a search or git hit, a listing's entry, an outline's command, a
card in Overview, an Open Quickly row chosen with ⏎: plain **goes to**
it where a tile shows it, in any space (beside, if none does); **⌘
means beside** — below the tile clicked in, taking its lower half; **⌥
means over** — the block goes over the tile clicked in, which is
docked under it until it's taken off (`showOver`), as ⌥-drag puts a
tile over another;
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
ticks the shell's commands — its outline. The knob is drawn alone, on
the terminal's own ground — no track, as macOS's overlay scroll bars and
the app's lists have none. It comes and goes as an
overlay scroll bar does — shown while the content scrolls or grows and
while the pointer is on it, fading a second after — unless the system's
scroll bars are set to stay. The shells Manifold starts
carry a hook (zsh's `preexec`, fish's `fish_preexec`, bash's DEBUG trap)
that writes the command line as `OSC 7502 ; line ST` before running it;
the host's status scanner (§3.7) sees it beside the OSC 133 marks and
appends `ran` to the block, then `exited` with the status at `133 D`;
the two stamps give how long it took, shown with how it ended wherever
a command is (its outline's entry from a second up, the tile's summary,
its output block).
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
the command line and its outcome above — how it ended, how long it took
(`ran` to `exited`, `BlockSummary.took`), when — read-only, Copy putting the
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

The terminal finds its links by reading the viewport's lines with ⌘ held
(`TerminalLinks`): a line as its program wrote it, the rows the terminal
wrapped it over joined — ghostty marks a row it wrapped, and its text
read across the end of one has no newline — so a link it wrapped is one,
drawn as a run on each row (the runs carry their link's number, and the
hovered link's are all on the band). A line a program broke itself
can't be told from two: only a path is joined across it, the last word
of one line and the first of the next (past its indent), when the
joined path has a slash and is there (looked at, or looked up on another
host as any path is). A file's link is only as sure as its path can be
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
with a block focused (⌥⌘N) is the same edge, from the block to the
note, as if the block had been ⇧-dragged into it. Into a note the
block also lands as a Markdown link, `[title](manifold:host/ulid)`,
hence a `mention` edge too; the editor draws such a link as a capsule
— symbol, title and status as the tile's bar has them, redrawn as they
change — and the preview as a small one, either clicked as any link; a
reference written bare (`manifold:host/id#place`, as agents write them)
the same. An embed, `![name](manifold:…)` alone on its line, is the
block's summary card instead (§3.1's, drawn in the editor in the line's
place but on the caret's line, under its row in the outline, as HTML in
the preview), redrawn as the summary changes; one naming a place (§2.5) is
that place's (`Block.summary(at:)`: a command's line and how it ended,
with its output's last lines where the terminal is shown; a heading's
or an item's section, `NoteOutlineMarkdown.section`; a PDF's page, with
its picture). Annotation is thus the graph again:
nothing new is stored but edges and the note's own text.

### 3.11 Dragging things

There are two kinds of drag. A tile's bar (or a block's row, card or
face) dragged plainly *moves* it, or brings the block — the arrangement
is what changes. Everything else dragged is a **thing**, and so is a
tile ⇧-dragged, or dragged by its bar's icon — the icon a proxy, as a
document window's title's is. The pointer on it swings the icon itself
out of the bar toward you, about 40°, hinged at its left edge in a
little perspective (a depth of 90 points to its 16), and grows by a
fifth, so it shows past the open hand over it — and a mark of our own
unfolds as it swings, so even a slight one has edges to turn: a
terminal's `>_` steps up and in as a window draws itself round it, a
note's turned corner peels half as far again, its back shaded
(`Marks.parts`: each stroke at rest, as the mark's image draws it, and
unfolded, the same points moved, animated as paths) — settling with a
little overshoot, a short shadow falling on the bar from the edge that
lifts — nothing lit behind it: the pose is the sign (`IconHandle`, which
draws the icon in a layer of its own while it's out — drawn there and
then, at the screen's scale and in the view's appearance, and set
without a fade — the icon's view hidden; with less motion, only the shadow comes). It swings back as the
pointer leaves or the drag begins: a block, or a place in one (an outline's item: a
command, a heading, a page, by its words — a command by its dot too, a
PDF's page by its thumbnail, `PDFPagesView`); a notebook's cell by its
gutter (its command's words, the notebook); a block named elsewhere — a
project's Here now, a node of the neighborhood map (which hides while
it's dragged, so a tile under it takes the drop, and closes after); a file or folder on a host
(a folder's entry, a search's hit, a changed file, one from the
Finder); a page's address; a picture; words. A thing is written the same
from wherever it's dragged (`DragThing`: the block and its place, the
file and its host, the folder a terminal is in, the address, the words),
beside what another app takes (its file here, its text), and read the
same wherever it lands (`Dragged`), from Manifold or not.

A **commit** is a thing too (`DragThing.Commit`: its host, repository,
sha and summary), from wherever one is shown: a git tile's history, a
project's sidebar, a commit's diff ⇧-dragged (whose block carries it).
Named — linked, referenced, inlined, opened as a tile — it's its diff,
the block found or made then (`Drags.commitBlock`); as words, its sha,
which is what a shell, an agent or code takes first (the `commits` kind
in the table below). Dropped with files, the files' words are their
paths: a shell gets `path sha sha` on one line.

**Several things** go in one drag, one pasteboard item each, and land
as each would alone, joined as the target joins them — on a command
line by spaces (paths, references, shas: `Dragged.asWords`), in a text
on lines of their own. The lists that offer things let several rows be
chosen, as the Finder's do (⌘-click one in or out, ⇧-click a run), and
a drag from one of them carries them all: a git tile's changes and
commits (headings left out of a run), a folder's files (in columns,
several in one folder, no column past theirs and nothing previewed; in
its tree, any, kept through relisting), a search's hits, a project's
homepage's search and its sidebar's changes and commits (rows of our
own, `HomeRow`, chosen by the sidebar), a tile's outline. A ⌘- or
⇧-click only chooses there, where a plain click would go somewhere
(the homepage's rows, an outline's entries); ⏎ in a git tile opens each
chosen. A row's menu, right-clicked among the chosen, acts on them all,
as the Finder's does (a row not chosen: its own): a folder's
(`DirectoryView.menu(for:)` asks for the several's menu) opens them
beside in a column of their own, each under the one before as several
dropped on the grid are, one already in a tile gone to, its slot left
for the next; reveals them in the Finder, downloads them, copies their
paths; a git tile's (`GitView.menuItems`, its own, it had none) opens
their diffs, the changes' files, reveals and copies those, copies the
commits' shas, a line each.

Where it lands takes it as one of the **forms** a thing can be: its
*link* (`[name](manifold:…)`, a file opened as a block to be linked to),
its *reference* (`manifold:host/id#place`), its *path* (on that host
only), its *text*, its *contents* (what it holds, or what's at the place:
a command's output, a heading's section, a page), *inline* (in a note: a
picture kept as an image block, any other block as its card), a *tile*
of its own, a *link to the tile* under it, a *copy* or a *move* into a
folder. Each target (`DropTaking`) says which it takes, the one that
suits first: a note a link (a picture inline), a shell a path (a place
its words, a block its reference), an agent a reference (a file its
path), a notebook a new cell, a folder a copy (its own
host's entries moved), the grid a tile where it lands, or over a tile
whose view takes nothing, for a block, the link to the tile. Each
target's order is a priority list, and what a thing can't be there is
left out of it: a file Manifold doesn't open (a film, an archive) can't
be linked to, referenced, inlined or read, so a note takes its path,
and the grid opens it in its own app — no form that would do nothing
is offered, the next in the list is the plain one instead.

The editors and terminals keep their lists in one table
(`Dropping.priorities`), by target — an agent, a shell, a note, code —
and by what kind of thing it is: pictures, a selection (words dragged
out of an editor, which carry a reference to their place too), a place
in a block (a heading, a command, a declaration), commits, a block,
files, plain words. An agent wants what it can read and point back to: a reference
first for a place or a block — its contents only when asked, which go
stale — a path for a file, a selection's words as they are (they're
what was meant; the reference is the palette's). A shell wants what a
command line takes, a path or the words; a note links; code takes a
place's words and a file's path. Reading across the table (a kind's row
in each target) is how the targets are kept to one idea of each kind.

Whatever's dragged out — words selected, a gutter's line, a tile, a
row, a link, a picture — the pointer is the closed hand from the moment
the drag begins until it ends (`DragCursor`), whatever it began as (an
I-beam over text, an arrow over a list) and over whatever it passes in
Manifold's windows, their cursor rects held off meanwhile; over another
app, the system's cursor for its drop.

Any drag resting on another space's row in the sidebar **springs** that
space open, as a Finder folder does (`OrganizationView.springUnder`):
the sidebar's outline takes every dragged type, though only blocks,
tiles and files drop on its rows — the rest only spring. Over the
system's spring-loading delay (`com.apple.springing.delay`; none with
`com.apple.springing.enabled` off) a band in the tint fills the row from
the left, eased in so it quickens (`SpringBand`), blinks twice, and the
space is selected under the drag, its grid sliding in as any switch
does; the band then fades where it is, in place of the one that glides
from space to space. The pointer leaving the row, the rows, or the drag
ending takes it away. Not for spaces and hosts being reordered, nor the
space shown; with less motion, the band lights at once and doesn't blink.

While a thing is dragged, it's shown as a **pill** of its own (`DragPill`:
its icon, its name, on a raised ground with an edge and a shadow — a
few one under another, then "and N more"), wherever it's dragged from,
so it reads over anything it passes; rows dragged by their bullets go
on a card the same way. The first pill wears a **badge** (`DropBadge`,
`DragPill.wear`) on its upper right corner, by the pointer, with the
symbol of what a drop does there — the palette's for that form, and
only that: no words; a drop answers an operation that shows no badge
of the system's. (The target draws it into the drag's own image: a
badge in the window would be under it. A drag from another app, whose
image isn't ours, has it beside the pointer, where the system's + would
be.) It's shown
again as the drag moves (a modifier pressed, another target, the
palette's rows), so it's always what dropping right then would do;
where nothing can be done, a grey ⃠. A quick drop does what it shows;
the pointer resting a moment (`Dropping.restDelay`, 0.6 s, as a folder
in the Finder springs open) — or ⌃ held — opens a palette there
(`DropPalette`, after Dropzone): a row for each form the target takes,
the plain one under the pointer, so a drop that doesn't move still does
what it would have, the others below it; moved onto one and dropped,
that's put in, where the pointer rested; moved well away, it closes and
the target has the drag again. While open the palette is the drop's
target itself, whatever is under it, and its lit row, with its symbol,
is what a drop does. What a view doesn't take goes on to the grid
behind it.

### 3.12 Threads

A **thread** is a conversation about something: a line, a declaration,
a diff's rows, a terminal's command, a PDF's page, a quote on a web
page — any place (§2.5) — or a whole space. You leave one anywhere
(⌥⌘M), to yourself or to an agent; an agent joins when tagged, and
leaves them too. They are notes to self while working (resolved when
fixed, in place of a `bugs.md`), a question to an agent asked where the
question is, an agent's "I assumed this", and a review: rows selected in
a diff, commented on, and later handed to an agent to address. Every
thread of a space, and of a project, is on one **timeline** with
everything that happened to them, read as Quip's updates are: what
you've seen kept, what you haven't marked.

**A thread is a block** (`BlockKind.thread`), so it is placed, linked,
dragged, kept and collected (§4) as every block is, and `mani` reads it.
Its log is its entries, in order; its state, open or resolved. It is
*about* one thing: one `annotates` link (§2.5's relation, a link by
hand, so it keeps what it's about and the place's anchor with it) from
the thread to a place, or to a space with no place in it — so no thread
is about nothing, and one about a space is the space's. It is the
space's it was made in: a `thread` link from the space to it, strong,
which keeps it (§4) and makes the space's timeline one lookup. It lives
on the space's host, written by the host (clients and `mani` propose),
whatever host what it's about is on.

**Entries, and who made them.** Each entry has an author, first-class in
the model and on screen:

- *You* — one author, the same on every Mac (the Mac it came from kept,
  said on hover).
- *An agent* — its block (the terminal it runs in), its kind (Claude,
  Codex, …), and the turn that wrote it (`captureTurn`'s), so an
  agent's comment leads back to the turn.
- *Manifold* — what no one typed: its place moved, its lines deleted.

An entry is a **comment** (Markdown, its references as a note's), or an
**event**: resolved, reopened, its place edited (by whom: you, an agent
— below) or gone, an agent asked, asking stopped. Authorship is
*fenced*, not claimed: it's set from how the entry came. From the app,
typed, it's yours; from `mani`, the host the command ran on asks the
socket for its caller (`LOCAL_PEERPID`, Linux's `SO_PEERCRED`) and walks
up its processes to the terminal they run under — an agent's (as its
hooks say, §3.7), the agent's; else yours, typed in a shell — and puts
that on the request before passing it on. No flag says who; an agent
can't write as you by clearing its environment.

**Places.** Every place a block kind knows (§2.5), and these, new:

- *A diff's rows* — what was seen (the rows and their hunk, as they
  were, kept in the anchor: what the comment means), and where that is
  now: new lines anchored in the file (as it is, or as the commit left
  it), removed lines at where they were removed — a place in the file,
  moved through its edits as any anchor is. So a thread made in a diff
  is shown in the file's editor too, at its lines, and outlives the
  diff. The commit, if the diff is one, kept as context; in Sapling a
  rewritten commit is followed to its successor, in git it's said
  rewritten.
- *A commit's line* — from the history strip (§7.1): the file as that
  commit left it.
- *A quote on a web page*, by its words and what's around them.
- *A region of an image.*
- *An agent's turn.*

A place may drift. Each thread says where its place is now and what it
was written against: "written at line 40, now 52", or gone, the context
then all there is — whatever its kind, not a diff's alone.

**References.** A thread takes what a note takes: a tile's pill, a line,
rows, a command, a page dragged into the composer, a `manifold:…#place`
pasted — each a capsule in the comment's text, and, as a note's
mentions are (§3.10), a `mention` edge from the thread to the place. So
a thread has two kinds of edge out: the one it's *about* (`annotates`:
it shows there — in place, in the gutter, on the timelines) and those it
*mentions* (shown among links both ways — "mentioned in a thread" at
the place — but no card there). Threads cross-correlate without a
mention scattering cards about.

**The chat.** A thread reads as a chat, the same wherever it's drawn:
at its head, what it's about (the excerpt; drifted, said so); then its
entries, each comment as Quip's conversation shows one, all at the
left: its author's round **mark** (your initial on the accent, an
agent's face; clicked, the agent and the turn), their name in bold and
when beside it, the words under the name in full ink, no bubble — one
more from the same author just after, its words alone under theirs;
in the timeline each thread's run a card a shade lighter than what
it's on, its place a heading over a hairline — and each event a
hairline sentence ("Resolved by Claude · 2m"); an agent at work on it
shows working, as its tile does; at its foot the composer (↩ sends,
⇧↩ a line, `@` an agent, drops take references) and Resolve. Replying to
a resolved thread reopens it.

**Where threads show.** One thread, several lenses (presentation is a
projection, §2.5):

- *In place*: a mark at the right edge of its line, over whatever text
  is there, the same in the text editor, the outline (a row: the lines
  of the Markdown it stands for) and a diff (its rows) — a small badge,
  a bubble and how many when more than one: on the accent while one has
  something not seen, outlined in it while one is open, grey once all
  are resolved (`ThreadMark`); clicked, the chat as a card there. A tile
  of another kind marks its place its own way (a terminal's command, a
  PDF's page, a notebook's cell).
- *As a tile*, for a long conversation — it's a block.
- *The sidebar's Threads* (⌥⌘3, an icon along its top beside Spaces and
  Files, with how many have something not seen): the space's threads
  listed by title — the open by what was said last, newest first, then
  the resolved, closed; each with where it's about and how long since,
  a count of what's not seen — or the timeline. Its header's buttons:
  the other way to show them, the filter (all, open or unread; the
  space's or its project's — filled while it narrows them), Mark All
  Read. A row clicked is read in the overlay; ⌘, a tile of its own; ⌥,
  its place.
- *The timeline*, in the sidebar or a tile of its own. A run's heading
  clicked goes to its place and reads the thread in the overlay (a
  space's thread, the overlay alone); its ↖↘ pops it out, a tile of its
  own. A thread popped out, an agent asked, a walk's step — anything
  made or shown without a place asked for — goes where acme puts a new
  window: in the active column, below its biggest tile; a new column
  only when asked for one (⌥⇧⌘ and a kind's letter, ⇧↩ in ⌘N's picker,
  `mani show --column`).
- *The overlay*, anywhere (below).

**The timeline.** All the activity that's relevant, newest last, as a
running chat: every entry of every thread of the space (or project —
the threads whose place is in it, by the project of the place's file or
the terminal's directory, §2.6), interleaved by time, each run headed by
its place. Relevant is: a thread's comments and events, a thread made,
the edits to a thread's place (attributed: an editor's are yours; a
file written by an agent's Edit or Write, its `PostToolUse` hook naming
the path, that agent's; else "changed on disk"), an agent asked from a
thread and its answer. Activity that touches nothing a thread is about
isn't there (a finished turn is the inbox's, §3.9). Edits to a place
are written into the thread as events by the host as it moves the
anchor through them (`edit`, `content`), so the timeline is the merge of
thread logs, nothing else. Filters: open only, mine, an agent's,
resolved too. Replying in the timeline replies in the thread.

**What you've seen** is kept as Quip keeps it: per thread, the last of
its entries you've seen — a mark in the host's desk (`.seen(thread,
upTo)`, the greatest kept, so every Mac's attached app moves it and
none undoes another; shared across Macs, as you are one). An entry is
seen once it has been on screen a moment (about a second, the window
key) in any of the lenses — the card, the tile, the timeline, the
overlay. Opening the timeline goes to the first entry not seen, a
**New** rule above it that stays while you're there; a thread with
entries not seen is bold in lists, with how many; Mark All Read. Only
others' entries count: what you wrote is seen.

**The inbox** (§3.9) gains a rule, a derivation still: a thread with
entries you haven't seen, not yours, is in it — an agent's answer, an
agent's question — gone through with ⌘J with the rest, and seeing them
takes it out.

**The overlay** (⌥⌘M), over the window from anywhere, as the switcher
floats, taking no tile. With a selection, or a place under the caret
(the declaration, the command, the page), on that place: its threads,
or the composer for a new one about it. With none, on the space's
timeline, its composer making a thread about the space. A place in it,
clicked, is gone to with the overlay kept; ⎋ closes it.

**Agents.** `@` and an agent — its pill, dropped or picked — asks it.
`@` at a word's start in a composer opens a list at the caret: the
agents at work (this space's first), then the words that ask one
(`claude`, `codex`: with nothing typed, those at work and the one
Settings names), then what ⌘O would find, ranked as it ranks (not
threads). ↩ or ⇥ takes one — a block a pill, sent as its link; a word
the word — ↑↓ move, ⎋ keeps what's typed, and ⌫ just after a pill puts
back what was typed for it. `@claude` alone picks one: the project's agent if there's one, else a
new one in the thread's project, the thread its first prompt. Asked, an
agent is sent a short prompt typed into its terminal — the thread's
reference, the comment, and `mani thread read`/`reply` — at once if
idle, else when its turn ends (its hooks, §3.7). An agent that has
written in a thread **follows** it: your comments there ask it again.
Agents' comments never ask another agent unless they tag it, and a
thread asks agents at most a few times in a row without you (a loop
stopped, said in the thread). **Ask @agent to address these**, on any
set of threads — a diff's, a project's open ones, the timeline's
filter — hands it them all at once; that is how a review is handed
over. The agent skill teaches the rest: reply on the thread, not in the
terminal; resolve only what you did; a question is a reply left open,
and the work goes on; a place gone is read by what it was written
against; agents start threads of their own where they're unsure.

**`mani`.** `mani threads [--space|--project|--place ref] [--all]
[--json]` (each thread: its place now, the text it was written against,
moved or gone, its entries with their authors); `mani thread read`,
`new <place> <text>`, `reply [--resolve] <thread> [text]`, `resolve`,
`reopen`. Text omitted is read from the input. The app answers them, as
it does every command that reads the screen — it has every host's
threads, and what each is about — with the author the command's host
put on it.

**The graph's indexes** (§3.5). `Graph` indexes edges by their ends and
kind; threads need, besides, edges by *relation* and by *(block,
anchor)* (a place's threads, for the gutter), blocks by *kind*, each
block's *project* (kept as its path or place is set — the nearest root
of the few, by walking up its folders — and for the blocks under a root
when a project is made or unmade), and threads by last activity and
what's not seen, per space and per project. Over them, a few composable
steps rather than a query language — `blocks(kind:).in(project:)`,
`edges(to:anchor:relation:)`, `walk(from:over:relation:depth:)` (what
`reachable` is, generalized) — the same in the app and the host, so
the sidebar, `mani threads` and agents' following ask alike. Measured
before tuned: a synthetic graph of 100k blocks and 1M edges, a
project's timeline under a millisecond, a two-step walk under five, the
whole rebuilt in under a second; if not, interned ids and packed
adjacency.

As built: the graph's indexes (`Graph`: by relation, by place, by kind,
by project; `walk`), timed in a test; `BlockKind.thread` and its events
(`threadAbout`, `threadSpace`, `threadEntry`; the desk's `threadSeen`),
written by the host (`ThreadService`: newThread, threadEntry,
threadSeen, threadSpace proposals; mentions; a mani command's author by
the socket's peer process); `ThreadChatView` (the chat), cards in place
(`ThreadCardView`, a popover) from an editor's gutter or a diff's rows,
`ThreadTileView` (lens `thread`), `ThreadTimelineView` (lens `threads`
on the space, Show Threads; narrow, the sidebar's), the sidebar's Threads (`Organization.threads`: the list, `threadsTree`, or the timeline), `ThreadOverlayView` (⌥⌘M elsewhere; ⌘J to a
thread); the inbox's rule and the Dock's count; agents asked, followed,
delivered to when idle, stopped after three asks in a row, handed a set
(`ThreadAgents`); `mani threads`, `mani thread …` (`ManiThreads`), and
the agent guide's section. Places: a text's (an editor's selection or
caret, a past version's from the history strip, kept with its commit),
a diff's rows, a terminal's command, a PDF's page, a page (its words
selected kept as the quote), a tile, a space. Edits to a place are
written into its thread by the host (`PlaceWatch`): yours, typed; an
agent's, its tool's hook having named the file (`AgentEvent.wrote`);
else changed on disk — gathered for twenty seconds; its lines deleted,
once. Not yet: a page's quote found again when it's gone to, a region
of an image, and an agent's turn as a place of its own (a terminal's
command stands for it). ⌥⌘M was the Neighborhood Map's; it moved to
⇧⌥⌘M.

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
registry told, and every replica following. What's thrown away —
collected, or deleted — the registry remembers a while (`Discarded`,
in `Registry.gone`: its id, kind, title and path, how and when it went;
for 30 days by the newest's time, 5,000 at most), so a reference to it
can still say what it was: the pointer over a `manifold:` link whose
block isn't here — in a terminal (⌘'s links, a program's OSC 8), a note,
an editor's Markdown, a preview — shows a line beside it
(`ReferenceTip`, from `Hosts.whyMissing`): deleted or collected, and
when; on a host not attached, still being reached, or unreachable; or
no such block. Followed anyway, the same line by the pointer (at the
window's foot for a link from another app); `mani` says it as its
error. A block reached again
within the grace is simply kept, its mark forgotten.

Closing is what makes things unreachable. ⌘W takes a tile off its
space — when it was the last tile of a block nothing else reaches, a
toast says so; ⇧⌘W removes a space whole. **Deleting** (⌘D) is the
one way a block goes for good: its tiles taken off everywhere at once,
and when the toast's countdown runs out (Undo meanwhile puts them back;
nothing is asked first) its links both ways broken on every host
(`unlink`), and the host discarding it (`discard`: its session ended,
its log deleted, unregistered) — unless it was placed again meanwhile. What only
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
something — a text with unsaved edits, a note's words, a terminal with
a job running, which collection will end — a toast (not for a note
tied to nothing: no edge from it, none to it but where it was opened
from, which every made block has, and nothing unsaved; it goes at once,
⇧⌘T bringing it back while it's kept) at the foot of the
window names each of them and offers Undo, which reopens what was closed
and so reaches them all again. A toast that can be undone counts down:
its shading draws back from right to left over its time, held while
the pointer is on it; what waits on it (a deletion) is done when it runs out, when the
toast is put away, or when another takes its place.

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

A link is `Link{from, fromAnchor, to, toAnchor, kind, relation, at}` in
the `links` shard of the host the `from` block lives on — an anchor (a
place, §2.5) at either end, or none, and what it means. Kinds:

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
path) and a line on it. File ▸ New's items (⌥⌘ and the kind's letter, below the focused
tile; ⌥⇧⌘, in a new column — the same action, its `show` told once), the
New Block picker (⌘N, the kind's letter or name then what it takes,
placed by the one rule's keys, ⇧↩ a new column) and
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
title. ⌘P is its sibling over the focused tile's outline, ⌘P again (or
⇥) widening it to the space's. Each shows its reach at the field's end
(§3.5).

⌘P looks nothing over as it's typed: each space keeps an index of its
tiles' outlines (`OutlineIndex`), every row's text cut into trigrams,
each trigram's rows a sorted posting list. An outline tells it when its
items change, and only the rows between the unchanged head and tail go
out and come in (an edit costs what it changed); rows taken out are
marked, a list compacted once half of it is gone, the index numbered
again once half of its rows are. A query's word of three letters or more
is found on its trigrams' lists, intersected shortest first by
exponential search and confirmed with `memmem`; a shorter one in every
row, at memory speed; the word with the fewest rows leads and the others
are checked in what it found; a tile's name counts for each of its rows.
About a millisecond for a word in 48,000 headings, and a dozen to list
them all.

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
  theme, as now. What's code is one table (`CodeLanguage`: each
  language's extensions and whole names, its line comment, and whether
  it's code proper, data, a build file or markup read as source), and
  everything that treats a file as code asks it: code is set fixed-width
  and viewed on a page of code (`Lens.viewRendering`), parsed by its
  language's grammar (`SyntaxLanguage`, by the language), served by the
  language server for its extensions (`LanguageServerConfig.defaults`),
  listed under its language in a folder (`FileGroup`) with the code
  glyph, and commented out with its leader.
- Set fixed-width, a doc comment's words are in the theme's technical
  font beside it (proportional; Xcode's way), its leader, delimiters
  and the stars down a block's left kept in the code's face, so where a
  comment starts and what it's lined up with stay on the code's grid;
  other comments are code's, monospaced. A doc comment's fenced block
  (``` or ~~~, as Markdown's, to its close in the same comment: a
  diagram, a table, an example) stays monospaced, its columns lined up
  — `SyntaxTree.isDocCode`; a comment is a run of one-line comments
  (`///`, `//!`, Go's), or one over lines of its own (`/** */`), a fence
  left open closing with it.
- Code's structure is shown without colour (`TextView.Structure`, code
  set fixed-width with a grammar): each definition's name in the face's
  bold (its strokes thickened where it has none as wide, so the grid
  holds); plain comments, leaders and all, in the text's ink at 62%
  (doc comments keep theirs, in the technical face); a hairline
  between the definitions of the top two levels — a file's, and its
  types' members — where either of the two spans lines, above the
  second's doc comment and attributes, in the blank line before it if
  there's one, from its indent, not above the first among its siblings;
  a bar beside the definition the caret's in, if it spans lines; and
  the definitions the top of the view is inside of, three at most,
  pinned over it, each its first line as the text has it (and its
  number), while that line's out of view (`PinnedDefinitions`) — a
  click goes to it. The definitions are the declarations query's, found
  once per parse and moved by edits until the next (a pass over the
  tree: 27 ms in 10,000 lines), found again too a moment after typing
  stops. What a doc comment is is the
  language's, asked of its tree-sitter grammar's tree (`ManifoldSyntax`:
  a grammar per language, and a query of its doc comments): one written so (`///`, `/** */` — not `////`, `/**/` —
  Doxygen's `//!` and `/*!` in C and C++), one the grammar says is
  (Rust's), the run of comments on the lines just above a declaration,
  none blank between (Go's, Ruby's), or a docstring (Python's, Elixir's
  `@doc`). Strings, raw and multi-line ones, interpolations and
  characters are as the language has them. Queries' predicates —
  `#match?`, `#eq?`, `#any-of?`, and `#adjacent?` of our own, for a
  declaration's run — are evaluated here, tree-sitter leaving them to
  whoever asks. The tree is kept as the text changes: what changed is
  found by comparing the text with the one parsed (the same at the
  start and the end), the tree edited at once and parsed again from it
  in the background, only what the change touched — the lines whose
  syntax changed (a block comment opened above them) laid out again
  when it's in. A comment's leader and delimiters are told from its
  words by the language's marks (`//`, `#`, `/*` … `*/`, `--[[`). In
  the app: no language server (most don't say, or say late, and a font
  changes layout). A language with no grammar has nothing set apart.
  The tree is there for more than this, later. The face
  alone: the same text colour, no hue.
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
path. Markdown isn't Quick Look's (its page didn't scroll there, and
broke lines where the text does): it's the preview lens's page
(`MarkdownView`, the tile's placement, so links go as a preview's). A
README in the folder (`FolderReadme`: Markdown first, then plain text
in a code block) is shown under the files, as GitHub shows one, on the
same page: its bar collapses it (kept with the tile, the last choice
for a new one) and, dragged, sizes it; it's read again when the
listing says it changed, and stays out of a filter's way. Over them, the way up (an arrow, ⌘↑) and a filter: typed, it lists
the tree's files matching it, ranked as Open Quickly ranks (`FileFinder`),
the letters matched shown; "?" and words search the files' contents, in a
search block (§7.5) beside.

Or in columns, as the Finder's (`DirectoryColumnsMode`), drawn with the
tree's parts — its rows, symbols and bands, a column a list each, the
preview after the last — the mode kept with the tile, and the one chosen
last taken by a tile without one. A column's entries are in groups
(`FileGroup`, View ▸ Use Groups, on unless the tile says otherwise): the
Finder's by kind, but code by its language, from a table of extensions
and whole names (Makefile, LICENSE), else from what the system makes of
the type, and a name in capitals before its first dot (README,
LICENSE, AGENTS.md) a group of its own, after the folders, whatever its
extension; folders first with no header, then each group under one,
keeping the sort's order; the arrows step over the headers, and a click
on one leaves the choice as it was. There the field filters rather than
searches: each column keeps, in its own order, the files matching it and
the folders on the way to them (from the same ranking, every match, not
the best thousand), the selection moving to the first match in that order
if it's gone; folders not listed yet are taken from the tree meanwhile,
so the columns reach a match at once.

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

A project's folder (§2.6) shows its homepage round the files, in
columns at first (the homepage a toggle beside the views, kept with
the tile): a strip under the header (`ProjectStrip`: the branch, the
changes, the index — each a flat button) and a sidebar at the right
(`ProjectSidebar`: its changes and recent commits, from its scoped git
block, read on the listing's timer since that block isn't placed), the
README under the files as ever, as wide as the tile — the sidebar
stands above it, beside the files; the tree previews nothing beside it
there, the sidebar having the right. A folder that looks like a
project's root (a repository's, an indexer's marker) and isn't one
offers Make Project in its header; a folder below a project's root
offers the project (its name, ⤒), which takes the tile up to its root,
the homepage on (`DirectoryView.goToProject`). On the homepage the header's field
searches the project (`ProjectSearchView`, in the files' place): a
search block asked again a moment after each key (the text from two
letters), watched as it changes (`Hosts.watch`: a block not placed
isn't a tile's to be told of), its symbols, files and lines each under
a heading; Open in a Tile places that block beside and the next search
is a new one. The search lens shows a project search's symbols and
files above its hits, previewed as hits are.

### 7.5 Image, PDF, diff, git, search, process, agent

Each its kind's natural view: PDFKit and an image view (zoom, pages); a
PDF with Preview's controls (the page of how many, back and forward, the
zoom, the layout, find) and its sidebar, the table of contents and the
pages, as a Markdown text has its headings (a tile's own sidebar, at its
left, the bar's button showing it, kept with the tile); a
side-by-side and inline diff; git status, log and blame as lists that open
diffs and files — the row chosen shown in a pane under the list, as a mail
reader shows a message (each half's contents laid out as the divider
between them moves, not only with the tile). Its sections — the changes,
the history — fold by their headings, kept with the tile. A commit's
message is what's said about code, so it's set in the technical face,
the code's companion (as comments are), in the history's rows and over a
commit's diff: there rendered as Markdown, its subject line a paragraph
like any other, not set as a title, without the system's font
smoothing, as WebKit's `antialiased` draws (`ReadingTextView`;
`CommitHeaderView`, `MarkdownText`: native text, not the preview's page);
its chevron folds it to its subject, as every commit's then shows until
it's unfolded. How far the branch is ahead of its upstream, or behind
(↑ ↓ by the branch), follows a push or a fetch from anywhere — a
terminal, another app: the server watches what they move (the
upstream's ref, its reflog, `packed-refs`, `FETCH_HEAD`), not the index
alone, which neither touches. Another Mac's push to the remote reaches
no file here; it shows with the next fetch. Search results grouped by file with context, live while
running; a process list (sort, filter, select many, signal); an agent's transcript with
its tool calls folded.

The process lens has two modes. **Blocks** lists the trees under the
host's terminals and agents (`ps`, from their shells), each block on a
panel of its own, air between them: its summary card (§3.1) at the top,
what it's doing beside what runs, and its processes on it, set in under
the card's words. The cards are as full as lets every block and process
fit in the tile: three lines, two, one, or the title alone. The CPU and
Mem headers order the blocks by what all their processes take together,
the most first (clicked again, the least), each tree by the same, siblings
among siblings; Command puts them back as the host lists them; the order
is kept with the tile. **Machine** is the
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

*As built.* The choice is `WebState.viaHost`, and its host is the
block's own: a page made from a block on another host — a link in its
terminal or in one of its pages, New Web Page or the picker's `web`
with one of its tiles focused, `mani new web` in its shell — is made
on that host, loaded through it (a link from one of its pages loaded
from here, from here); one made here is here's, with no other way to
load. Through its host, a page is in a website data store of the
host's (`WebStores`: one a host, by its id, kept from launch to
launch), whose every connection goes to a SOCKS5 proxy on this Mac's
loopback (`HostProxy`, a host's, listening from when a page first
asks, and taking only the name and password it made, which only the
store is given). Each connection is a stream of the host's connection
whose first frame is `connect` (a name or an address, and a port): the
host looks the name up and connects there (`TCPConnect`), answers
connected or why not, then relays the bytes as a forwarded port's. A
page asking while the host is being reached waits for it, 30 seconds at
most; one that failed for the host being away loads again once it's
back. WebKit never asks a proxy for the machine's own addresses
(localhost, 127/8, ::1, this Mac's interfaces), so the host's own
localhost is a port forwarded here, the page's, not listed with those
asked for — the block keeping the address as the host has it
(`localhost:3000`, not the port here), and a page going to another of
its ports having it forwarded first — every localhost in such a page
the host's, so another host's `name:port` typed there is a page of
that host's own, beside. What a page only fetches from another port
of the host's localhost (a script's call to its API at :8000) WebKit
asks of this Mac's: only what's gone to is forwarded. WebKit says only
"bad URL" of a connection its proxy refused, so the proxy keeps the
host's reason a while for the page to say (the name unknown there,
refused, no way there). The bar's button before back says which way a
page on another host loads, and loads it the other way (Load Through
*host* in its menu): the page made again in a web view of the other
store. Clear Website Data for a host (its menu's) empties its store —
This Mac's, the default — once asked, and loads its pages again.

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

### 7.9 Outline

A note — any Markdown text — as an outline (the `outliner` lens, ⌥⌘↩
from its editor or preview, and back): Prism's, after Bike. The Markdown
is read into rows (`NoteOutlineMarkdown`, in ManifoldCore): list items and
what nests in them, headings, paragraphs, quotes, fenced code, rules, each
with the small facts of how it was written (its bullet, its spacing, the
blank lines before it), so that a note read and written back unedited
comes back byte for byte. The rows are what's edited (`NoteOutlineView`,
a text view whose paragraphs are the rows, each carrying its row as an
attribute): Return makes a row, Tab and ⇧Tab move rows in and out with
their children, ⌃⌘↑ ⌃⌘↓ move them among their siblings, ⌘↩ cycles a
checkbox (open, checked, none), Markdown typed at a row's start (`#`,
`>`, `[ ]`, `1.`) sets its kind, a bullet clicked folds its children (a
fold is how it shows, not what it says: the children are still written),
paste of Markdown comes in as rows and copy of rows goes out as Markdown;
undo is the outline's own. Escape leaves the text for the rows: a block of
them selected, drawn behind them, that ↑ ↓ move and ⇧ extends, and that
Space checks off, Delete deletes, Tab moves in, ← and → fold and unfold,
⌘C copies as Markdown; Escape or Return goes back to the text. A bullet
dragged (past a few points; a click still folds) carries its row and the
rows under it, a line showing where they'll go and how deep, from where
the pointer is across; ⌥⌘9 ⌥⌘0 fold and unfold every row (as Prism does,
a heading's section folds under it). Inline Markdown — emphasis, code,
strikethrough, links (`InlineMarkup`,
`InlineEditing`, Prism's) — is styled, its markup laid out as zero-width
glyphs, so the bytes stay the note's: the caret steps over markup it
can't see, Delete takes what's shown and not a hidden `*`, and a link
clicked opens where it points. Each change is written back as the Markdown
the rows say — only the bytes between what's unchanged at either end, one
edit to the block's log — and a change from anywhere else (its editor,
another Mac, `mani write`) is read in again, the caret kept on its row,
its folds and its focus on the rows they were on (`NoteOutlineFolds`: by
place and words). A note whose Markdown doesn't come back the same
(`roundTrips`: tabs for indents, mixed line endings) is shown, not edited,
a line over it saying so — its first edit would rewrite what it didn't
touch.

Its actions are Prism's (`OutlineNoteCommands`), on Edit ▸ Outline and
a row's own menu, the keys Manifold's where Prism's are taken: rows
duplicated, deleted and moved by the editor's line keys (⇧⌘D, ⇧⌘K,
⌃⌘↑ ⌃⌘↓), in and out by ⌃⌘→ ⌃⌘←; a task (`+ [ ]`, round, and `+ ` typed)
beside a checklist item, Toggle Done, Move Done to Bottom (⌃⇧⌘D); Bullet
(⇧⌘8), Horizontal Line (⌥⌘-, or `---` typed), Code Block (⇧⌥⌘C: the rows
one block, or a block rows again), Turn Into; Select Row Text (⇧⌘L),
Select Branch (⇧⌘B), Expand and Contract Selection (⌃⌥⌘↑ ⌃⌥⌘↓: word,
sentence, text, row, branch, the branch it's in, every row); Format's
bold, italic, strikethrough, code, highlight (⇧⌘H) and Link… (⌥⌘K), and
an address pasted over words making them its link. **Focus** (⌃⌥⌘→, or
⌥-click a bullet; ⌃⌥⌘← out a step; Unfocus) shows a row and what's under
it as if it were the note, the rest set aside (`NoteOutlineFocus`) and
written round it, the path to it over the rows, each step a way back.
**Pictures** are drawn, Prism's way (`OutlineNotePictures`): a picture's
`![…](…)` hidden whole, one thing to the caret and to Delete, the picture
under its line's words — in place of them on a line with nothing else —
at its own size (no taller than 420 points, given none) or the size noted
after it (`<!-- {"width":320} -->`, as Prism's editor writes one), never
wider than its column. Where from: an image block (`manifold:…`, this
Mac's file read, another host's fetched), a file beside the note's own
(or a path), a picture on the web — fetched once, kept for the session,
the outlines told when it comes; one that isn't there or isn't a picture
stays its Markdown, greyed. Under the pointer a picture shows a grip in
its corner: dragged, the picture made larger or smaller in its own shape
(60 points to its column), the width written after its Markdown when it's
let go, one edit to undo; twice clicked, that taken away. The size is the
note's, not this Mac's (Prism keeps it per Mac), so the Markdown view
draws it so too. A picture selected is ringed; a picture pasted (a
screenshot copied, Copy Image) is kept as an image block, as one dropped
is, and goes in the caret's row if it's empty, else a row after it.
The lens is Prism's too: a fold told by a pill of three dots after the
row's words (clicked, unfolded), not on its bullet; a hollow ghost of a
bullet before the row under the pointer that has none — a heading's
clicked folds its section; a bullet with checkboxes under it ringed with
how many are done; a code block's language in its corner. A bullet with
nothing under it clicked selects its row. Return on a code block's
closing fence, or on the empty line before it, leaves the block. Where it
still differs: Return on an empty item deeper in brings it out a level
(Prism makes another), pictures aren't dragged by themselves, and there's no
`[[` completion — a note links to blocks by dropping them.

A note's outline — what its tile shows as ticks and in its sidebar, and
⌘P finds — is the same in every lens (`NoteOutlineMarkdown.items`): its
headings, and its top-level items each under the heading before it, with
the line each starts on; the editor goes there by line, the preview by
the element its line starts.

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
attachment last focused it (`own`) — focused *there*, by its user: a
focus that comes in from the host (another machine moving the space's
focus, which both show) or a launch's takes nothing, and a focus moved
here takes the space's pen before the move is appended — tells the one that held it it is
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
too. Only Take Over takes back: every shard of that host it may lead —
not only those taken from it, or what the other machine wrote to while
it led stayed its own, and the first write here to one was refused, as
if it had taken over again — whose holders are fenced and asked in
turn. Watching lasts through reconnections and whoever holds the pens
now — the other client gone, a server restarted — and ends with the app
(a launch takes nothing, and watches nothing). A connection is an attachment, but the app's `hello` names its
launch (`instance`): a link made again — its old connection maybe not yet
seen to close — keeps the pens the old one held, so a client is never
fenced by its own ghost. Terminals aren't fenced: what's typed goes to
the shell from any client.

Who the host is attached to is the host's to say, and it keeps it: the
launch that last took it (by a focus there, or Take Over) and an
**epoch**, counted up each time it changes hands, in `attached.json`
beside its logs — so it outlasts a server restarted. Every app is told
(`attachment`: the epoch, by whom, whether it's this launch, whether
that one is connected) on its welcome and whenever it changes, and says
the epoch it last knew on each reconnection (`hello`). One behind — a
Mac asleep, or its link down, while another took over, so the `fenced`
it should have had never came — is watching from its welcome: its
focus takes nothing, and what it appends is refused, whoever holds the
shard or no one (its holder's connection gone, which took its pens with
it — the gap a Mac woken used to take the host back through). Only Take
Over (`takeOver`) moves the epoch for it. A text not read in yet is
anyone's to put in. A fresh launch knows the epoch it's welcomed with,
so its first focus takes, as before. The host's news sounds only where
it's attached — the knocks, and a terminal's bell, which every Mac with
the terminal open hears — or, the Mac it's attached to not connected,
on every one, so nothing goes unheard. That is apex §4 cut down to the
events that matter; leases are not needed.

Who **acts** for a host is one answer, fenced as the pens are, and
everything that asks takes it: a `mani` command (all but `env`, which
the host answers), what the host asks a leader to write (a file's text
read in), and whose Mac sounds and notifies. It's the launch the host is
attached to, while that's connected; else the latest-connected app not
behind the epoch (a launch since, which knows it); else none — every app
connected is watching — and `mani` says so ("Manifold on … has this host
and isn't connected; Take Over in the Manifold you're at"), the sounds
going to every Mac rather than to none. Every app is told who acts
(`attachment`'s `acts`, `actor`) when it changes: an app come or gone, a
take-over. Whether a link is gone isn't guessed from quiet: an app that
pings (over a link, every two seconds) and from which nothing at all has
been read for 15 s, with nothing being written to it either, is closed
by the host, and so stops acting; one that closes with commands it
hadn't answered has each asker told ("Manifold (on …) went away before
it answered"), so `mani` never waits for good on a Mac that's gone.

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
Connect{host, port}                  a page's connection, made by the host (§7.6)
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

What's kept, and for how long (`retain`, hourly): a text's log as long as
Settings says (all of it, by default); a git block's or a process
block's, folded into its state (each refresh replaces the last); a
space's, a month, then folded — what was placed and moved; the registry,
the links and the desk, folded into their state as they go, as nothing
reads their history back — which kept every block's name and path, every
link's context and every time a block was seen, a discarded block's too,
and grew by megabytes a day; the state remembers what was discarded for a
while (`goneDays`) and no more. A block discarded (deleted, or collected)
takes its log and snapshot with it, its links here, a note's picture
Manifold kept, and a terminal's scrollback. Logs set aside by a change of
the data format (`logs.before-format-…`) are removed two weeks on.

A session is deleted for good (issue #1) by its server, asked by an app
(`erase`) or by `manifoldd erase` on the host: every app told (`erased`),
its shells and language servers and indexers ended, then every file in
its data folder removed but the app's list of other hosts (`hosts.json`,
on a Mac), and the server installed there (`~/.manifold/bin`) — the
default session's, not one under `MANIFOLD_DIR` — and the server gone,
nothing saved on the way out. Files of the user's own aren't the
session's. Each Mac keeps the ids of sessions deleted (`hosts.json`'s
`deleted`) and takes off what every host it reaches links to or places
of them, as it reaches it — so nothing points for good at what can't be
reached. Told, an app forgets another host's session; This Mac's, it
clears what it kept of it (its window's state, pages' history and icons
and website data, its logs) and starts again, a new session. One that
finds another session where one it knew was (deleted while it was away,
a new one started there by its bridge) notes the old one deleted.

---

A file's version-control history (`fileHistory`) is the host's to read:
the commits that changed it (`git log --follow`, `sl log --follow`, a
page of 200 at a time, each with the file's name then), the file as one
left it, and blame as of one (`git blame --porcelain`, `sl annotate
-Tjson -c -u -d`) — always of a commit; blame now is the last commit's,
carried onto the text as it is in the editor by a line diff
(`FileHistory.carry`), what differs not committed: the same for git and
Sapling, edits not saved included, and kept in step with each edit
until the file changes on disk. An editor shows a commit's text in
place, read-only (a `StaticDocument` it holds — the text view holds its
document weakly), the line at the top carried through the difference.

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
  parsing; status, log, `show`/`cat`), a repository watched whenever a
  git block refreshes (its index, and for git its upstream's refs),
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
  graph form, walked by re-centering (⇧⌥⌘M).
- The surface (§3.1, milestones 14–18): `ArrangementState` as acme's
  tiling — columns of tiles with `heights`, a new tile taking the lower
  half of the column's biggest (`bringing(_:lens:inColumn:below:)`),
  `growing(_:step:whole:)` for colgrow, a removed tile's height to its
  neighbor; `docked`, tiles out of the grid and where each was
  (`docking`, `revealing` — what going to a tile does, a docked one
  back where it was — and `replacing`, a tile over another, that one
  docked under it); `full` a tile maximized over the space;
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
  tile short of room, Open Quickly's rows, Overview.
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

### 8.6 A host's environment

A host's server starts its shells and tools with its own environment —
which, on a host reached over ssh, is the connection's that first
started it (its bridge's): its SSH_AUTH_SOCK dies with that connection,
and a proxy the host needs is set nowhere. So the server keeps:

- **Variables**, in the host's preferences (the desk, so every Mac sees
  and sets the same): a name, a value and a scope — `all`, `shells`
  (terminals, notebooks, panels' commands) or `tools` (what the server
  runs itself: indexers and their `npx` fetches, language servers, git,
  Sapling, search). `SpawnEnvironment` holds them, refreshed when the
  desk changes, and applies them as each child starts
  (`shellAndEnvironment`, the panel's, the indexer's, and every
  `Child` through `Child.environment`), not by `setenv` in a server whose
  other threads read its environment. Set by the `environment`
  proposal (one variable, set or unset), by `mani env`, which the server
  answers itself (attached or not, unlike other `mani` commands), and in
  the host's inspector, edited in place (`InspectorEditable`: the name in
  the label column, the value, the scope a menu with Remove; Add
  Variable… a new row to type in; the rows not rebuilt under one being
  edited, and a row given focus only while the app is active — the panel
  doesn't activate it, and would take another app's typing). Preferences from a client before them leave
  them as they are (nil, not empty).
- **The agent link**: a symlink, `agent.sock` in Manifold's folder (or the
  home, if that path is too long to name a socket or has spaces),
  given as SSH_AUTH_SOCK to everything — ssh follows a symlink, and the
  limit on a socket's path is the link's, not its target's. It points at
  the newest agent that answers, of: those bridges note as they start
  (a file each in `agents/`, the bridge's pid in it, taken away as it
  ends), sshd's for the user's logins (`/tmp/ssh-*/agent.*`, theirs), and
  those `mani env agent` names. `AgentLinkKeeper` looks every 5 s, and a
  bridge as it starts and ends; a link's target replaced by a rename,
  so a shell never sees none. Pointed at a gone agent it's left so
  until another comes. The status (where, from, live, keys by
  `ssh-add -l`) is said to clients on hello and as it changes
  (`agentLink`). A server not started by a bridge (`MANIFOLD_BRIDGED`
  unset) whose own agent answers — a Mac's launchd one — keeps that.

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

A terminal attached from two views at once (two Macs, two tiles) has one
size, a pty's: the view's that last attached or was typed into
(`Session.sizedFor`). Another's resizes are kept and applied when it's
typed into — not as they come, which flipped the pty between two widths,
each view drawing what was laid out for the other's (lines broken short,
a column of letters down an edge). What a view in the back sends by
itself (its focus going, a query answered: an escape sequence) doesn't
count as typing.

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
  before it's behind, and skips to the screen as it is — and whether
  the shell is at its prompt or in a command's output, which a resize
  goes by (the prompt is cleared, for the shell to draw again). To and from
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
  still hears the other's answer. A page loaded through a host (§7.6)
  goes the same way, a stream each of its connections, which the host
  makes where the page asked, each on a thread of its own — a name can
  take seconds to find, an address longer to answer — trying the
  resolver's addresses in its order, ten seconds each at most, and
  giving up as soon as the page goes. A Linux host's server, built
  static, looks names up as musl does: `/etc/hosts`, then the servers
  `resolv.conf` names (a VPN's, or systemd-resolved's stub), not NSS's
  other sources (mDNS, sssd). A host's forwards take 512 connections
  at once at most, past which one is refused: a host whose localhost
  is this Mac's (this Mac attached as another) would otherwise have a
  forward onto the same port here connect to itself without end, until
  the Mac had no ports left.

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
with Reduce motion on (Accessibility ▸ Display) nothing travels, grows
or shrinks — it fades, or is there at once — and fades stay, as the
system's do;
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

### Themes

Every colour Manifold draws its own things in is a theme's
(`Palette`, Palette.swift): each role a **Shade**, one colour in the
light and one in the dark — the chrome's grounds, washes and edges, the
texts' greys, the status colours, each tint's accent, caret and text
selection (the System tint stays the system's), code (its page, the
caret's line, matches, uses, Highlight Uses' pins, the gutter's change
marks, diagnostics, `==highlight==`), diffs, what search found (a PDF's
matches too), a machine's charts, the colours that tell kinds apart (a
file's type, a link's), a terminal's palette in each appearance (its
paper, text, caret, selection and all 256 colours: the sixteen, then the
extended palette's 6×6×6 cube and 24 greys — xterm's, in Paper, as
Ghostty's own were), and the preview's page. One is in use (`Palette.current`), and what draws asks it as it
draws: the named colours (`Theme.text`, `Status.failed`,
`TextView.addedColor`…) are each one object (`NSColor.themed`) whose
colour is the current theme's in the appearance it's drawn in, so a
theme set (`Palette.apply`) recolours everything as switching light and
dark does — drawn again, what layers hold set again by their theme hooks
— and the terminals are configured again: Ghostty's colours are written
from the theme (`TerminalPalette.config`, every one of the 256 given, none
left to Ghostty's defaults), and a command's output and a notebook's
cells are drawn in the same. The preview's page takes the
theme's as CSS variables (`--page-text`, `--page-link`…, light and
under `prefers-color-scheme: dark`), set again in an open page when the
theme changes. The theme is a setting (`Appearance.colorTheme`, by id,
Paper for one there isn't), set from Settings ▸ Appearance ▸ Theme
(`ColorThemePicker`: each a small window drawn in its colours as the
appearance has them — a sidebar with a row chosen in the accent and
blocks' states, an editor's tile with its gutter, the caret's line lit,
the caret, changes marked and a link's colour, and a terminal's tile,
focused, a test run in its palette with a word selected and its cursor
— its name under it). A theme has its own accent
(`Palette.accent`), which the **Theme** tint — the default — is: with it
a terminal's caret and selection are its palette's own; any other tint
is set over the theme's everywhere, Ghostty's caret and selection
written after the palette's, each tint in the theme's own shade of it
(`Palette.tints`). An extended palette may be made rather than given
(`TerminalPalette.generated`, as Ghostty's `palette-generate`): the
cube's eight corners the background, the sixteen's red to cyan and the
text, each step between taken in CIELAB, the greys from the background
to the text — from the background whatever it is (Ghostty's
"harmonious"), or turned round for a light one to go dark to light.

**Paper** is Manifold's look as it was before there were themes, to the
value: debug `colordump <path>` writes every named colour in both
appearances, the terminal's config and the 256 colours Ghostty makes of
it, compared with the build before. **Newsprint** is ink on newsprint:
paper #F2F2F0 and ink #333331, muted inks (brick red #B3402E, sage,
ochre, slate blue, plum, teal), a red caret on a grey selection
(#DDDDD6), its extended palette made from its own; by night paper
#1F1F1D and ink #D6D6D0, the inks lifted to read on it (each of the six
4.5:1 on the paper), warm greys throughout (a step less blue).
**Classic** is apex's Classic palette (~/src/apex,
`crates/apex-client/src/theme.rs`): paper #FCFCF2, ink #202224,
secondary #6E7072, the tags' pale blue (#EAF4F7, the sidebar #E8EFF1)
for panels and sheets, acme's yellow selection #F1E9A6, Go blue #007D9C
the accent and caret; by night go.dev's #202224 paper, #E6E6E6 ink, link
blue #50B7E0, selection #4A4526. Its colour-blind pairs as apex's: B3's
blue #2A5DB0 for added, done and passed, B2's burnt orange #C85A00 for
removed and warnings, the fenced fuchsia #CE3262 for errors and what
failed; the terminal's sixteen GitHub's colour-blind ones (xterm's cube
past them). Two of apex's are a step darker here, to read as text on a
panel at 4.5:1: the faint grey (#737577 for #8A8C8E) and stale's ochre
(#8F6B00 for #C79A00). **Financial Times** is
github.com/mariusae/financial-times-theme's, from FT Origami's palette:
paper #FFF1E5 and body ink #33302E, wheat #F2DFCE selected, teal #0D7680
the accent and links, an ink caret (as its Ghostty theme's); jade,
mandarin and crimson for what passed, wants attention and failed; FT's
warm greys (black-5 to black-30) for the chrome. By night its inverse:
slate #262A33, ink #E9EAEB (white for strong), black-70 #4D4845
selected, teal-80 #14BDCC, the inks lifted (#66CC99, #FF8833,
#FF6666). The terminal's sixteen are the theme's own Ghostty palette
(Origami's colours eased to 5.5:1 on the paper), the rest made from
them. FT's muted grey #807973 reads at 3.9:1, so secondary text is
black-60 #66605C; jade and mandarin are deepened where read as text
(#007A3D, #A35214). The backdrop is a theme's too, so the window is of
a piece: its wash's four stops and how its pools are lit, in each
appearance (`Palette.Backdrop`) — Paper's lavender, rose, peach and
cream (by night indigo, plum, umber, near-black), Newsprint's off-whites
a shade warmer or cooler than its paper with a faint blush of its red
(by night its paper unlit), Classic's acme pale blue into its cream and
yellow (by night go.dev's slate into acme's dark yellow), Financial
Times' FT pink into its paper and wheat (by night slate with a claret
dusk) — still turned
by the day, lit by the hour, its first pool the tint's; the Settings
picker draws each card on its wash. What isn't a theme's: a language's colour in
a project's bar (the code hosts'); masks and shadows (black or white at
an alpha); the page's neutral greys, which read on either ground.

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
  not, emptied or not, until it's removed (⇧⌘W, its row's menu) or
  dropped on another. One rule for what lasts. Pin in Space is how a
  block stays without a tile.
- **Closing can lose a block.** ⌘W on the last tile showing a block lets
  it go after half an hour, where macOS's closing never deletes. It's
  said, not silent: a toast with Undo, ⇧⌘T, Recently Closed, and
  Open Quickly's *recent* rows.
- **Size is presentation, not state.** A tile shrinks along one ladder —
  content, summary card, bar — by the room it has; there is no collapsed
  state to get stuck in, and every step comes back by resizing. Out of
  the way is docking (⌘M), one state, listed in the sidebar and a ⌃⇥
  away. Shrink to Summary (⇧⌘M) only sets a height.
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
- **⌘P is the outline, not Print.** Scoped to the focused tile, ⌘P again
  (or ⇥) widens it to the space; ⇧⌘P filters the tile's own outline and doesn't forget
  its filter, and pressed again leaves it. Print stays in the File menu,
  keyless: rare in a tiling tool.
- **⌘M is Dock,** the app's own minimize; ⇧⌘M, Shrink to Summary, is
  the step above it. Minimize stays in the Window menu, keyless.
- **⌥⌘M is Comment** (§3.12), taking macOS's Minimize All; ⇧⌥⌘M the
  neighborhood map.
- **⌘D deletes a block,** where the Finder duplicates: deleting is
  common, and its toast undoes it. Add Next Occurrence, Sublime's ⌘D,
  is Xcode's ⌥⌘E.
- **⇧⌘W removes a space,** as the Mac closes a window: Manifold's
  windows are its spaces; ⌘W on Settings closes it.
- **⇧⌘S saves and closes** an editor (vim's `:wq`, an `$EDITOR`'s done):
  save, and the bigger thing; there's no Save As.
- **⌃⌘T pins,** the Finder's Add to Sidebar: a pin keeps a block in its
  space's part of the sidebar, with a tile or without.
- **⌘` walks spaces,** the app's windows; with one space it walks
  windows.
- **⌃⇥ walks the space's tiles,** docked ones too, as a browser's tabs,
  in every view, a terminal's too; a quick release switches without
  showing cards, as ⌘⇥ does.
- **⌥⇥ walks the trail's tiles,** across spaces, as ⌘` walks its
  spaces: free on the Mac, and taken from a terminal as ⌃⇥ is (Meta-Tab,
  with Option as Meta). ⌃\` was the other choice, but a terminal's ⌃\` is
  NUL (Emacs's set-mark), and ⌥\` is the grave accent's dead key.
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
- **A docked tile's row** clicked puts it back where it was.
- **The map** is a graph browser: a click re-centres, double-click or ↩
  goes.
- **Reset Graph is only on the host's own row,** not in every menu as
  Reset Server is: it can't be undone, and the friction is the point.

### Look

- **Open Quickly's field is 22 points,** the one big field.
- **Colours that say something keep their own:** the diff's, a find
  match's, the terminal's palette, the code page's (go.dev's), a remote
  host's chip in the accent, the summary card's fill lifted above the
  panel in the dark.
- **Motion that isn't a transition** keeps its own time: the status
  spinner's 2 s loop, the backdrop's 0.6 s wash, the scroller's fade
  after a second (as the system's), predicted echo's glow.
- **What moves, moves where it goes, and says so:** a space comes in
  as the strip has it (from the right for one further along, from the
  left for one before), the sidebar's list sliding with it; a tile placed comes
  in where it lands, seen at once and growing from 86% about its
  middle, one closed goes in a puff — swelling a little as it fades,
  a small cloud bursting where it was and drifting apart, as the Dock's
  poof (only fading, with less motion); one moved to another space
  shrinks to 86% and fades where it was, or goes into its space's
  square in the strip, dropped there; one docked goes into its row in
  the sidebar (the window's left edge, where the sidebar slides out
  from, if it's put away), and back out of it undocked — each as the
  Dock's genie (`Genie`): the tile's picture in strips a few points
  wide across the way it goes, the funnel first bending into its near
  end, then the strips pouring down it into the row's right end, the
  nearest first, each as tall as the funnel where it is (about half a
  second); the row's slot opens as it pours, the rows round it gliding
  to make room (`OrganizationView.glide`), and what the row says is
  wiped in from the right as the tile gets there — undocked, wiped out,
  then the row glides back among those on screen as the tile pours out;
  a tile down to its bar (⌥-clicked's others) has only its bar to pour,
  so the bar flies to its row as wide as it is, then shrinks to the
  row's size, becoming the row on the way (`Genie.fly`), and back out
  the same way. Where it lands is marked: the tile takes on the accent
  as it goes, and its row a band of it, coming up as the tile arrives;
  what the row says is built up from the left in step with how much of
  the tile has crossed into the sidebar (the genie says, at each step,
  `Genie.Arrival`), and taken away the same way as it pours out — and the
  tiles beside either have their edges slide (on the travel curve, most
  of the way in the first third of 0.24 s, the focus ring with them);
  one moved (keys, or dragged and dropped) is a card picked up and put
  down, going over the rest from its place and size to its new ones as
  theirs slide aside; one maximized slides its edges out from its place
  over the rest, and back in, restored. Whatever a tile does, it's one
  card: what it shows is sized once, where it ends, and held at its top
  left as its edges pass, cut off or uncovered on its own ground, never
  stretched, not jumping to its size and sliding; its bar's glass goes
  with its edges, the buttons riding the right one; what goes with it
  (a terminal's dots and scroll bar, its ticks, its links' badge, its
  shadow) is carried along, not ahead of it. One arrived at has
  its focus ring swell (the one ring), one summarized crosses over to its card; a tile becoming its
  card (⌃⇥, Overview) is one shape going from the one's place and size
  to the other's, what it shows scaled to its width from its top (cut,
  never stretched) and changing on the way — shrinking to some 60% of
  that, for a card about as wide as its tile (⌃⇥'s, ⌥⇥'s), so the tile
  is seen to shrink into it rather than only be cut off from below, and a
  docked tile's card comes out of its row in the sidebar and goes back
  into it — nothing just fades in; the
  next ⌃⇥ puts away whatever's still on its way. Layout is done once, where things end, and only layers travel —
  a terminal resized once, not at every step. Focus, typing, a divider
  dragged and the palettes don't move at all.
- **Printing is black on white;** a system alert's accessory takes the
  system's label colours; content — editor, terminal, diff, notebook —
  takes the font themes, not the chrome's UIType.
