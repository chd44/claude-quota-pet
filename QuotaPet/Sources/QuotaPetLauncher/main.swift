import AppKit
import Combine
import QuotaPetCore

// No polling, file watching, quota parsing, or network requests in this process.
let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
let appURL = contents.deletingLastPathComponent()
let domain = "dev.quotapet.app"
// Keep this executable out of LaunchServices application identity registration.
// NSApplication.shared would make this helper impersonate its parent app.
if CommandLine.arguments.contains("--wake-cli") {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    NSWorkspace.shared.open([URL(string: "quotapet://cli")!], withApplicationAt: appURL, configuration: config) { _, error in
        exit(error == nil ? 0 : 1)
    }
    RunLoop.main.run()
    exit(0)
}
let prefs = UserDefaults.standard
var gate = DesktopLaunchGate()
var launching = false
func evaluate(_ ids: Set<String>) {
    prefs.synchronize()
    guard gate.shouldLaunch(enabled: prefs.bool(forKey: "desktopAutoLaunchEnabled"),
                            paused: prefs.bool(forKey: "desktopAutoLaunchPaused"),
                            runningIDs: ids, appRunning: launching || ids.contains(domain)) else { return }
    launching = true
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.arguments = ["--desktop-autostart"]
    NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
        DispatchQueue.main.async { launching = false }
    }
}
let relevantIDs: Set<String> = [domain, "com.openai.codex", "com.anthropic.claudefordesktop"]
let observer = NSWorkspace.shared.publisher(for: \.runningApplications, options: [.initial, .new])
    .map { apps in
        Set(apps.filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)).intersection(relevantIDs)
    }
    .removeDuplicates()
    .sink { evaluate($0) }
RunLoop.main.run()
