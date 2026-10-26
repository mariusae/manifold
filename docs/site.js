// Manifold's page, working as Manifold does: a space of tiles in columns,
// each a block under a bar; links that open by the one rule (plain goes to
// it, ⌘ beside, ⌥ over); stacks; the shrink ladder; Open Quickly.
"use strict";

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const html = (s) => { const t = document.createElement("template"); t.innerHTML = s.trim(); return t.content.firstElementChild; };
const narrow = () => matchMedia("(max-width: 860px)").matches;
const BAR = 30, GAP = 8;

// ---- Blocks: one per template --------------------------------------------

const BLOCKS = {};
for (const t of $$("template[data-block]")) {
  const d = t.dataset;
  BLOCKS[d.block] = {
    id: d.block, kind: d.kind, title: d.title, place: d.place || "", note: d.note || "",
    summary: (d.summary || "").split("|").map((s) => s.trim()).filter(Boolean),
    lens: d.lens || "", template: t, text: t.content.textContent.replace(/\s+/g, " ").toLowerCase(),
  };
}

const ICONS = {
  terminal: '<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M4.5 6l2 2-2 2M8 10.5h3.5"/>',
  note: '<rect x="2.5" y="1.5" width="11" height="13" rx="2"/><path d="M5 5h6M5 8h6M5 11h4"/>',
  page: '<path d="M4 1.5h5l3.5 3.5v8a1.5 1.5 0 0 1-1.5 1.5H4A1.5 1.5 0 0 1 2.5 13V3A1.5 1.5 0 0 1 4 1.5z"/><path d="M9 1.5V5h3.5M5 9h6M5 11.5h4"/>',
  file: '<path d="M6 4L2.5 8 6 12M10 4l3.5 4-3.5 4"/>',
  folder: '<path d="M1.5 4.5a1.5 1.5 0 0 1 1.5-1.5h3l1.5 1.5H13a1.5 1.5 0 0 1 1.5 1.5v6A1.5 1.5 0 0 1 13 13.5H3A1.5 1.5 0 0 1 1.5 12z"/>',
  keys: '<rect x="1" y="4" width="14" height="8.5" rx="1.8"/><path d="M4 7h.01M6.5 7h.01M9 7h.01M11.5 7h.01M5 10h6"/>',
  space: '<rect x="1.5" y="2.5" width="13" height="11" rx="2"/><path d="M7 2.5v11M7 8h7.5"/>',
};
const icon = (kind, cls = "sym") =>
  `<svg class="${cls}" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[kind] || ICONS.note}</svg>`;
const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// ---- The space: columns of tiles -----------------------------------------

let seq = 0;
const tile = (block, h = 1, from = null) => ({ id: "t" + ++seq, block, h, stack: [], from });

let columns = [
  { w: 0.57, tiles: [tile("overview")] },
  { w: 0.43, tiles: [Object.assign(tile("guide", 0.6), { stack: ["start"] }), tile("terminal", 0.4)] },
];
let focused = columns[0].tiles[0].id;
let maximized = null;
const closed = [];
const arriving = new Set();

const allTiles = () => columns.flatMap((c) => c.tiles);
const tileById = (id) => allTiles().find((t) => t.id === id);
const locate = (id) => {
  for (let ci = 0; ci < columns.length; ci++) {
    const ti = columns[ci].tiles.findIndex((t) => t.id === id);
    if (ti >= 0) return { ci, ti };
  }
  return null;
};

// ---- Drawing --------------------------------------------------------------

const grid = $(".grid");
const elements = new Map();   // tile id → its element, kept while it lives
const contents = new Map();   // block id → its content, kept across moves
const scrolls = new Map();    // tile id → its body's scroll, across draws
const sizes = new ResizeObserver((entries) => entries.forEach((e) => ladder(e.target)));

function content(block) {
  if (!contents.has(block)) {
    const c = document.createElement("div");
    c.className = "content";
    c.append(BLOCKS[block].template.content.cloneNode(true));
    contents.set(block, c);
    if (c.querySelector("[data-typed]")) typeOut(c.querySelector("[data-typed]"));
  }
  return contents.get(block);
}

