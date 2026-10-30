import AppKit
import ManifoldCore
import UserNotifications

/// The Mac's notifications for what happens out of sight (§3.7): a block
/// that comes to need you (an agent asking leave), one that finishes or
/// fails, a terminal's command that ran a while and ended. Only while
/// the block isn't in sight — Manifold not in front, or the tile not
/// showing — and only for what happens after launch. Clicked, it goes to
/// the block (and the command), as ⌘J does.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A command shorter than this ending says nothing.
    static let longCommand: Int64 = 10_000

    /// What's been seen of each block: its status record's stamp, and the
    /// last of its commands seen ended.
    private var seenStatus: [BlockID: Stamp] = [:]
    private var seenCommand: [BlockID: Int] = [:]
    private var seeded = false
    private var asked = false

    /// Whether the block is in sight now (Manifold in front, its tile showing).
    var inSight: (BlockID) -> Bool = { _ in false }
    /// A notification clicked: the block, and a command of it if one.
    var onOpen: ((BlockID, Int?) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Whose status is worth a notification: what runs (terminals,
    /// agents, notebooks) — not a git block's every refresh.
    static func speaks(_ kind: BlockKind) -> Bool { kind == .terminal || kind == .agent || kind == .notebook }

    /// The blocks as they are now: anything new out of sight said.
    func update(_ blocks: [Block]) {
        defer { seeded = true }
        for b in blocks {
            if let r = b.statusRecord {
                let new = seenStatus[b.id].map { $0 != r.at } ?? true
                seenStatus[b.id] = r.at
                if seeded, new, r.wantsAttention, Self.speaks(b.kind), !inSight(b.id) { post(status: r, of: b) }
            }
            // The shell's commands, not an agent's turns (marks on the
            // scrubber too): a turn ending is said by the agent's status.
            let turns = Set(b.terminal?.turns?.map(\.id) ?? [])
            if let commands = b.terminal?.commands, let last = commands.last(where: { $0.ended != nil && !turns.contains($0.id) }) {
                let before = seenCommand[b.id]
                seenCommand[b.id] = last.id
                if seeded, let before, last.id != before, let ended = last.ended, ended.wall - last.at.wall >= Self.longCommand, !inSight(b.id) {
                    post(command: last, of: b, took: ended.wall - last.at.wall)
                }
            }
        }
    }

    private func post(status r: StatusRecord, of b: Block) {
        let title: String, sound: Sound
        switch r.state {
        case .blocked: (title, sound) = ("\(b.displayTitle) needs you", .needsYou)
        case .error: (title, sound) = ("\(b.displayTitle) failed", .failed)
        default: (title, sound) = ("\(b.displayTitle) is done", .done)
        }
        post(id: "status-\(b.id)", title: title, body: r.msg ?? r.title ?? r.app ?? "", sound: sound, block: b.id, command: nil)
    }

    private func post(command c: ShellCommand, of b: Block, took ms: Int64) {
        let failed = (c.status ?? 0) != 0
        let title = failed ? "Failed after \(Self.duration(ms))" + (c.status.map { " (exit \($0))" } ?? "") : "Finished after \(Self.duration(ms))"
        post(id: "command-\(b.id)-\(c.id)", title: title, body: "\(c.text)\n\(b.displayTitle)", sound: failed ? .failed : .done,
             block: b.id, command: c.id)
    }

    /// What a notification sounds like: a knock on wood. Done, two, the
    /// second a touch higher; needs you, three, quicker, the last firmest;
    /// failed, two, slower, the second lower and duller. (Resources/Sounds,
    /// copied to the top of the bundle's Resources.)
    enum Sound: String {
        case done = "knock-done.caf", needsYou = "knock-needs-you.caf", failed = "knock-failed.caf"

        var url: URL? { Bundle.main.url(forResource: rawValue, withExtension: nil) }
    }

    /// The knock sounding, kept until it's done.
    private var playing: NSSound?

    /// The Mac plays a notification's named sound only if it's one of its
    /// own tones — it doesn't look in the bundle (ToneLibrary: "neither in
    /// of the collections for system or iTunes tones"), so the knock is
    /// played here, as the notification goes, when Manifold's may sound.
    private func play(_ sound: Sound) {
        guard let url = sound.url else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.soundSetting == .enabled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.playing = NSSound(contentsOf: url, byReference: true)
                self?.playing?.play()
            }
        }
    }

    static func duration(_ ms: Int64) -> String {
        let s = Int(ms / 1000)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    private func post(id: String, title: String, body: String, sound: Sound, block: BlockID, command: Int?) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // The knock's played by Manifold; the Mac's own sound only if it's missing (as under swift build).
            content.sound = sound.url == nil ? .default : nil
            content.threadIdentifier = block.description
            var info: [String: Any] = ["block": block.description]
            if let command { info["command"] = command }
            content.userInfo = info
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            self.play(sound)
        }
        posted.append(title + " — " + body.replacingOccurrences(of: "\n", with: " · "))
        // A test instance (it shares the app's identity) says nothing to the Mac.
        guard ProcessInfo.processInfo.environment["MANIFOLD_NO_NOTIFY"] == nil else { return }
        guard !asked else { return send() }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { DispatchQueue.main.async(execute: send) }
        }
    }

    /// Debugging: what's been posted.
    private(set) var posted: [String] = []

    // MARK: UNUserNotificationCenterDelegate

    /// In front, a block out of sight still says so, as a banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let block = (info["block"] as? String).flatMap(BlockID.init(string:))
        let command = info["command"] as? Int
        DispatchQueue.main.async { [weak self] in
            if let block { self?.onOpen?(block, command) }
            done()
        }
    }
}
