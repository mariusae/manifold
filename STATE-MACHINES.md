# Manifold's state machines

The lifecycles Manifold keeps (a shell's, a connection's, a tile walk's, a
toast's), how each is held, what must always be true of it (its
invariants), and its transitions. Many are *implicit*: a few Bools,
optionals and pending work items whose combinations matter, with no one type
saying which state it is in. This records them as they are, the invalid
states the code can actually reach (with the evidence), and what was done.

Kept with the code: a change to one of these lifecycles changes its entry.

**Legend.** *Explicit*: one state type holds it. *Implicit*: spread over
variables. A finding is **reproduced** (a test or a run shows it),
**confirmed on reading** (the path is certain from the code; not yet run),
**suspected** (plausible; not shown), or **fixed** (commit and regression
test named).

**Tests.** `ManifoldCoreTests` (model), `ManifolddTests` (the host server,
`@testable import manifoldd`), `ManifoldAppTests` (the app,
`@testable import Manifold`); all run by `swift test`. Window-level ones
are scenarios run through a debug instance's socket:
`MANIFOLD_DIR=/tmp/mft Tests/scenarios/run.sh` (a throwaway instance:
they open files and make threads).

---

## Issues

Grouped by cause, ordered by harm. Each names its machines (§ below).

| Issue | What | Status | Regression test |
|---|---|---|---|
| I-1 | Shells let go of before they exit: zombies, leaked ptys; notebook shells never reaped | fixed | `ManifolddTests/SessionLifecycleTests` |
| I-2 | Commands and turns left "running" after their shell; "running" read four ways | fixed | `ManifoldCoreTests/RunPhaseTests` |
| I-3 | A space change leaves a drag catcher and a ⌃⇥ walk behind | fixed | `ManifoldAppTests/TileWalkTests`, `scenarios/space-change.sh` |
| I-4 | A past revision becomes editable when its host comes back | fixed | `ManifoldAppTests/EditorAccessTests`, `scenarios/past-revision-read-only.sh` |
| I-5 | Stuck after one failure: web store, language server; a remote copy retried blindly | fixed | `WebRouteTests`, `LanguageServerLifecycleTests`, `LocalCopiesTests` |
| I-6 | A silent drop counted as unanswered; a resize attaching afresh | fixed | `HostLinkTests`, `TerminalLinkTests` |
| I-7 | A toast shown as the last one fades is lost | fixed | `ManifoldAppTests/ToastTests` |
| I-8 | Smaller: watcher gives up, re-index dropped, closed card acted on, stale search | confirmed ones fixed; suspected open | `FileWatcherTests`, `SCIPReindexTests`, `scenarios/thread-card-closed.sh`, `DebouncerTests` |

