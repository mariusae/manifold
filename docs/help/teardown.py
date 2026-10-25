#!/usr/bin/env python3
"""Draws teardown.svg: Manifold taken apart into layers, seen from above at
an angle — what you see on screen, the spaces under it, the graph of blocks
under those, and the hosts the blocks live on.

Each layer is a plane in its own coordinates (W × H, x right, y down),
projected by one oblique transform and dropped a step below the one above.
A thing that's the same thing on two layers (a tile, its placement, its
block) sits at the same plane point on each, so what joins them is a
straight line down.

    python3 docs/help/teardown.py

writes teardown.svg and teardown-dark.svg, captioned, and teardown-bare.svg
and teardown-bare-dark.svg, the layers alone (for the site, which captions
them in its own words).
"""

from pathlib import Path

W, H = 720, 440                      # a plane, in its own units
AX, AY = 0.92, 0.2                   # the plane's x axis, on the page
BX, BY = -0.40, 0.42                 # its y axis
OX = 250                             # where a plane's origin is, across
TOP, STEP = 70, 250                  # the first plane's origin, down; and each next
PAGE_W, PAGE_H = 1440, TOP + 3 * STEP + H * BY + W * AY + 30

FONT = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO = "'SF Mono', Menlo, monospace"

from types import SimpleNamespace

# Each appearance's colours, by what they're for.
THEMES = {
    "light": dict(
        ink="#1d1d1f", grey="#6e6e73", faint="#a1a1a6", accent="#3373f2", paper="#f5f4f0",
        shadow="#000000", slab_right="#d8d5cc", slab_front="#cbc7bd", plane_edge="#d6d2c8",
        tint_hosts="#efede7", tint_graph="#f7f6f2", tint_spaces="#f3f6fd",
        wash=("#e9e3f7", "#f6e6ec", "#fbeedd"), window_edge="#cfcac0",
        tile="#ffffff", tile_bar="#f3f3f5", tile_edge="#d2d2d7", text2="#3c3c43",
        term="#1f1f22", term_bar="#2c2c2f", term_text="#d8d8d8", term_title="#eeeeee", term_glyph="#aaaaaa",
        sheet="#f2f2f2", sheet_edge="#bdbdbd", capsule="#ffffff", capsule_edge="#c7c7cc",
        frame="#ffffff", placement="#eef3fe", surface="#ffffff", host="#ffffff", host_edge="#bdb8ad",
        k_terminal="#2c2c2e", k_file="#4f7bd9", k_note="#d99a06", k_page="#7a5af8", k_pdf="#d14343",
    ),
    "dark": dict(
        ink="#f2f2f7", grey="#a1a1a8", faint="#6c6c72", accent="#5b8ef7", paper="#161618",
        shadow="#000000", slab_right="#2a2a2e", slab_front="#222226", plane_edge="#3a3a3f",
        tint_hosts="#1f1f22", tint_graph="#232326", tint_spaces="#1f2430",
        wash=("#2a2140", "#3a2030", "#3a2c1c"), window_edge="#46464c",
        tile="#2a2a2d", tile_bar="#333337", tile_edge="#46464c", text2="#c7c7cc",
        term="#151517", term_bar="#232326", term_text="#d8d8d8", term_title="#eeeeee", term_glyph="#8e8e93",
        sheet="#38383c", sheet_edge="#5a5a60", capsule="#2a2a2d", capsule_edge="#55555b",
        frame="#2a2a2d", placement="#22304a", surface="#2a2a2d", host="#2a2a2d", host_edge="#4a4a50",
        k_terminal="#d1d1d6", k_file="#6f97ee", k_note="#e6ac2a", k_page="#9a82fb", k_pdf="#ee6a6a",
    ),
}
C = SimpleNamespace(**THEMES["light"])
KINDS = {}