function tileElement(t) {
  const key = [t.block, t.stack.join(","), t.from].join("|");
  let el = elements.get(t.id);
  if (el && el.dataset.key === key) return el;
  const b = BLOCKS[t.block];
  const summary = b.summary.map((l) => `<div>${esc(l)}</div>`).join("");
  // Its link, as the app's bar shows one: the other block's face, a
  // chevron in it for the direction (here always ‹, linked from), its
  // summary card on a rest.
  const capsule = t.from && BLOCKS[t.from]
    ? `<a class="face" href="#${t.from}" data-open="${t.from}" data-preview="${t.from}" aria-label="Linked from ${esc(BLOCKS[t.from].title)}"><span class="dir" aria-hidden="true"><svg viewBox="0 0 6 10"><path d="M4.5 1.5 1.5 5l3 3.5"/></svg></span>${icon(BLOCKS[t.from].kind)}</a>` : "";
  const sheets = t.stack.slice(0, 2).map((s, i) =>
    `<div class="sheet" data-behind="${i}" title="${esc(BLOCKS[s].title)} — behind; click to bring it to the top"></div>`).join("");
  const fresh = html(`
    <section class="tile${b.lens ? ` lens-${b.lens}` : ""}${t.stack.length ? " stacked" : ""}" data-tile="${t.id}" aria-label="${esc(b.title)}">
      ${sheets ? `<div class="sheets">${sheets}</div>` : ""}
      <div class="bar" title="Click to grow · ⌘-click to fill the column · ⌃-click for the menu">
        <button class="sym-button" data-menu title="The tile's menu">${icon(b.kind)}</button>
        <span class="title">${esc(b.title)}</span>
        <span class="place">${esc(b.place)}</span>
        ${b.note ? `<span class="note">${esc(b.note)}</span>` : ""}
        ${capsule}
        <span class="tools">
          <button class="icon-button maximize" data-maximize title="Maximize" aria-label="Maximize"><svg viewBox="0 0 16 16"><path d="M9.5 2.5h4v4M13.5 2.5 9 7M6.5 13.5h-4v-4M2.5 13.5 7 9"/></svg></button>
          <button class="icon-button" data-close title="Close Tile" aria-label="Close"><svg viewBox="0 0 16 16"><path d="M4 4l8 8M12 4l-8 8"/></svg></button>
        </span>
      </div>
      <div class="body"><div class="summary${b.kind === "terminal" ? " code" : ""}">${summary}</div></div>
    </section>`);
  fresh.querySelector(".body").append(content(t.block));
  fresh.dataset.key = key;
  // Its entrance played once: drawn again (moved), it doesn't play again.
  fresh.addEventListener("animationend", () => fresh.classList.remove("arriving", "flash"));
  if (el) { sizes.unobserve(el); el.replaceWith(fresh); }
  elements.set(t.id, fresh);
  sizes.observe(fresh);
  return fresh;
}

// The shrink ladder, by the room a tile has: content, its summary card,
// its bar alone (DESIGN.md §3.1).
function ladder(el) {
  if (narrow()) { el.classList.remove("summarized"); return; }
  const h = el.getBoundingClientRect().height;
  el.classList.toggle("collapsed", h < BAR + 22);
  el.classList.toggle("summarized", h >= BAR + 22 && h < BAR + 84);
}

