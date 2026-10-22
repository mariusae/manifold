# Manifold

A Mac app that is a desk rather than a set of windows. Terminals (drawn by
[libghostty](https://github.com/ghostty-org/ghostty)), files, notes,
folders and web pages are **blocks**; you arrange blocks to work, and an
workspace is itself a block you can name and come back to. Nothing is
closed: what isn't in use is tidied out of the way, and anything can be
found and recalled, with its history. Light or dark, in SF Pro and Menlo
as Notes sets them, or in [Monaspace](https://monaspace.githubnext.com)
and Mona Sans (bundled).
[DESIGN.md](DESIGN.md) says where it's going.

## Using it

- The **sidebar** is the spine of the window: the window buttons, New
  (+) and ⋯ along its top, then one browser over everything you have,
  organized four ways (Desk · Files · Links · Time, below), with a
  filter. It sits beside the content; ⌃⌘S (or the button at its top
  right) makes it slide out over the content when the mouse goes to the
  window's left edge instead. Drag its right edge to resize it, and its
  top to move the window. Along the bottom of the sidebar run **Search**
  (⌥⌘4: pushed over the tree as Kept is, a field under its name, and
  the words found in the contents of every block — a text's lines, a
  terminal's commands, a block's name, place or address — each block
  with what matched beneath it, clicked to go there: the line in its
  editor or page, the command in its terminal), a switch between by-workspace
  and by-file, the inbox, and, at the right, counts of what needs you,
  is working and is done and not yet read, which open the Inbox. The window sits on a wash of soft colour — a few
  pools of pastel light, deep tints in the dark — placed afresh each
  day, with what's behind the window blurred beneath it, and lit by the
  hour: the sun's height where your time zone's city is gives its
  light's colour temperature, so the wash is a touch warmer while the
  sun is low, morning and evening, a touch cooler when it's high, and a
  dim cool blue at night, looked at again every five minutes and eased
  into over a few seconds. The tree is one shape, always: a host's
  heading, then each of its workspaces, then every tile in it, in
  order. Nothing folds by itself; the current workspace wears a bar at
  its left edge, and a workspace's chevron closes it until you open it
  again (remembered). Only tiles have icons; a workspace's label is its
  name and a count of its tiles, a block's row has a second line for
  what it says. Above the bar at the foot sit two quiet rows, **Kept**
  and **Recently Closed**, each with a count; clicking one pushes that
  list over the tree, the header showing a back button, the list's
  name and what it holds, as Safari's Bookmarks does; neither is in
  the tree itself. Under **Workspaces**, the sidebar is
  the table of contents of the screen:
  click a tile to focus it, a workspace to go to it, double-click
  one to name it; drag a block from anywhere in the sidebar onto a tile
  to bring it in beside, onto a workspace for its active column, or
  between workspaces for one of its own, and drag workspaces to
  reorder them (among their host's, under its row) and hosts' rows to
  reorder the hosts (an order of this Mac's own, in Desk and Files).
- An **workspace** is a grid (DESIGN.md §3.1): columns of tiles,
  every tile a block, all of them visible, as acme tiles its windows.
  A workspace is what you made it: a block brought in stays until
  you take it off (⌘W), and nothing is tidied away. A new tile lands
  below the biggest tile of the active column, taking its lower half;
  Workspace ▸ Grow Tile (⌃⌘=) takes a step from its neighbors; Fill
  the Column (⌃⇧⌘=) gives it the whole column and **stashes** the
  others. A stash is a stack behind any tile: the sheets behind it peek
  out above its card, as a stack of paper. **Right-click the tile's
  title** (or press ⌘E) and the stack's tiles hang over it as cards,
  live, the tile's own bar put away, on the window's own background
  (a stack too short to hold them, down to its bar say, first grows —
  more than a tile gone to does: 320 points, or half the column): each
  as wide as the column, the tile at its own size, a title bar lower than the
  one behind it, all leaning back a little alike, and the one chosen
  peeking out between the rest, those in front of it let down part of
  the way. Right-clicked, the card under the pointer is
  the one chosen (scrolling works too): clicked, it comes back on its
  own as that tile's lower half, the rest staying behind the tile that
  showed; ⌥-clicked, it takes the top instead, whole, the tile that
  showed going behind it with the rest of the stack; ⎋ or a click away
  from the cards leaves things be (with no stack, the right-click is
  the tile's menu). With ⌘E, each E moves the choice a card down (⇧⌘E
  back up), and letting go of ⌘ brings the chosen one forward to the
  top (Escape leaves things be); without a stack, ⌘E finds the word at
  hand. ⌥-click the top tile's own pill and it swaps with the next
  behind it; keep ⌥ held and click again, as ⌃⇥ walks workspaces, and
  the next behind that comes up, round the stack, the tiles passed
  staying where they were — letting go of ⌥ settles on the one come to
  (⌥-clicking a pill peeking out above the stack goes straight to it). A stack is one
  thing: drop its top tile's pill on another's and the whole stack goes
  behind that tile; move the top tile and the stack moves with it.
  Unstack in the pill's menu lays the whole stack out in the column;
  Close Stack takes the tile and its stack off the workspace (from a
  maximized tile, Close Column takes the column).
  Opening a block that isn't in the workspace always makes it a tile of
  its own (below the biggest tile, after that tile's stack, never into
  it); going to one that is — a link, the sidebar, the finder, ⌘J,
  ⌘\, Back, a found line, opening it again — goes there: a tile on its
  own is focused, one in a stack comes to the top of it (the rest
  behind it, as they were), and the pointer follows. Going to a tile
  squeezed down to its bar — by a link, the sidebar, the finder, ⌘J,
  Back, or opening what's already there (Browse This Folder on a
  folder shown) — grows it a little, to show some of what's in it (160
  points, or a quarter of the column), taken from its neighbours as
  growing takes it, and the pointer goes to it, as apex does. **⌥ with any
  click that opens something** puts what opens over the tile clicked
  in, that tile going behind it (as ⌥-drag stacks): a link or a
  block's pill in a note, a badge's link, a sidebar row, a listing's
  file or folder, a scrubber's command, ⌘⌥-click on a terminal's link,
  ⌥⇧⌘-click on a page's. Drop a pill on
  another's to stash it there; ⌥-drag it instead and it goes on top,
  the target (and whatever was behind it) stashed behind — the outline
  while you drag is the target tile's shape, to say so; ⇧-drag a pill
  and it's not the tile you
  carry but its path (a terminal's folder, a page's address): dropped on
  a terminal it's typed there, quoted for the shell; on an editor,
  inserted where the pointer is; on another app, as a file or text.
  It carries the block too, linking it to where it lands (below);
  ⌥⇧-drag for the link alone: the tile it's dropped on (a terminal, a
  note) is linked to it, nothing typed or put in.
  Stash Tile (⌘M, or Stash in a pill's menu) puts the
  focused tile behind its nearest tile — the one above it, else the
  column's first — and focuses that one. Dragging the line between two tiles past one's least
  height stashes it, in the direction it was pushed (pushed up, behind
  the tile above it; pushed down, behind the tile below it), and goes
  on against the next, until all above or below are put away. Maximize Tile (⇧⌘↩, or the ⤢ at the right of a
  pill) puts a tile over the whole workspace until it is restored, or
  until you go to another tile. A pill is as wide as its title needs
  and never more than half its tile, so what's under the band stays
  reachable at the sides; the focused tile's is plain, the others'
  quieter. The focused tile's pill fades out while what's under it is
  in use — the text cursor on its line in an editor or a terminal, a
  page's address or the process list's filter taking the keyboard — and
  comes back when that's done, or when the pointer rests where it would
  be; the other tiles' pills stay, whatever is under them. A pill can
  also **become a field**: a web page has no address bar of its own —
  click the address in its pill (or ⌘L) and it becomes one, there, the
  title left as it is and the address selected to type over, or words
  to search for (the rest of the bar grows the tile, as any bar does); ⏎ goes, ⎋ leaves it. ⌘[ and ⌘]
  go back and forward, ⌘R reloads. The pill's menu (its icon) carries
  the view's own verbs first: a page's Back, Forward, Reload and Copy
  Address; the process list's Refresh Now and Filter.
  The focused tile has a ring around it. **⌘Z undoes** the workspace's
  last change at your hand (a tile placed, taken off, moved, stashed,
  resized, maximized), ⇧⌘Z redoes, a hundred deep per workspace, when
  nothing else takes the key (an editor undoes its own text). Undo
  doesn't rewind the log, which only grows: it appends the earlier state
  as one entry, so the history keeps what was undone. In the sidebar,
  ⇧-click (or ⌥-click) a chevron to open or close the whole subtree. Every lens shows its scroll
  bar; a terminal's comes from Ghostty's own account of the screen and
  its history. Going somewhere (⌘O, ⌘\, a found line) brings the pointer
  along, to the text cursor or the middle of the tile. Overview (⌘') shows every block in the
  workspace at once, Mission Control fashion; ⎋ comes back. Drag the
  lines between tiles and columns to
  resize them. Each tile is a **card** with a bar across its top:
  its symbol and name, where it is in grey, its links, the program its
  status names in a grey capsule, its status
  glyph, and maximize and close (×) at the right. The bar is always there; as
  a tile narrows it gives things up in order — the place, then the
  links' pill shrunk to its arrow and symbol, then the program, then
  the pill to its arrow alone, then maximize, then the pill — so the
  symbol and some of the name always show. The content runs beneath it, rounded,
  with room between cards and the window's wash showing through. Drag
  the bar to move the tile; click it to grow the tile a step (the
  pointer follows the bar, so a click again grows again), ⌘-click
  to fill the column, the corner to maximize; click its symbol for the
  tile's menu; ⇧-click it for where the block is, folder by folder up
  to the root (a terminal's working directory likewise), each browsing
  that folder here, as ⌘-clicking a document's title does in the
  Finder. ⌥⌘[ and ⌥⌘] move the focus between tiles.
- Two verbs put a block in front of you. **Go to** finds it where it
  already is: the workspace it is in (this one if it is here, else
  the one most recently gone to) is selected and the tile focused.
  **Bring here** makes a tile of it in this workspace; if it is here
  already, that tile is focused. A row clicked in the sidebar, or
  chosen in the finder (⌘O), goes to the block if it is placed anywhere,
  else brings it here; ⌘-click, Bring Here in the menu, and a drag onto
  the grid always bring (a drop between two tiles lands there). Opening
  something from inside a block — ⌘-click a path in a terminal, follow
  a link, a search hit, a change in a git block, a definition — brings
  it below the opener, taking its lower half, and links the two; a
  preview going page to page and a listing going into a folder change
  in place. New things (⌘N a terminal, ⇧⌘N a note, a search, an agent)
  are brought here, into the active column; ⌥⇧⌘N opens a terminal in a
  new column, ⌥⌘T a new workspace with one. A note is at home in the
  folder of the block it was made from: it is found there, and saved
  there by default. Open Folder… (⌥⌘O) browses a folder you choose
  beside the focused block; Browse This Folder (⌃⌘O) its own.
  The **block navigation stack**: **Navigate Back** and **Navigate
  Forward** (⌃- and ⌃⇧-, as in VS Code; or the mouse's back and forward
  buttons) go along every place you've been — the tiles focused and,
  within a block, where a jump took you from: a definition gone to, a
  found line, a heading, a command, an outline's entry, a PDF's page —
  back to the tile in its workspace (brought out if it was stashed) and
  the line, command, scroll or page it was at, the pointer with it.
  Going somewhere new from back there drops what was forward, as in VS
  Code. ⌘[ and ⌘] are for what has a history of its own: a web page's,
  and a folder tile's (the folders it showed, as a Finder window's Back
  goes); the mouse's buttons go there first in such a tile.
- **⌃⇥** walks the workspaces most recently gone to first, each
  sliding in from the right (⌃⇧⇥ from the left), for as long as control is
  held; letting go settles on the one come to. ⌘1–9 and ⇧⌘[ / ⇧⌘] switch
  workspaces too, as does the Dock icon's menu: every workspace, under
  its host when there are several, the one shown checked. A file or
  folder dropped on the Dock icon opens in the workspace shown, as a
  path clicked there does: a tile of its own, or gone to where it is.
- Drag a tile by its pill: between two tiles to put it there, near a
  column's side for a new column there, onto a workspace in the
  sidebar for its active column, or between workspaces for one of
  its own. To another workspace it moves, as a file does; ⌥-dragged it
  is copied — shown there as well, the same block in both. Held over a
  workspace's row, the workspace springs open under the drag, to drop
  it exactly where it should go there; one left empty and unnamed by a
  move goes. A stack's top takes the stack along; ⌘-drag it to take it
  alone, the next behind coming out in its place — a fanned-out pill
  drags its tile out alone the same way. ⌘W on a stack's top takes it
  off and the next comes out. Workspaces drag from the sidebar onto the grid the same
  way, their columns coming over.
- **Links by hand**: ⇧-drag any block's pill onto any tile and the
  dragged block *links* to the tile's block — one edge, read both
  ways. Both tiles wear the link in their bar, as a pill: an arrow for
  its direction (→ links to, ← linked from), the block's symbol and
  name, to click and go to, and (under the pointer) an × that breaks
  the link, both ways at once. With more than one link, the first's
  pill has sheets peeking out to its right, as a stack of cards, and the pointer
  resting on it fans the rest out below, each a pill the same. Links lists them under *links*
  and *linked from*. A note made with a block focused (⇧⌘N) is linked
  the same way, from the block to the note, as if the block had been
  ⇧-dragged into it. Dropped into a note (or any Markdown text) the
  block also lands in the text, `[title](manifold:…)`, shown as its
  pill — the block's symbol, name and status, live, as its tile's
  pill shows them — in the editor and as a small pill in the preview,
  clicked to go to the block; the note then *mentions* it too. So a
  web of annotations grows: notes about blocks, blocks in notes,
  blocks linked to blocks.
- **Images in notes**: paste one (a screenshot, a picture copied), drop
  image files, or right-click ▸ Insert from iPhone or iPad (a photo, a
  scan, a sketch) in a note or a Markdown file, and it's kept as an
  image block on the text's host — beside a Markdown file, named so any
  Markdown reader finds it (`![](image-2026-10-21-225841.png)`), or for
  a note in Manifold's own folder (`![](manifold:…)`) — and shown where
  the caret was: in the preview as the picture, in the editor as its
  pill. The text *embeds* it, a strong link: the image is kept while a
  text shows it, and once none does it's collected like anything else
  nothing keeps (a note's own copy with it).
- **Notes are Markdown, shown richly** as you write, the markers out
  of sight as in Prism: headings bold, `**bold**` and `*italic*` in
  their faces, `` `code` `` in its font on a tint, fenced code blocks
  in the code font edge to edge, list markers and quotes set off,
  links as their words, clicked to follow (the pointer over one is the
  hand), an address pasted over words making a link of them; a block's link is its pill,
  live. Every character stays where it is — the line the caret is on
  shows as written, markers dimmed — and the file is plain Markdown; a
  note shows no line numbers. ⌘B, ⌘I, ⌘⇧X and ⌘⇧C wrap the selection
  in bold, italic, strikethrough and code marks, or take them off.
  Return in a list carries it on — the next marker or number, an empty
  box in a task list — a quote with its mark, and on an empty item ends
  it. The pill's menu has Show Raw Markdown, kept per tile. Markdown
  files get the same.
- **Keep** (Keep in a bar's or a row's menu, or File ▸ Keep or Let Go)
  makes a block a root of its own: kept whatever refers to it, until
  let go. **Keep and Close** (⇧⌘W) keeps it and takes its tiles off
  every workspace; it then sits in **Kept**, the list at the foot of the
  sidebar, with the named workspaces off the desk, to be recalled with
  a click. Dropping a block's bar on the Kept row keeps it too.
- **Inbox** (Organize By ▸ Inbox, ⌥⌘3, or the counts at the sidebar's
  foot) lists the blocks whose status wants attention — done or failed
  and not yet read, or needing you — by host and workspace, each with
  what it said and how long ago. Reading a block (focusing it) takes it
  out; there is nothing to clear by hand. **⌘J** (Window ▸ Next in
  Inbox) goes through it in that order, from anywhere: to the next block
  after the focused one (or the first), in whatever workspace holds it,
  the pointer warped to its tile and the block marked read — a block
  that needs you stays until it's answered; with nothing in it, a beep.
- **⌘W** closes the focused tile; **⌥⇧⌘W** takes the workspace off the
  desk, and an unnamed workspace unseen for three days drifts off by
  itself. A block is kept while something reaches it — a workspace on
  the desk or a named one, a Keep, or a link by hand from a kept block
  — and once nothing does it waits half an hour in
  **Recently Closed**, the list at the foot of the sidebar (and in
  ⌘O, marked *recent*), then is collected: gone, with its history. An
  unnamed workspace taken off the desk goes the same way; a named one
  sits in **Kept**. **⇧⌘T** reopens the last thing closed where it
  was. Closing takes with it whatever only the closed block reached;
  when any of that has unsaved edits or a job running, a toast at the
  foot of the window names each, with Restore.

## Nothing is closed

Every block has a log: its edits, where it was placed, what it was named.
What you aren't using is tidied away rather than closed, and comes back
when you find it again.

- **⌘T finds the graph**: every block and workspace kept, and what can
  be made (new terminal, new note, attach a host, launch an agent),
  marked *do*. **⌘O** finds the same blocks and the files in the focused
  block's folder (a terminal's working directory, a file's folder),
  listed in the background and kept a while, so asking again is
  instant. Both rank off the main thread as you type, each keystroke
  giving up on the last, so typing never waits; the panel grows to fit
  and doesn't shrink under you. An agent is found by what it is: a
  block running Claude Code, Codex or another known agent answers to
  "claude", "codex" as surely as to its own title, and says so
  ("Terminal in ~/src · Claude Code").
- **⌘O finds anything** the host keeps. What the query *names* comes
  first: a title it is, or starts, or starts a word of, then one it's
  found in, then one with its letters in order, then a match only in
  what's around a block (its folder, its program). Among equals, the
  nearest to where you are over the graph — this workspace, then what's
  linked to the focused block, then step by step outward — and the most
  recently seen; with nothing typed, that is the whole order. Files not
  yet blocks come below the blocks (the system's scratch folders last).
  Each row says at the right where the block
  is — here, linked, near, kept, or *recent* for one closed
  and not yet collected, which choosing brings back — and how long
  since it was last seen. A
  workspace is found by its own name only — what it holds is found as
  itself. Choosing a block shows it here, in the focused column;
  choosing a workspace puts it on the desk. ⇥ goes round the finder's scopes: **In Files** has the host
  look for the words in the files under the project (as Find in Files
  does; the last row makes it a search block); **In Blocks** looks in
  the texts of the blocks — the workspace's first, then every note and
  file kept as a block. Either lists what it finds as a site's search
  does: a row a file or block, its name, where it is, and the lines that
  hold the words, two lines' worth, each match marked; ↩ goes to the
  first of them.
  A typed URL opens as a web page.
- **⌘\ goes through the workspace as an outline**, as Prism's Move to
  Heading does: its tiles by column, and under a Markdown tile its
  headings, set in by level; type words to narrow them, ↩ to focus the
  tile or go to the heading in its editor or preview. A terminal's row
  says where it is, what runs in it and what that reports, so "claude"
  finds the terminal running it.
- **Naming keeps.** An unnamed workspace is scratch: blocks unseen for a
  while leave nothing: nothing in a workspace is tidied away; an
  unnamed one emptied by hand leaves the desk. Name one (⇧⌘R, or double-click it in the sidebar)
  and it's kept as it is until you change it. Named workspaces wear a
  bookmark in the sidebar.
- **Terminals go dormant**, not away: a terminal off screen with an idle
  shell for eight hours (View ▸ End Idle Shells) has its shell ended and
  its transcript kept. Brought back, it starts a new shell under the old
  transcript, with a line across it saying when the last one ended and
  after how long idle, so it's never a surprise. The finder says
  *dormant* before you go to one.
- Blocks are linked by what you do: ⌘-clicking a file in a terminal links
  the two, and the palette lists what's linked to the focused block.

## Blocks

- **Terminals** are streams of their host's one connection, attached to a
  shell the server owns, so quitting and reopening the app brings every
  terminal back with the same processes still running. Ghostty runs in
  the app with no pty or process of its own: what the shell prints goes
  straight into it, off the main thread, and what's typed goes up the
  stream. A terminal whose host goes away keeps what it showed, and
  picks up where it was when the host is back — its history, scroll and
  selection kept, caught up with the screen; a remote host is one ssh session
  however many terminals it has. The host keeps each terminal itself, in
  the same emulator (Ghostty's, built into the server): a terminal
  attaching is sent a snapshot of it — screen, modes, cursor, a full-
  screen program on its own screen, and the last 5,000 lines of history —
  not the output that made it; and one that falls behind (a flood of
  output on a slow link) skips to the screen as it is now, as mosh does,
  instead of draining all it missed. Terminals are paced to the link as
  files are, but ahead of them. A terminal's
  menu (right-click) has, under Copy, Paste and Clear, the tree of what
  runs under its shell, the shell first, each process a submenu of End,
  Force End and what runs under it.
- **Text** blocks are files on the host, or notes (text with no file; ⌘S
  on one asks where to save it). A note has its own symbol (a note, not
  a file's page) wherever it's listed, and a name without being saved:
  Name… in its pill's menu, File ▸ Name Note… or the palette turns its
  pill's title into a field (⏎ names it, emptied it's Untitled again);
  saved, it's offered under that name, and its file's name names it
  from then on. A file's text is the file's: one shown whose text hasn't
  come in is asked for until it does (whatever went astray on the way),
  says "Reading the file…" and can't be typed into or saved meanwhile,
  and a file opened again is looked at on disk again. The **editor** lens is Manifold's own
  text view (the pill's menu switches a tile between the fixed-width
  and variable-width font, kept per tile): the file's text laid out
  with Core Text, line numbers, several
  cursors (⌘D selects the next occurrence; ⌃⇧↑/↓ add carets; ⌥-click
  adds one), find and replace (⌘F, ⌥⌘F; every match marked; see Find,
  below), Go to Line
  (⌘L), line operations (move ⌃⌘↑/↓, duplicate ⇧⌘D, delete ⌃⇧K, join ⌃J,
  comment ⌘/, indent and outdent with Tab and ⇧Tab over a selection),
  brackets and quotes paired, new lines indented like the last, undo as
  entries in the block's log (undone back to what was saved, it's clean
  again). Page Up and Down move the view a screenful, the caret along
  at the same place on screen. Files keep their encoding, line endings
  and permissions. One changed on disk reloads if clean, or shows a
  banner over unsaved changes. A tile with unsaved changes has a dot
  in its bar: grey, clicked to save; amber when the file also changed
  on disk beneath them, clicked to choose between reloading the file
  and overwriting it with the edits.
- **Viewing and editing**: a file opens to be viewed (unless `$EDITOR`
  opened it, to be edited) and a note to be written in; ⌘↩ (Edit ▸
  Edit or View, or the pill's menu) goes between the two in the same
  tile, the line at the top staying at the top and an editor's caret
  going along. How a file is viewed goes by its extension (a table in
  [Blocks.swift](Sources/ManifoldCore/Blocks.swift), anything not in
  it plain text): Markdown rendered (cmark-gfm), a note's too, following
  the text as it's edited on the same block or saved by another
  program; code and plain text as they are, not taken in. Viewed, both
  are set as go.dev sets the Go spec: code on its pale grey, lines at
  1.4, its text and line numbers' colors; Markdown in its colors,
  heading sizes and spacing, its links, and its code blocks, each with a
  copy button at its corner on hover — in the theme's fonts, code in its
  fixed-width one (as are a terminal's commands in its outline, and a
  commit's hash). Code (by its extension) is set in
  the fixed-width font when edited too, unless the tile's menu says
  otherwise. ⌥⇧⌘P puts the other mode beside the
  tile, so you can type on the left and read on the right; opening a
  file shown already, in either mode, goes to its tile. A link followed
  in a Markdown view opens another
  Markdown file in the same tile (Go Back returns to the one it came
  from), a web address as a web block below it, any other file as what
  it is, below; `#anchors` scroll.
- **HTML files** open as web blocks, read from the file with their
  folder (so their images and stylesheets work), from a terminal, the
  finder, a folder listing, a link in a preview, or the `manifold`
  command. View ▸ Editor Font chooses proportional or fixed
  width; View ▸ Theme the fonts: **Notes** (the default: SF Pro with its
  single-story "a", as Apple's Notes sets its text, Menlo for fixed
  width, the system font for the UI), Tiempos (Tiempos Text, Menlo),
  Tiempos/Fira (Tiempos Text, Fira Code), Tiempos/JetBrains (Tiempos
  Text, JetBrains Mono), Tiempos/Anthrosevka (Tiempos Text,
  [Anthrosevka Mono](https://nanx.me/anthrosevka/)), Mona (Mona Sans, Monaspace),
  Recursive, Go, or System (SF, SF Mono). All but SF are bundled;
  Tiempos Text is licensed, so the build copies it from your own fonts
  (`TIEMPOS_DIR`, by default its folder in iCloud Drive's Fonts)
  rather than fetching them.
- **Language servers** run on the file's host, one per language and
  workspace root, started when a file of theirs is placed: what they say
  is underlined, marked in the gutter and spelled out along the bottom
  when the caret is on it. Edit ▸ Code: Complete (⌃Space), Go to
  Definition (⌃⌘J, or ⌘-click: with ⌘ held, everything there's somewhere
  to go to — by the server's semantic tokens — shows in go.dev's link
  color, the one under the pointer underlined), Find References (⌃⌘R: a
  block of every use, beside, as a search's hits are shown — this file's
  first, each line previewed), Show Documentation
  (⌃⌘H), Rename Symbol… (⌃⌘N; other files change through their blocks, or
  on disk when they aren't open), Format Document (⌥⇧⌘F). Manifold ▸
  Language Servers… is the table: the languages by extension, the command
  (sourcekit-lsp, gopls, rust-analyzer, pyright, typescript-language-server,
  clangd and zls by default), the files that mark a workspace root, on or
  off; it's a setting on the desk, so every host runs the same — unless a
  host's own preferences (Preferences for *host*…, in its menu, This Mac's
  too) say otherwise, one setting a line as apex takes them:
  `lsp.rust ~/.apex/fblsp-server rust` runs that for Rust there,
  `lsp.root .hg` makes the folder holding `.hg` every language's workspace
  root (a monorepo one workspace), `lsp.rust.root …` one language's. A
  change restarts the servers it touches, their open files with them.
- **⌘-click** a file's name in a terminal to open it below the terminal,
  in its column: Markdown in a preview, folders in a listing (a folder's
  bare name too, as `ls` prints it, if there's a folder by that name where
  the terminal is), text to edit; `path:line:column` (as grep and compilers print it) goes to
  that place. The **`manifold`** command (Manifold ▸ Install Command Line
  Tool…) does the same from a shell: `manifold README.md src/`.
- **Folders** open as the Finder shows them, in three modes chosen at the
  bar's right: a **list** (name, date modified, size, kind; sorted by any,
  folders on top) whose folders open in place into the tree under it;
  **columns**, each folder chosen opening the next, a file chosen
  previewed in the last by Quick Look with its kind, size and date; and a
  **gallery**, the file chosen large over a strip of thumbnails. What the
  folder's repository ignores (git's or Sapling's rules) and hidden files
  are left out; ⇧⌘. shows them, dimmed. The **filter** (⌘F) looks
  through the whole tree beneath, less what's ignored — the matches
  shown with the folders on the way to them — ⏎ or ↓ to the files, ⎋ to
  clear it. Along the bar, the path: each folder in it clicked, or the
  arrow, ⌘↑, goes up. ⏎ or a double-click opens an entry — a folder in
  the same tile, as a browser goes; ⌘-double-click for a listing beside,
  this one staying; ⌥-double-click for one over it. Drag an entry out
  and it's its path — a terminal types it, an editor inserts it, the
  grid opens it where it lands (on its host, another's too), another
  app takes the file (one of this Mac's); ⇧-drag it
  and it's its block too, as a pill ⇧-dragged is: a note mentions it, a
  terminal or a tile it's dropped on is linked to it; ⌥⇧-drag it for
  the link alone. The mode, the
  selection, the folders left open, the sort and the filter are kept
  with the tile, and the listing keeps current as files come and go. On
  the folder's own host, remote or not (a remote file is fetched for its
  preview).
- **Files cross between hosts** as they would between folders: drop
  files from the Finder (or entries from another folder's tile, another
  host's too) on a folder's tile and they're copied into it, there —
  what's there already asked about before it's replaced; drop this
  Mac's files on another host's terminal and they're sent to its
  shell's folder (a name of their own if one's taken) and their paths
  there typed. Drag another host's entry to the Finder, the Desktop or
  Mail and it's fetched there. Right-click an entry (or a file tile's
  menu) for **Open With** — on another host, **Open Locally With**: a
  copy opened by the app here, sent back each time it's saved — and
  **Download**, to Downloads. Every copy shows at the foot of the
  sidebar while it goes — what, where to, how much of how much, how
  fast and how long is left, a bar filling — and × stops it, leaving
  nothing half-written; a failed one stays, red, until it's dismissed,
  and a finished download's row shows it in the Finder. With the sidebar
  away, a badge at the window's lower left says copies are going and
  brings it out. A drop of many things is one row. A copy between two
  hosts goes straight from the one to the other through this Mac, never
  onto its disk; a copy within a host is made by the host. Each copy is
  a stream of its own in the host's one connection — a whole folder
  one stream, its files' permissions, times and links kept — paced to
  what the link can take: no more
  of it on the way at once than the link holds (its rate and its
  round trip, measured as it goes), so a file on its way — an image or
  a PDF opening too — leaves a keystroke, an edit or an answer behind
  at most a piece of it, on a slow link or a fast one. The host reads
  and writes them aside from its terminals and other clients, and a
  file being replaced is only put in place once all of it has come.
- **Another host's ports come here**: open a `localhost` address from
  its tiles — ⌘-click `http://localhost:3000` in a remote terminal, a
  dev server's banner — and the port is forwarded through the host's
  own link to this Mac's localhost (the same port when it's free here,
  else another, which the toast says) and the address opened there: no
  `ssh -L`. **Forward a Port from *host*…** in the host's menu asks for
  one; each forward is listed there, to open or stop. A forward keeps
  listening while the host is away, and its connections go again when
  it's back. Each forwarded connection is a stream of the host's
  connection, paced as files are, and keeps no more than a megabyte on
  the way each way, so a fast server and a slow reader (or the other
  way round) fill nothing but themselves; and one side done sending
  still hears the other's answer.
- **A block's address**, `manifold:host/id`, opens it from any app on
  the Mac — pasted in Slack, a note in Notes, a commit message, or
  `open manifold:…` in a shell — going there as a link in a note does
  (a terminal's `#command=N` to that command). Copy Link in a tile's
  menu puts it on the clipboard: a link where links are taken, named
  for the block; text elsewhere; the block's pill in a note. Copy Path
  and Reveal in Finder are beside it. Closer in, the editor's menu has Copy
  Link to This Line (`#line=N`), an outline's heading or a PDF's page
  menu Copy Link to it (`#line=`, `#page=`), and a terminal's command or
  turn Copy Link to This Command; followed, each goes to that place.
- **Notes from what's at hand**: New Note from Selection, in an editor's
  or a terminal's menu (and ⇧⌘P's), makes a note of the selected text,
  quoted as code when it came from code, linked from where it came; New
  Note from Clipboard makes one of what was copied (a picture, an image
  block), and a
  terminal's Save Scrollback as Note keeps its whole transcript.
- **Links** go by the click: ⌘-click a web address — in a terminal, an
  editor, a preview or a web page — and the system's browser opens it;
  ⇧⌘-click and it opens in Manifold's own web lens beside (a plain click
  in a preview or a page does the same). File links in a Markdown
  preview go where the file leads: another Markdown file is previewed
  in the same tile, a folder is listed, an image or PDF shown, anything
  else edited.
- **Find** is a pill at a tile's upper right (⌘F): the query, how many
  matches, ↑ ↓ for the previous and next (↩ and ⇧↩, ⌘G and ⇧⌘G too), Aa
  for case, and ×; ⌥⌘F adds a row to replace with. ⌘E finds the word at
  hand and goes on to its next occurrence. Editors, Markdown previews,
  web pages, diffs and terminals are searched this way; in a terminal,
  Ghostty itself finds through the screen and its history and marks
  every match.
- **Copy on Select**: text selected with the mouse in a terminal is on
  the clipboard at once, the selection pulsing once to say so (not in
  full screen, where selecting is for reading); off and on from the
  terminal's pill menu, for every terminal.
- **Every tile prints** (File ▸ Print…, ⌘P), as it best goes on paper:
  a text or code as text, in its font; a Markdown preview or a web page
  as rendered; a PDF's pages and an image, fitted; a command's output, a
  terminal's transcript, a diff's changes and a notebook's cells as
  text. ⌘C copies an image (or a PDF's selected text) as other views
  copy theirs, and every tile's menu has Copy Link and, where it has a
  place, Copy Path and Reveal in Finder.
- **A tile's own outline**: a terminal (its commands, an agent's turns,
  each with how it ended and when — clicked, the terminal goes there and
  the command's whole output opens beside as a block of its own), a
  Markdown text (in the editor or the preview), a PDF, a diff (its
  files, each change under them, by the function it's in or its line)
  and a web page (its headings) have a sidebar of their own at the
  tile's left —
  the sidebar button in the tile's bar, or View ▸ Show Outline (⌥⌘S) —
  listing the headings (a PDF's table of contents), each clicked to go
  there (the pointer staying where it is), the one you're in marked as
  you scroll; a PDF's has its pages too, as thumbnails (the two buttons
  at its top). Shown or not, it's kept with the tile.
- **An outline** is a scrubber's marks as a list: Show Outline Beside
  (⇧⌘O, or in a terminal's, editor's or preview's bar menu) shows the
  block through its outline lens beside it, listing the commands (with
  their outcome and when) or the headings, each clicked to go there in
  the block's tile — or, with none shown, in one opened beside. A
  terminal's command clicked there also opens its output as a block of
  its own: the command line, how it ended and when, and what it printed
  as the terminal drew it — its colours, faces and carriage returns, in
  the terminal's palette and font — read-only, with Copy (the command
  and its output, as text), ⌘F to search it, and Show in Terminal (back
  to the command, the terminal scrolled to where it began).
  The bytes are the host's, kept from the command's start to its end, so
  a command scrolled off the screen or run before the window opened
  still shows whole; one from before the host kept them shows the
  screen's text instead. One per command; clicked again, the same block
  comes back.
- **A terminal's scroll bar is a scrubber**, as Prism's: a strip down
  the tile's right edge, the knob where you are, and a tick for each
  command the shell ran (the shells Manifold starts say so; red for one
  that failed, pulsing for one still running). Rest the pointer on a
  tick and a tip names the command and how it ended; click the tick to
  scroll to it. Click the tip, double-click or ⌘-click the tick, or
  right-click it for **Show Command and Output**, and the command and
  what it printed, as the screen showed them, become a note beside the
  terminal; the tip's copy button (or **Copy Command and Output**) puts
  the same on the clipboard. An editor's and a preview's scroll bars
  are scrubbers too, their ticks the headings of a Markdown text (or a
  note): hover for the heading, click to go to it. Drag the knob or click the track to scroll as ever.
  A scrubber shows as macOS shows its scroll bars: while you scroll,
  while the pointer rests on it, and a moment after, fading otherwise
  (and staying, if your scroll bars are set to always show).
- **Shell notebooks** (File ▸ New Shell Notebook, ⌃⇧⌘N, or New Shell
  Notebook in ⌘T) are Jupyter's notebooks for a shell: a column of cells,
  each a command (as many lines as you like) with what its last run
  printed beneath it, all run in one shell that lives on — your zsh or
  bash, with your rc files, on the notebook's host, `TERM=dumb` — so a
  variable exported, a directory changed into or an alias made in one
  cell is there in the next. ⌘↩ runs a cell; ⇧↩ runs it and goes to the
  next (made if it's the last); ⌥↩ runs it and makes one below; ↑ and ↓
  past a cell's first or last line go to the cells beside it; ⌥⌘↑ and
  ⌥⌘↓ move it. A run's output streams in as it comes and replaces the
  last; beneath it, the sidebar's status glyph (turning while it runs, a
  check once done, red when it failed) with how it ended (Done, Exit 1,
  Interrupted), how long it took and when; the gutter numbers the runs as
  the editor numbers lines. The focused cell wears the accent's bar at its
  left, as a selected row does, and a light ring, as a focused tile does;
  ▶ and the cell's menu (also on a right-click) show under the pointer.
  The header groups its buttons in capsules, as the folder view's modes
  are: run, run all, stop (red while there's something to stop); a new
  cell, restart, more. Cells run one at a time, in the order asked
  (Run All runs them all); one that fails stops those waiting. ⌘. (or
  the stop button) interrupts the running cell with ^C and drops those
  waiting; again kills its program, for one that ignores ^C. Restart
  Shell starts a fresh one. ⌘-click a path or an address in an output to
  open it — a name from where the shell is now, `file:line:column` at
  that place. The header says what the shell is doing and where; the
  notebook's status (working, done, failed) shows in the sidebar and the
  Inbox as a terminal's does. Cells, outputs and counts are kept in the
  notebook's log; the shell itself goes with the host's server, and the
  next run starts a new one. A cell's menu has Open Output as Block: what it
  printed, as a command's output block, beside the notebook and linked
  from it.
- **Searches** are blocks too: Find in Files… (⇧⌘F, from the editor's
  selection if there is one) makes one on the focused block's host under
  its project (the nearest folder up with `.git`), placed beside it; the
  host runs `rg` (or `grep`) and the hits arrive grouped by file as they're
  found, matches marked, each file's name staying at the top while its
  hits scroll under it until the next file's takes over. ⏎ in the field asks again (Aa for case, .* for a
  regular expression); ↓ then ⏎, or a double-click, opens the file at the
  hit beside the results. The hit chosen (the first, before one is) is
  previewed as the column browser previews a file — beside the hits when
  the tile is wide, beneath them when it's tall: the whole file in the
  code face with its line numbers, the hit's line lit in the middle, its
  match boxed and every other match marked; a double-click in it opens
  the file at that line. A search is found again by its query in ⌘O. A folder's
  menu (in a folder tile or the sidebar) has Find in This Folder…, for
  the same search under it.
- **Git and Sapling** repositories get a block each (File ▸ Source Control
  for This Project, ⌥⌘G, for the focused block's; the nearest `.sl`,
  `.hg` (a Sapling checkout as Meta's are) or `.git` up from it says
  which, Sapling first; with none, the tile goes and says so): the branch or bookmark
  (with how far ahead or behind), what's changed, and the last 200
  commits, looked at again when shown, when a file is saved from
  Manifold, or when the index (or Sapling's dirstate) changes. Sapling is
  spoken to as `sl` on the host's PATH. ⏎ or a
  double-click on a change opens a **diff** block beside it — the file
  against HEAD, context folded (click to unfold), double-click a row to
  open the file there; on a commit, the whole commit; on **All changes
  as one diff** (first under the changes, or in the tile's menu), every
  outstanding change at once, as plain `git diff` (`sl diff`) shows it,
  read again as the repository moves. Compare with Last
  Commit (⌥⌘D) does the same for the file being edited. A diff shows
  old and new side by side when its tile is wide enough for two
  columns, unified when it isn't. A diff's row or file has a menu:
  Open This Version (the file as it was at the commit, from `git show`,
  a block of its own beside), Open the Version Before, This File's
  Changes Alone (from a whole commit's diff) and Open the File. The editor's
  gutter shows how its lines stand against HEAD: a green bar for added
  lines, blue for changed, a red wedge where lines were taken out. Diff
  blocks keep the texts they compared in their logs, so they're records.
- **Interactive Smartlog** (File ▸ Interactive Smartlog, ⌥⌘I): Sapling's
  own smartlog for the repository the focused block is in — its commits
  and stacks, to commit, amend, rebase and split by hand — as a block of
  its own, beside, like any other: the host runs `sl web` (or finds the one
  running), and the tile shows what it serves, with nothing of a browser
  about it; a link out of it (a pull request) opens in the browser. A
  file you open from it (clicking one in a commit's or the working copy's
  files, or Open File in its menu) opens here, beside it, as any file
  does — at the line, when it names one — and Open Containing Folder
  opens the folder's listing, not the host's editor or the Finder
  (Sapling's `isl.open-file-cmd` isn't used, or changed). On
  another host it comes through the host's connection; its theme follows
  the app's. It works on a git repository as well as a Sapling one;
  outside any repository, or with no `sl`, the tile says so. The servers look for tools (`git`, `sl`, `rg`, language servers)
  where they're commonly installed — Homebrew's and Linuxbrew's folders,
  `~/.local/bin` — as well as on the PATH they were started with.
- **The sidebar organizes the same graph three ways** (View ▸ Organize
  By, ⌥⌘1–3): **Workspaces** — the desk, each workspace named by what it
  holds unless you name it (its blocks' folder, with the branch when a
  git block is there); **Files** — every
  block with a path under its folders — and every block that is *at* a
  folder, under it by its title: a terminal in its working directory
  (moving as it moves), a note at home there, a patch against it —
  across hosts, as a sparse tree; in every folder, what is on a
  workspace now is listed first, what's kept otherwise after it, dimmed;
  what's closed and not yet collected is only in Recently Closed
  (repositories, `~` and `/` at the top; runs of single folders one row;
  counts beneath; rows fade as they go unseen); **Inbox** — what wants
  attention (above). A filter narrows any of them. The rows work the
  same everywhere, by the one rule for opening things: click to go to
  the block (or bring it here, if it is nowhere), ⌘-click to show it
  beside the focused tile, ⌥-click to show it over the focused tile;
  rest the pointer for a card — after a moment, the block itself, live,
  when it's out of sight (another workspace, stacked, collapsed, or
  nowhere): its own view lent to the card and drawn smaller, a terminal
  still running in it, an editor, a page, a notebook as they are, put
  back when the card goes (one with no view yet gets one made for the
  card, let go after); a block whose tile is on screen, a picture of
  it, as Safari previews a tab. The card is drawn in the window, and
  goes when Manifold isn't in front;
  right-click for Go To, Show Beside, Show
  Over and the Neighborhood Map. Links written in a text — `[[title]]`,
  `[words](file.md)` — become edges the moment they're typed, so the
  map shows a note's backlinks whether or not anyone followed them.
- **One rule for the modifiers**, wherever a click opens a block — a
  sidebar row, a link, a tile's links badge, a listing's entry, a
  scrubber's command, a finder row chosen with ⏎: plain **goes to** it
  where it is (or opens it here); **⌥ puts it over** the tile you
  clicked in, which goes behind it, as ⌥-drag stacks; **⌘ puts it
  beside** that tile. ⇧ is about the path: ⇧-click a bar for where the
  block is, folder by folder; ⇧-drag a bar to link. In a terminal, ⌘ is
  what makes a click a click on a link at all, so there ⌘⌥ is over and
  ⌘ alone beside.
- **Links are two kinds**: by hand (⇧-drag a bar onto a tile, a note
  made beside a block), which keep what they point at; and by the way
  (a file ⌘-clicked in a terminal, a hit followed, a diff of a file, a
  `[[mention]]` in a note, a diff to the open files it changes, a block's
  link followed from a terminal, an output or a page), which are history
  and keep nothing; each says what made it ("followed", "subfolder",
  "chosen in ⌘O", "⇧-dragged in"), and the same link said twice in a
  moment is made once. The tile's links badge shows the ones by hand,
  and a note's images (the note, on an image's), which go when the note
  stops showing them rather than by ×; **the Neighborhood Map**
  (Window ▸ Show the Neighborhood Map, ⌥⌘N, or the badge's or a row's
  menu) draws a block's surroundings in graph form, two steps out —
  what it's joined to on a ring around it, what those are joined to
  beyond, with what made each link shown when a block is pointed at,
  and what you went to before and after it, from the trail. Click a
  block to look around *it* instead (Back returns), double-click or ⏎ to
  go there, arrow keys move, Space re-centers, ⎋ closes. The trail —
  every tile focused and every workspace gone to, which the host keeps
  — orders ⌃⇥'s round of the workspaces and the map's before and after.
- **Every block has a status** (DESIGN.md §3.7), in the schema of
  [OSC 7501](https://mitchellh.com/writing/program-status-osc7501):
  idle, working (with progress, or without), done, blocked (waiting for
  permission, an answer, or a sign-in), or failed, with the program's
  name and a line about it. Terminals and agents get theirs from the
  program — the host reads OSC 7501 out of the byte stream it owns, so
  remote hosts work the same; OSC 9;4 progress counts until a 7501
  report arrives; a new prompt or the process ending clears working
  and blocked; done and failed stay, read once you attend to the block
  by focusing it — or at once, when it finishes while you're looking. A busy terminal that says nothing is working.
  Searches, git and diff blocks report as the host works for them. One
  glyph says it wherever a block is named — an open ring turning for
  working (filling clockwise from the top when the program says how
  far, as OSC 9;4 progress does), an amber ring
  with a dot for a block that needs you, a filled check for done and
  not read yet (red for failed), a plain check once read, a moon for a
  terminal gone inactive — at the right of each tile's bar and of the
  sidebar's rows, with how long ago beside it there, and in the
  finder; the Dock badge counts the blocks that need you or are
  done and unread. Out of sight — Manifold not in front, or the tile
  not showing — the Mac's **notifications** say so: a terminal, agent or
  notebook that comes to need you, finishes or fails, and a terminal's
  command that ran ten seconds or more ending (how long, and its exit
  status if it failed); clicked, one goes to the block, and the command. The **Inbox** (⌥⌘3, or the counts at the foot of
  the sidebar) lists what wants attention, the unread first and how
  long ago at the right. Overview (⌘') shows a workspace's blocks
  themselves, live, as a **state view**: a list, stacked down one
  scrolling column as Prism's notes are, each under its pill; or an
  overview, all of them in one grid at once, as Mission Control lays out
  windows: as big as they can be with every one in the room (from about
  square to twice as wide as tall), scrolling only when there are so many
  they'd be small. Nothing is placed: click a pill to go to the block, ⌘-click
  to bring it to the workspace you were in, ⎋ (or ×) to go back.
  **Clear Status**, in a row's menu in Status or the tile's pill menu,
  forgets what a block reported until it reports again; a group's row
  offers Clear All. From a shell:

  ```sh
  status() { printf '\e]7501;state=%s:msg=%s\e\\' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"; }
  status working "Syncing photos"; rsync -a ~/Photos backup:/photos && status done "Photos synced" || status error "rsync failed"
  ```
- **Every lens comes back as it was.** Each placement keeps its lens's
  state in the block's log — the editor's selection and scroll, a
  preview's scroll and selection, a web page's history and scroll, a
  folder's or search's or git block's selected row and scroll, a diff's
  scroll and whether it was unfolded, an image's zoom, a PDF's page, the
  process list's filter and sort — so a restart, a move between lenses or
  a reload shows exactly what you left. The block keeps what it was last
  left at through each lens too, so a tile made for it again (recalled
  after it was closed, brought to another workspace) starts there.
- **History of This File…** (⌥⌘Y) scrubs the focused file through every change it's had
  in Manifold: Restore This Text puts a version back (one undoable edit);
  Compare with Now opens a diff block of then against now. Open This
  Version opens the text as it was then as a block of its own, beside.
- **Web pages** open in an embedded browser when a URL is ⇧⌘-clicked in a
  terminal, typed in the finder, or asked for in the palette: the page
  has the whole tile, its pill has the address (click it, or ⌘L), and
  back, forward and reload (stop, while it loads) are buttons on its bar
  as well as ⌘[ and ⌘]; its pages are in its log. It's known to sites as
  the Safari that's installed (a site that doesn't know it by WebKit's name
  alone — Google — would serve an old, plain page). A link that
  opens a new window (`target=_blank`, `window.open`) opens a web block
  beside, linked from the page; a page's alerts, confirmations and
  questions are sheets over the window, and a file input opens the
  Open panel.
- **Images and PDFs** open in their own lenses, their bytes from the
  file's host: images fit the view and zoom (⌘+/−, a pinch; double-click
  for actual size). PDFs show as Preview shows them: along the top the
  page (type a number to go there) of how many, ‹ › back and forward,
  the zoom (− + and ⌘+/−), and a menu of layouts — single page or two,
  scrolling or not, as a book — with Actual Size, Zoom to Fit and
  rotating; ⌘F finds in the text, every match a strong yellow and the
  one gone to blue, apart for colour-blind eyes too. A file named .pdf
  is one, whatever is inside it.
- **Agents** (File ▸ New Agent, ⌥⌘A) are terminal blocks that run the
  agent command (`claude` unless the settings say otherwise) in a login
  shell where the focused block is; their transcripts are kept like a
  terminal's, and they come back after a restart the same way. An agent
  started in a git repository has the working tree noted as it starts
  — all of it, untracked files too, without touching the index — and
  **Changes Since It Started** in its tile's menu shows everything it
  has changed since as a diff block of its own, linked from it: edits,
  new files, commits, but nothing that was already changed before it
  began. **Each turn** is noted too (with the hooks Manifold installs,
  `manifold --install-skill`): what was asked, the working tree as the
  turn began and as it ended (a checkpoint, in a git repository), the
  files it changed, its last words. Its tick on the scrubber, its line in
  the terminal's outline or the outline lens opens the turn as a block
  of its own: what was asked, what it did (its words and each tool it
  used, from Claude Code's transcript), what it said, the files it
  changed and **Changes in this turn** as links — a block linked from
  the agent and to each of them. Right-click the turn (or the agent's
  menu ▸ Last Turn) for **Changes in This Turn** and **Undo This Turn**:
  what the turn changed taken back, later work kept — or, where later
  work touched the same lines, nothing touched and Manifold says so.
  Turns are found with ⌘O — by what was asked among the names, by what
  was asked or said In Blocks — each opening as its block. **Window ▸
  Agents** (⌃⌘A) shows every agent on every host at once, live, as a
  list or an overview — those that need you first, then those at work,
  done, idle — each bar saying what it's on, for how long (or how long
  it took) and how many files it changed; click one to go there, ⎋ to
  come back.
  An agent's **to-do list** (Claude Code's) is a checklist note of its
  own, linked from it and kept by it, rewritten as the list changes:
  done ticked, the item at work in bold. Launch
  Agent Here (in the File menu, a tile's menu, or the box, ⌘T) offers each
  agent Manifold knows (Claude Code, Codex, Pi, Muse, Gemini CLI,
  opencode, Amp, Cursor Agent, Goose, Aider) that the focused block's
  host has: the host looks for them through your login shell (the
  shell its preferences name, if any) when a Mac attaches, when its
  shell preference changes, and again as the menu opens.
- **Agents' hooks** (`manifold --install-skill`, on any host, in one of
  its terminals or not) let an agent that doesn't speak OSC 7501 (Codex,
  say) show its status, and give every agent an outline: each prompt is
  a mark on the terminal's scrubber and in its outline, as a shell's
  command is, found on the screen where the agent echoes it, until the
  turn ends. The hooks run `manifold agent <event> --agent <name>`
  (start, prompt, working, waiting, stop, end), which tells the host
  over its socket and does nothing outside Manifold's terminals; status
  goes working on a prompt or a tool, blocked on a permission, done (with
  the agent's last words) when the turn ends. Each hook runs the
  `manifold` that installed it, by its full path (the app's Helpers, a
  remote host's `~/.manifold/bin`), never another `manifold` an agent
  finds first on its PATH. Installed for whichever of
  these are found (or those named): Claude Code (`~/.claude/settings.json`;
  MetaCode reads these too, and is told apart), Codex
  (`~/.codex/hooks.json`; Codex asks to review new hooks once), Muse
  (`~/.config/muse/settings.json`), and Pi (an extension,
  `~/.pi/agent/extensions/manifold.ts`, as Pi has no command hooks).
  Installing again replaces Manifold's hooks and keeps the rest of each
  file (a copy of it as it was is left beside it, `.before-manifold`);
  `manifold --uninstall-skill` takes them out.
- **Processes** (File ▸ Processes) is a block per host listing what `ps`
  sees, again every few seconds while shown, in tight rows by block:
  filter, sort by column, select any number (⇧, ⌘, ⌘A) and End them
  (SIGTERM; ⌫) or Force End them (SIGKILL; ⌥⌫, after asking), from the
  buttons or a row's menu, which also goes to the row's block. Its
  controls sit under the pill, and stack as the tile narrows.

## Contrast correction

Programs pick their colors for dark terminals, so on light paper `fd`'s greens
or an `ls`'s yellows can't be read. Manifold checks each cell's text against
its background as it's drawn and, where they don't reach WCAG AA (4.5:1),
moves the text's color in Oklab lightness until they do. Its hue and chroma
are kept, and nudged toward the nearest theme color. With deuteranopia
correction (the default), the text must also read as a deuteranope sees it.
**View ▸ Contrast Correction** switches between that, typical vision only,
and off. This is a port of apex's `contrast.rs`, in [the Ghostty
patch](patches/ghostty.patch). View ▸ Appearance follows the system, or
keeps to light or dark.

## Host and app

Everything lives in `manifoldd`, a server (one per host) the app starts
when it isn't running and that outlives it. Every block is a shard with
its own append-only log, kept in `~/Library/Application Support/Manifold/
logs` with snapshots beside, plus a registry of the host's blocks (kind,
title, last seen, held or dormant), their links, and the desk. The app
mirrors the host's shards and **leads** the ones it edits — workspaces,
text, the desk — appending entries locally first, so nothing waits on a
round trip; the host leads terminals and folders and does the file system
work (reading, writing, watching) on proposal. Both apply the same entries
with the same code, so they agree. State from before blocks (`state.json`)
is migrated into logs on first run.

- **End All Sessions and Quit** (in the app menu or the sidebar's ⋯ menu)
  stops the server; everything is kept, and terminals start fresh shells
  next time. Manifold ▸ Restart Server… restarts it (offered when the app
  finds a server from another version). A remote host's server from
  another version is restarted on its own: the app has installed its
  own there already, so it stops the old one and comes back through a
  bridge that starts the new; its shells start again, each in its
  directory, under their recent output.
- **Remoting** (Manifold ▸ Remoting…) is a table of providers: a name and
  a command that runs a command line on a destination with stdio
  connected, `%h` the destination and `%c` the command (appended when
  there is no `%c`), such as `my_special_script.sh %h`; `ssh` is built
  in. Attach to a host (⇧⌘K) with a provider and a destination it
  understands, or type `provider:target`. A provider not in the table
  is still looked for on your PATH as `manifold-remote-<provider>`.
- **Remote hosts** (Manifold ▸ Attach to Host…, ⇧⌘K) work as apex's do: a
  destination ssh understands, or `provider:name` for a
  `manifold-remote-<provider>` command on the PATH that takes a destination
  and a command to run there. Manifold asks the host what it is, installs
  the bundled `manifoldd` for it in `~/.manifold/bin` if the one there
  differs (stripped, gzipped on the way when the host has gunzip, into a
  file of that upload's own and put in place only if it hashes as what
  was sent; given up on only once nothing has moved for a minute, its
  progress in the host's tooltip), and runs `manifoldd bridge`, which pumps the same frames between
  the pipe and the host's own server (started if need be). Blocks are
  `host/ulid`, so a remote terminal, file or folder is placed, linked and
  found like a local one; its terminals attach through the same provider.
  A workspace lives on a host too, in that host's desk, which every Mac
  attached to the host sees: New Terminal in a New Workspace (⌥⌘T)
  makes it on the focused block's host, a host's row in the Desk
  sidebar has New Workspace on *host* in its menu, and the box (⌘T)
  lists one per host. What a Mac shows and settles on is its own.
  A host names itself: a session id minted once, which every block made
  there carries, so a block means the same thing from every Mac; what
  you see is its label. Hosts are remembered in `hosts.json` by session,
  with their destination and label, and attached again at start. A
  host stands in the sidebar from the moment it's attached to (a new one
  under its name until it says its session; gone again, with why, if it
  can't be reached the first time) and a remembered one from the start: a spinner and
  "connecting…" while it's being reached, a slashed ring and
  "unreachable" (dimmed) when it can't be — tried again after two
  seconds, then four, eight, up to two minutes between tries (the
  tooltip says when the next is; **Try Again Now** in the row's menu
  hurries it), and once connected, pinged every fifteen seconds so a
  bridge that hangs is noticed and made again. When the Mac wakes, or
  its network comes back or changes (another Wi-Fi, a VPN), every host
  is tried at once and every connected one asked straight away whether
  it's still there — given up on and made again in five seconds if not
  — so remote terminals come back as the lid opens. **Detach from *host*…**
  (in the row's menu, or the box, ⌘T) forgets it here, even while it's still
  being reached: it isn't attached again at start, and its server,
  shells and blocks stay there for attaching again. **Reset Server on
  *host*…** (the same menu, or the palette) installs the server there
  again whatever is there, stops the one running and starts the new one:
  its shells end and its terminals start fresh ones, its blocks and
  workspaces stay. **Reset Graph on *host*…** forgets every link between
  the host's blocks — opened from, found by, mentions, compared, made by
  hand — and its trail, leaving the graph empty (what's on each
  workspace stays; mentions come back as texts change). Both are in
  every menu of something on a host, under the host's name: a tile's,
  a terminal's or an editor's right-click, a workspace's or a block's
  row in the sidebar; the host's own row has them as they are. A bridge that keeps
  dying before the host answers is taken as a server gone missing
  there, and the host is bootstrapped again. While a host is unreachable its
  blocks stay as last seen: each tile's pill wears the slashed ring, an
  editor there takes no edits, and nothing new reaches it until it's
  back. Click a host's row in Files (or Desk) and its home folder opens
  as a listing on that host; a folder row with no listing yet opens one
  when clicked (the disclosure, or a double-click, unfolds it); a host
  with nothing of it yet shows just its `~`. A tile whose block is on a
  host you aren't attached to at all is a placeholder that says so,
  with Attach. Two Manifolds may attach to one host and share
  it: each block a client can edit (a note, a file, a web page, a
  workspace) has one owner at a time, whichever focused it last; the
  other mirrors until it focuses the block again. Linux servers (x86_64
  and aarch64, static) come from `scripts/build-linux.sh`, which
  `scripts/build-app.sh` runs: they are built with a swift.org toolchain
  through swiftly (`SWIFT_LINUX`, 6.4.1 by default — installed, with its
  Static Linux SDK, if missing), since the SDK goes with the toolchain
  of its own version and not with Xcode's; `LINUX=0` skips them.
- **`$EDITOR`** in Manifold's shells is `manifold --wait` (on a remote
  host, `manifoldd open --wait`): `git commit` and friends edit in an
  editor over the terminal that ran them, the terminal stashed behind
  it, and return when the editor is taken off (⌘W) and the terminal
  comes back. The block it edited in is ephemeral: once the command
  returns it is discarded, unless the file was a block already or the
  editor was moved somewhere else, so a commit message or an agent's
  prompt leaves nothing behind in the graph.
- **`git diff | manifold diff`** shows a patch as a diff block, beside the
  terminal it ran in (`manifold diff "before lunch"`, or `--title`, names
  it; else it is "Patch, n files"). Double-click a line to open the file
  there, against the directory the command ran in. On a remote host the
  same, through its `manifold` script.
- **`manifold` is first on the PATH** in Manifold's shells, once your rc
  files have run: the app's Helpers folder here, the server's folder on
  a remote host (with a `manifold` script standing in). zsh gets it
  through a .zshenv layer of Manifold's own that hands over to Ghostty's
  integration and then yours; fish through a command run after its
  configuration; bash through an rc file of Manifold's that sources the
  profile files and .bashrc. The same hooks tell Manifold each command
  the shell runs, for the terminal's scrubber; and the shell says where
  it is (OSC 7, as zsh and fish do through Ghostty's integration and
  bash through Manifold's rc), so a terminal's folder follows a `cd` at
  once — a shell that doesn't say is asked through its process every
  couple of seconds. A shell on another machine, through ssh in the
  terminal, names that host and is left alone. Manifold starts the
  shell a host's preferences name (Preferences for *host*… in its
  row's menu, or the box, ⌘T: a name on its PATH or a path, kept on the
  host, so every Mac attached shares it, and refused if the host can't
  run it); else `MANIFOLD_SHELL` in the server's environment; else your
  login shell. Shells already running keep theirs.
- **A memory watchdog** keeps an eye on the app's own footprint from a
  thread of its own: past 6 GB it has the system sample the process
  (every thread's stack) into `logs/memory-sample.txt` in the data
  folder, once, for finding what runs away; past 24 GB it ends the
  app — a renderer; the server keeps everything — rather than take the
  machine down, and says so in the log.
- **Retention** is tunable, in View ▸ Keep History: how many days of text
  changes to keep (older ones are folded into a base state beside the
  log, once an hour; history and scrubbing start from the base), how long
  to keep the transcripts of dormant terminals, and how many undo steps
  an editor holds. End Idle Shells sets when off-screen shells go
  dormant.
- `manifoldd state` prints what the host has; `manifoldd stop` ends it.
- Protocol: length-prefixed binary frames over a Unix socket
  ([Protocol.swift](Sources/ManifoldCore/Protocol.swift)); the same
  `Codable` entries as the logs, raw bytes for terminal I/O.
- `MANIFOLD_DIR` runs everything against another directory, for a second,
  throwaway instance (`MANIFOLD_NO_WARP` leaves the pointer alone, for one
  driven by a script); with `MANIFOLD_DEBUG` set too, the app listens on
  `$MANIFOLD_DIR/app-debug.sock` for scripted commands (see
  [DebugControl.swift](Sources/Manifold/DebugControl.swift)).
  `MANIFOLD_NO_NOTIFY` keeps such an instance from posting notifications
  (it shares the app's identity, and so its permission).
- **Secure Keyboard Entry** keeps what you type from other apps (as
  Terminal's does): on by hand in the Manifold menu, and on by itself
  while the focused terminal's program reads a password — `sudo`, `ssh`,
  any prompt that turns the terminal's echo off — on this Mac or another
  host (its server says so), a lock at the terminal's lower right while
  it lasts. Only while Manifold is in front.
- **When Manifold crashes**, it leaves word: the system's crash report
  (in ~/Library/Logs/DiagnosticReports — Ghostty's own reporter, which
  quit quietly, no longer takes the crash first), and a report of its own
  in ~/Library/Logs/Manifold — the signal and a backtrace, written from a
  stack of its own, so a stack overflow is caught too — beside
  Manifold.log, the app's error output when it isn't started from a
  terminal (Swift's "Fatal error" says what went wrong). The next launch
  says a report was kept. If Manifold dies within half a minute of
  starting twice in a row, it asks to **start safely**: a new, empty
  workspace shown instead of the last one, and other hosts left until
  you attach them — everything else as it was.

## Building

```
scripts/build-ghostty.sh    # once: fetches Zig and Ghostty into vendor/, builds Frameworks/
scripts/fetch-fonts.sh      # once: fetches Monaspace, Mona Sans, Recursive, Go, Fira Code, JetBrains Mono and Anthrosevka Mono into Frameworks/; copies Tiempos Text and Berkeley Mono
scripts/build-app.sh run    # builds build/Manifold.app and opens it
swift test
```

Ghostty is pinned to v1.3.1 with [a small patch](patches/ghostty.patch): Metal
shaders compile at runtime (no Metal toolchain needed), archives are merged in
a way Apple's current `libtool` accepts, a surface can run a command
directly (without `login(1)`), a surface can have its bytes carried by the
app (a "manual" I/O backend: no pty, no process — output fed in, typing and
sizes handed out), which is how terminals reach their hosts, and the
contrast correction above. Zig 0.15 can't read the stubs of the newest
macOS SDKs, so the build uses a cloned copy of the SDK whose stubs also
name arm64.

Nothing needs to be set up by hand, and nothing in `vendor/` needs to be
cleared: `scripts/build-ghostty.sh` and `scripts/build-manifold-vt.sh` both
start with `scripts/ghostty-env.sh`, which checks every time that Zig is
there (checked against its SHA-256), that `vendor/ghostty` is the pinned
release with the current patch (if the patch changed, the tree is reset and
it's applied again; edits of its own are saved to
`vendor/ghostty-local-<time>.patch` first), that the SDK copy covers every
stub. Downloads Zig makes during a build are retried, and named if they
keep failing. The host's terminal library is built with
`-Dmanifold-vt-only`, which sets up nothing of Ghostty's app, so it fetches
two small packages (uucode, zlib), not the GTK, Wayland and font libraries
Ghostty's Linux app wants.