def use(theme):
    """Takes up an appearance's colours, and the kinds' marks in them."""
    global C, KINDS
    C = SimpleNamespace(**THEMES[theme])
    KINDS = {  # a block's kind: its mark's colour and glyph
        "terminal": (C.k_terminal, ">_"),
        "file": (C.k_file, "{ }"),
        "note": (C.k_note, "¶"),
        "page": (C.k_page, "◐"),
        "pdf": (C.k_pdf, "▤"),
        "space": (C.accent, "▦"),
    }


def P(layer, x, y):
    """A plane point on the page."""
    return (OX + x * AX + y * BX, TOP + layer * STEP + x * AY + y * BY)


def plane(layer):
    """The transform that sets plane coordinates on a layer."""
    return f"matrix({AX} {AY} {BX} {BY} {OX} {TOP + layer * STEP})"


def pts(*ps):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in ps)


out = []
add = out.append


def sheet(layer, tint, label, rect=(0, 0, W, H), face=True):
    """A layer's plane: a thin slab, its edge darker, a soft shadow under it.
    `face`: its top drawn too (the window draws its own)."""
    x0, y0, x1, y1 = rect
    c = [P(layer, x0, y0), P(layer, x1, y0), P(layer, x1, y1), P(layer, x0, y1)]
    d = 5
    shadow = [(x + 10, y + 16) for x, y in c]
    add(f'<polygon points="{pts(*shadow)}" fill="{C.shadow}" opacity="0.05" filter="url(#blur)"/>')
    # The two edges toward us, as the slab's thickness.
    add(f'<polygon points="{pts(c[1], c[2], (c[2][0], c[2][1] + d), (c[1][0], c[1][1] + d))}" fill="{C.slab_right}"/>')
    add(f'<polygon points="{pts(c[2], c[3], (c[3][0], c[3][1] + d), (c[2][0], c[2][1] + d))}" fill="{C.slab_front}"/>')
    if not face:
        return
    add(f'<polygon points="{pts(*c)}" fill="{tint}" fill-opacity="0.92" stroke="{C.plane_edge}" stroke-width="1"/>')
    # The layer's name, set into its far corner.
    add(f'<g transform="{plane(layer)}"><text x="{x1 - 14}" y="{y0 + 22}" text-anchor="end" font-family="{FONT}" '
        f'font-size="13" font-weight="600" letter-spacing="1.2" fill="{C.faint}">{label}</text></g>')


def drop(top_layer, x, y, bottom_layer, faint=False):
    """A line straight down from a point on one layer to the same point below."""
    (x1, y1), (x2, y2) = P(top_layer, x, y), P(bottom_layer, x, y)
    style = f'stroke="{C.faint}" stroke-width="0.8" stroke-dasharray="1.5 3"' if faint else \
        f'stroke="{C.accent}" stroke-width="1" stroke-opacity="0.55" stroke-dasharray="3 3"'
    add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" {style}/>')


def callout(layer, title, lines, at=(W, H * 0.45)):
    """A layer's caption, flat, at the right, joined to the plane's edge."""
    ex, ey = P(layer, *at)
    tx, ty = 1035, ey - 34
    add(f'<polyline points="{pts((ex + 6, ey), (tx - 70, ey), (tx - 14, ty + 8))}" fill="none" stroke="{C.faint}" stroke-width="0.8"/>')
    add(f'<circle cx="{ex + 6:.1f}" cy="{ey:.1f}" r="2.5" fill="{C.faint}"/>')
    add(f'<text x="{tx}" y="{ty + 12}" font-family="{FONT}" font-size="17" font-weight="650" fill="{C.ink}">{title}</text>')
    for i, line in enumerate(lines):
        add(f'<text x="{tx}" y="{ty + 36 + i * 19}" font-family="{FONT}" font-size="13.5" fill="{C.grey}">{line}</text>')


# ---- Layer 0: what you see ---------------------------------------------

WIN = (24, 24, 470, 416)              # the window, on the plane
SIDEBAR = 128
COLS = [(140, 300), (306, 462)]
TILES = {  # name: (column, top, bottom, kind, title, place, lines)
    "terminal": (0, 34, 198, "terminal", "Terminal", "~/src/app", ["$ make test", "ok  32 tests", "$ git status"]),
    "server": (0, 204, 408, "file", "Server.swift", "Sources", ["func serve() {", "  let s = Session()", "  s.start()", "}"]),
    "readme": (1, 50, 230, "page", "README.md", "~/src/app", ["App", "A small server and", "the notes about it."]),
    "plan": (1, 236, 408, "note", "Plan", "", ["Ship the server", "☐ sessions", "☐ the README"]),
}


