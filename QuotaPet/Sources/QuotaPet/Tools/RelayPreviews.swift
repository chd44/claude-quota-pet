import AppKit
import SwiftUI
import QuotaPetCore

/// QuotaPet --render-relay-previews <dir>：双宠接力和面板顶部信息的三张预览图。
/// 只用固定的合成数据和固定的「现在」，不读本机的额度记录、也不读本机的设置（宠物形象固定成经典 + 龙娘）。
/// 画面走 OverviewView，和真正的面板是同一套显示逻辑；中英各一套，英文的文件名带 -en
@MainActor
enum RelayPreviews {
    static let claudeStyle = PetStyle.classic
    static let codexStyle = PetStyle.dragon

    /// 固定的「现在」：2026-11-20 17:00（本地时间），截图里的时间不随运行时间变
    static var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 17, minute: 0))!
    }

    static func renderAll(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures: [String] = []
        for language in Language.allCases {
            L10n.language = language
            let lang = language == .zhHans ? "" : "-\(language.rawValue)"
            let samples: [(String, [UsageSnapshot], ProviderID)] = [
                // 1. 接力可用：Claude 5 小时额度用完，Codex 读数 8 分钟前、最高 27%
                ("relay-available", [claude(.blocked), codex(readAgo: 8 * 60)], .claude),
                // 2. 接力对象的读数过期：Codex 的读数是 2 小时前的
                ("relay-stale", [claude(.blocked), codex(readAgo: 2 * 3600)], .claude),
                // 3. 只有一家：Codex 在设置里关掉了（走和面板一样的 visible 过滤）
                ("relay-single",
                 UsageSnapshot.visible([claude(.forecast), codex(readAgo: 8 * 60)], hidden: [.codex]), .claude),
            ]
            for (name, shown, selected) in samples {
                let view = overview(shown: shown, selected: selected, now: now)
                PreviewRenderer.write(PreviewRenderer.render(view, dark: false), to: dir.appendingPathComponent("popover-\(name)\(lang).png"))
            }
            if language == .zhHans { failures += verifyClick(to: dir) }
        }
        L10n.language = .zhHans
        print("接力预览图已写入 \(dir.path)")
        if failures.isEmpty { print("点击验证通过") } else { failures.forEach { print("点击验证失败：\($0)") } }
    }

    /// 和 PopoverRoot 一样的取法：选中的那家不在显示的几家里就回到宠物跟着的那家；只有一家时没有切换条
    static func overview(shown: [UsageSnapshot], selected requested: ProviderID, now: Date,
                         onSelect: @escaping (ProviderID) -> Void = { _ in },
                         onRelayButtonFrame: @escaping (CGRect) -> Void = { _ in }) -> OverviewView<PetImage> {
        let focus = UsageSnapshot.focus(of: shown)?.provider
        let selected = PanelSelection.resolve(shown: shown, requested: requested, focus: focus)
        let snapshot = shown.first { $0.provider == selected }
        let status = PetStatus.of(snapshot, now: now, lateNight: false)
        let style = PetStyle.of(selected, claudeStyle: claudeStyle, codexStyle: codexStyle)
        return OverviewView(snapshot: snapshot, errorMessage: nil, mood: status.mood, line: status.line(0),
                            pet: PetImage(picture: PetSprites.frames(for: status.mood, style: style)[0].portrait),
                            tabs: shown.count > 1 ? shown : [], focus: focus, onSelect: onSelect,
                            styleFor: { PetStyle.of($0, claudeStyle: claudeStyle, codexStyle: codexStyle) },
                            onRelayButtonFrame: onRelayButtonFrame, fixedNow: now)
    }

    // MARK: - 合成数据

    enum ClaudeCase {
        /// 5 小时额度官方 100%，18:00 恢复
        case blocked
        /// 5 小时额度官方 52%（9 分钟前）+ 本机估算 6 个点，照 60%/小时会在 17:42 用完
        case forecast
    }

    static func claude(_ kind: ClaudeCase) -> UsageSnapshot {
        let week = 7 * 86400.0
        let today = ActivitySummary(requests: 262, tokens: 21_400_000, usd: 21.15,
                                    byFamily: [FamilyUsage(family: "Opus", requests: 174, usd: 14.40),
                                               FamilyUsage(family: "Sonnet", requests: 48, usd: 5.78),
                                               FamilyUsage(family: "Haiku", requests: 40, usd: 0.97)])
        let readAgo: TimeInterval = kind == .blocked ? 5 * 60 : 9 * 60
        let readAt = now.addingTimeInterval(-readAgo)
        let session: UsageWindow
        switch kind {
        case .blocked:
            session = UsageWindow(id: "five_hour", title: UsageWindow.sessionTitle, duration: 5 * 3600, percent: 100, official: 100,
                                  officialAt: readAt, startedAt: now.addingTimeInterval(-4 * 3600), resetsAt: now.addingTimeInterval(3600),
                                  burnPerHour: 0)
        case .forecast:
            session = UsageWindow(id: "five_hour", title: UsageWindow.sessionTitle, duration: 5 * 3600, percent: 58, official: 52,
                                  officialAt: readAt, startedAt: now.addingTimeInterval(-2 * 3600), resetsAt: now.addingTimeInterval(3 * 3600),
                                  burnPerHour: 60)
        }
        let weekly = UsageWindow(id: "seven_day", title: UsageWindow.weeklyTitle, duration: week, percent: 47, official: 47, officialAt: readAt,
                                 startedAt: now.addingTimeInterval(-3 * 86400), resetsAt: now.addingTimeInterval(4 * 86400),
                                 burnPerHour: 0.5, burnLookback: 86400)
        return UsageSnapshot(provider: .claude, windows: [session, weekly], generatedAt: now, officialAt: readAt, today: today,
                             lastActiveAt: now.addingTimeInterval(-2 * 60))
    }

    /// Codex：5 小时 27% 和每周 18%，都没满；官方读数是 readAgo 前的
    static func codex(readAgo: TimeInterval) -> UsageSnapshot {
        let readAt = now.addingTimeInterval(-readAgo)
        let session = UsageWindow(id: "five_hour", title: UsageWindow.sessionTitle, duration: 5 * 3600, percent: 27, official: 27,
                                  officialAt: readAt, startedAt: now.addingTimeInterval(-2 * 3600), resetsAt: now.addingTimeInterval(3 * 3600),
                                  burnPerHour: 0.5)
        let weekly = UsageWindow(id: "seven_day", title: UsageWindow.weeklyTitle, duration: 7 * 86400, percent: 18, official: 18,
                                 officialAt: readAt, startedAt: now.addingTimeInterval(-2 * 86400), resetsAt: now.addingTimeInterval(5 * 86400),
                                 burnPerHour: 0.3, burnLookback: 86400)
        return UsageSnapshot(provider: .codex, windows: [session, weekly], generatedAt: now, officialAt: readAt,
                             lastActiveAt: readAt, notes: [])
    }

    // MARK: - 点击验证

    /// 选中哪家，放在引用类型里：点击时按钮的闭包在 SwiftUI 里改它，外面再读
    final class Selection {
        var provider: ProviderID
        /// 接力按钮在面板里的位置（SwiftUI 坐标，y 从上往下）
        var buttonFrame: CGRect?
        init(_ provider: ProviderID) { self.provider = provider }
    }

    /// 带状态的面板：点按钮（onSelect）后换成另一家的页，和 PopoverRoot 里 state.selected 的作用一样
    struct Harness: View {
        let shown: [UsageSnapshot]
        let box: Selection
        @State private var selected: ProviderID

        init(shown: [UsageSnapshot], box: Selection) {
            self.shown = shown
            self.box = box
            _selected = State(initialValue: box.provider)
        }

        var body: some View {
            RelayPreviews.overview(shown: shown, selected: selected, now: RelayPreviews.now,
                                   onSelect: { picked in
                                       selected = picked
                                       box.provider = picked
                                   },
                                   onRelayButtonFrame: { box.buttonFrame = $0 })
            .frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// 把第 1 张图的面板放进离屏窗口，用辅助功能的「按下」去点「查看 Codex」，看选中的是不是真的换成了 Codex、页面是不是 Codex 的。
    /// 返回失败的原因（空 = 通过）。点击后的样子存成 popover-relay-clicked.png
    static func verifyClick(to dir: URL) -> [String] {
        let shown = [claude(.blocked), codex(readAgo: 8 * 60)]
        let box = Selection(.claude)
        let host = NSHostingView(rootView: Harness(shown: shown, box: box))
        host.appearance = NSAppearance(named: .aqua)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        var problems: [String] = []
        guard let frame = box.buttonFrame else { return ["面板里没有接力按钮（没拿到它的位置）"] }
        // 在按钮中心按下、松开：和用户点一下一样，走 SwiftUI 的手势，不是直接调闭包
        let point = NSPoint(x: frame.midX, y: size.height - frame.midY)
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // 放到屏幕外，别在用户眼前闪一下
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        if box.provider != .codex { problems.append("点了之后选中的是 \(box.provider.rawValue)，不是 codex") }

        // 点击之后的页存成图，看是不是 Codex 的页
        let afterSize = host.fittingSize
        host.frame = NSRect(origin: .zero, size: afterSize)
        window.setContentSize(afterSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        // 点之后 Codex 页上没有「查看 Codex」按钮：按钮的位置不再更新、选中的是 codex（页面内容看 popover-relay-clicked.png）
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            PreviewRenderer.write(rep.representation(using: .png, properties: [:]), to: dir.appendingPathComponent("popover-relay-clicked.png"))
        }
        return problems
    }
}
