# Manifold

A Mac app that is a desk rather than a set of windows. Terminals (drawn by
[libghostty](https://github.com/ghostty-org/ghostty)), files, notes,
folders and web pages are **blocks**; you arrange blocks to work, and an
arrangement is itself a block you can name and come back to. Nothing is
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
  top to move the window. Under **Desk**, each arrangement expands to
  its tiles in order, the selected one open and the focused tile
  highlighted, so the sidebar is the table of contents of the screen:
  click a tile to focus it, an arrangement to go to it, double-click
  one to name it; drag a block from anywhere in the sidebar onto a tile
  to bring it in beside, onto an arrangement for its active column, or
  between arrangements for one of its own, and drag arrangements to
  reorder them.
- An **arrangement** is a grid (DESIGN.md §3.1): columns of tiles,
  every tile a block, all of them visible, as acme tiles its windows.
  An arrangement is what you made it: a block brought in stays until
  you take it off (⌘W), and nothing is tidied away. A new tile lands
  below the biggest tile of the active column, taking its lower half;
  Arrangement ▸ Grow Tile (⌃⌘=) takes a step from its neighbors; Fill
  the Column (⌃⇧⌘=) gives it the whole column and **stashes** the
  others: their pills bunch in a small stack under its pill, fan out
  when the pointer rests on it, and one clicked comes back (Stash, in a
  pill's menu, puts a tile away the same way). Maximize Tile (⇧⌘↩, or
  the ⤢ at the right of a pill) puts a tile over the whole arrangement
  until it is restored. Drag the lines between tiles and columns to
  resize them. Each tile wears a **pill** floating over its top, one
  width for all, with its symbol, name and status glyph: drag it to
  move the tile, click it for the tile's menu. ⌥⌘[ and ⌥⌘] move the
  focus between tiles.
- Two verbs put a block in front of you. **Go to** finds it where it
  already is: the arrangement it is in (this one if it is here, else
  the one most recently settled on) is selected and the tile focused.
  **Bring here** makes a tile of it in this arrangement; if it is here
  already, that tile is focused. A row clicked in the sidebar, or
  chosen in the finder (⌘O), goes to the block if it is placed anywhere,
  else brings it here; ⌘-click, Bring Here in the menu, and a drag onto
  the grid always bring (a drop between two tiles lands there). Opening
  something from inside a block — ⌘-click a path in a terminal, follow
  a link, a search hit, a change in a git block, a definition — brings
  it below the opener, taking its lower half, and links the two; a
  preview going page to page and a listing going into a folder change
  in place. New things (⌘N a terminal, ⇧⌘N a note, a search, an agent)
  are brought here; ⌥⌘T starts a new arrangement with a terminal.
  **Go Back** and **Go Forward** (⌘[ ⌘]) walk the trail across tiles
  and arrangements.
- **⌃⇥** walks the arrangements most recently settled on first, each
  sliding in from the right (⌃⇧⇥ from the left), for as long as control is
  held; letting go settles on the one come to. ⌘1–9 and ⇧⌘[ / ⇧⌘] switch
  arrangements too.
- Drag a tile by its pill: between two tiles to put it there, near a
  column's side for a new column there, onto an arrangement in the
  sidebar for its active column, or between arrangements for one of
  its own. Arrangements drag from the sidebar onto the grid the same
  way, their columns coming over.
- **⌘W** takes the focused tile off its arrangement; **⇧⌘W** takes the
  arrangement off the desk. Neither loses anything: the block, with its
  history, is a ⌘O away. There is no Close.

## Nothing is closed

Every block has a log: its edits, where it was placed, what it was named.
What you aren't using is tidied away rather than closed, and comes back
when you find it again.

- **⌘O finds anything** the host knows, ranked by where you are: what's
  linked to the focused block (opened from it, placed with it, compared
  against it) comes first, nearest first and the most recently joined
  first among them, with nothing typed; a match near it outranks one far
  from it. Then blocks by title and path, named
  arrangements, terminals by where they are, and the files under the
  focused block's folder, ranked by how well they match and how recently
  they were seen. Choosing a block shows it here, in the focused column;
  choosing an arrangement puts it on the desk.
  A typed URL opens as a web page.
- **Naming keeps.** An unnamed arrangement is scratch: blocks unseen for a
  while leave nothing: nothing in an arrangement is tidied away; an
  unnamed one emptied by hand leaves the desk. Name one (⇧⌘R, or double-click it in the sidebar)
  and it's kept as it is until you change it. Named arrangements wear a
  bookmark in the sidebar.
- **Terminals go dormant**, not away: a terminal off screen with an idle
  shell for eight hours (View ▸ End Idle Shells) has its shell ended and
  its transcript kept. Brought back, it starts a new shell under the old
  transcript, with a line across it saying when the last one ended and
  after how long idle, so it's never a surprise. The finder says
  *dormant* before you go to one.
- **⌘Y** shows an arrangement's history: a slider through every change,
  the arrangement drawn as it was, and Restore, which appends what makes it
  so again (a new version, never a revert).
- Blocks are linked by what you do: ⌘-clicking a file in a terminal links
  the two, and the palette lists what's linked to the focused block.

## Blocks

- **Terminals** run `manifoldd attach <block>`, which connects them to a
  shell the server owns, so quitting and reopening the app brings every
  terminal back with the same processes still running.
- **Text** blocks are files on the host, or notes (text with no file; ⌘S
  on one asks where to save it). The **editor** lens is Manifold's own
  text view: the file's text laid out with Core Text, line numbers, several
  cursors (⌘D selects the next occurrence; ⌃⇧↑/↓ add carets; ⌥-click
  adds one), find and replace (⌘F, ⌥⌘F; every match marked), Go to Line
  (⌘L), line operations (move ⌃⌘↑/↓, duplicate ⇧⌘D, delete ⌃⇧K, join ⌃J,
  comment ⌘/, indent and outdent with Tab and ⇧Tab over a selection),
  brackets and quotes paired, new lines indented like the last, undo as
  entries in the block's log (undone back to what was saved, it's clean
  again). Files keep their encoding, line endings and permissions. One
  changed on disk reloads if clean, or shows a banner over unsaved
  changes. The **preview** lens renders Markdown (cmark-gfm) and follows
  the text as it's edited in an editor on the same block, or saved by
  another program. Edit ▸ Edit or Preview (⌥⌘P) turns the focused
  preview into an editor in place, or a Markdown editor back into a
  preview; ⌥⇧⌘P puts the other beside it, so you can type on the left
  and read on the right. A link followed in a preview opens another
  Markdown file in the same tile (Go Back returns to the one it came
  from), a web address as a web block below it, any other file as what
  it is, below; `#anchors` scroll.
- **HTML files** open as web blocks, read from the file with their
  folder (so their images and stylesheets work), from a terminal, the
  finder, a folder listing, a link in a preview, or the `manifold`
  command. View ▸ Editor Font chooses proportional or fixed
  width; View ▸ Theme the fonts: **Notes** (the default: SF Pro with its
  single-story "a", as Apple's Notes sets its text, Menlo for fixed
  width, the system font for the UI), Tiempos (Tiempos Text, Berkeley
  Mono), Mona (Mona Sans, Monaspace), Recursive, Go, or System (SF, SF
  Mono). All but SF are bundled; Tiempos Text and Berkeley Mono are
  licensed, so the build copies them from your own fonts (`TIEMPOS_DIR`
  and `BERKELEY_DIR`, by default their folders in iCloud Drive's Fonts)
  rather than fetching them.
- **Language servers** run on the file's host, one per language and
  workspace root, started when a file of theirs is placed: what they say
  is underlined, marked in the gutter and spelled out along the bottom
  when the caret is on it. Edit ▸ Code: Complete (⌃Space), Go to
  Definition (⌃⌘J, or ⌘-click), Find References (⌃⌘R), Show Documentation
  (⌃⌘H), Rename Symbol… (⌃⌘N; other files change through their blocks, or
  on disk when they aren't open), Format Document (⌃⌘F). Manifold ▸
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
  to open it, ⌘↑ for the folder above.
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
  By, ⌥⌘1–5): **Desk** — the arrangements, as before; **Files** — every
  block with a path under its folders, across hosts, as a sparse tree
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
  *compared*, *mentions*, *also in* (other arrangements holding it),
  *before* and *after* (what you went to around it, from the trail), each
  row with what made the link (the ⌘-clicked line, the search hit, the
  editor line that named a definition) and when. Window ▸ Go Back and Go
  Forward (⌃⌘[, ⌃⌘]) walk the trail across columns and arrangements:
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
  glyph says it wherever a block is named — a thin arc turning (or
  filling, when the program says how far) for working, an amber ring
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
  to bring it to the arrangement you were in, ⎋ (or ×) to go back.
  From a shell:

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
- **History** (Arrangement ▸ History…, ⌘Y) scrubs the arrangement through
  its log: the layout then, the blocks as they are now; with **Everything
  as it was** checked, each placed file is read as of that moment too, and
  Restore brings both back — as new entries, never a revert. History of
  This File… (⌥⌘Y) scrubs the focused file through every change it's had
  in Manifold: Restore This Text puts a version back (one undoable edit);
  Compare with Now opens a diff block of then against now.
- **Web pages** open in an embedded browser when a URL is ⌘-clicked in a
  terminal, typed in the finder, or asked for in the palette: an address
  bar, back and forward, and its pages in its log.
- **Images and PDFs** open in their own lenses, their bytes from the
  file's host: images fit the view and zoom (⌘+/−, a pinch; double-click
  for actual size), PDFs page in PDFKit.
- **Agents** (File ▸ New Agent, ⌥⌘A) are terminal blocks that run the
  agent command (`claude` unless the settings say otherwise) in a login
  shell where the focused block is; their transcripts are kept like a
  terminal's, and they come back after a restart the same way.
- **Processes** (File ▸ Processes) is a block per host listing what `ps`
  sees, again every few seconds while shown: filter, sort by column, End
  (SIGTERM) or Force End (SIGKILL) the selected one.

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
mirrors the host's shards and **leads** the ones it edits — arrangements,
text, the desk — appending entries locally first, so nothing waits on a
round trip; the host leads terminals and folders and does the file system
work (reading, writing, watching) on proposal. Both apply the same entries
with the same code, so they agree. State from before blocks (`state.json`)
is migrated into logs on first run.

- **End All Sessions and Quit** (in the app menu or the sidebar's ⋯ menu)
  stops the server; everything is kept, and terminals start fresh shells
  next time. Manifold ▸ Restart Server… restarts it (offered when the app
  finds a server from another version).
- **Remote hosts** (Manifold ▸ Attach to Host…, ⇧⌘K) work as apex's do: a
  destination ssh understands, or `provider:name` for a
  `manifold-remote-<provider>` command on the PATH that takes a destination
  and a command to run there. Manifold asks the host what it is, installs
  the bundled `manifoldd` for it in `~/.manifold/bin` if the one there
  differs, and runs `manifoldd bridge`, which pumps the same frames between
  the pipe and the host's own server (started if need be). Blocks are
  `host/ulid`, so a remote terminal, file or folder is placed, linked and
  found like a local one; its terminals attach through the same provider.
  Hosts are remembered in `hosts.json` and attached again at start. Linux
  servers (x86_64 and aarch64, static) come from `scripts/build-linux.sh`.
- **`$EDITOR`** in Manifold's shells is `manifold --wait` (on a remote
  host, `manifoldd open --wait`): `git commit` and friends edit beside
  the terminal and return when it's taken off (⌘W).
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