def screen():
    g = [f'<g transform="{plane(0)}" font-family="{FONT}">']
    x0, y0, x1, y1 = WIN
    g.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" fill="url(#wash)" stroke="{C.window_edge}"/>')
    for i, c in enumerate(["#ff5f57", "#febc2e", "#28c840"]):
        g.append(f'<circle cx="{x0 + 14 + i * 11}" cy="{y0 + 13}" r="3.6" fill="{c}"/>')
    # The sidebar: the spaces, the current one barred, its tiles beneath.
    rows = [("manifold", True, 0), ("Terminal", False, 1), ("Server.swift", False, 1), ("README.md", False, 1),
            ("Plan", False, 1), ("website", False, 0)]
    for i, (name, current, depth) in enumerate(rows):
        y = y0 + 40 + i * 20
        if current:
            g.append(f'<rect x="{x0 + 4}" y="{y - 10}" width="2.5" height="14" rx="1" fill="{C.accent}"/>')
        g.append(f'<text x="{x0 + 12 + depth * 10}" y="{y}" font-size="8.5" font-weight="{600 if depth == 0 else 400}" fill="{C.ink}">{name}</text>')
    g.append(f'<text x="{x0 + 12}" y="{y0 + 54 + 6 * 20}" font-size="7.5" fill="{C.faint}">Pinned: todo.md</text>')
    # A stack's sheets above README: notes.md behind it.
    c0, c1 = COLS[1]
    for k, inset in enumerate([10, 5]):
        g.append(f'<rect x="{c0 + inset}" y="{38 + k * 5}" width="{c1 - c0 - 2 * inset}" height="14" rx="5" fill="{C.sheet}" stroke="{C.sheet_edge}" stroke-width="0.6"/>')
    for name, (col, top, bottom, kind, title, place, lines) in TILES.items():
        a, b = COLS[col]
        color, glyph = KINDS[kind]
        dark = kind == "terminal"
        g.append(f'<rect x="{a}" y="{top}" width="{b - a}" height="{bottom - top}" rx="8" fill="{C.term if dark else C.tile}" stroke="{C.tile_edge}" stroke-width="0.7"/>')
        g.append(f'<rect x="{a}" y="{top}" width="{b - a}" height="18" rx="8" fill="{C.term_bar if dark else C.tile_bar}"/>')
        g.append(f'<rect x="{a}" y="{top + 10}" width="{b - a}" height="8" fill="{C.term_bar if dark else C.tile_bar}"/>')
        g.append(f'<text x="{a + 8}" y="{top + 12.5}" font-size="7" fill="{color if not dark else C.term_glyph}" font-family="{MONO}">{glyph}</text>')
        g.append(f'<text x="{a + 24}" y="{top + 12.5}" font-size="8.5" font-weight="600" fill="{C.term_title if dark else C.ink}">{title}</text>')
        if place:
            g.append(f'<text x="{a + 30 + len(title) * 5}" y="{top + 12.5}" font-size="7.5" fill="{C.faint}">{place}</text>')
        if name == "plan":  # its link to Server.swift, a capsule on the bar
            g.append(f'<rect x="{b - 58}" y="{top + 4}" width="50" height="10" rx="5" fill="{C.capsule}" stroke="{C.capsule_edge}" stroke-width="0.5"/>')
            g.append(f'<text x="{b - 53}" y="{top + 11.6}" font-size="6.3" fill="{C.grey}">→ Server.swift</text>')
        font = MONO if kind in ("terminal", "file") else FONT
        for i, line in enumerate(lines):
            size = 10.5 if (kind == "page" and i == 0) else 8
            weight = 650 if (kind == "page" and i == 0) else 400
            fill = C.term_text if dark else (C.ink if i == 0 or kind != "file" else C.text2)
            g.append(f'<text x="{a + 10}" y="{top + 36 + i * 15}" font-size="{size}" font-weight="{weight}" fill="{fill}" font-family="{font}">{line}</text>')
    g.append("</g>")
    out.extend(g)


def tile_center(name):
    col, top, bottom = TILES[name][:3]
    a, b = COLS[col]
    return (a + b) / 2, (top + bottom) / 2 + 6


# ---- Layer 1: spaces -----------------------------------------------------

def spaces():
    g = [f'<g transform="{plane(1)}" font-family="{FONT}">']

    def frame(x0, y0, x1, y1, name, note):
        g.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="10" fill="{C.frame}" fill-opacity="0.6" stroke="{C.accent}" stroke-width="1.2" stroke-opacity="0.6"/>')
        g.append(f'<rect x="{x0}" y="{y0 - 20}" width="{len(name) * 7 + 22}" height="16" rx="8" fill="{C.accent}"/>')
        g.append(f'<text x="{x0 + 11}" y="{y0 - 8.5}" font-size="9" font-weight="600" fill="#fff">{name}</text>')
        g.append(f'<text x="{x0 + len(name) * 7 + 30}" y="{y0 - 8.5}" font-size="8" fill="{C.grey}">{note}</text>')

    def placement(x0, y0, x1, y1, label, lens, dashed=False):
        dash = ' stroke-dasharray="4 3"' if dashed else ""
        g.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="7" fill="{C.placement}" stroke="{C.accent}" stroke-opacity="0.45" stroke-width="0.9"{dash}/>')
        g.append(f'<text x="{x0 + 9}" y="{y0 + 15}" font-size="8.5" font-weight="600" fill="{C.ink}">{label}</text>')
        g.append(f'<text x="{x0 + 9}" y="{y0 + 27}" font-size="7.5" fill="{C.grey}">{lens}</text>')

    frame(134, 28, 468, 414, "manifold", "a space: its tiles' places")
    lenses = {"terminal": "terminal lens", "server": "editor lens", "readme": "preview lens", "plan": "editor lens"}
    for name, (col, top, bottom, kind, title, *_) in TILES.items():
        a, b = COLS[col]
        placement(a, top, b, bottom, title, lenses[name])
    # notes.md, stacked behind README: a placement too, stashed.
    a, b = COLS[1]
    g.append(f'<rect x="{a + 8}" y="{38}" width="{b - a - 16}" height="9" rx="4" fill="none" stroke="{C.accent}" stroke-opacity="0.45" stroke-dasharray="3 2"/>')
    g.append(f'<text x="{a + 14}" y="{45.5}" font-size="6.5" fill="{C.grey}">notes.md, stashed behind</text>')
    # A pin: kept by the space, with no tile.
    g.append(f'<rect x="{32}" y="{318}" width="92" height="30" rx="7" fill="{C.surface}" stroke="{C.accent}" stroke-opacity="0.6" stroke-dasharray="4 3"/>')
    g.append(f'<text x="{42}" y="{331}" font-size="8.5" font-weight="600" fill="{C.ink}">📌 todo.md</text>')
    g.append(f'<text x="{42}" y="{342}" font-size="7.2" fill="{C.grey}">pinned, no tile</text>')
    frame(498, 70, 704, 330, "website", "another space")
    placement(508, 80, 694, 196, "Terminal", "on devbox · npm run dev")
    placement(508, 202, 694, 320, "localhost:3000", "web lens")
    g.append("</g>")
    out.extend(g)


# ---- Layer 2: the graph ---------------------------------------------------

NODES = {  # name: (x, y, kind, title, alive)
    "space": (173, 16, "space", "manifold", True),
    "website": (533, 58, "space", "website", True),
    "terminal": (*tile_center("terminal"), "terminal", "Terminal", True),
    "server": (*tile_center("server"), "file", "Server.swift", True),
    "readme": (*tile_center("readme"), "page", "README.md", True),
    "plan": (*tile_center("plan"), "note", "Plan", True),
    "notes": (420, 54, "file", "notes.md", True),
    "todo": (78, 333, "note", "todo.md", True),
    "design": (436, 408, "pdf", "design.pdf", True),
    "devterm": (601, 138, "terminal", "Terminal", True),
    "site": (601, 261, "page", "localhost:3000", True),
    "old": (606, 398, "file", "old.log", False),
}

EDGES = [  # (from, to, strong, label)
    ("space", "terminal", True, None),
    ("space", "server", True, None),
    ("space", "readme", True, "placed"),
    ("space", "plan", True, None),
    ("space", "notes", True, None),
    ("space", "todo", True, "pinned"),
    ("website", "devterm", True, "placed"),
    ("website", "site", True, None),
    ("plan", "server", True, "linked by hand"),
    ("plan", "design", True, "linked by hand"),
    ("terminal", "server", False, "opened"),
    ("readme", "notes", False, "mentions"),
    ("devterm", "site", False, "opened"),
    ("terminal", "old", False, "printed"),
]


def node_at(name):
    x, y = NODES[name][:2]
    return P(2, x, y)


def graph():
    add(f'<g font-family="{FONT}">')
    for a, b, strong, label in EDGES:
        (x1, y1), (x2, y2) = node_at(a), node_at(b)
        dead = not NODES[b][4]
        if strong:
            style = f'stroke="{C.accent}" stroke-width="1.6"'
        else:
            style = f'stroke="{C.faint if dead else C.grey}" stroke-width="1.1" stroke-dasharray="4 3.5"'
        add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" {style}/>')
        if label:
            mx, my = (x1 + x2) / 2, (y1 + y2) / 2
            w = len(label) * 5.6 + 10
            add(f'<rect x="{mx - w / 2:.1f}" y="{my - 7:.1f}" width="{w:.1f}" height="13" rx="6.5" fill="{C.paper}" opacity="0.92"/>')
            add(f'<text x="{mx:.1f}" y="{my + 3:.1f}" text-anchor="middle" font-size="9.5" font-style="italic" fill="{C.accent if strong else C.grey}">{label}</text>')
    for name, (x, y, kind, title, alive) in NODES.items():
        px, py = P(2, x, y)
        color, glyph = KINDS[kind]
        if kind == "space":
            add(f'<rect x="{px - 13:.1f}" y="{py - 13:.1f}" width="26" height="26" rx="7" fill="{C.accent}"/>')
            add(f'<text x="{px:.1f}" y="{py + 4.5:.1f}" text-anchor="middle" font-size="13" fill="#fff">{glyph}</text>')
            add(f'<text x="{px + 19:.1f}" y="{py + 4:.1f}" font-size="11.5" font-weight="650" fill="{C.accent}">{title}</text>')
            continue
        op = "1" if alive else "0.45"
        add(f'<g opacity="{op}">')
        dash = "" if alive else ' stroke-dasharray="2.5 2"'
        add(f'<circle cx="{px:.1f}" cy="{py:.1f}" r="11" fill="{C.surface}" stroke="{color}" stroke-width="1.6"{dash}/>')
        add(f'<text x="{px:.1f}" y="{py + 3.2:.1f}" text-anchor="middle" font-size="8.5" font-family="{MONO}" fill="{color}">{glyph}</text>')
        add(f'<text x="{px + 16:.1f}" y="{py + 4:.1f}" font-size="11" font-weight="600" fill="{C.ink}">{title}</text>')
        if not alive:
            add(f'<text x="{px + 16:.1f}" y="{py + 17:.1f}" font-size="9.5" font-style="italic" fill="{C.grey}">nothing keeps it: collected in 30 min</text>')
        add("</g>")
    add("</g>")


# ---- Layer 3: hosts --------------------------------------------------------

HOSTS = [  # (x0, y0, x1, y1, name, detail)
    (16, 16, 482, 424, "This Mac", "manifoldd · ~/Library/Application Support/Manifold"),
    (494, 16, 704, 424, "devbox", "manifoldd over ssh"),
]


def host_of(x):
    return 0 if x < 488 else 1


def hosts():
    g = [f'<g transform="{plane(3)}" font-family="{FONT}">']
    for x0, y0, x1, y1, name, detail in HOSTS:
        g.append(f'<rect x="{x0}" y="{y0}" width="{x1 - x0}" height="{y1 - y0}" rx="12" fill="{C.host}" fill-opacity="0.55" stroke="{C.host_edge}" stroke-width="1"/>')
        g.append(f'<text x="{x0 + 14}" y="{y1 - 28}" font-size="15" font-weight="650" fill="{C.ink}">{name}</text>')
        g.append(f'<text x="{x0 + 14}" y="{y1 - 13}" font-size="8.5" fill="{C.grey}">{detail}</text>')
    g.append("</g>")
    out.extend(g)
    # Under every block, its log: a little stack of entries.
    for name, (x, y, kind, title, alive) in NODES.items():
        px, py = P(3, x, y)
        op = 1 if alive else 0.4
        for k in range(3):
            add(f'<rect x="{px - 9:.1f}" y="{py - 6 + k * 4:.1f}" width="18" height="3" rx="1.2" fill="{C.grey}" opacity="{op * (0.35 + 0.2 * k):.2f}"/>')


# ---- The page --------------------------------------------------------------

def draw(theme, callouts=True):
    """The whole figure in an appearance; without the callouts, only as wide
    as the layers (for a page that captions it itself)."""
    use(theme)
    out.clear()
    width = PAGE_W if callouts else 940
    add(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {PAGE_H:.0f}" width="{width}" height="{PAGE_H:.0f}">')
    add(f'''<defs>
  <filter id="blur" x="-10%" y="-10%" width="120%" height="120%"><feGaussianBlur stdDeviation="8"/></filter>
  <linearGradient id="wash" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{C.wash[0]}"/><stop offset="0.55" stop-color="{C.wash[1]}"/><stop offset="1" stop-color="{C.wash[2]}"/>
  </linearGradient>
</defs>''')
    if callouts:
        add(f'<rect width="100%" height="100%" fill="{C.paper}"/>')

    # Bottom up, each layer over the lines rising from the one beneath.
    sheet(3, C.tint_hosts, "HOSTS")
    hosts()
    for x, y, *_ in NODES.values():
        drop(2, x, y, 3, faint=True)
    sheet(2, C.tint_graph, "THE GRAPH")
    graph()
    for name in TILES:
        drop(1, *tile_center(name), 2)
    for name in ("space", "website", "todo"):
        drop(1, *NODES[name][:2], 2)
    sheet(1, C.tint_spaces, "SPACES")
    spaces()
    for name in TILES:
        drop(0, *tile_center(name), 1)
    sheet(0, C.tile, "", rect=WIN, face=False)
    screen()

    if callouts:
        callout(0, "What you see", at=(WIN[2], WIN[1] + (WIN[3] - WIN[1]) * 0.45),
                lines=["Tiles in a grid. Each shows a block through a lens —",
                       "a terminal, an editor, a preview — under a bar",
                       "with its title and its links."])
        callout(1, "Spaces", ["A space arranges placements: which block, through",
                              "which lens, where. A pin keeps a block without a tile.",
                              "A space stays until you remove it."])
        callout(2, "The graph", ["Blocks, and the links between them. Solid links keep",
                                 "what they reach — placed, pinned, linked by hand;",
                                 "dashed ones are history — opened, mentioned, printed.",
                                 "What no space reaches is collected after half an hour."])
        callout(3, "Hosts", ["Every block lives on a host — this Mac, a dev box —",
                             "as an append-only log its server keeps.",
                             "One window shows blocks from many."])
    add('</svg>')
    return "\n".join(out)


here = Path(__file__).parent
for theme, suffix in (("light", ""), ("dark", "-dark")):
    for callouts, kind in ((True, ""), (False, "-bare")):
        path = here / f"teardown{kind}{suffix}.svg"
        path.write_text(draw(theme, callouts))
        print("wrote", path)