function render() {
  for (const [id, el] of elements) scrolls.set(id, el.querySelector(".body").scrollTop);
  const live = new Set(allTiles().map((t) => t.id));
  for (const [id, el] of elements) if (!live.has(id)) { sizes.unobserve(el); elements.delete(id); }
  grid.textContent = "";
  if (!live.size) {
    grid.append(html(`<div class="empty"><h2>No tiles</h2><p>Every tile on this page is closed. Bring one back, or find one.</p>
      <button class="button primary" data-open="overview">Manifold</button><button class="button" data-open="guide">Guide</button><button class="button" data-action="quick">Open Quickly…</button></div>`));
  }
  columns.forEach((col, ci) => {
    if (ci) grid.append(html(`<div class="col-gap" data-col-gap="${ci}"></div>`));
    const c = html(`<div class="column"></div>`);
    c.style.flex = `${col.w} 1 0px`;
    col.tiles.forEach((t, ti) => {
      if (ti) c.append(html(`<div class="row-gap" data-row-gap="${ci}:${ti}"></div>`));
      const el = tileElement(t);
      el.style.flex = `${t.h} 1 0px`;
      el.classList.toggle("focused", t.id === focused);
      el.classList.toggle("maximized", t.id === maximized);
      if (arriving.has(t.id)) { el.classList.remove("arriving"); void el.offsetWidth; el.classList.add("arriving"); }
      c.append(el);
    });
    grid.append(c);
  });
  arriving.clear();
  for (const [id, el] of elements) {
    const s = scrolls.get(id);
    if (s) el.querySelector(".body").scrollTop = s;
    el.querySelector("[data-maximize]").title = id === maximized ? "Restore" : "Maximize";
  }
  requestAnimationFrame(() => elements.forEach(ladder));
  renderSidebar();
  $('[data-count="closed"]').textContent = closed.length;
}

function renderSidebar() {
  const tree = $(".tree");
  tree.textContent = "";
  tree.append(html(`<button class="row space chosen" data-space>${icon("space")}<span class="label">Manifold</span><span class="pill">${allTiles().length}</span></button>`));
  for (const t of allTiles()) {
    const row = (block, behind) => html(`<button class="row leaf${behind ? " behind" : ""}${!behind && t.id === focused ? " chosen" : ""}"
        data-row="${t.id}" ${behind ? `data-row-behind="${block}"` : ""}>${icon(BLOCKS[block].kind)}<span class="label">${esc(BLOCKS[block].title)}</span></button>`);
    if (t.stack.length) {
      const g = html(`<div class="stack-group"></div>`);
      g.append(row(t.block, false), ...t.stack.map((s) => row(s, true)));
      tree.append(g);
    } else {
      tree.append(row(t.block, false));
    }
  }
}

// ---- Going places and opening things ------------------------------------

function focus(id, { flash = false, scroll = false } = {}) {
  focused = id;
  for (const [tid, el] of elements) el.classList.toggle("focused", tid === id);
  $$(".tree .row.leaf").forEach((r) => r.classList.toggle("chosen", r.dataset.row === id && !r.dataset.rowBehind));
  const el = elements.get(id);
  if (!el) return;
  if (flash) { el.classList.remove("flash"); void el.offsetWidth; el.classList.add("flash"); }
  if (scroll || narrow()) el.scrollIntoView({ behavior: "smooth", block: "nearest" });
  const t = tileById(id);
  if (t) history.replaceState(null, "", "#" + t.block);
}

/** What a click says: plain goes to it, ⌘ beside, ⌥ over (the one rule). */
const how = (e) => (e && e.altKey ? "over" : e && (e.metaKey || e.ctrlKey) ? "beside" : "go");

/** A block opened from a tile (or none), as `mode` says. */
function follow(block, fromId, mode = "go") {
  if (!BLOCKS[block]) return;
  const from = fromId && tileById(fromId) ? fromId : focused && tileById(focused) ? focused : null;
  if (mode === "go") {
    const shown = allTiles().find((t) => t.block === block);
    if (shown) return goTo(shown.id);
    const behind = allTiles().find((t) => t.stack.includes(block));
    if (behind) { toTop(behind, block); return goTo(behind.id); }
  }
  if (mode === "over" && from) return over(block, from);
  beside(block, from);
}

/** Gone to: focused, grown a little if it was down to its summary or bar. */
function goTo(id) {
  maximized = maximized && maximized !== id ? null : maximized;
  const el = elements.get(id);
  if (el && !narrow() && (el.classList.contains("collapsed") || el.classList.contains("summarized"))) {
    const loc = locate(id);
    if (loc) give(columns[loc.ci], columns[loc.ci].tiles[loc.ti], 0.4);
  }
  render();
  focus(id, { flash: true, scroll: true });
}

