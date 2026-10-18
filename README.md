# Manifold

A Mac app that is a desk rather than a set of windows. Terminals (drawn by
[libghostty](https://github.com/ghostty-org/ghostty)), files, notes,
folders and web pages are **blocks**; you arrange blocks to work, and an
arrangement is itself a block you can name and come back to. Nothing is
closed: what isn't in use is tidied out of the way, and anything can be
found and recalled, with its history. Light or dark, in
[Monaspace](https://monaspace.githubnext.com) and Mona Sans (bundled).
[DESIGN.md](DESIGN.md) says where it's going.

## Using it

- The window is all content. Move the mouse to its left edge and the
  sidebar slides out over it: the window buttons, the **desk** (your
  arrangements), and **New**. It slides away again when the mouse leaves.
  ⌃⌘S (or the button at its top right) shows or hides it for good; drag its
  right edge to resize it, and its top to move the window.
- An **arrangement** is a row of columns of blocks. Shown as **stacks**
  (the default), each column shows its top block, with the edges of the
  ones beneath peeking out above it like a stack of paper: hover the edges
  to list them, click one to raise it. Shown as **tiles** (Arrangement ▸
  Show as Tiles, ⌃⌘2), every block in a column is visible, top to bottom,
  each with a title bar to grab it by and lines between to resize. Shown
  as a **list** (⌃⌘3), one row per block, with the chosen one beneath.
  Switching lens changes nothing in the arrangement.
- A new terminal goes on the focused column's stack (⌘N), in a new column
  beside it (⌘D), or in a new arrangement (⌥⌘T), starting in the focused
  block's directory. ⇧⌘N makes a note. ⌘T opens the palette, which offers
  those first, then whatever is linked to the focused block, then the desk.
- **⌘E** turns the focused stack into a file of cards, live: the top sheet
  drops flat to the bottom and the one beneath it stands up in front. More
  E's flip further down (⇧E back up; ⇧⌘E starts from the bottom), and
  letting go of ⌘ brings the chosen one forward.
- **⌃⇥** walks the arrangements most recently settled on first, each
  sliding in from the right (⌃⇧⇥ from the left), for as long as control is
  held; letting go settles on the one come to. ⌘1–9 and ⇧⌘[ / ⇧⌘] switch
  arrangements too.
- Drag a block by its top edge (a stack's edges, a tile's title bar, or a
  buried one by its row in the list): onto a column's middle to push it
  onto that stack, near a column's side for a new column there, onto an
  arrangement in the sidebar for its focused stack, or between arrangements
  for one of its own. Arrangements drag from the sidebar onto the window
  the same way; Separate Columns splits one back up.
- **⌘W** takes the focused block off its arrangement; **⇧⌘W** takes the
  arrangement off the desk. Neither loses anything: the block, with its
  history, is a ⌘O away. There is no Close.

## Nothing is closed

Every block has a log: its edits, where it was placed, what it was named.
What you aren't using is tidied away rather than closed, and comes back
when you find it again.

- **⌘O finds anything** the host knows: blocks by title and path, named
  arrangements, terminals by where they are, and the files under the
  focused block's folder, ranked by how well they match and how recently
  they were seen. Choosing a block places it beside the focused terminal,
  or on the focused stack; choosing an arrangement puts it on the desk.
  A typed URL opens as a web page.
- **Naming keeps.** An unnamed arrangement is scratch: blocks unseen for an
  hour leave it (View ▸ Tidy Unused Blocks Away sets how long), unless they
  have unsaved changes or a running job, and terminals never do; emptied,
  it leaves the desk. Name one (⇧⌘R, or double-click it in the sidebar)
  and it's kept as it is until you change it. Named arrangements wear a
  bookmark in the sidebar.
- **Terminals go dormant**, not away: a terminal off screen with an idle
  shell for eight hours (View ▸ End Idle Shells) has its shell ended and
  its transcript kept. Brought back, it starts a new shell under the old
  transcript, with a line across it saying when the last one ended and
  after how long idle, so it's never a surprise. The finder and the tiles'
  title bars say *dormant* before you go to one.
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
  another program. View ▸ Editor Font chooses proportional (Mona Sans) or
  fixed width; View ▸ Theme the fonts.
- **⌘-click** a file's name in a terminal to open it beside the terminal,
  on the stack to its right: Markdown in a preview, folders in a listing,
  text to edit; `path:line:column` (as grep and compilers print it) goes to
  that place. The **`manifold`** command (Manifold ▸ Install Command Line
  Tool…) does the same from a shell: `manifold README.md src/`.
- **Folders** open in a listing (name, date, size); double-click an entry
  to open it, ⌘↑ for the folder above.
- **Web pages** open in an embedded browser when a URL is ⌘-clicked in a
  terminal, typed in the finder, or asked for in the palette: an address
  bar, back and forward, and its pages in its log.

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
scripts/fetch-fonts.sh      # once: fetches Monaspace, Mona Sans, Recursive and Go into Frameworks/
scripts/build-app.sh run    # builds build/Manifold.app and opens it
swift test
```

Ghostty is pinned to v1.3.1 with [a small patch](patches/ghostty.patch): Metal
shaders compile at runtime (no Metal toolchain needed), archives are merged in
a way Apple's current `libtool` accepts, a surface can run a command
directly (without `login(1)`), which the attach helper needs, and the
contrast correction above.
