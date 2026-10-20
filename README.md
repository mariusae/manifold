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
  top to move the window. The Workspaces, Inbox and Status
  organizations are flat: a host's heading opens and closes its
  workspaces, a workspace's label goes to it (the current one's folds
  it, and opens it again), groups' labels open and close, and a block's
  row has a second line for what it says. Only the current workspace
  shows whole; the others fold to the tiles that peek out — working,
  needing you, done or failed — as apex folds them. Under **Desk**, each workspace expands to
  its tiles in order, the selected one open and the focused tile
  highlighted, so the sidebar is the table of contents of the screen:
  click a tile to focus it, a workspace to go to it, double-click
  one to name it; drag a block from anywhere in the sidebar onto a tile
  to bring it in beside, onto a workspace for its active column, or
  between workspaces for one of its own, and drag workspaces to
  reorder them.
- An **workspace** is a grid (DESIGN.md §3.1): columns of tiles,
  every tile a block, all of them visible, as acme tiles its windows.
  A workspace is what you made it: a block brought in stays until
  you take it off (⌘W), and nothing is tidied away. A new tile lands
  below the biggest tile of the active column, taking its lower half;
  Workspace ▸ Grow Tile (⌃⌘=) takes a step from its neighbors; Fill
  the Column (⌃⇧⌘=) gives it the whole column and **stashes** the
  others. A stash is a stack behind any tile: a few edges peek out
  beside its pill, fan out from behind it when the pointer rests there
  (packed, opaque, the edges gone while they're out, the one under
  the pointer ringed in the accent), and one clicked
  comes back on its own as that tile's lower half, the rest staying
  behind the tile that showed; ⌥-clicked (an edge or a
  fanned-out pill), it takes the top instead, whole, the tile that
  showed going behind it with the rest of the stack; ⌥-click the top
  tile's own pill and it swaps with the next behind it. A stack is one
  thing: drop its top tile's pill on another's and the whole stack goes
  behind that tile; move the top tile and the stack moves with it;
  **⌘E turns a stack into a file of cards** over its tile, live: the
  top drops flat to the bottom and the one beneath it stands up in
  front, leaning back, with the title bars of the rest behind it. More
  E's flip further down (⇧⌘E back up; scrolling works too; a card
  clicked is chosen), and letting go of ⌘ brings the chosen one forward
  to the top (Escape leaves things be). Without a stack, ⌘E finds the
  word at hand.
  Unstack in the pill's menu lays the whole stack out in the column;
  Close Stack takes the tile and its stack off the workspace (from a
  maximized tile, Close Column takes the column).
  Going to a stashed block from the sidebar or the
  finder brings it out too, and the pointer follows. **⌥ with any
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
  Stash Tile (⌘M, or Stash in a pill's menu) puts the
  focused tile behind its nearest tile — the one above it, else the
  column's first — and focuses that one. Dragging the line between two tiles past one's least
  height stashes it and goes on against the next, until all above or
  below are put away. Maximize Tile (⇧⌘↩, or the ⤢ at the right of a
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
  click its pill (or ⌘L) and it widens into one, the address selected
  to type over, or words to search for; ⏎ goes, ⎋ leaves it. ⌘[ and ⌘]
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
  resize them. Each tile wears a **pill** floating over its top, one
  width for all, with its symbol, name and status glyph: drag it to
  move the tile; click it to grow the tile a step, ⌘-click to fill the
  column; click its symbol for the tile's menu; ⇧-click it for where the
  block is, folder by folder up to the root (a terminal's working
  directory likewise), each browsing that folder here, as ⌘-clicking a
  document's title does in the Finder. ⌥⌘[ and ⌥⌘] move the
  focus between tiles.
- Two verbs put a block in front of you. **Go to** finds it where it
  already is: the workspace it is in (this one if it is here, else
  the one most recently settled on) is selected and the tile focused.
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
  **Go Back** and **Go Forward** (⌘[ ⌘]) walk the trail across tiles
  and workspaces.
- **⌃⇥** walks the workspaces most recently settled on first, each
  sliding in from the right (⌃⇧⇥ from the left), for as long as control is
  held; letting go settles on the one come to. ⌘1–9 and ⇧⌘[ / ⇧⌘] switch
  workspaces too.
- Drag a tile by its pill: between two tiles to put it there, near a
  column's side for a new column there, onto a workspace in the
  sidebar for its active column, or between workspaces for one of
  its own. A stack's top takes the stack along; ⌘-drag it to take it
  alone, the next behind coming out in its place — a fanned-out pill
  drags its tile out alone the same way. ⌘W on a stack's top takes it
  off and the next comes out. Workspaces drag from the sidebar onto the grid the same
  way, their columns coming over.
- **Links by hand**: ⇧-drag any block's pill onto any tile and the
  dragged block *links* to the tile's block — one edge, read both
  ways. Both tiles wear a badge at the upper right, a link's symbol
  and how many; the pointer resting there fans the links out below,
  each with an arrow for its direction (→ links to, ← linked from),
  the block's symbol and name, to click and go to, and an × that
  breaks the link, both ways at once. Links lists them under *links*
  and *linked from*. A note made with a block focused (⇧⌘N) is linked
  the same way, from the block to the note, as if the block had been
  ⇧-dragged into it. Dropped into a note (or any Markdown text) the
  block also lands in the text, `[title](manifold:…)`, shown as its
  pill — the block's symbol, name and status, live, as its tile's
  pill shows them — in the editor and as a small pill in the preview,
  clicked to go to the block; the note then *mentions* it too. So a
  web of annotations grows: notes about blocks, blocks in notes,
  blocks linked to blocks.
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
- **Archive** (⇧⌘W, or Archive in a pill's or a row's menu) puts a
  block away as it is: its tiles leave every workspace, and it sits
  under **Archived** at the end of its host in the Workspaces sidebar,
  to be recalled with a click. A terminal's shell is ended and not
  started again — the transcript shows as it was, and the shell's exit
  archives a terminal by itself. Unarchive, in the same menus, takes it
  out again (a terminal then gets a shell when next shown).
- **Inbox** (Organize By ▸ Inbox, ⌥⌘6) lists the blocks whose status
  came to need attention — done, failed, needs you — by host and
  workspace, each with what it said and how long ago, until taken out
  by hand: ⇧⌘I, or Remove from Inbox in a pill's or a row's menu (Add
  to Inbox puts any block there).
- **⌘W** takes the focused tile off its workspace; **⇧⌘W** takes the
  workspace off the desk. Neither loses anything: the block, with its
  history, is a ⌘O away, and a workspace taken off sits under
  **Recent** at the foot of the sidebar's Desk, dimmed, opened by
  hovering (as Files' Recent is), the last seen first; click it and it
  is back on the desk. There is no Close.

## Nothing is closed

Every block has a log: its edits, where it was placed, what it was named.
What you aren't using is tidied away rather than closed, and comes back
when you find it again.

- **⌘O finds anything** the host knows, ranked by where you are: what's
  linked to the focused block (opened from it, placed with it, compared
  against it) comes first, nearest first and the most recently joined
  first among them, with nothing typed; a match near it outranks one far
  from it. Then blocks by title and path, named
  workspaces, terminals by where they are, and the files under the
  focused block's folder, ranked by how well they match and how recently
  they were seen, and the processes under the host's terminals and
  agents, by command or path, each going to its block. Choosing a block
  shows it here, in the focused column; choosing a workspace puts it on
  the desk. ⇥ goes round the finder's scopes: **In Files** has the host
  look for the words in the files under the project (as Find in Files
  does; ↩ opens the file at the line, and the last row makes it a search
  block); **In Blocks** finds lines in the texts of the workspace's
  blocks and goes to them.
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
- **⌘Y** shows a workspace's history: a slider through every change,
  the workspace drawn as it was, and Restore, which appends what makes it
  so again (a new version, never a revert).
- Blocks are linked by what you do: ⌘-clicking a file in a terminal links
  the two, and the palette lists what's linked to the focused block.

## Blocks

- **Terminals** run `manifoldd attach <block>`, which connects them to a
  shell the server owns, so quitting and reopening the app brings every
  terminal back with the same processes still running. A terminal's
  menu (right-click) has, under Copy, Paste and Clear, the tree of what
  runs under its shell, the shell first, each process a submenu of End,
  Force End and what runs under it.
- **Text** blocks are files on the host, or notes (text with no file; ⌘S
  on one asks where to save it). The **editor** lens is Manifold's own
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
  again). Files keep their encoding, line endings and permissions. One
  changed on disk reloads if clean, or shows a banner over unsaved
  changes. The **preview** lens renders Markdown (cmark-gfm) and follows
  the text as it's edited in an editor on the same block, or saved by
  another program. Edit ▸ Edit or Preview (⌥⌘P) puts an editor over
  the focused preview, or a preview over a Markdown editor — the one
  beneath stashed behind it until the one on top is taken off (⌘W), or
  ⌥⌘P again; ⌥⇧⌘P puts the other beside it, so you can type on the
  left and read on the right. A link followed in a preview opens another
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
  Tiempos/Fira (Tiempos Text, Fira Code), Mona (Mona Sans, Monaspace),
  Recursive, Go, or System (SF, SF Mono). All but SF are bundled;
  Tiempos Text is licensed, so the build copies it from your own fonts
  (`TIEMPOS_DIR`, by default its folder in iCloud Drive's Fonts)
  rather than fetching them.
- **Language servers** run on the file's host, one per language and
  workspace root, started when a file of theirs is placed: what they say
  is underlined, marked in the gutter and spelled out along the bottom
  when the caret is on it. Edit ▸ Code: Complete (⌃Space), Go to
  Definition (⌃⌘J, or ⌘-click), Find References (⌃⌘R), Show Documentation
  (⌃⌘H), Rename Symbol… (⌃⌘N; other files change through their blocks, or
  on disk when they aren't open), Format Document (⌥⇧⌘F). Manifold ▸
  Language Servers… is the table: the languages by extension, the command
  (sourcekit-lsp, gopls, rust-analyzer, pyright, typescript-language-server,
  clangd and zls by default), the files that mark a workspace root, on or
  off; it's a setting on the desk, so every host runs the same.
- **⌘-click** a file's name in a terminal to open it below the terminal,
  in its column: Markdown in a preview, folders in a listing,
  text to edit; `path:line:column` (as grep and compilers print it) goes to
  that place. The **`manifold`** command (Manifold ▸ Install Command Line
  Tool…) does the same from a shell: `manifold README.md src/`.
- **Folders** open in a listing (name, date, size); double-click an entry
  to open it — a folder in the same tile, as a browser goes; ⌘-double-
  click for a listing beside, this one staying; ⌥-double-click for one
  over it — ⌘↑ for the folder above; on the folder's own host, remote
  or not.
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
- **An outline** is a scrubber's marks as a block of their own: Show
  Outline Beside in a terminal's, editor's or preview's pill menu makes
  one (linked to its subject as its source, so Links shows it) listing
  the commands (with their outcome and when) or the headings, each
  clicked to go there in the subject's tile — or, with none shown, in
  one opened beside. An outline whose last tile closes is gone for
  good; it was only ever a view. A block put away shows faded
  wherever a link names it, with an archive box for its glyph.
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
- **Searches** are blocks too: Find in Files… (⇧⌘F, from the editor's
  selection if there is one) makes one on the focused block's host under
  its project (the nearest folder up with `.git`), placed beside it; the
  host runs `rg` (or `grep`) and the hits arrive grouped by file as they're
  found, matches marked. ⏎ in the field asks again (Aa for case, .* for a
  regular expression); ↓ then ⏎, or a double-click, opens the file at the
  hit beside the results. A search is found again by its query in ⌘O.
- **Git and Sapling** repositories get a block each (File ▸ Source Control
  for This Project, ⌥⌘G, for the focused block's; the nearest `.sl` or
  `.git` up from it says which, `.sl` first): the branch or bookmark
  (with how far ahead or behind), what's changed, and the last 200
  commits, looked at again when shown, when a file is saved from
  Manifold, or when the index (or `.sl/dirstate`) changes. Sapling is
  spoken to as `sl` on the host's PATH. ⏎ or a
  double-click on a change opens a **diff** block beside it — the file
  against HEAD, context folded (click to unfold), double-click a row to
  open the file there; on a commit, the whole commit. Compare with Last
  Commit (⌥⌘D) does the same for the file being edited. A diff shows
  old and new side by side when its tile is wide enough for two
  columns, unified when it isn't. The editor's
  gutter shows how its lines stand against HEAD: a green bar for added
  lines, blue for changed, a red wedge where lines were taken out. Diff
  blocks keep the texts they compared in their logs, so they're records.
- **The sidebar organizes the same graph five ways** (View ▸ Organize
  By, ⌥⌘1–5): **Desk** — the workspaces, as before; **Files** — every
  block with a path under its folders — and every block that is *at* a
  folder, under it by its title: a terminal in its working directory
  (moving as it moves), a note at home there, a patch against it —
  across hosts, as a sparse tree; in every folder, what is on a
  workspace now is listed, and the rest waits under Recent, which opens
  when the pointer rests on it
  (repositories, `~` and `/` at the top; runs of single folders one row;
  counts beneath; rows fade as they go unseen); **Links** (⌥⌘N) — what's
  joined to the focused block by kind, each row opening one more step;
  **Time** — blocks by the day they were last seen; **Status** — by
  what they are doing (below). A filter narrows any
  of them. The rows work the same everywhere: click to go to the block
  (or bring it here, if it is nowhere), ⌘-click to bring it here, rest
  the pointer for a card, right-click for Go To, Bring Here and Links
  Around This. Links written in a text —
  `[[title]]`, `[words](file.md)` — become edges the moment they're
  typed, so the Links view shows a note's backlinks whether or not
  anyone followed them.
- **Links is a block's neighborhood** in the graph of blocks (DESIGN.md
  §3.5), in the sidebar, following the focus: *opened here*, *found by*,
  *compared*, *mentions*, *also in* (other workspaces holding it),
  *before* and *after* (what you went to around it, from the trail), each
  row with what made the link (the ⌘-clicked line, the search hit, the
  editor line that named a definition) and when. Window ▸ Go Back and Go
  Forward (⌃⌘[, ⌃⌘]) walk the trail across columns and workspaces:
  back to the block you were at before, wherever it was, and forward
  again. Show the Neighborhood Map, in the palette, draws the focused
  block's surroundings in graph form, two steps out — what it's joined
  to on a ring around it, what those are joined to beyond, edges by
  kind, with what made each shown when a block is pointed at. Click a
  block to look around *it* instead (Back returns), double-click or ⏎ to
  go there, arrow keys move, Space re-centers, ⎋ closes.
- **Every block has a status** (DESIGN.md §3.7), in the schema of
  [OSC 7501](https://mitchellh.com/writing/program-status-osc7501):
  idle, working (with progress, or without), done, blocked (waiting for
  permission, an answer, or a sign-in), or failed, with the program's
  name and a line about it. Terminals and agents get theirs from the
  program — the host reads OSC 7501 out of the byte stream it owns, so
  remote hosts work the same; OSC 9;4 progress counts until a 7501
  report arrives; a new prompt or the process ending clears working
  and blocked; done and failed stay, read once you attend to the block
  by focusing it. A busy terminal that says nothing is working.
  Searches, git and diff blocks report as the host works for them. One
  glyph says it wherever a block is named — three dots with the lit one
  travelling for working (a thin arc filling, when the program says how
  far), an amber ring
  with a dot for a block that needs you, a filled check for done and
  not read yet (red for failed), a plain check once read, a moon for a
  terminal gone inactive — in each tile's pill, the sidebar's rows and
  the finder; the Dock badge counts the blocks that need you or are
  done and unread. **Status** in the sidebar (⌥⌘5) lists blocks by it,
  the unread first and how long ago at the right. Click a group's row —
  Needs you, Done, Failed, Working, Inactive — and the surface shows its
  blocks themselves, live, as a **state view**: a list, stacked down one
  scrolling column as Prism's notes are, each under its pill; or an
  overview, all of them in one grid at once, as Mission Control lays out
  windows. Nothing is placed: click a pill to go to the block, ⌘-click
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
  a reload shows exactly what you left.
- **History** (Workspace ▸ History…, ⌘Y) scrubs the workspace through
  its log: the layout then, the blocks as they are now; with **Everything
  as it was** checked, each placed file is read as of that moment too, and
  Restore brings both back — as new entries, never a revert. History of
  This File… (⌥⌘Y) scrubs the focused file through every change it's had
  in Manifold: Restore This Text puts a version back (one undoable edit);
  Compare with Now opens a diff block of then against now.
- **Web pages** open in an embedded browser when a URL is ⇧⌘-clicked in a
  terminal, typed in the finder, or asked for in the palette: the page
  has the whole tile, its pill is the address (click it, or ⌘L), ⌘[ and
  ⌘] go back and forward, and its pages are in its log.
- **Images and PDFs** open in their own lenses, their bytes from the
  file's host: images fit the view and zoom (⌘+/−, a pinch; double-click
  for actual size), PDFs page in PDFKit.
- **Agents** (File ▸ New Agent, ⌥⌘A) are terminal blocks that run the
  agent command (`claude` unless the settings say otherwise) in a login
  shell where the focused block is; their transcripts are kept like a
  terminal's, and they come back after a restart the same way.
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
  differs, and runs `manifoldd bridge`, which pumps the same frames between
  the pipe and the host's own server (started if need be). Blocks are
  `host/ulid`, so a remote terminal, file or folder is placed, linked and
  found like a local one; its terminals attach through the same provider.
  A workspace lives on a host too, in that host's desk, which every Mac
  attached to the host sees: New Terminal in a New Workspace (⌥⌘T)
  makes it on the focused block's host, a host's row in the Desk
  sidebar has New Workspace on *host* in its menu, and New… (⌘T) lists
  one per host. What a Mac shows and settles on is its own.
  A host names itself: a session id minted once, which every block made
  there carries, so a block means the same thing from every Mac; what
  you see is its label. Hosts are remembered in `hosts.json` by session,
  with their destination and label, and attached again at start. A
  remembered host stands in the sidebar from the start: a spinner and
  "connecting…" while it's being reached, a slashed ring and
  "unreachable" (dimmed) when it can't be — tried again after two
  seconds, then four, eight, up to two minutes between tries (the
  tooltip says when the next is; **Try Again Now** in the row's menu
  hurries it), and once connected, pinged every fifteen seconds so a
  bridge that hangs is noticed and made again. A bridge that keeps
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
  comes back.
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
  terminal, names that host and is left alone. Manifold starts your
  login shell; `MANIFOLD_SHELL` in the server's environment names
  another.
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
  throwaway instance; with `MANIFOLD_DEBUG` set too, the app listens on
  `$MANIFOLD_DIR/app-debug.sock` for scripted commands (see
  [DebugControl.swift](Sources/Manifold/DebugControl.swift)).

## Building

```
scripts/build-ghostty.sh    # once: fetches Zig and Ghostty into vendor/, builds Frameworks/
scripts/fetch-fonts.sh      # once: fetches Monaspace, Mona Sans, Recursive and Go into Frameworks/; copies Tiempos Text and Berkeley Mono
scripts/build-app.sh run    # builds build/Manifold.app and opens it
swift test
```

Ghostty is pinned to v1.3.1 with [a small patch](patches/ghostty.patch): Metal
shaders compile at runtime (no Metal toolchain needed), archives are merged in
a way Apple's current `libtool` accepts, a surface can run a command
directly (without `login(1)`), which the attach helper needs, and the
contrast correction above.
