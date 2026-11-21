import AppKit
import ManifoldCore

/// What agents at work are doing now (§3.8) is what they say — their
/// host keeps it as their status's message (`Block.agentDoing`) — shown on
/// their bars where the tile can't show it: down to its bar, or its
/// conversation's end, where it's said, scrolled out of sight. Which
/// conversations have their end out of sight, they tell.
extension MainWindowController {
    func conversationEnd(_ placement: PlacementID, hidden: Bool) {
        guard conversationEndHidden.contains(placement) != hidden else { return }
        if hidden { conversationEndHidden.insert(placement) } else { conversationEndHidden.remove(placement) }
        render()
    }
}