**Open (suspected: plausible on reading, not shown).** The space slide's
completion race (M22); `$EDITOR` stacks not pruned off screen (M23);
Overview left up over another space (M25); the ⌘\` order and ⌃-
navigation timers (M26, M28); the heartbeat across a reconnect's handshake
(M14); a session's pty touched between its EOF and its exit, and
`endedForIdleness` never reset (M1); stale `pid`/`busy`/search/notebook
"running" after the host's server restarts, until reattached (M10, M11);
FileReceiver unlinking in `.create`/`.append` (M6, latent: unused modes).
Each becomes an issue once shown.

### I-1 Shells let go of before they've exited · **fixed** · high
Deleting a terminal or notebook block (`Server.discard`), or restarting a
notebook (`restartNotebook`), takes its `Session`/`NotebookShell` out of
the server's table and hangs up on the shell, before the shell has exited.
Nothing else holds the object strongly: its exit watch and its pty's read
source capture it weakly. So it is freed while the shell is still ending:
- the shell is never `waitpid`ed: a **zombie** for the server's life;
- the pty's master is never closed (its read source is never cancelled): a
  **leaked descriptor**, and a read source left armed on a dead pty;
- a notebook's temporary folder is never removed.
- and **no notebook shell was ever reaped**: `NotebookShell.processExited`
  never called `waitpid` (the Linux watcher looks with `WNOWAIT`), so every
  one that ended, however, was left a zombie.

Evidence: `ManifolddTests/SessionLifecycleTests` — on the old code both
shells stay zombies (`kinfo_proc.p_stat == SZOMB`) and the process's
descriptor count stays up.
Fix: a session or notebook shell hung up on keeps itself until its shell
has exited (`keptUntilExit`), and kills a shell that ignores the hang-up
after `Session.killAfter` (5 s); a notebook's shell is reaped on exit.
Both tests pass. Machines: M1, M2.

### I-2 Runs left open, and "running" read four ways · **fixed** · high
A command or an agent's turn is closed only by the shell's own report of
its end (`.exited`, the host's `finishTurns`). A shell that ends or goes
dormant mid-command (killed, the server restarted or updated, idled out)
leaves it open for good: `ended == nil` forever. So:
- `mani ls`, the switcher's card and the Inspector say "running for 3 d" /
  "working"; `mani info` says `running: true` (agents act on that);
- `Block.agent` finds an agent among the last commands with `status == nil`,
  so a dead agent's terminal is still taken for one at work;
- readers disagree on "running": `ended == nil` (`isRunning`), `status ==
  nil` (TerminalView's outline, Run Again's guard, `Block.agent`),
  `status == nil && last` (TerminalView's detail).
The output block's summary (`Summary`) reads `status == nil` as "running",
so every **file's old version** (`ran` nil, `ended` set) and every notebook
cell whose shell died shows "· running" in `mani ls` and cards; the output
tile itself says "ok" for the dead cell.

Fix: `TerminalState` closes every open command and turn when its shell
ends, goes dormant or is replaced (`closeRuns`, on `.shell(.ended /
.dormant / .started)`): ended then, with no status (`abandoned`). It's in
`apply`, so app and server agree and a log replays to the same; a
snapshot taken before keeps its open commands until the terminal's next
shell starts. One reading: `isRunning` (`ended == nil`) everywhere, and
one wording of how a run ended (`ShellCommand.outcome`, `OutputState.run`
/ `.outcome`, `RunOutcome`): "ok", "exit 2", "its shell ended". A file's
old version has no outcome and no prompt. The notifier doesn't announce an
abandoned command as finished; `mani run --wait` on one exits 1, saying
its shell ended; `mani info` marks it `shellEnded`.
Tests: `ManifoldCoreTests/RunPhaseTests` (the command and turn tests fail
with the closing taken out). Machines: M8, M9.

### I-3 A space change leaves the old space's transient state behind · **fixed** · high
The window notices a space change in one place (`renderNow`'s
`selected != shownArrangement`); about 30 callers select a space (⌘1–9,
⌘\`, the strip, spring-loading, `mani`). State bound to the space shown
isn't told:
- **Drag catcher stuck on the old grid.** `dragChanged(true)` sets
  `content.dragging` on grid A; a spring-load during the drag switches
  `content` to grid B; `dragChanged(false)` clears B. A keeps its catcher,
  a view over every tile: back on A, its tiles take no clicks or scrolls
  until another drag ends.
- **⌃⇥ walk preview drawn in another space.** `walkPreview` holds no space;
  a space selected during the walk (an agent's `mani open`, a host
  dropping the space) renders the old space's preview into the new grid,
  and letting go selects the old space again.

Evidence: `Tests/scenarios/space-change.sh` against the test instance — on
the old code the catcher stays on the space left (`catching=Z6KQ02
shown=ZPYD0A`), still there after the drag ends, and the walk (with its
preview, 24 tiles of the old space) outlives the switch.
Fix: where the window notices a space change, the drag's catcher moves to
the grid shown and comes off the one left; a walk begun in another space
is dropped (as Escape, nothing gone to). The walk is a value bound to its
space (`TileWalk`), and its preview is made at each render from the space
as it is (`walkPreview`, computed), so it is never of another space or out
of date (a tile closed during the walk). `debug drag` reports the drag and
the grids catching it; `tilewalk` names the walk's space.
Tests: `ManifoldAppTests/TileWalkTests`; the scenario passes.
Machines: M20, M21.

### I-4 A past revision becomes editable · **fixed** · medium-high
Three formulas set `textView.isEditable`: `documentChanged` (all reasons,
but it returns early while a past revision is shown), file history's
(`false`), and `offline`'s didSet (`!offline && !unreadable`, ignoring the
rest). Shown a past revision, the host goes offline and comes back: the
past text is editable. Typing does nothing to it (a static document), but
the text view records undo groups against it; after history closes ⌘Z can
apply them to the live file (suspected).

Evidence: `Tests/scenarios/past-revision-read-only.sh` — on the old code a
past revision of `Package.swift` reports `editable true` once
`fencing away 2` has taken its host away and back.
Fix: one rule (`EditorView.readOnly`: reading, unreadable, offline, past,
viewing) decides, through `updateEditable()`, at every change of any of
them; the history's `filehistory` report says why (`editable false (a past
revision)`).
Tests: `ManifoldAppTests/EditorAccessTests`; the scenario passes.
Machine: M15.

### I-5 One failure, stuck for good (or retried blindly) · **fixed** · medium
- **Web page through a host**: the host's proxy failing to start leaves
  `awaitingStore` true: every address typed after is parked, the error
  stays up, until the route itself changes. (M29) — **fixed**: the store is
  one state (`WebView.Store`: none / asked(pending) / ready /
  unavailable(why, for)); unavailable, another address wanted (typed, a
  link) asks for it again, the same one doesn't. Test:
  `ManifoldAppTests/WebRouteTests` (fails without the ask-again).
- **Language server**: one that failed to start, timed out initializing, or
  crashed is `failed` for good: `server(for:)` returns nil and never makes
  another, so diagnostics, completion and hovers are gone until the host's
  server restarts; a timed-out one's process is never killed. (M3) Found
  on the way: no language server's process was ever reaped (a zombie for
  each one that exited or was stopped), and its pipes were never closed.
  — **fixed**: `LanguageServer.phase` (starting / ready / failed(why));
  failing ends its process and closes its input, its reader closes its
  output and reaps it; a failed server is started afresh when next wanted,
  `retryAfter` (30 s) on, doubling with each failure since it last came up
  (to 16 min), its files opened with the new one. Test:
  `ManifolddTests/LanguageServerLifecycleTests` (fails with a failed server
  given up on).
- **A remote file opened here** (`LocalCopies`, as changed 2026-11-09):
  while its host is away, a send is tried every 10 s, each one a failed
  transfer row and a notice that pile up. (M18) — **fixed**: while its
  host's link isn't up it looks again quietly (`awayRetry`), and sends
  once it is. Test: `ManifoldAppTests/LocalCopiesTests` (fails without
  the guard: a failed transfer and a notice).
Machines: M3, M18, M29.

### I-6 Connection lifecycles misread · **fixed** · medium
- **A silent drop counted as unanswered.** The heartbeat sets
  `link = .unreachable("not answering")` and closes; `onClose` then reads
  `link != .connected` as "the host never answered": the reason shown
  becomes "the connection closed before the host answered", and
  `closedUnanswered` counts one, bringing a re-bootstrap (the server
  copied again) a try sooner. (M14) — **fixed**: a link given up on for
  silence counts as answered, and how the host stands after a close comes
  from why it closed (`HostClient.afterClose(answered:silent:unanswered:)`).
  Test: `ManifoldAppTests/HostLinkTests` (the decision; the wiring in
  `onClose` is by reading — it's installed by a real connect).
- **A terminal resized while its link is down attaches afresh**
  (`resized()` → `attach()`, not `attach(resume: everAttached)`): the
  resume that keeps the screen and resends what was typed meanwhile is
  skipped. (M17) — **fixed**: an attach after the first is a resume however
  it comes about. Test: `ManifoldAppTests/TerminalLinkTests` (a pair of
  muxes; `HostClient.debugUse`, debug builds only) — the second attach
  wasn't a resume.
Machines: M14, M17.

### I-7 A toast shown as the last one fades is lost · **fixed** · medium-low
The window's toast (the sidebar away) is one view, reused. `hide()` fades
it and, on completion, sets `isHidden = true` and calls `onGone`. A `show`
inside the fade (a toast's action that says something, as `act()` hides
then acts; or any `toast.say` in that 0.12 s) is hidden by the old fade's
completion.

Evidence and test: `ManifoldAppTests/ToastTests` — hide, then show inside
the fade: hidden on the old code.
Fix: each `show` is counted (`shows`); a fade's end hides the toast only if
no show came after it began. Machine: M30.

### I-8 Smaller ones · confirmed ones fixed, suspected open
- Thread card: `popover`/`card` never cleared on close; a closed card is
  refreshed and resized, and acted on: `threads reply` posted to a closed
  card's thread. **fixed**: both let go of as the popover closes. Test:
  `Tests/scenarios/thread-card-closed.sh` (the reply went through on the
  old code). (M36)
- Project search: `searchWork` cancelled but not cleared, so a search isn't
  started after type-clear-type with Home toggled; and ⏎ (`perform()`) ran
  that stale item: a search for what was typed before. **fixed**: a
  `Debouncer` (`searchSoon`) — typing cancels what waits, ⏎ `flush()`es it
  (once; nothing if cancelled). Test: `ManifoldCoreTests/DebouncerTests`
  (the mechanism; the timing isn't reachable through the debug socket,
  whose `dir search` runs at once). (M31)
- SCIP: a re-index asked for while the root is indexing is dropped; the
  index stays stale until the next save. **fixed**: it's kept
  (`wantedAgain`) and run once the current run's done. Test:
  `ManifolddTests/SCIPReindexTests` (two runs, not three, on the old
  code). (M5)
- File watcher (Darwin) gives up 2 s after a file's deleted; recreated
  later, it isn't followed again (Linux polls on). **fixed**: after its
  quick looks it looks once a second for as long as it's watched. Test:
  `ManifoldCoreTests/FileWatcherTests` (made again 3 s on: unheard on the
  old code). (M4)
- Space slide: a second switch within the slide is cut short by the first
  one's completion. **suspected** (M22)
- `$EDITOR` stacks not pruned when the editor goes off screen. **suspected** (M23)
- Overview of space A stays up over B after ⌘2 / ⌘\` / `mani`. **suspected** (M25)
- ⌘\` order and ⌃- navigation timers. **suspected** (M26, M28)

---

## Machines

Each: where it lives · how it's held · states · invariants · transitions ·
findings · decision.

### Host server (manifoldd)

#### M1 Session — a terminal's shell · implicit
`Session` (Session.swift); owned by `Server.sessions[block]`.
Held by `exited`, `readSource.isCancelled`, `endedForIdleness`/`idleSeconds`,
the exit watch.

| State | Held as |
|---|---|
| running | `!exited`, read source live |
| output closed | read source cancelled (EOF before the exit is seen) |
| terminating(reason) | hung up on (`terminate`/`endForIdleness`), not yet exited |
| exited(status) | `exited`, reaped, sources cancelled, `onExit` called |

Invariants: the shell is reaped exactly once; the pty's master is closed
exactly once; **the object lives until `exited`** (it keeps itself from
`terminate` on); `onExit` fires once; a shell hung up on is gone within
`killAfter`.

| From | Event | To |
|---|---|---|
| running | pty EOF | output closed |
| running / output closed | `terminate` · `endForIdleness` | terminating (kept by itself) |
| terminating | `killAfter` passes, still running | terminating (SIGKILL sent) |
| any but exited | process exit seen, reaped | exited (`onExit`, let go) |

Findings: I-1 (freed while terminating). `endedForIdleness` is never reset:
a shell that ignores SIGHUP is hung up on at every sweep, and a later
plain `exit` is recorded as dormancy (rare).

#### M2 NotebookShell — a notebook's shell · implicit
`NotebookShell` (Notebook.swift); `Server.notebooks[block]`. `ready`,
`busy`, `capturing`, `interrupted`, `exited`.
States: starting → idle ⇄ sent(interrupted?) → running → idle; any → exited.
Invariants: as M1 (reaped, master closed, lives until exited); `capturing`
⇒ `busy`. Findings: I-1 (discard, restart; never reaped at all) — fixed. `capturing` left true after
exit (harmless).

#### M3 LanguageServer · explicit (`LanguageServer.Phase`)
`LanguageServer` (LanguageServers.swift); `LanguageServers.servers[lang|root]`,
`failures[lang|root]`. `phase`, `failedAt`, `child`, `queued`; `onState`
strings on the wire ("starting", "ready", "failed: …", "exited",
"couldn't start"), unchanged.

| From | Event | To |
|---|---|---|
| — | wanted (a file of its language opened or changed) | starting |
| starting | initialize answered | ready (failures forgotten) |
| starting | spawn fails · initialize refused or unanswered (15 s) | failed |
| starting · ready | its output closes (exited, killed) | failed ("exited") |
| failed | wanted again, `retryAfter · 2^failures` on | a new one, starting |

Invariants: a failed server's process is ended, reaped, its pipes closed;
a failed server is replaced when next wanted, after its wait. Findings:
I-5 — fixed. `showMessage` text still goes out through `onState`.

#### M4 FileWatcher · implicit
`FileWatcher` (ManifoldCore/FileWatcher.swift). `source`, a retry count in
an `asyncAfter` chain (Darwin); a polling timer (Linux).
States (Darwin): watching → (deleted/renamed) looking (every 0.1 s, 20
times; then every 1 s) → watching (and heard as a change). Invariant: a
watched path is followed for as long as it's watched. Finding: I-8 — fixed.

#### M5 SCIP indexing per root · implicit
`SCIPService` `running: Set<root>`, `wantedAgain`, `failures[root]`,
`pendingIndex`. States: idle → running(again?) → idle | failed(why); asked
while running → running(again) → (done) running. Invariant: an index asked
for is run, at once or after the run under way. Finding: I-8 — fixed.

#### M6 FileReceiver target · implicit · latent
`FileReceiver` (FileStreams.swift) `path`, `writing`, `handle`, `failure`,
`ended`. Whether it made `writing` isn't recorded; `finish`/`cut` unlink it.
In `.create` (exists) or `.append` mode that's the user's file. Only
`.unique` is used today. Decision: leave until another mode is used; noted.

#### Fine as they are (server)
Mux pacing probe (`probing`, `probe`; both writes keep `probe ⇒ probing`),
MuxStream close (`_closing`/`_closed`/`closeTaken`, two domains; traced
correct), the three write sources (optional + active flag; resume before
cancel), PortRelay, FileSender, TreeSource/TreeSink, Attach, Peer pings.

### Model (ManifoldCore)

Persisted in logs and snapshots and sent on the wire: changes here are
computed views or new events, never a change of stored shape.

#### M8 A shell command's and an agent turn's run · implicit
`ShellCommand.status`/`ended`, `AgentTurn.ended`/`before`/`after`/`files`
(Blocks.swift); in `TerminalState.commands`/`turns`.

| State | Held as |
|---|---|
| running | `ended == nil` |
| ended(status) | `ended`, `status` set (the shell's report) |
| abandoned | `ended`, `status == nil` (its shell went first) |

Invariants: **no command or turn is running without a live shell**; one
reading of "running" everywhere (`ended == nil`).

| From | Event | To |
|---|---|---|
| — | `.ran` | running |
| running | `.exited(status)` | ended(status) |
| running | `.shell(.ended/.dormant/.started)` | abandoned (`closeRuns`) |

Findings: I-2 — fixed.

#### M9 An output block's run · implicit
`OutputState.source`/`command`/`ran`/`ended`/`status`.
States: not a command (a file's old version: `ran` nil) · running (`ran`,
no `ended`) · ended(status) · abandoned (`ended`, no status: its shell
died). Invariant: words for it come from one place (`OutputState.run`,
`.outcome`). Findings: I-2 — fixed.

#### M10 A terminal's shell (model) · implicit
`TerminalState.pid`, `busy`, `dormantSince`, `dormantAfter`.
States: never started · live(idle | busy) · ended · dormant. "Never started"
and "ended" share a shape. Invariants: `busy ⇒ pid != nil`; `dormantSince
⇒ pid == nil`. Readers each test their own mix (Agents, ThreadMentions,
Finder, StatusGlyph). After the server restarts nothing reconciles a stale
`pid` until the terminal attaches (`.started`). Decision: computed phase
with I-2; reconcile stale state when the server starts.

#### M11 Search and notebook "running" (model) · implicit
`SearchState.running`; `NotebookState.running`/`queued`/`pid`. Kept
consistent while the server lives; stale after a crash. Decision: reconcile
at server start (with M10).

#### Fine as they are (model)
`TextState` disk state (unread / unreadable / clean / dirty / stale; kept
by `apply`), `StatusRecord` (explicit; mirrors OSC 7501), arrangement
focus and maximized tile (`normalize`), a block's payload by kind,
`SyntaxTree`, `PathCrawl`, `ThreadState.resolved` (a cache).

### App

#### M14 HostClient — a host's link · implicit (one explicit part)
HostClient.swift: `link: Standing` (connecting / connected /
unreachable(why)) plus `conn`, `mux`, `child`, `isConnected`,
`disconnected`, `erased`, `retryWork`/`nextTry`/`backoff`,
`closedUnanswered`, `droppedSilent`, `serverRestarting`, `pingTimer`,
`pingSent`, `connectedSince`. Bootstrap steps in `Hosts`.

| State | Held as |
|---|---|
| bootstrapping(step) | `step`, Hosts' `attaching` |
| handshaking | `isConnected`, `link == .connecting` |
| connected | `link == .connected` |
| waiting to retry | `link == .unreachable`, `retryWork` set |
| unreachable | `link == .unreachable`, no retry |
| erased / closed | `erased` / `disconnected` |

Invariants: the reason a link closed is decided where it's closed, not
read back from `link` afterwards; `closedUnanswered` counts only links the
host never answered.

| From | Event | To |
|---|---|---|
| handshaking | welcome | connected |
| connected | heartbeat finds silence | (close, silent: answered, "not answering") → waiting to retry (0.3 s) |
| connected | closed by the far side | waiting to retry (back-off) |
| handshaking | closed | waiting to retry; `closedUnanswered += 1`; at 3 → bootstrapping |
| any | `disconnect` | closed |

Findings: I-6 — fixed. Suspected, open: the heartbeat isn't stopped across a
reconnect, so a slow handshake after the first connection is dropped at
~8 s.

#### M15 Editor editability and mode · implicit
EditorView `viewing`, `offline`, `isLoaded`, `document.unreadable`,
`fileHistory.position` (scrubbed), `pastDocument`.
Invariant: editable ⇔ loaded ∧ readable ∧ online ∧ not viewing ∧ not on a
past revision; computed in one place (`readOnly`, `updateEditable()`),
called wherever one of them changes. Findings: I-4 — fixed.

#### M16 Editor file history and blame · implicit
`fileHistory` (shown, position), `blameShown`, `historyAsked`, the strip's
mirror. Rule: `fileHistory` kept ⇔ strip shown ∨ blame on. No live bug.

#### M17 TerminalLink — a terminal's attachment · implicit
`stream`, `attaching`, `attached`, `everAttached`, `acceptInput` (under a
lock). States: never attached → attaching → replaying → live → detached
(ever attached) → stopped. Invariant: an attach after the first is a
resume — `resume()`'s and `resized()`'s alike. Findings: I-6 — fixed.

#### M18 LocalCopies — a remote file opened here · implicit
`Copy.sending`, `modified`, the `settle` debouncer. States: watching →
settling → (host away: waiting, quietly) → sending → watching; let go
(deleted, host gone). Invariant: a send is tried only while its host is
connected. Findings: I-5 — fixed.

#### Fine as they are (app)
`ProxyConnection.step` (explicit), StreamPipe, Transfer, EchoPrediction
(independent flags with `debugState`), PortForwards, `Transfers.Item.state`,
MarkdownView's page (consistent; reset code repeated four times).

### Window, grid and sidebar

#### M20 A drag over the window · implicit
`draggingTab`, each `GridView.dragging` (its catcher), `dropped`, `drop`.
Invariant: **only the grid shown has a catcher, and only during a drag.**
Transitions: drag begins → catcher on the grid shown; space changes →
catcher moves with it; drag ends → none. Findings: I-3 — fixed.

#### M21 ⌃⇥ tile walk · explicit (`TileWalk`)
`tileWalk: TileWalk?` (space, places, index), `tileHold`, `walkPreview`
(computed), `dockSeen` (borrowed while walking).
States: idle · walking(space, index).

| From | Event | To |
|---|---|---|
| idle | ⌃⇥ with control held | walking (index ±1) |
| walking | ⌃⇥ / ⌃⇧⇥ | walking (index stepped, wrapping) |
| walking | control let go | idle; gone to the place (arrival glow) |
| walking | Escape | idle; the space as it was |
| walking | another space shown | idle; nothing gone to |

Invariants: a walk belongs to the space it began in; its preview is that
space as it is now, with the walked tile focused. Findings: I-3 — fixed.

#### M22 Space slide · implicit
`slidingAway`, `sliding` (always `slidingAway != nil`), `shownArrangement`.
Finding: I-8 (suspected completion race).

#### M23 `$EDITOR` stacks · implicit
`stackTops` (terminal → editor) and `stacked` (= its values). Finding:
I-8 (suspected leak off screen).

#### M24 Departure intents · implicit
`flownAway`, `replacedInPlace`, `recentlyClosed`, consumed by
`departure()` in order. Entries for views that never depart leak (minor).

#### M25 Overlays over the grid · implicit
`stateView`+`stateShown`, `history`, `neighborhoodView`, `emptyState`,
`spacePeek`, `spaceSwitcher`. Finding: I-8 (suspected).

#### M26–M28 ⌘\` switch, ⌃- navigation, dead arrival code
⌘\`: `spaceSwitch`/`spaceSwitchHold`, coherent; the order is a snapshot.
`navigating`: a fixed 0.6 s reset, no token. GridView's `pendingArrival`,
`hold`, `arrive`: never set or called (dead).

### Other views

#### M29 Web page route · explicit store (`WebView.Store`)
WebView `through` (the way: nil, from here; or a host), `store`,
`retryWhenBack`, `generation` (answers from an earlier way let go),
`failure`.

| From | Event | To |
|---|---|---|
| none | through a host wanted | asked(pending: nil) |
| asked | an address loaded | asked(pending: it) |
| asked | the store comes | ready; the block's page loaded, then the pending one |
| asked | none to be had | unavailable(why, for: the address wanted) |
| unavailable | another address wanted | asked (again) |
| unavailable | the same address | unavailable |
| any | the way changes | none, then as above |

Invariant: from every state an address wanted leads somewhere — loaded,
waited for, or the way asked for again. `debugRoute` names the state.
Findings: I-5 — fixed.

#### M30 Toast · implicit
ToastView `isHidden`/`alphaValue` (the real phase), `hideWork`, `then`,
`counting`, `remaining`, `runningSince`, `pointerOn`.
States: hidden · running · held (pointer on it) · leaving (fading).
Invariant: a fade's end hides only the toast it began to hide (`shows`).
Findings: I-7 — fixed.

#### M31–M37 Smaller
Project search work (M31, fixed: `searchSoon`), project facts' git/index load (M32, "Not in a
repository" for three different states), PathInserter's status kept in its
words (M33), footer menu `(view?, which)` (M34), Finder's mode (M35), the
thread card popover (M36), copy-check timers, LinkBadge's gap preview,
MediaView reloading on every window move (M37).

#### M38 A thread chat's composer · explicit (`editing`)
`ThreadChatView.editing` (the entry), `draft` (what was being written).
States: composing · editing(entry, draft?).

| From | Event | To |
|---|---|---|
| composing | Edit Comment (yours) · ↑ with nothing written (your last) | editing; what was written kept as the draft |
| editing | ↩ (words) | composing; the edit proposed; the draft back |
| editing | ⎋ | composing; nothing changed; the draft back |
| editing | the comment gone from the thread | composing; the draft back |

Invariants: only your own comments are edited (the host refuses another
author's, `editThreadEntry`; `apply` ignores one); ↩ never sends a new
comment while editing. Tests: `ManifoldAppTests/CommentEditTests`,
`ManifoldCoreTests/ThreadEditTests`.

#### M39 A host's pill in the strip · derived
`SpaceStripView.Pending`: a remote host with no state yet (`!hasState`),
connecting (turning ring) or unreachable (its mark). Gone once the host
welcomes this launch and its spaces take its place; the pointer on it,
the host's card, its standing live (`HostDashboard.standing`: the step
under way, its progress, how long).

#### M40 The drop palette · implicit
`DropPalette.shown`, `watch`; opened by a rest's timer (`Dropping.rest`)
or ⌃. States: closed · open(target, anchor, forms).

| From | Event | To |
|---|---|---|
| closed | the drag rests over a target with choices (or ⌃) | open — only while the drag's going |
| open | dropped on a row · moved well past it · the drag's over (no button held) | closed |

Invariant: **open only during a drag.** AppKit doesn't reliably tell a
destination a drag was given up (⎋, let go where nothing takes it), and a
rest's timer can fire just after: the palette stayed over the window,
stuck. **Fixed**: it opens only while the button's held (`dragGoing`), and
while open looks a few times a second for the drag being over. Tests:
`ManifoldAppTests/DropPaletteTests`.

#### Fine as they are (views)
BusyNote (explicit), HoverCard (has `debugState`), the timeline's visit,
notebook cells, ManiDesk's waits, PopMenu, ScrollerFlash, ScrubberView,
the previews' token counters.