/** Below the opener, taking its lower half — or, with too little room for
 *  that, a column of its own beside it; failing that, below the biggest. */
function beside(block, fromId) {
  const fresh = tile(block, 1, fromId ? tileById(fromId).block : null);
  if (!columns.length) {
    columns = [{ w: 1, tiles: [fresh] }];
  } else {
    const loc = fromId ? locate(fromId) : { ci: columns.length - 1, ti: columns[columns.length - 1].tiles.length - 1 };
    const col = columns[loc.ci], opener = col.tiles[loc.ti];
    const colPx = grid.getBoundingClientRect().height;
    const openerPx = (opener.h / col.tiles.reduce((s, t) => s + t.h, 0)) * colPx;
    const roomForColumn = grid.getBoundingClientRect().width / (columns.length + 1) >= 380;
    if (narrow() || openerPx / 2 >= 220 || !roomForColumn && openerPx / 2 >= 150) {
      fresh.h = opener.h / 2;
      opener.h /= 2;
      col.tiles.splice(loc.ti + 1, 0, fresh);
    } else if (roomForColumn) {
      const w = col.w / 2;
      col.w -= w;
      columns.splice(loc.ci + 1, 0, { w, tiles: [fresh] });
    } else {
      // The biggest tile anywhere gives its lower half.
      let best = null;
      columns.forEach((c, ci) => {
        const sum = c.tiles.reduce((s, t) => s + t.h, 0);
        c.tiles.forEach((t, ti) => { const share = t.h / sum; if (!best || share > best.share) best = { ci, ti, share }; });
      });
      const c = columns[best.ci], t = c.tiles[best.ti];
      fresh.h = t.h / 2;
      t.h /= 2;
      c.tiles.splice(best.ti + 1, 0, fresh);
    }
  }
  maximized = null;
  arriving.add(fresh.id);
  render();
  focus(fresh.id, { scroll: true });
}

/** Over the opener, which goes behind it, as ⌥-drag stacks. */
function over(block, fromId) {
  const t = tileById(fromId);
  if (t.block === block) return goTo(t.id);
  t.stack = [t.block, ...t.stack.filter((s) => s !== block)];
  t.from = t.block;
  t.block = block;
  arriving.add(t.id);
  render();
  focus(t.id);
}

/** One behind a tile brought to its top; the top goes behind it. */
function toTop(t, block) {
  t.stack = [t.block, ...t.stack.filter((s) => s !== block)];
  t.block = block;
}

/** A tile taken off: the next behind it comes out; else its room goes to
 *  its neighbour, and an emptied column's to the next. */
function close(id) {
  const loc = locate(id);
  if (!loc) return;
  const col = columns[loc.ci], t = col.tiles[loc.ti];
  closed.push(t.block);
  if (maximized === id) maximized = null;
  if (t.stack.length) {
    t.block = t.stack.shift();
    t.from = null;
    render();
    return focus(t.id);
  }
  col.tiles.splice(loc.ti, 1);
  const heir = col.tiles[loc.ti - 1] || col.tiles[loc.ti];
  if (heir) heir.h += t.h;
  else {
    columns.splice(loc.ci, 1);
    const next = columns[loc.ci - 1] || columns[loc.ci];
    if (next) next.w += col.w;
  }
  const after = heir || allTiles()[0];
  focused = after ? after.id : null;
  render();
  if (after) focus(after.id);
}

/** A tile given a share of its column, the others the rest in proportion. */
function give(col, t, share) {
  const n = col.tiles.length;
  if (n < 2) return;
  const sum = col.tiles.reduce((s, x) => s + x.h, 0);
  const colPx = grid.getBoundingClientRect().height || 600;
  const floor = (BAR + 2) / colPx;
  share = Math.min(share, 1 - floor * (n - 1));
  const rest = col.tiles.filter((x) => x !== t);
  const restSum = rest.reduce((s, x) => s + x.h, 0) || 1;
  rest.forEach((x) => { x.h = Math.max(floor, ((1 - share) * x.h) / restSum) * sum; });
  t.h = share * sum;
}

