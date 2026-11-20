import Foundation

/// Tracks desktop application launch edges; terminal processes are intentionally excluded.
public struct DesktopLaunchGate {
    private var previous: Set<String> = []
    public init() {}
    public mutating func shouldLaunch(enabled: Bool, paused: Bool, runningIDs: Set<String>, appRunning: Bool) -> Bool {
        let current = runningIDs.intersection(["com.openai.codex", "com.anthropic.claudefordesktop"])
        let newlyOpened = current.subtracting(previous)
        previous = current
        return enabled && !paused && !appRunning && !newlyOpened.isEmpty
    }
}

public struct DesktopRunSession {
    private var automatic: Bool
    public init(automatic: Bool) { self.automatic = automatic }
    public mutating func keepRunning() { automatic = false }
    public func shouldExit(claudeRunning: Bool, codexRunning: Bool) -> Bool {
        automatic && !claudeRunning && !codexRunning
    }
}

public enum DesktopActivation {
    public static func isCLI(_ url: URL) -> Bool { url.absoluteString == "quotapet://cli" }
}

public enum LaunchModeTransition {
    public static func shouldDisablePrevious(enabling: Bool, succeeded: Bool, active: Bool, needsApproval: Bool) -> Bool {
        enabling && succeeded && active && !needsApproval
    }
}
