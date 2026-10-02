# Manifold

A Mac app for hosting many kinds of views. For now: terminals, drawn by
[libghostty](https://github.com/ghostty-org/ghostty), light or dark, in
[Monaspace](https://monaspace.githubnext.com) (Xenon, with Radon for italics),
which is bundled with the app.

## Using it

- The window is all content. Move the mouse to its left edge and the sidebar
  slides out over it: the window buttons, your tabs, and **New Tab**. It slides
  away again when the mouse leaves. ⌃⌘S (or the button at its top right) shows
  or hides it for good; drag its right edge to resize it, and its top to move
  the window.
- A new terminal goes on the focused column's stack (⌘N), in a new column
  beside it (⌘D), or in a new tab (⌥⌘T), starting in the focused pane's
  directory. ⌘T opens the palette, which offers those three first (⏎ for
  ⌘N's), or finds a tab by typing.
- A tab is a row of columns, and each column is a **stack**: only its top
  pane shows, with the edges of the ones beneath peeking out above it like a
  stack of paper. Hover the edges to list them, click one to raise it (click
  the edges to raise the one just beneath); ⌘W pops the top.
- **⌘E** turns the focused stack into a file of cards, within its column,
  live: the top sheet drops flat to the bottom and the one beneath it
  stands up in front, leaning back, with the title bars of the rest behind
  it. More E's flip further down (⇧E back up; scrolling works too; ⇧⌘E starts
  from the bottom, going up), and
  letting go of ⌘ brings the chosen one forward to the top (Escape leaves
  things be).
- Stacked columns keep their top sheets level with each other, however
  many sheets each has beneath.
- Sheets are meant to be many and cheap: one not seen for an hour, with
  nothing unsaved, is put away (terminals never are). View ▸ Put Away Unused
  Sheets changes how long, or turns it off.
- Drag a sheet by its top edge (a lone pane's thin top band, or a stack's
  edges for its top sheet; a buried one by its row in the list): onto a
  column's middle to push it onto that stack, near a column's side for a new
  column there, onto a tab in the sidebar for that tab's stack, or between
  tabs for a tab of its own. Drag to the window's left edge to bring out the
  sidebar. Tabs drag from the sidebar onto the window the same way. A tab with columns
  shows how many in the sidebar, and its branch button (or **Separate
  Columns**) splits it back into tabs. ⌘D opens a terminal in a new column to
  the right; ⌘[ and ⌘] move between columns; drag the line between them to
  resize. The focused column is underlined.
- Double-click a tab (or right-click it, or ⇧⌘R) to rename it. Drag tabs to
  reorder them. ⌘W closes the focused pane, ⇧⌘W the whole tab; ⌘1–9 and
  ⇧⌘[ / ⇧⌘] switch tabs.
- **⌃⇥** walks the tabs most recently settled on first, each sliding in from
  the right as the one it replaces slides out, live (⌃⇧⇥ the other way, from
  the left), for as long as control is held; letting go settles on the one
  come to. So one ⌃⇥ goes back to the last tab, and another comes back. The
  tabs passed on the way don't count as settled on, and Escape goes back to
  where the walk began.

## Markdown

Markdown files open in a live preview, which follows the file as it's saved
(scroll position kept), rendered as GitHub does (cmark-gfm: tables, task
lists, footnotes; front matter hidden). Links to other Markdown files open in
the same preview, others in their usual apps.

- **⌘-click** a Markdown file's name in a terminal (`README.md`,
  `docs/notes.md`, ...) to preview it beside the terminal: pushed onto the
  stack of the column to its right (or a new column, if there's none), or
  raised there if it's already on it.
- **`manifold file.md`** does the same from a shell: beside the terminal
  when run in one of Manifold's, else in a tab of its own, bringing Manifold
  forward (starting it if need be). Manifold ▸ Install Command Line Tool…
  links it into `/usr/local/bin`.
- **⌘O** finds one by name, as below.

## Editing

Files open to edit in an editor sheet: plain text, no highlighting, set in
[Mona Sans](https://github.com/github/mona-sans) (bundled) or, by View ▸
Editor Font, in Monaspace Xenon. It does what a Mac editor does: undo, find
and replace (⌘F, ⌥⌘F, ⌘G), Save (⌘S) and Revert to Saved, Go to Line (⌘L),
bigger and smaller text, new lines indented like the last. Files keep their
encoding, line endings, and permissions. A file changed on disk reloads, or,
with unsaved changes, offers to. Closing a file with unsaved changes asks, as
Mac apps do; quitting doesn't need to, as unsaved changes (and the selection
and scroll position) are kept and come back. A tab with unsaved changes has
a dot in the sidebar.

- **⌘-click** a file's name in a terminal to edit it beside the terminal, on
  the stack to its right; `path:line` and `path:line:column` (as grep and
  compilers print them) go to that place (Markdown files preview instead; the palette's Edit
  This File edits one, and Preview This File previews one being edited).
- **⌘O** finds a file by name under the focused pane's folder, listed
  nearest first (from git, respecting `.gitignore`, in a repository), or
  takes a path. It opens beside a terminal, or on a file's own stack.

## Light and dark

**View ▸ Appearance** follows the system (the default), or keeps to Light or
Dark. Everything goes with it, as it switches: the window and sidebar, the
editor, Markdown, and terminals, which take GitHub's dark palette on dark
paper (and tell programs that ask, by mode 2031); contrast correction works
against either.

## Themes

**View ▸ Theme** sets everything in a pair of fonts: terminals in its
fixed-width font, the editor in either (View ▸ Editor Font), and Markdown in
the proportional one with code in the fixed-width one. The themes are fixed:

- **Mona** (the default): Mona Sans, and Monaspace Xenon with Radon italics
  and stylistic sets 2, 3, 7 and 8.
- **Recursive**: Recursive Sans and Recursive Mono (the Linear styles).
- **Go**: Go and Go Mono.
- **System**: SF and SF Mono (Terminal.app's copy, used in place).

## Contrast correction

Programs pick their colors for dark terminals, so on light paper `fd`'s greens
or an `ls`'s yellows can't be read. Manifold checks each cell's text against
its background as it's drawn and, where they don't reach WCAG AA (4.5:1),
moves the text's color in Oklab lightness until they do. Its hue and chroma
are kept, and nudged toward the nearest theme color. It lands past the
threshold by half as far again as it started short, so colors a program tells
apart stay apart. With deuteranopia correction (the default), the text must
also read as a deuteranope sees it. **View ▸ Contrast Correction** switches
between that, typical vision only, and off. This is a port of apex's
`contrast.rs`, in [the Ghostty patch](patches/ghostty.patch)
(`src/renderer/manifold_contrast.zig`, with its tests).

## Client and server

Everything lives in `manifoldd`, a server the app starts when it isn't running
and that outlives it. The app only draws the server's state and sends it
changes (`Command`s, in [Model.swift](Sources/ManifoldCore/Model.swift)).

- The server owns every shell, on pseudo-terminals of its own. Each terminal in
  the app runs `manifoldd attach <pane>`, which connects it to its shell and
  replays the shell's recent output, so quitting and reopening the app brings
  back every tab, split, and screen exactly as it was, with the same processes
  still running.
- The workspace is saved to `~/Library/Application Support/Manifold/state.json`,
  and each pane's recent output beside it in `history/`. If the server itself
  goes away (a restart), the app starts a new one; each pane gets a new shell in
  its last directory, under its old output.
- **End All Sessions and Quit** (in the app menu or the sidebar's ⋯ menu) stops
  the server; tabs are kept and start fresh shells next time.

Protocol: length-prefixed frames over a Unix socket
([Protocol.swift](Sources/ManifoldCore/Protocol.swift)); JSON for state and
commands, raw bytes for terminal I/O.

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

`manifoldd state` prints the workspace; `manifoldd stop` ends the server.
Manifold ▸ Restart Server… restarts it (the app offers to when it finds one
from another version still running): tabs are kept, shells start again.
`MANIFOLD_DIR` runs everything against another directory, for a second,
throwaway instance; with `MANIFOLD_DEBUG` set too, the app listens on
`$MANIFOLD_DIR/app-debug.sock` for scripted commands (see
[DebugControl.swift](Sources/Manifold/DebugControl.swift)).
