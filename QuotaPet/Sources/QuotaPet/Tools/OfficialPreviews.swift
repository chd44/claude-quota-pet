import AppKit
import SwiftUI
import QuotaPetCore

/// QuotaPet --render-official-previews <dir>：正常模式额度面板的预览图。
/// 只用合成读数，不运行 agy CLI，不读本机设置或账号。
@MainActor
enum OfficialPreviews {
    static func renderAll(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let reading = sampleReading(now: now)
        let unknown = AgyQuotaReading(status: .signInRequired, checkedAt: now.addingTimeInterval(-60))
        let gardener = OfficialPetChoice(rawValue: "agy-stargazer")!
        let samples: [(String, OfficialQuotaEntry, OfficialPetChoice, AgyQuotaReading?, String)] = [
            ("official-agy", .antigravity, .antigravity, reading, ""),
            ("official-agy-gardener", .antigravity, gardener, reading, ""),
            ("official-agy-unknown", .antigravity, .antigravity, unknown, tr("额度未知 · 请先在 agy CLI 登录", "Quota unknown · Sign in to agy CLI first")),
            // 选中 Claude / Codex 时 agy 不读取，页签上的 agy 也是「–」
            ("official-claude", .claude, OfficialPetChoice(rawValue: PetStyle.classic.rawValue)!, nil, ""),
            ("official-codex", .codex, OfficialPetChoice(rawValue: PetStyle.dragon.rawValue)!, nil, ""),
            ("official-claude-empty", .claude, OfficialPetChoice(rawValue: PetStyle.classic.rawValue)!, nil, "empty"),
        ]
        let usage = sampleUsage(now: now)
        // 过期：上次 CLI 读数是 40 分钟前
        let staleClaude = ClaudeUsageReading(status: .available, windows: [.init(kind: .session, usedPercent: 40, resetsAt: nil)],
                                             checkedAt: now.addingTimeInterval(-40 * 60)).snapshot(now: now)
        // 边界：读数是 14 分钟前的（仍新鲜），最紧张的 Claude / GPT 五小时窗口 5 分钟前已重置
        let resetSoon = sampleReading(now: now.addingTimeInterval(-600), tightResetIn: 300)
        for dark in [false, true] {
            L10n.language = .zhHans
            let view = OfficialOverviewView(entry: .antigravity, choice: .antigravity, artwork: artwork, reading: resetSoon,
                                            agyStatus: tr("额度未知 · 读数已过期或不完整", "Quota unknown · Reading expired or incomplete"),
                                            canOpenAntigravity: true, fixedNow: now)
            PreviewRenderer.write(PreviewRenderer.renderInWindow(view, dark: dark),
                                  to: dir.appendingPathComponent("official-agy-tight-reset\(dark ? "-dark" : "").png"))
        }
        for language in Language.allCases {
            L10n.language = language
            let lang = language == .zhHans ? "" : "-\(language.rawValue)"
            for (name, entry, choice, reading, status) in samples {
                for dark in [false, true] {
                    let view = OfficialOverviewView(entry: entry, choice: choice, artwork: artwork,
                                                    reading: reading, agyStatus: status == "empty" ? "" : status,
                                                    usage: status == "empty" ? [staleClaude] : usage,
                                                    desktopRunning: entry == .claude, canOpenAntigravity: true,
                                                    fixedNow: now)
                    PreviewRenderer.write(PreviewRenderer.renderInWindow(view, dark: dark),
                                          to: dir.appendingPathComponent("\(name)\(lang)\(dark ? "-dark" : "").png"))
                }
            }
        }
        for language in Language.allCases {
            L10n.language = language
            let lang = language == .zhHans ? "" : "-\(language.rawValue)"
            let settings = AppSettings(defaults: TransientDefaults(), allowsSystemActions: false)
            for dark in [false, true] {
                let view = OfficialSettingsView(settings: settings, artwork: artwork, onBack: {})
                PreviewRenderer.write(PreviewRenderer.renderInWindow(view, dark: dark),
                                      to: dir.appendingPathComponent("official-settings\(lang)\(dark ? "-dark" : "").png"))
            }
        }
        print("正常模式面板预览图已写入 \(dir.path)")
    }