/** The bar clicked: a step bigger, as acme's colgrow — clicked again, more. */
function grow(id) {
  const loc = locate(id);
  if (!loc) return;
  const col = columns[loc.ci], t = col.tiles[loc.ti];
  const share = t.h / col.tiles.reduce((s, x) => s + x.h, 0);
  give(col, t, share < 0.5 ? 0.5 : share + 0.2);
  render();
  focus(id);
}

/** ⌘-clicked: the whole column, the others down to their bars. */
function fill(id) {
  const loc = locate(id);
  if (!loc) return;
  give(columns[loc.ci], columns[loc.ci].tiles[loc.ti], 1);
  render();
  focus(id);
}

/** Down to its summary card, or back. */
function shrink(id) {
  const loc = locate(id);
  if (!loc) return;
  const col = columns[loc.ci], t = col.tiles[loc.ti];
  const colPx = grid.getBoundingClientRect().height || 600;
  const sum = col.tiles.reduce((s, x) => s + x.h, 0);
  const others = col.tiles.filter((x) => x !== t);
  if (!others.length) return;
  // The room it gives up goes to the biggest other, as the app's does; back,
  // it takes it from there.
  const biggest = others.reduce((a, x) => (x.h > a.h ? x : a));
  const target = t.unshrunk ? t.unshrunk * sum : Math.min(t.h, ((BAR + 60) / colPx) * sum);
  t.unshrunk = t.unshrunk ? null : t.h / sum;
  const delta = t.h - target;
  if (biggest.h + delta <= 0) return;
  t.h = target;
  biggest.h += delta;
  render();
}

function toggleMaximize(id) {
  maximized = maximized === id ? null : id;
  render();
  focus(id);
}

// ---- A link's card, under the bar ------------------------------------------

let cardWork = null, cardEl = null;
function hideCard() { clearTimeout(cardWork); cardWork = null; if (cardEl) { cardEl.remove(); cardEl = null; } }
document.addEventListener("mouseover", (e) => {
  const face = e.target.closest("[data-preview]");
  if (!face) return hideCard();
  if (cardEl && cardEl.dataset.for === face.dataset.preview) return;
  clearTimeout(cardWork);
  // A moment's rest first, so sweeping across the bar doesn't flash cards.
  cardWork = setTimeout(() => {
    hideCard();
    const b = BLOCKS[face.dataset.preview];
    const tileEl = face.closest("[data-tile]");
    if (!b || !tileEl) return;
    cardEl = html(`<div class="link-card" data-for="${b.id}">${icon(b.kind)}<div><div class="t">${esc(b.title)}<span class="where">${esc(b.place)}</span></div>
      ${b.summary.map((l) => `<div class="l">${esc(l)}</div>`).join("")}</div></div>`);
    tileEl.append(cardEl);
    const f = face.getBoundingClientRect(), r = tileEl.getBoundingClientRect();
    const w = Math.min(280, r.width - 12);
    cardEl.style.width = w + "px";
    cardEl.style.left = Math.max(6, Math.min(f.left + f.width / 2 - w / 2 - r.left, r.width - w - 6)) + "px";
    cardEl.style.top = (f.bottom - r.top + 8) + "px";
  }, 150);
});

// ---- The tile's menu -------------------------------------------------------

