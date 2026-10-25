# Manifold

A Mac app that works like a wiki rather than a set of windows. Terminals
(drawn by [libghostty](https://github.com/ghostty-org/ghostty)), files,
notes, folders and web pages are **blocks**, and everything is linked: a
workspace links the blocks it shows, a note the blocks it mentions, and
what you do leaves links behind (this terminal opened that file). A block
stays alive as long as it is reachable in that graph — from a workspace,
a name, a Keep, a link by hand — and what nothing reaches any more is
collected, after a while to bring it back. A workspace is itself a block
you can name and come back to, and anything reachable can be found and
followed, with its history. Light or dark, in SF Pro and Menlo
as Notes sets them, or in [Monaspace](https://monaspace.githubnext.com)
and Mona Sans (bundled).
[DESIGN.md](DESIGN.md) says where it's going.

## Using it

- The **sidebar** is the spine of the window: the window buttons, New
  (+) and ⋯ along its top, then one browser over everything you have,
  organized three ways (Workspaces · Files · Inbox, below), with a
  filter. It sits beside the content; ⌃⌘S (or the button at its top
  right) makes it slide out over the content when the mouse goes to the
  window's left edge instead. Drag its right edge to resize it, and its
  top to move the window. Along the bottom of the sidebar run **Search**
  (⌥⌘4: pushed over the tree as Kept is, a field under its name, and
  the words found in the contents of every block — a text's lines, a
  terminal's commands, a block's name, place or address — each block
  with what matched beneath it, clicked to go there: the line in its
  editor or page, the command in its terminal), Workspaces and Files,
  the Inbox, and, at the right, counts of what needs you,
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
  the table of contents of the screen: a workspace's tiles in order,
  a stack's tiles together under its top — nearest first, as it fans,
  those behind set in and a step dimmer, the stack's rows on one faint
  rounded ground. Click a tile to focus it (one behind comes to the top
  of its stack), a workspace to go to it, double-click
  one to name it; drag a block from anywhere in the sidebar onto a tile
  to bring it in beside, onto a workspace for its active column, or
  between workspaces for one of its own, and drag workspaces to
  reorder them (among their host's, under its row) and hosts' rows to
  reorder the hosts (an order of this Mac's own, in Workspaces and Files).
- A **workspace** is a grid (DESIGN.md §3.1): columns of tiles,
  every tile a block, all of them visible, as acme tiles its windows.
  A workspace is what you made it: a block brought in stays until
  you take it off (⌘W), and nothing is tidied away. A new tile lands
  below the biggest tile of the active column, taking its lower half;
  Workspace ▸ Grow Tile (⌃⌘=) takes a step from its neighbors; Fill
  the Column (⌃⇧⌘=) gives it the whole column and **stashes** the
  others. A stash is a stack behind any tile: the sheets behind it peek
  out above its card, as a stack of paper — each a card of its own, with
  an edge and a shadow, stepped in further the deeper it is, within the
  gap between tiles, so a stacked tile takes no more room than a tile
  alone — and its bar's stack button wears how many are behind. A stack
  just made (or grown) has its sheets drop into place; the pointer on
  the stack button raises them into tabs at once — on the sheets, once
  it rests there a moment with no button down, as the sheets are in the
  gap where a drag resizes the tiles (passing through, or pressing, they
  stay down, and a press in the gap always resizes) — one for each tile
  behind, its symbol and
  title, over whatever is above (or, at the top of a column, below the
  bar), staying while the pointer is on them: click one to bring its tile
  to the top, or drag it out to put the tile anywhere, as a fanned card
  is dragged (past four, the count fans the stack). **Click those sheets**, or
  the stack button on the tile's bar (beside maximize), or press ⌃⇥, and
  in the tile's place the stack opens as a column of **summary cards**,
  as iOS opens a stack of notifications: the top first, then those behind
  it, nearest first, each its symbol, title and where it is, when it last
  did something (or its state, in its color), and two or three lines of
  what it holds — a terminal its last command and the last lines of its
  screen, an agent what it was asked and what it said, a note its first
  lines, a diff its files and lines changed, a search its hits — with a
  picture of a page, a PDF or an image. Scroll through them; the one
  chosen is ringed. With ⌃⇥, each ⇥ moves the choice a card down (⌃⇧⇥
  back up), and letting go of control brings it to the top (Escape leaves
  things be) — and as with ⌘⇥, a ⌃⇥ let go quickly (within a fifth of a
  second, about when macOS's switcher would appear) goes to the tile
  behind with no cards shown at all (⌃⇧⇥, the farthest), the cards
  coming only for a ⌃⇥ held; move the pointer over the cards and the card under it is
  chosen from then on, a click bringing it to the top. A click away from
  the cards leaves things be. Either way, **drag a card** to take that tile out of the stack:
  the cards fold away, the stack as it was, and the tile goes where it's
  dropped as a tile dragged does (between tiles, onto one, ⌥ over one),
  on its own — the top dragged out, the next behind it shows.
  The same summary is everywhere a block is shown small. **A tile shrinks
  in steps**: under 80 points of content, its summary stands in for it
  in its body, under its bar — its lines, as many as fit, when at the
  right (a click goes to it and grows it a little), squared off under
  its bar and rounded below as a tile is. **Shrink to Summary** (⇧⌘M, a
  ⌃-click on its bar, or its bar's menu) takes a tile down to that
  itself, giving its room to its nearest neighbour showing its content;
  again (Show Content), it's back as it was. Under 24, it's down to its
  bar, its summary's line in the bar where the folder was ("$ make test ·
  exit 2 · 4m"); a sidebar row's hover card has it
  under its picture; in ⌘O a block's row is its card, and what it says
  is found;
  `mani ls`, `info` and `context` print it. ⌥-click the top tile's own pill and it swaps with the next
  behind it; keep ⌥ held and click again, as ⌘\` walks workspaces, and
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
  ⌘P, Back, a found line, opening it again — goes there: a tile on its
  own is focused, one in a stack comes to the top of it (the rest
  behind it, as they were), and the pointer follows. Going to a tile
  squeezed down to its bar — by a link, the sidebar, the finder, ⌘J,
  Back, or opening what's already there (Browse This Folder on a
  folder shown), or down to its summary — grows it a little, to show some of what's in it (160
  points, or a quarter of the column), taken from its neighbours as
  growing takes it, and the pointer goes to it, as apex does. **⌥ with any
  click that opens something** puts what opens over the tile clicked
  in, that tile going behind it (as ⌥-drag stacks): a link or a
  block's pill in a note, a badge's link, a sidebar row, a listing's
  file or folder, ⌘⌥-click on a terminal's link, a page's, or a symbol in an
  editor (its definition stacked over the editor). Drop a pill on
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
  its history. Going somewhere (⌘O, ⌘P, a found line) brings the pointer
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
  beside the focused block; Browse This Folder (⌃⌘O) its own (a
  terminal's working directory, a file's folder, the folder a search looks under).
  The **block navigation stack**: **Navigate Back** and **Navigate
  Forward** (⌃- and ⌃⇧-, as in VS Code — except in a terminal, where
  ⌃- is the shell's or Emacs's undo; or the mouse's back and forward
  buttons) go along every place you've been — the tiles focused and,
  within a block, where a jump took you from: a definition gone to, a
  found line, a heading, a command, an outline's entry, a PDF's page —
  back to the tile in its workspace (brought out if it was stashed) and
  the line, command, scroll or page it was at, the pointer with it.
  Going somewhere new from back there drops what was forward, as in VS
  Code. ⌘[ and ⌘] are for what has a history of its own: a web page's,
  and a folder tile's (the folders it showed, as a Finder window's Back
  goes); the mouse's buttons go there first in such a tile. A web page
  zooms with ⌘+ and ⌘− in Safari's steps (50% to 300%), ⌘0 back.
- **⌘\`** walks the workspaces most recently gone to first, each
  sliding in from the right (⇧⌘\` from the left), for as long as ⌘ is
  held; letting go settles on the one come to (with one workspace, it
  goes to Manifold's next window, as macOS has it). ⌘1–9 and ⇧⌘[ / ⇧⌘] switch
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
- **Images in notes**: paste one (a screenshot, a picture copied — from
  a browser or a chat too, whose Copy Image puts its address beside it:
  the image is taken over text that only says where it's from), drop
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
  sidebar, with the named workspaces taken out of spaces, to be recalled with
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
- **⌘W** closes the focused tile; **⌥⇧⌘W** takes the workspace out of
  spaces (where workspaces are kept), and an unnamed workspace unseen
  for three days drifts out by itself. A block is kept while something reaches it — a workspace in
  spaces or a named one, a Keep, or a link by hand from a kept block
  — and once nothing does it waits half an hour in
  **Recently Closed**, the list at the foot of the sidebar (and in
  ⌘O, marked *recent*), then is collected: gone, with its history. An
  unnamed workspace taken out of spaces goes the same way; a named one
  sits in **Kept**. **⇧⌘T** reopens the last thing closed where it
  was. Closing takes with it whatever only the closed block reached;
  when any of that has unsaved edits or a job running, a toast at the
  foot of the window names each, with Restore.

## Finding and following

Every block has a log: its edits, where it was placed, what it was named.
Whatever the graph still reaches can be found, by name or by what's
around it, and comes back with its history.

- **⌘O** finds every block and workspace, and the files in the focused
  block's folder (a terminal's working directory, a file's folder),
  listed in the background and kept a while, so asking again is
  instant. It ranks off the main thread as you type, each keystroke
  giving up on the last, so typing never waits; the panel grows to fit
  and doesn't shrink under you. An agent is found by what it is: a
  block running Claude Code, Codex or another known agent answers to
  "claude", "codex" as surely as to its own title, and says so
  ("Terminal in ~/src · Claude Code").
- **Help ▸ Search** finds any menu command by name, as in every Mac app.
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
  and not yet collected, which choosing brings back — and, in a pill,
  how long since it was last seen (nothing, for just now). A block's row
  is its summary card — its title and where it is, two or three lines of
  what it holds under them ("$ make test", "exit 2"), so the many
  "Terminal"s are told apart — and what the summary says is found as
  well as the name, every word of the query in it (a command run a while
  ago, an agent's last words), ranked with the names the query is only
  scattered in (a found line's row, in In Blocks, stays as found). A
  workspace is found by its own name only — what it holds is found as
  itself. Choosing a block goes to it where it's placed, or brings it into
  the focused column if it's nowhere (⌘ beside, ⌥ over);
  choosing a workspace puts it in spaces. ⇥ goes round the finder's scopes: **In Files** has the host
  look for the words in the files under the project (as Find in Files
  does; the last row makes it a search block); **In Blocks** looks in
  the texts of the blocks — the workspace's first, then every note and
  file kept as a block. Either lists what it finds as a site's search
  does: a row a file or block, its name, where it is, and the lines that
  hold the words, two lines' worth, each match marked; ↩ goes to the
  first of them.
  A typed URL opens as a web page.
- **⌘P goes through the workspace as an outline**, as Prism's Move to
  Heading does: its tiles by column, and under each its outline, set in
  by level — a Markdown tile's headings, and whatever else has one
  (§7.5): a terminal's commands (how each ended beside it), an agent's
  turns, a source file's symbols from its language server, a PDF's
  contents, a diff's files; type words to narrow them, ↩ to focus the
  tile or go to the place in it, as a click in its own outline goes. It
  opens on where you are, the focused tile's item. A terminal's row
  says where it is, what runs in it and what that reports, so "claude"
  finds the terminal running it.
- **Naming keeps.** An unnamed workspace is scratch: blocks unseen for a
  while leave nothing: nothing in a workspace is tidied away; an
  unnamed one emptied by hand leaves spaces. Name one (⇧⌘R, or double-click it in the sidebar)
  and it's kept as it is until you change it. Named workspaces wear a
  bookmark in the sidebar.
- **Terminals go dormant**, not away: a terminal off screen with an idle
  shell for eight hours (Settings ▸ Terminals) has its shell ended and
  its transcript kept. Brought back, it starts a new shell under the old
  transcript, with a line across it saying when the last one ended and
  after how long idle, so it's never a surprise. The finder says
  *dormant* before you go to one.
- Blocks are linked by what you do: ⌘-clicking a file in a terminal links
  the two, and ⌘O ranks what's linked to the focused block first.

## Blocks

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
- **Text** blocks are files on the host, or notes (text with no file; ⌘S
  on one asks where to save it). A note has its own symbol (a note, not
  a file's page) wherever it's listed, and a name without being saved:
  Name… in its pill's menu or File ▸ Name Note… turns its
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
  (⌘L), line operations (move ⌃⌘↑/↓, duplicate ⇧⌘D, delete ⇧⌘K or ⌃⇧K, join ⌃J,
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
  program; code and plain text as they are, not taken in, set exactly
  as they're edited — face, size, lines, colors, line numbers — on the
  pale grey of a page of code, so going between the two changes only
  the page under the text; Markdown as go.dev sets the Go spec, in its colors,
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
  finder, a folder listing, a link in a preview, or the `mani`
  command. Besides the interface's system font, a theme has three: a
  **monospaced** one for terminals and code, an **editing** one for what's
  edited (notes, text in an editor — or, Settings ▸ Appearance ▸ Editor
  Text, the monospaced one), and a **reading** one for previews (a
  Markdown preview). Each theme sets the three — face, size, line height
  (a multiple of the size), letter spacing and OpenType features — and
  no fonts are shipped: **System** (SF and SF Mono), **Apple** (the
  default: Avenir Next 15 to edit, New York 16 to read — the system's
  serif — and Menlo 13), and **Humanist** (Hoefler&Co.'s ScreenSmart
  faces: Ideal Sans Book 14.5 to edit, with lining, tabular figures and
  ligatures, `lnum, tnum, liga`; Chronicle 15.5 to read, at 1.55, with
  ligatures; Menlo 13), which is offered only where Ideal Sans SSm and
  Chronicle SSm are installed (without them, a saved Humanist is set as
  Apple, and it comes back when they are). Lines are 1.45 to edit, 1.3
  for code, and to read 1.45 (SF), 1.5 (New York), 1.55 (Chronicle).
  Headings in a preview take the reading role's heading weight, as the
  family's nearest face (Humanist's a step below Bold: Chronicle has no
  Semibold, so Medium). In the dark, what's read and edited at length —
  an editor's text, a preview's body — is 86% white, against glare over
  a long read, with headings and bold brighter (97%) to do emphasis's
  work. Code spans are marked by their face alone; only fenced code
  blocks sit on a tint.
  **Settings ▸ Appearance ▸ Enable advanced typography** adds a
  **Typography** pane and a fourth theme, **Custom**, set there a role
  at a time: any installed family (the monospaced role's list leads with
  those of fixed pitch; New York too) and its face (by weight), the
  size, the line height, letter spacing (thousandths of an em), and
  OpenType features by tag (`ss01, zero, -liga, cv05=2`, or checked off
  a menu of those the font has); the reading role also its measure (the
  longest line in a preview, in characters) and the space between
  paragraphs (and its headings' face). Bold and italic come from the family's own faces, by
  their weights: bold a face about three hundred heavier (Regular's
  Bold) — or the face a role names (its **Bold** menu: Humanist's
  editing role names Semibold, Ideal's Bold being heavy beside Book, and
  its weights too close together to say so) — italic the slanted face of the weight, in editors, previews and
  terminals alike. Each role's size scales everything set in it, and all
  of it reaches everywhere the role is used: editors and notes (the
  editor's lines and letters too; a file viewed has lines of 1.4 at
  least), previews (as CSS), and terminals (as Ghostty's font family,
  style, size and features, its cells' height and width giving the line
  height and spacing). A sample shows the role as it's set; changes
  apply as you make them (and choose Custom); Start From copies a
  theme's, all of it or the role's. Fonts installed while Manifold runs
  are taken up at once.
- **Language servers** run on the file's host, one per language and
  workspace root, started when a file of theirs is placed: what they say
  is underlined, marked in the gutter and spelled out along the bottom
  when the caret is on it. Edit ▸ Code: Complete (⌃Space), Go to
  Definition (⌃⌘J, or ⌘-click — ⌘⌥-click stacks it over the editor: with ⌘ held, everything there's somewhere
  to go to — by the server's semantic tokens — shows in go.dev's link
  color, glowing softly in it, the one under the pointer on a soft band — a step in lightness,
  not a hue, as a chosen row's), Find References (⌃⌘R: a
  block of every use, beside, as a search's hits are shown — this file's
  first, each line previewed), Show Documentation
  (⌃⌘H), Rename Symbol… (⌃⌘N; other files change through their blocks, or
  on disk when they aren't open), Format Document (⌥⇧⌘F). Manifold ▸
  Settings ▸ Language Servers is the table: the languages by extension, the command
  (sourcekit-lsp, gopls, rust-analyzer, pyright, typescript-language-server,
  clangd and zls by default), the files that mark a workspace root, on or
  off; it's a setting in spaces, so every host runs the same — unless
  the host says otherwise. Above the table, **All Hosts** or one host
  (This Mac too; or Preferences for *host*… ▸ Language Servers… in its
  menu): set for one host, the same table shows what that host runs, and a
  command or root markers changed there are its own (in the accent color),
  as apex's settings are — `~/.apex/fblsp-server rust` for Rust there, say;
  set back to all hosts' value, they're let go of. Below it, a root marker
  for every language on that host: `.hg` makes the folder holding it every
  language's workspace root (a monorepo one workspace). A host's own
  settings are its preferences, shared by every Mac attached to it. A
  change restarts the servers it touches, their open files with them.
- **⌘-click** a file's name in a terminal to open it below the terminal,
  in its column: Markdown in a preview, folders in a listing (a folder's
  bare name too, as `ls` prints it, if there's a folder by that name where
  the terminal is), text to edit; `path:line:column` (as grep and compilers print it) goes to
  that place — read from the word's start for as long as it goes on as a
  path and a line and column, so `bootstrap.py:177:1:def run(` and
  `DESIGN.md:3:Manifold is…` each go to their file's line. A path with a
  line needs a dot or a slash; without one, the look of a path (`./x`,
  `~/a`, a name with an extension); a bare name, to be there (on this
  Mac). **Hold ⌘** over a terminal and what can be clicked shows, its text
  in the link color an editor shows ⌘'s links in, with the same glow
  around its letters, the one under the pointer on the same soft band. **`mani open`** (see **The `mani` command**) does the same from a
  shell: `mani open README.md src/`.
- **Folders** open as one tree, as Claude Code's file panel shows one:
  flat, in the system font, each folder opening in place (a click on its
  row or its chevron, ⏎), a file a small symbol in its type's colour; the
  file chosen is previewed at the right by Quick Look with its kind, size
  and date, as the Finder's columns do (the divider dragged as you like;
  a narrow tile shows the tree alone). What the folder's repository
  ignores (git's or Sapling's rules) and hidden files are left out; ⇧⌘.
  shows them, dimmed. The **filter** at the top (⌘F) looks through the
  whole tree beneath as it's typed, less what's ignored, and lists the
  files that match — their letters in order, as the picker matches —
  best first, the letters matched in bold and the folder each is in
  beside it; ⏎ opens the best, ↓ goes to the list, ⎋ clears it. "?" and
  some words, then ⏎, searches inside the files instead, in a search
  beside. The arrow, or ⌘↑, goes up to the enclosing folder; ⌘↓ goes into
  the folder chosen, in the same tile. A double-click (or ⏎) opens a file
  beside. Drag an entry out
  and it's its path — a terminal types it, an editor inserts it, the
  grid opens it where it lands (on its host, another's too), another
  app takes the file (one of this Mac's); ⇧-drag it
  and it's its block too, as a pill ⇧-dragged is: a note mentions it, a
  terminal or a tile it's dropped on is linked to it; ⌥⇧-drag it for
  the link alone. The
  selection, the folders left open, the divider and the filter are kept
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
- **Another host's ports come here**: open a `localhost` address from
  its tiles — ⌘-click `http://localhost:3000` in a remote terminal, a
  dev server's banner — and the port is forwarded through the host's
  own link to this Mac's localhost (the same port when it's free here,
  else another, which the toast says) and the address opened there: no
  `ssh -L`. **Forward a Port from *host*…** in the host's menu asks for
  one; each forward is listed there, to open or stop. A forward keeps
  listening while the host is away, and its connections go again when
  it's back. Each forwarded connection is a stream of the host's
  connection, paced as files are (not compressed: what goes through a
  port is mostly compressed already, or encrypted, and its size could
  tell what it holds), and keeps no more than a megabyte on
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
- **Links** go by the click, every kind alike — a web address, a path,
  a block's pill, a tile's link — in a terminal, an editor, a preview or
  a page: **⌘-click** opens it in Manifold beside (a page in its web
  lens), ⌘⌥ over; **⇧⌘-click** gives it to the system — an address to
  your browser, a file of this Mac to the app that opens it. A plain
  click in a page follows the link in the page, as a browser does; in a
  preview it opens beside. File links in a Markdown
  preview go where the file leads: another Markdown file is previewed
  in the same tile, a folder is listed, an image or PDF shown, anything
  else edited.
- **Find** is a pill at a tile's upper right (⌘F): the query, how many
  matches, ↑ ↓ for the previous and next (↩ and ⇧↩, ⌘G and ⇧⌘G too), Aa
  for case, and ×; ⌥⌘F adds a row to replace with. ⌘E (Use Selection
  for Find) finds the selection, or the word at hand, and goes on to its
  next occurrence; ⇧⌘E (Use Selection for Replace) puts it in the
  replace row. Editors, Markdown previews,
  web pages, diffs and terminals are searched this way; in a terminal,
  Ghostty itself finds through the screen and its history and marks
  every match.
- **Copy on Select**: text selected with the mouse in a terminal is on
  the clipboard at once, the highlight pulsing once with the glow
  typed-ahead keystrokes have — around it, as if lit from behind — to say
  so (not in
  full screen, where selecting is for reading); off and on from the
  terminal's pill menu, for every terminal.
- **Every tile prints** (File ▸ Print…), as it best goes on paper:
  a text or code as text, in its font; a Markdown preview or a web page
  as rendered; a PDF's pages and an image, fitted; a command's output, a
  terminal's transcript, a diff's changes and a notebook's cells as
  text. ⌘C copies an image (or a PDF's selected text) as other views
  copy theirs, and every tile's menu has Copy Link and, where it has a
  place, Copy Path and Reveal in Finder.
- **Outline ticks**: a tile whose block has an outline — a Markdown
  text's headings (in the editor or the preview), a source file's types,
  functions and methods (as its language server says, nested as they are,
  each with its kind, not a function's locals or a type's fields), a
  PDF's contents, a diff's files and changes, a web page's headings, an
  agent's turns —
  shows it as a few short ticks at its content's upper right (five at
  most, however long the outline), the one nearest where you are longer
  and darker; they take no room of their own. Rest the pointer on them
  and the whole outline opens over them, indented by level, where you are
  marked: click an item to go there, or its ⋯ (or right-click it) for what
  else it can do — copy a link to a heading or a page, a turn's changes,
  undo a turn. **⇧-drag an item** and it carries what the block's pill
  ⇧-dragged does, its link naming the item's place (`#line=`, `#page=`):
  into a note it's a link to that heading or page; on a tile, the blocks
  are linked; on a terminal or an editor, the block's path; ⌥⇧-drag for
  the link alone. An agent's turn (a command, in a terminal's sidebar)
  carries the block it opens as when clicked — the turn, the command's
  output — made then if it wasn't yet. A diff's file carries itself, as a
  file ⇧-dragged from a listing does; dragged plainly, an item carries
  what it does from the sidebar (a command's text, a diff's file). A **shell's commands** have a dot each too, beside the
  prompt (red for one that failed, the accent for one still running):
  rest the pointer on a dot for **Copy Command and Output** and **Show as
  Block**.
- **A tile's own sidebar**: the same outline — a terminal's commands (an
  agent's turns), each with how it ended and when, clicked, the terminal
  goes there (its ⋯ shows the command's output, or the turn, as a block);
  a Markdown text's, a source file's, a PDF's, a diff's or a web page's — as a
  list at the tile's left —
  the sidebar button in the tile's bar, or View ▸ Show Outline (⌥⌘S) —
  listing the headings (a PDF's table of contents), each clicked to go
  there (the pointer staying where it is), the one you're in marked as
  you scroll; a PDF's has its pages too, as thumbnails (the two buttons
  at its top). Shown or not, it's kept with the tile.
- **Search Outline** (⇧⌘O, or in a tile's bar menu): the focused tile's
  own sidebar — its commands, headings, symbols, contents or files —
  shown if it wasn't, the pointer going to the **filter field** at its
  top; type to narrow it (every word somewhere in an entry, the matches
  listed flat), ↑↓ and ⏎ to go there, as clicking one does; Escape
  clears what's typed, then leaves. Either way the tile has the keyboard
  back, and a sidebar opened for the search is put away again. (A tile
  with an outline but no sidebar searches it in the finder.) A command's **output** (Show Output in its ⋯,
  or Show as Block on its dot) opens as a block of
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
- **A terminal's, an editor's and a preview's scroll bar** is a strip
  down the tile's right edge, the knob where you are: drag the knob or
  click the track to scroll as ever. (Where things are in what it holds
  is the outline's, above.) It shows as macOS shows its scroll bars: while you scroll,
  while the pointer rests on it, and a moment after, fading otherwise
  (and staying, if your scroll bars are set to always show).
- **Shell notebooks** (File ▸ New Shell Notebook, ⌃⇧⌘N) are Jupyter's notebooks for a shell: a column of cells,
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
  Commit (⌥⇧⌘D; ⌥⌘D is the system's, hiding the Dock) does the same for the file being edited. A diff shows
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
  By, ⌥⌘1–3; Search, ⌥⌘4, is over them all): **Workspaces** — spaces, each workspace named by what it
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
  it, as Safari previews a tab — and under the picture, the block's
  **summary card**, as a stack's column has it (its title, where it is,
  when it last did something, its few lines). The card is drawn in the window, and
  goes when Manifold isn't in front;
  right-click for Go To, Show Beside, Show
  Over and the Neighborhood Map. Links written in a text — `[[title]]`,
  `[words](file.md)` — become edges the moment they're typed, so the
  map shows a note's backlinks whether or not anyone followed them.
  A row says what its block's status adds to its glyph (a question's
  kind, its message — not "Done"); an untitled note goes by its first
  words, as its links name it; a text with unsaved edits has its bar's
  dot after the name; a page has its site's icon.
- **Pin in Workspace** (a tile's bar menu, a terminal's or an editor's
  right-click menu, or a sidebar row's): the block stays
  at the top of its workspace in the sidebar, above a hairline, in the
  order pinned — and stays there with its tile closed, dimmed, to click
  for the tile back in that workspace. A pin is an edge from the
  workspace to the block, a strong one: the workspace keeps the block,
  and a workspace with anything pinned is kept itself — a root, as a
  named one is; it doesn't drift out of spaces, nor go when its last
  tile closes. Unpin from the same menus.
- **One rule for the modifiers**, wherever a click opens a block — a
  sidebar row, a link, a tile's links badge, a listing's entry, a
  finder row chosen with ⏎: plain **goes to** it
  where it is (or opens it here); **⌥ puts it over** the tile you
  clicked in, which goes behind it, as ⌥-drag stacks; **⌘ puts it
  beside** that tile; **⇧⌘ gives it to the system** (the browser, the
  file's app). ⇧ alone is about the path: ⇧-click a bar for where the
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
  — orders ⌘\`'s round of the workspaces and the map's before and after.
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
  **Clear Status**, in a row's menu in the Inbox or the tile's pill menu,
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
- **Web pages** open in an embedded browser when a URL is ⌘-clicked in a
  terminal, typed in the finder, or made with File ▸ New Web Page: the page
  has the whole tile, its pill has the address (click it, or ⌘L — Go to
  Line's key in an editor, the address's elsewhere), and
  back, forward and reload (stop, while it loads) are buttons on its bar
  as well as ⌘[ and ⌘]; its pages are in its log. The address works as
  Chrome's: `localhost:3000`, `10.0.0.5`, any `name:port` are addresses
  (not searches); **`host:port`, an attached host's name** (`slowbox:3000/api`)
  is that host's own localhost — the port forwarded here and opened, the
  pill showing it as `slowbox:3000` still; words, a search. As you type,
  completions come under it: the page you've been to that begins with
  it, filled in inline (the rest selected — type on, or ⌫ it away),
  else what you typed (to go to, or search for); pages you've been to
  that match it by address or title; the attached hosts (`slowbox:`,
  and their ports you've been to); a search. ↑↓ or ⇥ move through them,
  ⏎ goes, ⎋ closes them (a second ⎋ leaves the address), ⇧⌫ forgets a
  page. The pages any web tile shows are kept for this, with their
  titles, in `web-history.json` in the app's folder. It's known to sites as
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
  at work in a block — an agent block, or a terminal running one — shows
  its maker's mark wherever the block's symbol shows (Claude Code, Codex,
  Gemini CLI, Cursor, Goose, opencode, Amp, Pi; Meta AI's for Muse), from
  [Lobe Icons](https://github.com/lobehub/lobe-icons) (MIT) and pi.dev, in
  Resources/AgentIcons; the marks are their makers' trademarks. An agent
  started in a git repository has the working tree noted as it starts
  — all of it, untracked files too, without touching the index — and
  **Changes Since It Started** in its tile's menu shows everything it
  has changed since as a diff block of its own, linked from it: edits,
  new files, commits, but nothing that was already changed before it
  began. **Each turn** is noted too (with the hooks Manifold installs,
  `mani skill install`): what was asked, the working tree as the
  turn began and as it ended (a checkpoint, in a git repository), the
  files it changed, its last words. Its item in the terminal's outline
  (its ticks, or its sidebar) goes to the turn; its ⋯ opens the turn as a block
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
  Agent Here (in the File menu or a tile's menu) offers each
  agent Manifold knows (Claude Code, Codex, Pi, Muse, Gemini CLI,
  opencode, Amp, Cursor Agent, Goose, Aider) that the focused block's
  host has: the host looks for them through your login shell (the
  shell its preferences name, if any) when a Mac attaches, when its
  shell preference changes, and again as the menu opens.
- **Agents' hooks** (`mani skill install`, on any host, in one of
  its terminals or not) let an agent that doesn't speak OSC 7501 (Codex,
  say) show its status, and give every agent an outline: each prompt is
  an item in the terminal's outline, found on the screen where the agent echoes it, until the
  turn ends. The hooks run `mani agent <event> --agent <name>`
  (start, prompt, working, waiting, stop, end), which tells the host
  over its socket and does nothing outside Manifold's terminals; status
  goes working on a prompt or a tool, blocked on a permission, done (with
  the agent's last words) when the turn ends. Each hook runs the
  `mani` that installed it, by its full path (the app's Helpers, a
  remote host's `~/.manifold/bin`), never another `mani` an agent
  finds first on its PATH. Hooks put in when the command was `manifold`
  are moved over to the `mani` of the same copy of Manifold once it has
  one, as the app and each host's server start. Installed for whichever of
  these are found (or those named): Claude Code (`~/.claude/settings.json`;
  MetaCode reads these too, and is told apart), Codex
  (`~/.codex/hooks.json`; Codex asks to review new hooks once), Muse
  (`~/.config/muse/settings.json`), and Pi (an extension,
  `~/.pi/agent/extensions/manifold.ts`, as Pi has no command hooks).
  Installing again replaces Manifold's hooks and keeps the rest of each
  file (a copy of it as it was is left beside it, `.before-manifold`);
  `mani skill uninstall` takes them out.
- **Processes** (File ▸ Processes) is a block per host listing what `ps`
  sees, again every few seconds while shown, in tight rows by block:
  filter, sort by column, select any number (⇧, ⌘, ⌘A) and End them
  (SIGTERM; ⌫) or Force End them (SIGKILL; ⌥⌫, after asking), from the
  buttons or a row's menu, which also goes to the row's block. Its
  controls sit under the pill, and stack as the tile narrows.

## Look

One flat style throughout, in the system font. A field or a button has
no bezel: a hairline on a faint fill, darker under the pointer; a field
outlined in the accent while it has the keyboard, a magnifier at its left
when it filters and a cross at its right to clear it (⎋ clears it too). A
toggle (Aa, .*) that's on is in the accent; the one thing to do (Attach)
is filled in it. A choice of a few (the picker's scopes, the state view's
modes) is a row of words or symbols, the chosen one on a grey band. Every
list's chosen row is a soft grey band, a fainter one under the pointer.
Panels floating over the window (the palette, cards, toasts, history, the
sidebar unpinned) are rounded alike with one soft shadow; the picker is
plain, not glass. The system's own alerts are left as they are.

## Contrast correction

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

**Settings** (⌘,) holds every setting, a pane each: Appearance (light or
dark, the accent color, the fonts, the editor's text, contrast), Terminals (copy
on select, ending idle shells), History, Remoting and Language Servers.
The **accent color** — System (the macOS one), Blue, Orange (Overcast's),
Purple, Pink, Green or Graphite — colors the app's own marks: the focus
ring, what's chosen or toggled, the selection bands, progress, the caret
and selected text in editors and terminals, and one of the backdrop's
pools of light. Each is set for light and for dark (in the light, deep
enough to read as a thin line on white). Colors that say something keep
their own: links, find matches, status, diffs, a terminal's palette.

## Host and app

Everything lives in `manifoldd`, a server (one per host) the app starts
when it isn't running and that outlives it. Every block is a shard with
its own append-only log, kept in `~/Library/Application Support/Manifold/
logs` with snapshots beside, plus a registry of the host's blocks (kind,
title, last seen, held or dormant), their links, and spaces. The app
mirrors the host's shards and **leads** the ones it edits — workspaces,
text, spaces — appending entries locally first, so nothing waits on a
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
- **Remoting** (Settings ▸ Remoting) is a table of providers: a name and
  a command that runs a command line on a destination with stdio
  connected, `%h` the destination and `%c` the command (appended when
  there is no `%c`), such as `my_special_script.sh %h`; `ssh` is built
  in. Attach to a host (Manifold ▸ Attach to Host…) with a provider and a destination it
  understands, or type `provider:target`. A provider not in the table
  is still looked for on your PATH as `manifold-remote-<provider>`.
- **Remote hosts** (Manifold ▸ Attach to Host…) work as apex's do: a
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
  A workspace lives on a host too, in that host's spaces, which every Mac
  attached to the host sees: New Terminal in a New Workspace (⌥⌘T)
  makes it on the focused block's host, a host's row in the Workspaces
  sidebar has New Workspace on *host* in its menu. What a Mac shows and settles on is its own.
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
  — so remote terminals come back as the lid opens. **What waits on a
  host says so**, a moment in (a quick answer shows nothing): a folder
  being listed, a file being read (in its editor or preview), a
  repository's status, the processes, a search match's file, a terminal
  being reached each show a spinner and "Reading…" (or "Connecting…") where
  their contents will be; a subfolder opened in a listing, "Reading…" at its
  foot; a folder that's empty, hidden-files-only, missing or unreadable
  says which, rather than showing nothing. A click that waits for a host
  to make something (a command's output, a turn, a version, a notebook,
  a port forwarded) says what it's getting from where, and if the host
  doesn't answer in half a minute, that too. **Detach from *host*…**
  (in the row's menu) forgets it here, even while it's still
  being reached: it isn't attached again at start, and its server,
  shells and blocks stay there for attaching again. **Reset Server on
  *host*…** (the same menu) installs the server there
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
  back. Click a host's row in Files (or Workspaces) and its home folder opens
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
- **`$EDITOR`** in Manifold's shells is `mani open --wait` (on a remote
  host, `manifoldd mani open --wait`): `git commit` and friends edit in an
  editor over the terminal that ran them, the terminal stashed behind
  it, and return when the editor is taken off (⌘W) and the terminal
  comes back. The block it edited in is ephemeral: once the command
  returns it is discarded, unless the file was a block already or the
  editor was moved somewhere else, so a commit message or an agent's
  prompt leaves nothing behind in the graph.
- **`git diff | mani diff`** shows a patch as a diff block, beside the
  terminal it ran in (`--title "before lunch"` names it; else it is
  "Patch, n files"). Double-click a line to open the file there, against
  the directory the command ran in. On a remote host the same, through
  its `mani` script.
- **The `mani` command** is Manifold from a shell, for you and for the
  agents in its terminals: `mani <command> [flags] [args]`. One table of
  its commands makes its parser, `mani help` and each command's
  `--help`, so what it says it does is what it does.
  - **Names.** A block is named by its id (as `mani ls` prints it), a
    path, a title, or a position: `@here` (the terminal it runs in),
    `@focused`, `@selection` (the last text selected anywhere but
    `@here` — an editor's, a terminal's, a PDF's, a page's — so "the code
    I highlighted" is `mani read @selection`, and `mani info @selection`
    says where: block, path, lines, page), `@last` (what `mani` last
    made), `@workspace`; `@left`, `@right`, `@above`, `@below` (the
    nearest tile that way from `@here`), `@leftmost`, `@rightmost`,
    `@top`, `@bottom`, `@under` (stacked under `@here`), `@1`…`@9`
    (columns left to right, each top down). A kind narrows any of them:
    `@right:diff`, `@:pdf` (the one PDF shown). A name that could be
    more than one is an error that lists them, ids and all.
  - **Looking.** `mani ls` lists the workspace's tiles (`--all`, every
    workspace); `--json` gives the whole layout — columns of tiles, each
    with its block, kind, title, path, frame (x, y, width, height as
    shares of the window), the tiles sharing each of its edges, the
    names it answers to, the tiles stacked under it, and its summary
    (title, place, lines, note — what a summary card shows; `mani ls`
    prints the lines under each tile). `mani info`
    describes a block (its summary, commands, links, outline); `mani read` prints
    what it holds as text — a note's or file's text as it is now, saved
    or not, a terminal's screen (`--all`, its transcript; `--command -1`,
    its last command's output), a page's or PDF's text (`--pages`), a
    diff, a listing, search results, a notebook — with `--lines a-b`.
    `mani context` says it all at once: the layout, the selection, the
    terminals' last commands and how they ended, unsaved files.
  - **Doing.** `mani open` (files, folders, addresses), `mani new note |
    terminal | agent | web | search` (a note's text from its input:
    `… | mani new note --preview` renders it), `mani show`, `mani close`,
    `mani write` (a note's or file's text; `--append`, `--save`),
    `mani rename`, `mani pin`/`unpin`, `mani link`; what they show goes
    below `@here` unless told `--above`, `--right`, `--left`, `--column`
    or `--over`, by `--at` another tile. `mani run <terminal> <command>`
    types a command into a terminal's shell (through its host, shown or
    not); `--wait` waits for it to end, prints its output and exits with
    its status (`--timeout`: 124 if it doesn't). A terminal with no shell
    running — dormant, or not shown since its host's server started —
    has one started for it, as showing it would: in its directory, at
    its last size (else 80×24), the command typed once it prompts; the
    tile, shown later, takes up that shell.
  - **Panels.** `mani ui new < widgets.json` makes a panel: widgets an
    agent describes as JSON — labels and Markdown, buttons, fields,
    text, checkboxes, selects, sliders, progress, tables and lists,
    images, rows and groups, and an `html` widget (a page, with
    `mani.emit(name, value)`) for the rest — drawn with the system's
    controls, below `@here` unless placed elsewhere. `mani ui set panel
    progress=0.4 status=Building` sets values (`go.label="Deploy now"`
    a widget's property; widgets on the input replace them), `mani ui
    get` prints them, and `mani ui wait` waits for the next thing done
    in it — a click, a change — and prints it as JSON with all the
    values; what's done while nothing waits is kept for the next wait. A
    widget with `"run": "…"` runs that command on the panel's host when
    used (the panel as `@here`, the event in `MANI_EVENT`), so a button
    can answer in the panel itself. Values are kept in the block, and
    come back with it.
  - **Watching.** `mani watch` prints a JSON line for each thing that
    happens — focus, selection, a command started or ended (with its
    status), a block's status, a tile shown or taken off, a file saved,
    another workspace, something done in a panel — until it's
    interrupted (`--only` some).
  - **For agents.** `mani skill show` prints a guide to all this for
    coding agents: how to look before asking when the user says "this",
    "on my right" or "what I highlighted", what users say and what to
    run, the commands. `mani skill install` gives it to them along with
    the hooks: Claude Code as a skill (`~/.claude/skills/manifold`,
    loaded when it's in a Manifold terminal and the user means what's on
    screen), Codex as a few lines in `~/.codex/AGENTS.md` that point to
    it (the rest of the file kept). A newer Manifold's guide replaces
    the old as it starts.
  - `mani diff`, `mani skill`, `mani agent` (what agents' hooks run) and
    `mani help` are done by `mani` itself; the
    rest are passed to the app through the host, so they work alike from
    a remote host's terminals.
  It's strict: an unknown command or flag, a flag missing its value, too
  many or too few arguments are errors, with the command's usage, status
  2 (a path given bare says to `mani open` it); failing to do what was
  asked is status 1. Manifold ▸ Install Command Line Tool… links it
  into /usr/local/bin (taking away the `manifold` link of before). On a
  remote host a `mani` script beside the server runs `manifoldd mani`.
- **`mani` is first on the PATH** in Manifold's shells, once your rc
  files have run: the app's Helpers folder here, the server's folder on
  a remote host (with a `mani` script standing in). zsh gets it
  through a .zshenv layer of Manifold's own that hands over to Ghostty's
  integration and then yours; fish through a command run after its
  configuration; bash through an rc file of Manifold's that sources the
  profile files and .bashrc. The same hooks tell Manifold each command
  the shell runs, for the terminal's dots and outline; and the shell says where
  it is (OSC 7, as zsh and fish do through Ghostty's integration and
  bash through Manifold's rc), so a terminal's folder follows a `cd` at
  once — a shell that doesn't say is asked through its process every
  couple of seconds. A shell on another machine, through ssh in the
  terminal, names that host and is left alone. Manifold starts the
  shell a host's preferences name (Preferences for *host*… in its
  row's menu: a name on its PATH or a path, kept on the
  host, so every Mac attached shares it, and refused if the host can't
  run it); else `MANIFOLD_SHELL` in the server's environment; else your
  login shell. Shells already running keep theirs.
- **A memory watchdog** keeps an eye on the app's own footprint from a
  thread of its own: past 6 GB it has the system sample the process
  (every thread's stack) into `logs/memory-sample.txt` in the data
  folder, once, for finding what runs away; past 24 GB it ends the
  app — a renderer; the server keeps everything — rather than take the
  machine down, and says so in the log.
- **Retention** is tunable, in Settings ▸ History: how many days of text
  changes to keep (older ones are folded into a base state beside the
  log, once an hour; history and scrubbing start from the base), how long
  to keep the transcripts of dormant terminals, and how many undo steps
  an editor holds. Settings ▸ Terminals sets when off-screen shells go
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
  (it shares the app's identity, and so its permission), and
  `MANIFOLD_NO_OCCLUSION` has its terminals and status glyphs drawn and
  turning when its window is behind others. Its `busy start` / `busy stop`
  time every turn of the main thread in between — the hitches a person
  would feel — and `picker bench`, `layouts` and `spinners` look at the
  finder's ranking, the grid's layouts and the backdrop's drawings, and
  the turning glyphs.
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