    /// 合成的官方面板：两组各有每周和五小时窗口（agy 1.5.15 起 Argon 并入 Gemini 组，不再单列）
    static func sampleReading(now: Date, tightResetIn: TimeInterval = 95 * 60) -> AgyQuotaReading {
        let checked = now.addingTimeInterval(-4 * 60)
        let windows = [
            AgyQuotaReading.Window(group: "Gemini", window: "每周", remainingPercent: 62.5, resetsAt: now.addingTimeInterval(3 * 86400 + 5 * 3600)),
            AgyQuotaReading.Window(group: "Gemini", window: "五小时", remainingPercent: 81, resetsAt: now.addingTimeInterval(2 * 3600 + 40 * 60)),
            AgyQuotaReading.Window(group: "Claude / GPT", window: "每周", remainingPercent: 91, resetsAt: nil),
            AgyQuotaReading.Window(group: "Claude / GPT", window: "五小时", remainingPercent: 18, resetsAt: now.addingTimeInterval(tightResetIn)),
        ]
        let top = windows[3]
        return AgyQuotaReading(status: .available, remainingPercent: top.remainingPercent,
                               groupName: top.group + " · " + top.window, checkedAt: checked, message: "",
                               groupTitle: top.group, windowTitle: top.window, resetsAt: top.resetsAt, windows: windows)
    }

    /// 合成的 Claude（CLI /usage 读数，带 30 分钟前的一次用来算速度）和 Codex（日志里带重置时间的读数）
    static func sampleUsage(now: Date) -> [UsageSnapshot] {
        let session = now.addingTimeInterval(2 * 3600 + 7 * 60), week = now.addingTimeInterval(4 * 86400 + 11 * 3600)
        func reading(_ ago: TimeInterval, _ s: Double, _ w: Double, _ sonnet: Double) -> ClaudeUsageReading {
            ClaudeUsageReading(status: .available, windows: [
                .init(kind: .session, usedPercent: s, resetsAt: session),
                .init(kind: .week, usedPercent: w, resetsAt: week),
                .init(kind: .weekModel("Sonnet only"), usedPercent: sonnet, resetsAt: week),
            ], checkedAt: now.addingTimeInterval(-ago))
        }
        let claude = reading(4 * 60, 66, 41, 12).snapshot(now: now, history: [reading(34 * 60, 58, 40, 12)])
        let read = now.addingTimeInterval(-6 * 60)
        let codex = UsageSnapshot(provider: .codex, windows: [
            UsageWindow(id: "five_hour", title: UsageWindow.title(minutes: 300), duration: 5 * 3600, percent: 34, official: 34,
                        officialAt: read, startedAt: now.addingTimeInterval(-2 * 3600), resetsAt: now.addingTimeInterval(3 * 3600)),
            UsageWindow(id: "seven_day", title: UsageWindow.title(minutes: 10080), duration: 7 * 86400, percent: 57, official: 57,
                        officialAt: read, startedAt: now.addingTimeInterval(-4 * 86400), resetsAt: now.addingTimeInterval(3 * 86400),
                        burnLookback: 86400),
        ], generatedAt: now, officialAt: read, lastActiveAt: read, notes: [])
        return [claude, codex]
    }

    static func artwork(_ choice: OfficialPetChoice, _ mood: PetMood) -> NSImage {
        let file = OfficialPetChoice.resolved(choice.file(mood: mood, panel: true), exists: OfficialMenuController.artExists)
        let url = PaintedArt.root?.appendingPathComponent(file)
        return url.flatMap { NSImage(contentsOf: $0) } ?? NSImage(systemSymbolName: "pawprint", accessibilityDescription: nil)!
    }
}