let menuEl = null;
function closeMenu() { if (menuEl) { menuEl.remove(); menuEl = null; } }
function tileMenu(id, x, y) {
  closeMenu();
  const el = elements.get(id);
  const t = tileById(id);
  const items = [
    ["Grow", () => grow(id)],
    ["Fill the Column", () => fill(id)],
    [el && el.classList.contains("summarized") ? "Show Content" : "Shrink to Summary", () => shrink(id)],
    [maximized === id ? "Restore" : "Maximize", () => toggleMaximize(id)],
    ...(t.stack.length ? [["Next in Stack", () => { toTop(t, t.stack[0]); render(); focus(id); }]] : []),
    null,
    ["Close Tile", () => close(id)],
  ];
  menuEl = html(`<div class="menu" role="menu"></div>`);
  for (const item of items) {
    if (!item) { menuEl.append(html(`<hr>`)); continue; }
    const b = html(`<button role="menuitem">${esc(item[0])}</button>`);
    b.addEventListener("click", () => { closeMenu(); item[1](); });
    menuEl.append(b);
  }
  document.body.append(menuEl);
  const r = menuEl.getBoundingClientRect();
  menuEl.style.left = Math.min(x, innerWidth - r.width - 8) + "px";
  menuEl.style.top = Math.min(y, innerHeight - r.height - 8) + "px";
}

// ---- Clicks ----------------------------------------------------------------

document.addEventListener("click", (e) => {
  if (menuEl && !menuEl.contains(e.target)) closeMenu();
  const tileEl = e.target.closest("[data-tile]");
  const tid = tileEl && tileEl.dataset.tile;
  const link = e.target.closest("[data-open]");
  if (link) {
    e.preventDefault();
    return follow(link.dataset.open, tid, how(e));
  }
  const action = e.target.closest("[data-action]");
  if (action) {
    const a = action.dataset.action;
    if (a === "quick") return quick.open();
    if (a === "theme") return cycleTheme();
    if (a === "closed" && closed.length) return follow(closed.pop(), focused, "go");
  }
  const row = e.target.closest("[data-row]");
  if (row) {
    const t = tileById(row.dataset.row);
    const block = row.dataset.rowBehind || t.block;
    const mode = how(e);
    if (mode === "go" && row.dataset.rowBehind) { toTop(t, block); return goTo(t.id); }
    return mode === "go" ? goTo(t.id) : follow(block, focused !== t.id ? focused : null, mode);
  }
  if (!tid) return;
  if (e.target.closest("[data-close]")) return close(tid);
  if (e.target.closest("[data-maximize]")) return toggleMaximize(tid);
  if (e.target.closest("[data-menu]")) { const r = e.target.closest("[data-menu]").getBoundingClientRect(); return tileMenu(tid, r.left, r.bottom + 4); }
  const sheet = e.target.closest("[data-behind]");
  if (sheet) {
    const t = tileById(tid);
    if (e.metaKey) {  // ⌘: out of the stack, beside
      const block = t.stack.splice(+sheet.dataset.behind, 1)[0];
      render();
      return beside(block, tid);
    }
    toTop(t, t.stack[+sheet.dataset.behind]);
    render();
    return focus(tid);
  }
  if (e.target.closest(".bar")) {
    if (narrow()) { tileEl.classList.toggle("collapsed"); return; }
    return e.metaKey ? fill(tid) : grow(tid);
  }
});

document.addEventListener("contextmenu", (e) => {
  const bar = e.target.closest(".bar");
  if (!bar) return;
  e.preventDefault();
  tileMenu(bar.closest("[data-tile]").dataset.tile, e.clientX, e.clientY);
});

grid.addEventListener("mousedown", (e) => {
  const tileEl = e.target.closest("[data-tile]");
  if (tileEl && tileEl.dataset.tile !== focused) focus(tileEl.dataset.tile);
});

