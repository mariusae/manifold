import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `mani`, Manifold's command: `mani <command> [flags] [args]`. One table
/// of commands makes the parser, `mani help` and each command's `--help`,
/// so what's said and what's done can't drift apart. Shared by the app's
/// `mani` (in its Helpers) and a remote host's, which runs `manifoldd mani`;
/// each says how it reaches the host (`Platform`).
///
/// Strict: an unknown command or flag, a flag without its value, too many
/// or too few arguments are errors, with the command's usage, status 2;
/// a failure doing it is status 1. What's asked for goes to stdout, what
/// went wrong to stderr.
public enum Mani {
    public static let name = "mani"

    public struct Flag: Sendable {
        public var name: String
        public var short: Character?
        /// The value's name, for one that takes a value ("--title name").
        public var value: String?
        public var help: String
    }

    public struct Verb: Sendable {
        /// "open", or "skill install": a command of a group.
        public var words: [String]
        /// What follows the flags, as usage shows it: "[path ...]".
        public var args: String
        public var minArgs: Int
        public var maxArgs: Int?
        public var flags: [Flag]
        public var summary: String
        public var details: String
        /// Done by the app (passed on through the host), not here.
        public var inApp = false
        /// Reads its input (piped, or a file), unless --text gives it.
        public var readsInput = false

        public var name: String { words.joined(separator: " ") }

        /// "mani open [--wait] [path ...]"; "[flags]" for more than three.
        public var usage: String {
            let flagPart = flags.count > 3 ? ["[flags]"] : flags.map { f in "[--\(f.name)\(f.value.map { " " + $0 } ?? "")]" }
            return ([Mani.name, name] + flagPart + (args.isEmpty ? [] : [args])).joined(separator: " ")
        }
    }

    /// Where a block a command shows goes: by a tile (`--at`, else the one
    /// mani runs in, else the focused).
    static let placing: [Flag] = [
        Flag(name: "below", help: "below it, taking its lower half (where things go, unless told)"),
        Flag(name: "above", help: "above it, taking its upper half"),
        Flag(name: "right", help: "in the column to its right (a new one, if it's the last)"),
        Flag(name: "left", help: "in the column to its left (a new one, if it's the first)"),
        Flag(name: "column", help: "in a new column, right of it"),
        Flag(name: "over", help: "in its place, it docked, as ⌥ opens over"),
        Flag(name: "at", value: "name", help: "the tile it goes by"),
        Flag(name: "size", value: "share", help: "its share of its column, 0 to 1 (of the width, in a column of its own)"),
    ]
    static let json = Flag(name: "json", help: "as JSON")
    /// The space a command acts in, if not the one it runs in (or, run
    /// elsewhere, the one shown); `MANI_SPACE` says it for every command.
    static let space = Flag(name: "space", value: "name", help: "in that space, by name or id, not this one (else $MANI_SPACE)")

