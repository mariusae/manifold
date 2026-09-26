# Manifold

A Mac app for hosting many kinds of views. For now: terminals, drawn by
[libghostty](https://github.com/ghostty-org/ghostty), in light colors and
[Monaspace](https://monaspace.githubnext.com) (Xenon, with Radon for italics),
which is bundled with the app.

## Using it

- The window is all content. Move the mouse to its left edge and the sidebar
  slides out over it: the window buttons, your tabs, and **New Tab**. It slides
  away again when the mouse leaves. ⌃⌘S (or the button at its top right) shows
  or hides it for good; drag its right edge to resize it, and its top to move
  the window.
- **New Tab** (⌘T) opens the palette: open a terminal, or type to find a tab.
  ⌥⌘T opens a terminal directly.
- A tab is a row of columns, and each column is a **stack**: only its top
  pane shows, with the edges of the ones beneath peeking out above it like a
  stack of paper. Hover the edges to list them, click one to raise it (click
  the edges to raise the one just beneath); ⌘E cycles through the stack;
  ⌘W pops the top.
- Drag a tab from the sidebar onto the window: near a column's side to make a
  new column there, in its middle to push onto its stack. A tab with columns
  shows how many in the sidebar, and its branch button (or **Separate
  Columns**) splits it back into tabs. ⌘D opens a terminal in a new column to
  the right; ⌘[ and ⌘] move between columns; drag the line between them to
  resize. The focused column is underlined.
- Double-click a tab (or right-click it, or ⇧⌘R) to rename it. Drag tabs to
  reorder them. ⌘W closes the focused pane, ⇧⌘W the whole tab; ⌘1–9 and
  ⇧⌘[ / ⇧⌘] switch tabs.

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
- **⌘O** (or Open Markdown File… in the palette) picks one.

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
scripts/fetch-fonts.sh      # once: fetches Monaspace into Frameworks/monaspace
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