// The gaps, dragged: the two tiles (or columns) on either side share the
// room they had between them.
grid.addEventListener("pointerdown", (e) => {
  const gap = e.target.closest(".col-gap, .row-gap");
  if (!gap) return;
  e.preventDefault();
  gap.setPointerCapture(e.pointerId);
  gap.classList.add("dragging");
  let a, b, total, size, start;
  if (gap.dataset.colGap) {
    const ci = +gap.dataset.colGap;
    a = columns[ci - 1]; b = columns[ci];
    const els = $$(".column", grid);
    size = els[ci - 1].getBoundingClientRect().width + els[ci].getBoundingClientRect().width;
    total = a.w + b.w; start = { px: e.clientX, share: a.w / total };
  } else {
    const [ci, ti] = gap.dataset.rowGap.split(":").map(Number);
    a = columns[ci].tiles[ti - 1]; b = columns[ci].tiles[ti];
    size = elements.get(a.id).getBoundingClientRect().height + elements.get(b.id).getBoundingClientRect().height;
    total = a.h + b.h; start = { px: e.clientY, share: a.h / total };
  }
  const key = gap.dataset.colGap ? "w" : "h";
  const min = (key === "w" ? 220 : BAR) / size;
  const move = (ev) => {
    const d = ((key === "w" ? ev.clientX : ev.clientY) - start.px) / size;
    const share = Math.min(1 - min, Math.max(min, start.share + d));
    a[key] = share * total; b[key] = (1 - share) * total;
    const flexOf = (x) => `${x[key]} 1 0px`;
    if (key === "w") { const els = $$(".column", grid); els[columns.indexOf(a)].style.flex = flexOf(a); els[columns.indexOf(b)].style.flex = flexOf(b); }
    else { elements.get(a.id).style.flex = flexOf(a); elements.get(b.id).style.flex = flexOf(b); }
  };
  const up = () => { gap.classList.remove("dragging"); gap.removeEventListener("pointermove", move); gap.removeEventListener("pointerup", up); };
  gap.addEventListener("pointermove", move);
  gap.addEventListener("pointerup", up);
});

// ---- Open Quickly (⌘K, ⌘O, /) ------------------------------------------------