    public static let verbs: [Verb] = [
        Verb(words: ["ls"], args: "", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "all", help: "every space, and pinned blocks"), json, space],
             summary: "List the space's tiles: what each shows, where",
             details: """
                 The shown space's tiles, a row each: number, block id, kind,
                 title, and the names it answers to from here, and under it the
                 tile in a line (its summary: a terminal's last command and how it
                 ended, a note's first lines). With --json, the
                 whole layout: columns of tiles, each with its block, kind, title,
                 path, frame (x, y, width, height as shares of the window, from
                 the top left), the tiles sharing each of its edges (adjacent),
                 the names it answers to, its summary (title, place, lines, note,
                 tone); and the tiles docked, with where each was.
                 """, inApp: true),
        Verb(words: ["info"], args: "<name>", minArgs: 1, maxArgs: 1, flags: [],
             summary: "Describe a block, as JSON",
             details: """
                 A block: its id, kind, title, path, working directory, status,
                 where it's shown, its summary, its links, its outline. For @selection, where
                 the selection is (block, path, lines, page).
                 """, inApp: true),
        Verb(words: ["read"], args: "<name>", minArgs: 1, maxArgs: 1,
             flags: [Flag(name: "lines", value: "a-b", help: "only these lines (from 1; a- to the end)"),
                     Flag(name: "pages", value: "a-b", help: "a PDF's pages (from 1)"),
                     Flag(name: "command", value: "n", help: "a terminal's command and its output: 1 the first, -1 the last"),
                     Flag(name: "all", help: "a terminal's whole transcript, not just its screen"),
                     Flag(name: "outline", help: "the block's outline: a line and title each")],
             summary: "Print a block's content as text",
             details: """
                 What a block holds, as text: a note's or editor's text as it is
                 now (saved or not), a terminal's screen, a page's text, a PDF's
                 text, a diff's patch, a folder's listing, search results, a
                 notebook's cells and output. @selection prints what's selected.
                 """, inApp: true),
        Verb(words: ["context"], args: "", minArgs: 0, maxArgs: 0, flags: [json],
             summary: "Say where you are: space, focus, selection, commands",
             details: """
                 At a glance: the space and its tiles, the one mani runs in
                 and the focused one, the last selection (and where), the last
                 commands of the terminals shown with their status, and unsaved
                 files.
                 """, inApp: true),
        Verb(words: ["open"], args: "[path|url ...]", minArgs: 0, maxArgs: nil,
             flags: [Flag(name: "wait", short: "w", help: "return once they've been put away again (what $EDITOR runs)"),
                     Flag(name: "line", value: "n", help: "at this line"), space] + placing,
             summary: "Open files, folders and pages",
             details: """
                 Markdown opens in a live preview, a folder in a listing, a web
                 address as a page, anything else in an editor. Run in one of
                 Manifold's terminals, they go beside it; anywhere else, in the
                 shown space, with Manifold brought forward (and started if
                 need be). With no paths, brings Manifold forward.
                 """, inApp: true),
        Verb(words: ["new"], args: "<kind> [what]", minArgs: 1, maxArgs: 2,
             flags: [Flag(name: "title", short: "t", value: "title", help: "its title"),
                     Flag(name: "text", value: "text", help: "a note's text (else its input, if piped)"),
                     Flag(name: "preview", help: "a note shown rendered, as Markdown (an agent's always is)"),
                     Flag(name: "edit", help: "a note shown in an editor, to type into (an agent's too)"),
                     Flag(name: "cwd", value: "dir", help: "a terminal's, agent's or repository's directory (else this one)"),
                     Flag(name: "run", value: "command", help: "a terminal's command, typed in once it starts; an agent's first prompt"),
                     space] + placing,
             summary: "Make a block (" + BlockKinds.all.map(\.name).joined(separator: ", ") + ") or a space",
             details: """
                 Makes a block and shows it, printing its id (and it's @last) —
                 the kinds File ▸ New lists, and the New Block picker (⌘N) reads
                 as typed, the same way:
                 \(BlockKinds.help)
                   space [--title name]  a space with a terminal in --cwd; it prints
                                         the space's id, @last is the terminal

                 A script can make a space and fill it, every command after
                 the first acting there:
                   export MANI_SPACE=$(mani new space --title app --cwd ~/src/app)
                   mani new agent --right --size 0.6 --run "read the README"
                   mani new terminal --at @leftmost --below --run "make test"
                   mani new git --at @leftmost --over
                 """, inApp: true, readsInput: true),
        Verb(words: ["write"], args: "<name>", minArgs: 1, maxArgs: 1,
             flags: [Flag(name: "append", short: "a", help: "after what's there, not in its place"),
                     Flag(name: "text", value: "text", help: "the text (else the input)"),
                     Flag(name: "save", help: "a file's editor saved after")],
             summary: "Replace (or add to) a note's or file's text",
             details: """
                 Puts text in a note, or in a file's text as Manifold has it (the
                 file left unsaved unless --save).
                 """, inApp: true, readsInput: true),
        Verb(words: ["show"], args: "<name>", minArgs: 1, maxArgs: 1,
             flags: [Flag(name: "line", value: "n", help: "at this line"), space] + placing,
             summary: "Bring a block to view and focus it",
             details: """
                 A tile on screen is focused (its space shown); a block that
                 isn't is placed, by the tile it's told, else beside this one.
                 """, inApp: true),
        Verb(words: ["close"], args: "<name>", minArgs: 1, maxArgs: 1, flags: [],
             summary: "Take a tile off its space (as ⌘W), or remove a space (as ⇧⌘W)",
             details: """
                 The tile goes, as ⌘W takes it. A block nothing else keeps (no other tile, pin or link by hand) is collected after half an hour; until then ⌘O or Recently Closed brings it back.
                 A space named (by its name or id, or @space for this one) is removed from the sidebar, as ⇧⌘W removes it: to Recently Closed, its tiles' blocks collected after the same half hour unless something else keeps them — this terminal too, if it's in that space.
                 """, inApp: true),
        Verb(words: ["run"], args: "<terminal> <command ...>", minArgs: 2, maxArgs: nil,
             flags: [Flag(name: "wait", short: "w", help: "wait for it to end: print its output, exit with its status"),
                     Flag(name: "timeout", value: "seconds", help: "with --wait, give up after this long (status 124)"), space],
             summary: "Run a command in a terminal",
             details: """
                 Types the command into the terminal's shell, and return, as if
                 at its keyboard. With --wait, waits for it to end (the shell's
                 integration says when) and prints what it printed.
                 """, inApp: true),
        Verb(words: ["pin"], args: "<name>", minArgs: 1, maxArgs: 1, flags: [],
             summary: "Pin a block in its space",
             details: "Pinned, it heads its space in the sidebar and stays there when its tile is closed.", inApp: true),
        Verb(words: ["unpin"], args: "<name>", minArgs: 1, maxArgs: 1, flags: [],
             summary: "Unpin a block", details: "Takes the pin `mani pin` (or the menus) put on it.", inApp: true),
        Verb(words: ["link"], args: "<from> <to>", minArgs: 2, maxArgs: 2,
             flags: [Flag(name: "note", value: "text", help: "what the link is for"),
                     Flag(name: "as", value: "relation", help: "what it means: describes, annotates, explains, step, or any word")],
             summary: "Link one block (or a place in it) to another",
             details: """
                 A link by hand, as a ⇧-drag onto a tile makes: among both tiles' links,
                 followed from either. Either end may be a place, as a reference names
                 one (`mani ref` prints them): a note that describes a function is
                   mani link @last "$(mani ref Sources/App.swift --symbol App.run)" --as describes
                 """, inApp: true),
        Verb(words: ["threads"], args: "", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "project", help: "the project this folder is in, not the space"),
                     Flag(name: "place", value: "reference", help: "only those about this place (or block)"),
                     Flag(name: "all", help: "resolved ones too"), json, space],
             summary: "List the space's threads: comments on places, yours and agents'",
             details: """
                 The open threads of the space mani runs in (else the one shown) — or
                 of a project, or about a place — each: its reference, what it's
                 about and where that is now (moved, or gone), the text it was
                 written against, and its comments, each with who wrote it. Reply
                 with `mani thread reply`, by the reference it prints.
                 """, inApp: true),
        Verb(words: ["thread", "read"], args: "<thread>", minArgs: 1, maxArgs: 1, flags: [json],
             summary: "Print a thread: its place, what it was written against, its entries",
             details: """
                 Where the place is now (and the line it was written at, if it moved;
                 "gone" if its lines were deleted — then the text it was written
                 against is all there is), then every entry: comments, with who
                 wrote each, and what happened (resolved, reopened, edited).
                 """, inApp: true),
        Verb(words: ["thread", "new"], args: "<place> [text]", minArgs: 1, maxArgs: 2, flags: [],
             summary: "Start a thread about a place: a reference, a file, a block, or @selection",
             details: """
                 A thread about the place (`mani ref` prints one: a declaration, a
                 line), its first comment the text (else the input). Written as you,
                 or, run by an agent in its terminal, as that agent. Prints the
                 thread's reference.
                 """, inApp: true, readsInput: true),
        Verb(words: ["thread", "reply"], args: "<thread> [text]", minArgs: 1, maxArgs: 2,
             flags: [Flag(name: "resolve", help: "and resolve it (only what you did)")],
             summary: "Reply to a thread",
             details: """
                 A comment on the thread (the text, else the input) — as the agent
                 whose terminal runs it, or as you. --resolve resolves it after:
                 only when you did what it asked.
                 """, inApp: true, readsInput: true),
        Verb(words: ["thread", "resolve"], args: "<thread>", minArgs: 1, maxArgs: 1, flags: [],
             summary: "Resolve a thread", details: "Done with, as Resolve in its chat.", inApp: true),
        Verb(words: ["thread", "reopen"], args: "<thread>", minArgs: 1, maxArgs: 1, flags: [],
             summary: "Reopen a resolved thread", details: "As Reopen in its chat.", inApp: true),
        Verb(words: ["symbols"], args: "<file>", minArgs: 1, maxArgs: 1, flags: [],
             summary: "List a file's declarations (or a Markdown text's headings)",
             details: """
                 Each declaration its language's grammar finds — its path (`Type.method`)
                 and the line it starts on — or each heading of a Markdown text, indented
                 by its level. What `mani ref --symbol` and `--heading` take.
                 """, inApp: true),
        Verb(words: ["project"], args: "[folder]", minArgs: 0, maxArgs: 1,
             flags: [Flag(name: "make", help: "make the folder a project"),
                     Flag(name: "remove", help: "the project it's in, no longer one")],
             summary: "The project a folder is in: its root, its changes, its index",
             details: """
                 The project this folder (or the one named) is in — the nearest folder
                 above it made a project, on its host — with its repository's branch and
                 its own changes (where it's a folder deep in the repository, those in it
                 alone) and how its index stands. --make makes the folder a project
                 (indexed at once, if its language has an indexer); --remove makes the
                 one it's in a folder again. In the app, its folder's tile shows its
                 homepage, and searches it.
                 """, inApp: true),
        Verb(words: ["index"], args: "[file or folder]", minArgs: 0, maxArgs: 1,
             flags: [Flag(name: "wait", short: "w", help: "wait for it to be made, and say how it went"),
                     Flag(name: "status", help: "only say how the index stands")],
             summary: "Index a project (SCIP): its symbols, and where each is used",
             details: """
                 Runs the indexer for the project the file (else this folder) is in, on
                 its host, in the background: rust-analyzer for a Cargo crate,
                 scip-typescript (TypeScript, JavaScript) and scip-python, fetched by npx
                 when first used; scip-go, scip-clang (with compile_commands.json) and
                 scip-java where they're installed. Then `mani refs` finds where a symbol
                 is used across the project, and Find References does when no language
                 server answers. Run it again after big changes.
                 """, inApp: true),
        Verb(words: ["refs"], args: "<file or reference>", minArgs: 1, maxArgs: 1,
             flags: [Flag(name: "symbol", value: "path", help: "a declaration in the file, by its path (`Type.method`) or name"),
                     Flag(name: "line", value: "n", help: "the declaration at this line (from 1)"),
                     Flag(name: "markdown", help: "each as a reference, [file:line](manifold:…), for a note")],
             summary: "Where a symbol is used across its project (from its SCIP index)",
             details: """
                 Every place the symbol is used, across the project's files, from its
                 index (`mani index` makes it): `path:line: the line`, its definition
                 marked. The symbol by a reference to it (`mani ref` prints one), or a
                 file and --symbol or --line. --markdown prints each as a reference to
                 its place, for a walk through code.
                 """, inApp: true),
        Verb(words: ["callers"], args: "<file or reference>", minArgs: 1, maxArgs: 1,
             flags: [Flag(name: "symbol", value: "path", help: "a declaration in the file, by its path (`Type.method`) or name"),
                     Flag(name: "line", value: "n", help: "the declaration at this line (from 1)"),
                     Flag(name: "depth", value: "n", help: "callers of the callers, this many levels (1 to 4; 1 if not said)")],
             summary: "The functions that call a symbol, across its project (from its SCIP index)",
             details: """
                 Each function that uses the symbol — found by the index, named by the
                 grammar of the file it's in — with where it does, as Markdown: each a
                 reference, for a note or a walk (Code ▸ Show Callers makes the note).
                 --depth goes up the tree.
                 """, inApp: true),
        Verb(words: ["ref"], args: "<file>", minArgs: 1, maxArgs: 1,
             flags: [Flag(name: "symbol", value: "path", help: "a declaration, by its path (`Type.method`) or name"),
                     Flag(name: "heading", value: "title", help: "a Markdown heading, by its title"),
                     Flag(name: "line", value: "n", help: "a line (from 1): the declaration or heading there, else the line"),
                     Flag(name: "markdown", help: "as a Markdown link, [name](reference)")],
             summary: "Print a reference to a place in a file: a declaration, a heading, a line",
             details: """
                 A reference (`manifold:host/id#anchor`) to the place: kept by the file as
                 it changes — the declaration or heading followed wherever it moves —
                 and the same reference again for the same place. Put it in a note, a
                 link (`mani link`), a walk through code: Manifold shows it as a pill,
                 a card, and goes there when it's followed.
                 """, inApp: true),
        Verb(words: ["annotate"], args: "<name> [key=value…]", minArgs: 1, maxArgs: nil,
             flags: [json],
             summary: "Keep keys and values on a block or a space, for tools to know it by",
             details: """
                 Sets each key to its value on the block (`key=` takes it away); with
                 none, prints its keys, `key=value` a line. A tool's own handle on a
                 block or a space — a task's id, a role — that stays whatever its title
                 becomes: name it by one anywhere a name goes,
                   mani annotate @last task=T-123 role=build-log
                   mani read task=T-123
                   mani ls --space space=review
                 `'key=*'` (quoted, for the shell) names the one block with that key,
                 whatever its value. The inspector (⌥⌘I) shows them.
                 """, inApp: true),
        Verb(words: ["rename"], args: "<name> <title>", minArgs: 2, maxArgs: 2, flags: [],
             summary: "Give a block a title", details: "Its title, as Name… in the tile's menu sets a note's, or a space's in its row's.", inApp: true),
        Verb(words: ["watch"], args: "", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "only", value: "events", help: "these events, by kind, comma-separated")],
             summary: "Print what happens, a JSON line each",
             details: """
                 Until interrupted, a JSON object a line for each thing that
                 happens: focus (a tile focused), selection (text selected,
                 where), command (a terminal's command started or ended, with its
                 status), status (a block's status), open and close (a tile shown,
                 taken off), save (a file saved), space (another shown), panel
                 (something done in a panel, as `ui wait` prints it).
                 """, inApp: true),
        Verb(words: ["ui", "new"], args: "< widgets", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "title", short: "t", value: "title", help: "its title (else the widgets')"),
                     Flag(name: "text", value: "json", help: "the widgets (else the input)")] + placing,
             summary: "Make a panel of widgets, from JSON",
             details: """
                 A panel: native widgets described as JSON, {"title": …, "items":
                 [widget, …]}, each widget {"type": …, "id": …, …}:
                   label, markdown  {"text"}; "style": heading | secondary
                   button           {"label", "run"?}; "style": primary
                   field, text      {"label", "value", "placeholder"} (text: lines)
                   checkbox         {"label", "value": true|false}
                   select           {"label", "options": […], "value"}
                   slider           {"label", "min", "max", "step", "value"}
                   progress         {"label", "value": 0…1, or null for busy}
                   table            {"columns": […], "rows": [[…]], "select": single|multiple}
                   list             {"items": […], "select": single|multiple}
                   image            {"path", "height"}
                   row, group       {"items": […]} side by side; boxed, with a "label"
                   divider
                   html             {"html", "height"}: a page; mani.emit(name, value)
                 Any can have "disabled", "tip". A widget with "run" runs that
                 command (sh, in the panel's folder) when used, with MANI_EVENT
                 (JSON) and MANI_VALUE set, and the panel as @here. Prints the
                 panel's id.
                 """, inApp: true, readsInput: true),
        Verb(words: ["ui", "set"], args: "<panel> [id=value ...]", minArgs: 1, maxArgs: nil,
             flags: [Flag(name: "text", value: "json", help: "new widgets in place of the old (else the input, if piped)")],
             summary: "Set a panel's values, its widgets' properties, or its widgets",
             details: """
                 id=value sets a widget's value (JSON if it reads as JSON: 0.4,
                 true, [1,2]; else a string); id.property=value sets one of its
                 properties (label, text, rows, options, disabled, …). Widgets on
                 the input replace the panel's.
                 """, inApp: true, readsInput: true),
        Verb(words: ["ui", "get"], args: "<panel> [id]", minArgs: 1, maxArgs: 2, flags: [],
             summary: "Print a panel's values",
             details: "Every value, as a JSON object by widget id; or one, as itself (a string bare, anything else as JSON).", inApp: true),
        Verb(words: ["ui", "wait"], args: "<panel>", minArgs: 1, maxArgs: 1,
             flags: [Flag(name: "id", value: "id", help: "only what's done to this widget"),
                     Flag(name: "timeout", value: "seconds", help: "give up after this long (status 124)")],
             summary: "Wait for something to be done in a panel",
             details: """
                 Prints the next thing done in the panel, as a JSON line: event
                 (click, change, emit), the widget's id, its value, and all the
                 panel's values. What's done while nothing waits is kept for the
                 next wait, so a loop of waits misses nothing.
                 """, inApp: true),
        Verb(words: ["diff"], args: "< patch", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "title", short: "t", value: "name", help: "the diff block's title")],
             summary: "Show a patch as a diff block",
             details: """
                 Reads a patch from the input (git diff | mani diff) and shows it
                 beside this terminal as a diff block; double-click a line to open
                 the file there.
                 """),
        Verb(words: ["skill", "install"], args: "[agent ...]", minArgs: 0, maxArgs: nil, flags: [],
             summary: "Put Manifold's hooks in coding agents",
             details: """
                 Hooks in the coding agents found here, or those named (of
                 \(AgentSkill.known.joined(separator: ", "))), so a Manifold terminal running one shows
                 its status, and each of its turns in the tile's outline. The hooks run `mani agent`, and do nothing outside
                 Manifold's terminals. And the guide (`mani skill show`), so they
                 know mani: Claude Code's as a skill, Codex's from AGENTS.md.
                 And Claude Code's /block: its last response (or what's named
                 after it) shown beside its terminal, rendered. Installing again
                 replaces them.
                 """),
        Verb(words: ["skill", "show"], args: "", minArgs: 0, maxArgs: 0, flags: [],
             summary: "Print the guide for agents: seeing and driving Manifold",
             details: "The guide `skill install` gives Claude Code (as a skill) and Codex (pointed to from AGENTS.md): names, what users say and what to run, the commands."),
        Verb(words: ["skill", "uninstall"], args: "[agent ...]", minArgs: 0, maxArgs: nil, flags: [],
             summary: "Take Manifold's hooks out of coding agents",
             details: "Takes out what `mani skill install` put in: of the agents found here, or those named."),
        Verb(words: ["env"], args: "", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "for", value: "scope", help: "only those given to all, shells or tools"),
                     Flag(name: "show", help: "secrets' values too"), json],
             summary: "List the variables this host sets in what it starts, and its ssh agent",
             details: """
                 The host's server sets these in the environment of what it
                 starts, each for a scope: all; shells (terminals, notebooks,
                 panels' commands); or tools (what the server runs itself: the
                 code indexer and its fetches, language servers, git). They're
                 the host's, wherever it's reached from, and new shells and
                 tools get them; a shell already running, by `mani env export`.
                 Its shells' SSH_AUTH_SOCK is a link to the newest agent
                 forwarded to the host that answers, so they keep signing as
                 connections come and go (unless the host has its own agent).
                 """, inApp: true),
        Verb(words: ["env", "set"], args: "<NAME=value | NAME> ...", minArgs: 1, maxArgs: nil,
             flags: [Flag(name: "for", value: "scope", help: "all (the default for a new one), shells or tools")],
             summary: "Set variables this host gives what it starts",
             details: """
                 NAME alone takes its value from this shell. A variable set
                 again keeps its scope unless --for says another. A proxy for
                 the indexer's fetches only: mani env set --for tools
                 HTTPS_PROXY=http://proxy:3128 NO_PROXY=localhost.
                 """, inApp: true),
        Verb(words: ["env", "unset"], args: "<NAME> ...", minArgs: 1, maxArgs: nil, flags: [],
             summary: "Stop giving variables to what this host starts", details: "", inApp: true),
        Verb(words: ["env", "export"], args: "", minArgs: 0, maxArgs: 0,
             flags: [Flag(name: "for", value: "scope", help: "the scope's (shells, unless said)")],
             summary: "Print the variables as export lines, for a shell already running",
             details: """
                 With the agent's link: eval "$(mani env export)" in sh, bash or
                 zsh; mani env export | source in fish.
                 """, inApp: true),
        Verb(words: ["env", "agent"], args: "[socket]", minArgs: 0, maxArgs: 1, flags: [],
             summary: "Say how this host's ssh agent stands, or give its shells another",
             details: """
                 Agents forwarded to Manifold's connections and to ssh logins are
                 found on their own. A socket named (this shell's SSH_AUTH_SOCK,
                 if none is) is linked at once, if it's the newest.
                 """, inApp: true),
        Verb(words: ["agent"], args: "<event> [json]", minArgs: 1, maxArgs: 2,
             flags: [Flag(name: "agent", value: "name", help: "the agent the hook is in (claude, codex, ...)"),
                     Flag(name: "no-input", help: "read nothing from the input")],
             summary: "What agents' hooks run",
             details: """
                 Tells the terminal it runs in what its agent is doing, so the
                 terminal shows its status and turns. The event is one of
                 \(AgentHookCommand.events.joined(separator: ", ")). Reads the hook's JSON from the
                 input, or as the last argument. Prints nothing and always
                 succeeds once it's understood: no agent waits on it.
                 """),
        Verb(words: ["help"], args: "[command]", minArgs: 0, maxArgs: 2, flags: [],
             summary: "Say what mani does, or what a command does",
             details: "With a command, its usage, flags and what it does."),
    ]

    /// The guide for agents (`mani skill show`, and the skill `skill
    /// install` writes): how to see and drive what's on the user's screen,
    /// the commands from the table, and what users say mapped to them.
    public static var guide: String {
        let commands = verbs.filter { $0.inApp || ["diff"].contains($0.name) }.map { "- `\($0.usage)` — \($0.summary)" }
        return """
            # Manifold: the mani command

            You're in a Manifold terminal when MANIFOLD_BLOCK is set. Manifold lays out blocks —
            terminals, editors, notes, previews, pages, PDFs, diffs, panels — as tiles in
            columns, and `mani` reads and drives them: what the user sees, has selected, and ran.
            When they say "this", "that", "here", "on my right", "what I highlighted", look with
            mani before asking.

            ## Seeing
            - `mani context` — the layout, the last selection (and where), the terminals' last
              commands and how they ended, unsaved files. Start here when unsure.
            - `mani ls --json` — every tile: its block id, kind, title, path, frame (x, y, width,
              height as shares of the window, from the top left), the tiles on each edge
              (adjacent), the names it answers to (@left, @2, …), a summary of each (its
              last command and how it ended, its first lines), and what's docked.
            - `mani read <name>` — what a block holds, as text; `mani info <name>` — about it (JSON).

            ## Naming
            \(namesHelp.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n"))

            ## References
            A block's reference is `manifold:<host>/<id>`, with a place in it after `#`
            (`#line=12`, `#page=3`, `#command=7`); in Markdown it's a link,
            `[Its name](manifold:…)`, which a note shows as the block's name. You'll find them
            where the user put them: dragged into your prompt (a block, a file, an outline's
            item dropped on you comes as its reference, its link, its path or what it holds —
            they chose which as they dropped it), in a note's text, from Copy Link. Treat one as "that block":
            - Any mani command takes one as a name, either form: `mani read manifold:…`
              (at `#command=7`, that command's output; at `#page=3`, that page),
              `mani info manifold:…` (what and where it is, its links),
              `mani show manifold:…#line=12` (brought to view, at that line).
            - To change what it holds: `mani write manifold:… < new-text` (a note's or a
              file's whole text; `--append` adds; `--save` saves a file),
              `mani rename manifold:… "Name"`, `mani pin manifold:…`,
              `mani link manifold:A manifold:B` (A links to B, as the user's links do),
              `mani run --wait manifold:… "cmd"` for a terminal.
            - To give one back: `mani info <name>` has `ref` and `link`; `mani ls --json`
              has each tile's `ref`. Write the link into a note (`[name](manifold:…)`)
              and it shows as the block, a click away; on a line of its own as an image,
              `![name](manifold:…)`, it shows as the block's live card (a place's: a
              command's line and how it ended, a heading's section, a page); a reference
              written bare in a note shows as the block too. Print a reference in your reply
              and the user ⌘-clicks it to go there.
            - A reference to a block that's gone (deleted) or on a host that isn't connected
              says so; don't guess its contents.

            ## Places in code, and links between them
            A place in a file — a declaration, a heading — has a reference of its own,
            `manifold:<host>/<id>#<anchor>`, that follows it as the file changes (the
            function moved or the lines above it changed, it's still the function).
            Never write an anchor by hand; ask for it:
            - `mani symbols <file>`: its declarations (`Type.method` and their lines), or
              a Markdown file's headings.
            - `mani ref <file> --symbol Type.method` (or `--heading "Title"`, `--line 40`)
              prints the reference; `--markdown` as `[Type.method](manifold:…)`. The same
              place gives the same reference. `mani read` of one prints its lines.
            - Links have places at either end and say what they mean:
              `mani link <note> "$(mani ref <file> --symbol f)" --as describes` — a note
              that describes f (its pseudocode, what it's for). Relations: describes,
              annotates, explains, step, or any word. Manifold decides how to show them.
            - A walk through code (how a request is handled, what boot does) is a note of
              such references in order, a sentence each: make it with `mani new note`.
            - `mani info <file>` lists its places referred to and what links to each.
            - `mani project` says which project you're in (its root, changes, index);
              a folder deep in a repository can be one, its changes its own.
            - Across files: `mani index` (in the project; `--wait`) makes its SCIP index,
              then `mani refs <file> --symbol Type.method` (or a reference) lists every
              place the symbol is used, `path:line: the line`; `--markdown` as references,
              ready for a walk. Use it before guessing at callers with grep.

            ## Threads: comments on places, yours and the user's
            The user leaves threads — comments on a line, a declaration, a diff's rows, a
            command, a page, or the space — and asks you in one by tagging you (`@claude`),
            or hands you a set ("address these"). Manifold then types a line into your
            terminal naming the thread. Work in the thread, not in your reply here:
            - `mani thread read <thread>` — what it's about, where that is now (the line it
              was written at, if it moved; "gone" if deleted — then the text it was written
              against is all there is, so read it), and every comment with who wrote it.
              `mani threads` lists the space's open ones (`--project`, `--all`).
            - Do what it asks; then `mani thread reply <thread> "what you did"`, with
              `--resolve` only if you did it. A question, or a choice for the user, is a reply
              without `--resolve` — then go on with the rest; don't stop to ask in the terminal.
            - Never resolve what you didn't address. Keep replies short; they're read beside
              the code.
            - Where you're unsure of something you did (an assumption, a guess), leave a
              thread on it for the user: `mani thread new "$(mani ref <file> --line 40)" "…"`.
            - Your replies are marked as yours by Manifold; you can't write as the user.

            ## What the user says, and what to run
            - "this" with a `manifold:` reference in their message: `mani read <it>` (and
              `mani info <it>` for where it is); "fix that note": read it, then `mani write` it.
            - "the code I highlighted", "this selection": `mani read @selection`;
              where it is (file, lines): `mani info @selection`.
            - "the diff on my right": `mani read @right:diff` (or `@right` if it's the only one).
            - "this PDF describes an algorithm": `mani read @:pdf` (`--pages 3-5` for some).
            - "the page I have open": `mani read @:web`.
            - "what failed in the other terminal": `mani read @right:terminal --command -1`.
            - "render the result in a new markdown block": `… | mani new note --preview --title Result`.
            - "open it", "show me": `mani open path/to/file --line 42` (beside you).
            - "run the tests over there": `mani run @right:terminal --wait "make test"` — prints the
              output and exits with the command's status.
            - "let me choose", "ask me": a panel —
              `mani ui new <<< '{"title":"Pick","items":[{"type":"list","id":"pick","items":["a","b"],"select":"single"},{"type":"button","id":"ok","label":"OK","style":"primary"}]}'`,
              then `mani ui wait @last --id ok` and `mani ui get @last pick`.
            - "show progress": a panel with a progress widget, and `mani ui set @last progress=0.5 status="Building"`.
            - "set up a space for this repo": `export MANI_SPACE=$(mani new space --title app --cwd .)`,
              then `mani new agent --right --size 0.6 --run "…"`, `mani new terminal --at @leftmost
              --below --run "make test"`, `mani new git --at @leftmost --over` — each in that space.

            ## Commands
            \(commands.joined(separator: "\n"))

            `mani <command> --help` says more; `mani ui new --help` lists the widgets.

            ## Conventions
            - What you make goes below this terminal unless told: --right, --left, --above,
              --column (a new one), --over (in its place, it docked), by --at another tile; --size gives it a share
              of its column. `@last` is what mani last made. --space (or $MANI_SPACE) acts in
              another space, without showing it.
            - `new`, `open` and `show` move the user's focus; prefer `read`, `info`, `ls` to look.
            - Output is for reading; errors go to stderr with status 1 (couldn't), 2 (asked wrong).
              A name that could be several tiles fails and lists them: pick one by its id.
            - `mani read` gives a file's text as Manifold has it, unsaved edits included; read
              the file itself if you want what's on disk.
            """
    }

    /// How blocks are named, for the overview (and agents).
    public static let namesHelp = """
        Blocks are named by reference (manifold:host/id), id (as ls prints it), path,
        title, or position:
          @here        the terminal mani runs in       @focused   the focused tile
          @selection   the last text selected outside @here (read it; info says where)
          @last        the block mani last made         @space     the space shown
          @left @right @above @below   the nearest tile that way from @here
          @leftmost @rightmost @top @bottom   the outermost tile that way
          @1 … @9      tiles in order
        Or by what it's annotated with (mani annotate): key=value, 'key=*' for
        any value — the one block (or space) with it, in the space shown first.
        A kind narrows one: @right:diff, @:pdf (the one PDF shown). Kinds:
        note, file, terminal, agent, folder, web, image, pdf, search, diff,
        output, notebook, git, preview, editor, ui. A name that could be more
        than one is an error, listing them.
        """

    /// What was asked for.
    public enum Parsed: Equatable, Sendable {
        case run(Invocation)
        /// Help: about a command (its name), or about mani.
        case help(String?)
    }

    public struct Invocation: Equatable, Sendable {
        public var verb: String
        /// Flags given, by name: a value, or "" for one that takes none.
        public var flags: [String: String]
        public var args: [String]

        public func has(_ flag: String) -> Bool { flags[flag] != nil }
        public func value(_ flag: String) -> String? { flags[flag] }
    }

    public struct UsageError: Error, Equatable, Sendable {
        public var message: String
        /// The command it's about, whose usage goes with it.
        public var verb: String?
    }

    public static func verb(_ name: String) -> Verb? { verbs.first { $0.name == name } }

    /// The argument list (less the program's name) as a command.
    public static func parse(_ argv: [String]) -> Result<Parsed, UsageError> {
        guard let first = argv.first else { return .success(.help(nil)) }
        if first == "-h" || first == "--help" { return .success(.help(nil)) }
        if first.hasPrefix("-") {
            return .failure(UsageError(message: "\(first) isn't a command; the command comes first"))
        }
        let groups = Set(verbs.filter { $0.words.count > 1 }.map { $0.words[0] })
        // The longest command the words begin with.
        guard let verb = verbs.filter({ argv.starts(with: $0.words) }).max(by: { $0.words.count < $1.words.count }) else {
            if groups.contains(first) {
                let next = argv.dropFirst().first
                if next == "-h" || next == "--help" { return .success(.help(first)) }
                let subs = verbs.filter { $0.words[0] == first }.map { $0.words[1] }
                let message = next.map { "\(first) has no command \($0)" } ?? "\(first) needs a command"
                return .failure(UsageError(message: message + ": " + subs.joined(separator: ", "), verb: first))
            }
            var message = "no command \(first)"
            if FileManager.default.fileExists(atPath: first.expandingTildeInPath) { message += " (to open it: mani open \(first))" }
            return .failure(UsageError(message: message))
        }
        var flags: [String: String] = [:]
        var args: [String] = []
        var rest = argv.dropFirst(verb.words.count).makeIterator()
        var onlyArgs = false
        while let a = rest.next() {
            if onlyArgs || a == "-" || !a.hasPrefix("-") {
                args.append(a)
                continue
            }
            if a == "--" {
                onlyArgs = true
                continue
            }
            if a == "-h" || a == "--help" { return .success(.help(verb.name)) }
            var given = a
            var inline: String?
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                given = String(a[..<eq])
                inline = String(a[a.index(after: eq)...])
            }
            let flag = given.hasPrefix("--")
                ? verb.flags.first { "--" + $0.name == given }
                : verb.flags.first { $0.short.map { "-\($0)" } == given }
            guard let flag else {
                return .failure(UsageError(message: "\(verb.name) has no flag \(given)", verb: verb.name))
            }
            if flag.value != nil {
                guard let value = inline ?? rest.next() else {
                    return .failure(UsageError(message: "--\(flag.name) needs a value", verb: verb.name))
                }
                flags[flag.name] = value
            } else {
                guard inline == nil else {
                    return .failure(UsageError(message: "--\(flag.name) takes no value", verb: verb.name))
                }
                flags[flag.name] = ""
            }
        }
        if args.count < verb.minArgs {
            return .failure(UsageError(message: "\(verb.name) needs \(verb.args)", verb: verb.name))
        }
        if let max = verb.maxArgs, args.count > max {
            let extra = args[max]
            return .failure(UsageError(message: max == 0 ? "\(verb.name) takes no arguments (\(extra))" : "\(verb.name) takes at most \(max) (\(extra))", verb: verb.name))
        }
        if verb.name == "help" {
            guard !args.isEmpty else { return .success(.help(nil)) }
            let name = args.joined(separator: " ")
            guard Self.verb(name) != nil || groups.contains(name) else {
                return .failure(UsageError(message: "no command \(name)", verb: "help"))
            }
            return .success(.help(name))
        }
        return .success(.run(Invocation(verb: verb.name, flags: flags, args: args)))
    }

    /// What `mani help` says: every command, a line each; or a command's
    /// (or a group's) usage, what it does and its flags.
    public static func help(_ name: String?) -> String {
        guard let name else {
            let width = verbs.map { ($0.name + " " + $0.args).count }.max() ?? 0
            let lines = verbs.map { v -> String in
                let left = v.name + (v.args.isEmpty ? "" : " " + v.args)
                return "  " + left.padding(toLength: width + 2, withPad: " ", startingAt: 0) + v.summary
            }
            return """
                usage: mani <command> [flags] [args]

                Manifold, from a shell. Run in one of Manifold's terminals, mani acts
                beside it.

                \(lines.joined(separator: "\n"))

                \(namesHelp)

                What's asked for goes to stdout, what went wrong to stderr; status 0
                when done, 1 when it couldn't be, 2 when it was asked wrong.
                mani <command> --help says more about one.
                """
        }
        let matching = verbs.filter { $0.name == name || $0.words.first == name && $0.words.count > 1 }
        return matching.map { v in
            var out = "usage: \(v.usage)\n\n\(v.details)"
            if !v.flags.isEmpty {
                let names = v.flags.map { f in (f.short.map { "-\($0), " } ?? "") + "--\(f.name)" + (f.value.map { " " + $0 } ?? "") }
                let width = names.map(\.count).max() ?? 0
                out += "\n\n" + zip(names, v.flags).map { "  " + $0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $1.help }.joined(separator: "\n")
            }
            return out
        }.joined(separator: "\n\n")
    }

    /// How a platform's `mani` reaches the host.
    public struct Platform {
        /// Has the host do `body` over a connection to it (a socket's fd),
        /// starting what must be started and asking again if the app
        /// wasn't there (`ManiClient.absent`), and bringing Manifold
        /// forward if `activates` (a command that shows something, run
        /// outside it): the exit status.
        public var request: (_ activates: Bool, _ body: (Int32) -> Int32) -> Int32
        /// Brings Manifold forward, starting it if need be; nil where
        /// there's no app (a remote host).
        public var bringForward: (() -> Void)?

        public init(request: @escaping (_ activates: Bool, _ body: (Int32) -> Int32) -> Int32, bringForward: (() -> Void)?) {
            self.request = request
            self.bringForward = bringForward
        }
    }

    /// The block this runs in: one of Manifold's terminals says (MANIFOLD_BLOCK).
    public static var here: BlockID? {
        ProcessInfo.processInfo.environment["MANIFOLD_BLOCK"].flatMap(BlockID.init(string:))
    }

    /// Runs the command line and exits.
    public static func main(_ argv: [String], platform: Platform) -> Never {
        signal(SIGPIPE, SIG_IGN)
        let invocation: Invocation
        switch parse(argv) {
        case .failure(let error): usageError(error)
        case .success(.help(let name)):
            print(help(name))
            exit(0)
        case .success(.run(let i)): invocation = i
        }
        let ways = placing.filter { $0.value == nil && invocation.has($0.name) }.map { "--" + $0.name }
        if ways.count > 1 {
            usageError(UsageError(message: "one of \(ways.joined(separator: ", ")), not all", verb: invocation.verb))
        }
        if verb(invocation.verb)?.inApp == true {
            var request = ManiRequest(verb: invocation.verb, flags: invocation.flags, args: invocation.args,
                                      cwd: FileManager.default.currentDirectoryPath, here: here)
            // A script's space, said once for all its commands.
            if request.flags["space"] == nil, verb(invocation.verb)?.flags.contains(where: { $0.name == "space" }) == true,
               let s = ProcessInfo.processInfo.environment["MANI_SPACE"], !s.isEmpty {
                request.flags["space"] = s
            }
            if invocation.verb == "open" {
                // Paths made whole here, where they are; addresses as they are.
                var resolved: [String] = []
                for a in invocation.args {
                    if WebAddress.looksLikeURL(a) { resolved.append(a); continue }
                    switch OpenCommand.resolve([a]) {
                    case .success(let p): resolved += p
                    case .failure(let error): fail(error.message)
                    }
                }
                request.args = resolved
                if resolved.isEmpty {
                    guard let bringForward = platform.bringForward else {
                        usageError(UsageError(message: "open needs a path here: there's no Manifold on this host to bring forward", verb: "open"))
                    }
                    bringForward()
                    exit(0)
                }
            }
            let env = ProcessInfo.processInfo.environment
            if invocation.verb == "env set" {
                // NAME alone: its value here.
                request.args = invocation.args.map { a in
                    guard !a.contains("=") else { return a }
                    guard let v = env[a] else { fail("\(a) isn't set in this shell; give it a value: \(a)=…") }
                    return a + "=" + v
                }
            }
            if invocation.verb == "env agent", request.args.isEmpty, let s = env["SSH_AUTH_SOCK"], !s.isEmpty {
                request.args = [s]
            }
            if verb(invocation.verb)?.readsInput == true, invocation.value("text") == nil {
                request.input = readInput()
            }
            let shows = ["open", "new", "show", "ui new"].contains(invocation.verb)
            let status = platform.request(shows) { ManiClient.run(fd: $0, request: request) }
            if status == ManiClient.absent { fail("Manifold isn't attached to this host") }
            exit(status)
        }
        switch invocation.verb {
        case "diff":
            let patch: String
            switch OpenCommand.readPatch() {
            case .success(let p): patch = p
            case .failure(let error): fail(error.message)
            }
            let root = FileManager.default.currentDirectoryPath
            let title = invocation.value("title")
            let status = platform.request(true) { OpenCommand.runPatch(fd: $0, patch: patch, root: root, title: title, beside: here) }
            if status == ManiClient.absent { fail("Manifold isn't attached to this host") }
            exit(status)
        case "skill show":
            print(guide)
            exit(0)
        case "skill install", "skill uninstall":
            let names = invocation.args.map { $0.lowercased() }
            if let unknown = names.first(where: { !AgentSkill.known.contains($0) }) {
                usageError(UsageError(message: "no hooks known for \(unknown); known: \(AgentSkill.known.joined(separator: ", "))", verb: invocation.verb))
            }
            AgentSkill.runInstall(names, uninstall: invocation.verb == "skill uninstall")
        case "agent":
            let event = invocation.args[0]
            guard AgentHookCommand.events.contains(event) else {
                usageError(UsageError(message: "no event \(event); events: \(AgentHookCommand.events.joined(separator: ", "))", verb: "agent"))
            }
            AgentHookCommand.run(event: event, agent: invocation.value("agent") ?? "agent",
                                 readsInput: !invocation.has("no-input"), payload: invocation.args.dropFirst().first)
        default:
            fail("\(invocation.verb) isn't done yet")
        }
    }

    /// The input, if it's piped or a file (not a terminal, not nothing).
    static func readInput() -> String? {
        var st = stat()
        guard fstat(0, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        guard type == S_IFIFO || type == S_IFREG else { return nil }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    /// What went wrong and the usage that goes with it, on stderr; status 2.
    public static func usageError(_ error: UsageError) -> Never {
        var out = "mani: \(error.message)\n"
        let group = verbs.filter { $0.words.count > 1 && $0.words[0] == error.verb }
        if let name = error.verb, let v = verb(name) {
            out += "usage: \(v.usage)\n(mani \(name) --help says more)\n"
        } else if let name = error.verb, !group.isEmpty {
            out += group.map { "usage: \($0.usage)\n" }.joined() + "(mani \(name) --help says more)\n"
        } else {
            out += "commands: \(verbs.map(\.name).joined(separator: ", "))\n(mani help says more)\n"
        }
        FileHandle.standardError.write(Data(out.utf8))
        exit(2)
    }

    public static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("mani: \(message)\n".utf8))
        exit(1)
    }
}
