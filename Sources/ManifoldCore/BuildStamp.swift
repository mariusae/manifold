import CBuildStamp
import Foundation

/// What a build was made from (scripts/stamp-build.sh): its git revision
/// and when that was first built. The app's, and its host's server's as it
/// said on welcoming it.
public struct BuildStamp: Codable, Sendable, Equatable {
    /// The git revision, "-dirty." and a hash of the changes after it when
    /// the tree had any; "" for a build without a stamp (a plain `swift build`).
    public var revision: String
    /// When it was built, if it's known.
    public var built: Date?

    public init(revision: String, built: Date?) {
        self.revision = revision
        self.built = built
    }

    /// This build's.
    public static let current: BuildStamp = {
        let t = manifold_build_time()
        return BuildStamp(revision: String(cString: manifold_build_revision()), built: t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil)
    }()

    /// The revision as said: "unstamped" for none.
    public var revisionName: String { revision.isEmpty ? "unstamped" : revision }
    /// Built from a tree with changes not committed.
    public var dirty: Bool { revision.contains("-dirty") }
}