const quick = (() => {
  const root = $(".quick"), field = $(".quick-field"), list = $(".quick-list");
  let rows = [], chosen = 0;

  function rank(q) {
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    const shown = new Set(allTiles().map((t) => t.block));
    return Object.values(BLOCKS).map((b) => {
      const name = b.title.toLowerCase();
      const hay = [name, b.place.toLowerCase(), b.summary.join(" ").toLowerCase(), b.text].join(" ");
      if (!words.every((w) => hay.includes(w))) return null;
      let score = shown.has(b.id) ? 1 : 0;
      for (const w of words) score += name.startsWith(w) ? 6 : name.includes(w) ? 4 : b.summary.join(" ").toLowerCase().includes(w) ? 2 : 0.5;
      return { b, score, here: shown.has(b.id) };
    }).filter(Boolean).sort((x, y) => y.score - x.score || x.b.title.localeCompare(y.b.title));
  }

  function mark(text, q) {
    let out = esc(text);
    for (const w of q.split(/\s+/).filter(Boolean)) out = out.replace(new RegExp(`(${w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "ig"), "<mark>$1</mark>");
    return out;
  }

  function draw() {
    const q = field.value.trim();
    rows = rank(q);
    chosen = Math.min(chosen, Math.max(0, rows.length - 1));
    list.innerHTML = rows.map(({ b, here }, i) => `
      <li role="option" data-i="${i}" class="${i === chosen ? "chosen" : ""}">${icon(b.kind)}
        <div class="card"><div class="t">${mark(b.title, q)}<span class="where">${esc(b.place)}</span></div>
        ${b.summary.map((l) => `<div class="l">${mark(l, q)}</div>`).join("")}</div>
        ${here ? '<span class="tag">here</span>' : ""}</li>`).join("") || `<li class="none">Nothing called that.</li>`;
  }

  function choose(i, e) {
    const r = rows[i];
    if (!r) return;
    close();
    follow(r.b.id, focused, how(e));
  }

  function open() { root.hidden = false; field.value = ""; chosen = 0; draw(); field.focus(); }
  function close() { root.hidden = true; }

  field.addEventListener("input", () => { chosen = 0; draw(); });
  field.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { chosen = Math.min(rows.length - 1, chosen + 1); draw(); e.preventDefault(); }
    else if (e.key === "ArrowUp") { chosen = Math.max(0, chosen - 1); draw(); e.preventDefault(); }
    else if (e.key === "Enter") { e.preventDefault(); choose(chosen, e); }
    else if (e.key === "Escape") { close(); }
    const c = list.querySelector(".chosen");
    if (c) c.scrollIntoView({ block: "nearest" });
  });
  list.addEventListener("click", (e) => { const li = e.target.closest("[data-i]"); if (li) choose(+li.dataset.i, e); });
  root.addEventListener("mousedown", (e) => { if (e.target === root) close(); });
  return { open, close, get shown() { return !root.hidden; } };
})();

document.addEventListener("keydown", (e) => {
  const typing = /INPUT|TEXTAREA/.test(document.activeElement.tagName);
  if ((e.metaKey || e.ctrlKey) && (e.key === "k" || e.key === "o")) { e.preventDefault(); return quick.shown ? quick.close() : quick.open(); }
  if (e.key === "/" && !typing && !quick.shown) { e.preventDefault(); return quick.open(); }
  if (e.key === "Escape") { closeMenu(); if (quick.shown) quick.close(); }
});

// ---- Appearance --------------------------------------------------------------

const THEMES = ["auto", "light", "dark"];
function theme() { return document.documentElement.dataset.theme || "auto"; }
function setTheme(t) {
  if (t === "auto") delete document.documentElement.dataset.theme; else document.documentElement.dataset.theme = t;
  try { if (t === "auto") localStorage.removeItem("manifold-theme"); else localStorage.setItem("manifold-theme", t); } catch (e) {}
  $$("[data-theme-name]").forEach((n) => (n.textContent = { auto: "Auto", light: "Light", dark: "Dark" }[t]));
}
function cycleTheme() { setTheme(THEMES[(THEMES.indexOf(theme()) + 1) % THEMES.length]); }
setTheme(theme());

// The wash's pools, placed afresh each day, as the app's are.
(() => {
  let seed = Math.floor(Date.now() / 86400000);
  const rand = () => ((seed = (seed * 9301 + 49297) % 233280) / 233280);
  const s = document.documentElement.style;
  [[5, 30, 5, 35], [60, 95, 0, 30], [50, 90, 70, 100], [0, 40, 65, 100]].forEach(([x0, x1, y0, y1], i) => {
    s.setProperty(`--p${i + 1}x`, (x0 + rand() * (x1 - x0)).toFixed(0) + "%");
    s.setProperty(`--p${i + 1}y`, (y0 + rand() * (y1 - y0)).toFixed(0) + "%");
  });
})();

// ---- The terminal, typing ---------------------------------------------------

function typeOut(term) {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const parts = [...term.children];
  const cmds = parts.map((p) => p.querySelector(".t-cmd"));
  const texts = cmds.map((c) => (c ? c.textContent : null));
  parts.forEach((p) => (p.style.visibility = "hidden"));
  cmds.forEach((c) => c && (c.textContent = ""));
  let i = 0;
  const next = () => {
    if (i >= parts.length) return;
    const p = parts[i], c = cmds[i], text = texts[i];
    p.style.visibility = "";
    i++;
    if (!c) return setTimeout(next, p.classList.contains("t-out") ? 380 : 200);
    let k = 0;
    const tick = () => {
      c.textContent = text.slice(0, ++k);
      if (k < text.length) setTimeout(tick, 28 + Math.random() * 40);
      else setTimeout(next, 260);
    };
    setTimeout(tick, 400);
  };
  setTimeout(next, 700);
}

// ---- Begin ---------------------------------------------------------------------

render();
const asked = location.hash.slice(1);
if (BLOCKS[asked] && asked !== "overview") follow(asked, columns[0].tiles[0].id, "go");
addEventListener("resize", () => elements.forEach(ladder));
// A link to another block of the page (#keys) followed from elsewhere, or
// typed: opened as a click would.
addEventListener("hashchange", () => {
  const id = location.hash.slice(1);
  if (BLOCKS[id] && !(tileById(focused) && tileById(focused).block === id)) follow(id, focused, "go");
});
