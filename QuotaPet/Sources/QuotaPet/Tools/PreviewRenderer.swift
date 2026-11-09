import AppKit
import SwiftUI
import QuotaPetCore

/// QuotaPet --render-previews <dir>：把宠物动画、菜单栏效果和面板渲染成 PNG，
/// 不用真的启动 App 就能检查设计。面板和设置页中英各一套，英文的文件名带 -en。
/// 同时有 Claude 和 Codex 时的样子在 popover-codex*、menubar-codex、settings-codex*。
@MainActor
enum PreviewRenderer {
    static func renderAll(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = AppSettings()  // 它会按设置切换界面语言，所以要在下面固定语言之前建
        // 「官方读数」那一组打开时的样子：用一份临时的设置，不动本机真实的设置（它建出来时也会切换界面语言，所以在下面固定语言之前）
        let probeSuite = "dev.quotapet.previews"
        UserDefaults.standard.removePersistentDomain(forName: probeSuite)
        let probeDefaults = UserDefaults(suiteName: probeSuite)!
        probeDefaults.set(true, forKey: "claudeCLIProbe")
        let probeSettings = AppSettings(defaults: probeDefaults)
        defer { UserDefaults.standard.removePersistentDomain(forName: probeSuite) }
        L10n.language = .zhHans  // 动画表上的心情名、真实数据那两张用中文
        for style in PetStyle.allCases {
            let suffix = style == .classic ? "" : "-\(style.rawValue)"
            write(spriteSheet(style: style), to: dir.appendingPathComponent("pet-sheet\(suffix).png"))
            write(spriteSheet(style: style, poked: true), to: dir.appendingPathComponent("pet-poke\(suffix).png"))
            write(menuBarStrip(style: style), to: dir.appendingPathComponent("menubar\(suffix).png"))
        }
        write(menuBarGlyphStrip(), to: dir.appendingPathComponent("menubar-codex.png"))

        let now = Date()
        // 用本机真实数据渲染一张，和点开菜单栏看到的一样：先看宠物跟着的那家（宠物停在第一帧）
        let live = UsageSnapshot.visible([try? ClaudeProvider().snapshot(now: now), try? CodexProvider().snapshot(now: now)].compactMap { $0 },
                                         hidden: settings.hiddenProviders)
        if let focus = UsageSnapshot.focus(of: live) {
            let status = PetStatus.of(focus, now: now), mood = status.mood
            let style = PetStyle.of(focus.provider, claudeStyle: settings.petStyle, codexStyle: settings.codexPetStyle)
            for dark in [false, true] {
                let view = OverviewView(snapshot: focus, errorMessage: nil, mood: mood, line: status.line(0),
                                        pet: PetImage(picture: PetSprites.frames(for: mood, style: style)[0].portrait),
                                        tabs: live.count > 1 ? live : [], focus: focus.provider, fixedNow: now)
                write(render(view, dark: dark), to: dir.appendingPathComponent("popover-live\(dark ? "-dark" : "").png"))
            }
        }

        for language in Language.allCases {
            L10n.language = language
            let lang = language == .zhHans ? "" : "-\(language.rawValue)"
            for dark in [false, true] {  // 所有形象并排（名字跟着语言）
                write(styleStrip(dark: dark), to: dir.appendingPathComponent("styles\(lang)\(dark ? "-dark" : "").png"))
            }
            if language != .zhHans {  // 看看各种心情的名字
                write(spriteSheet(style: .classic), to: dir.appendingPathComponent("pet-sheet\(lang).png"))
            }
            for (name, snapshot) in sampleSnapshots(now: now) {
                let status = sampleStatus(snapshot, now: now), mood = status.mood
                // busy 的数据再给别的形象各出一张（popover-<形象>），看半身像在面板里的样子；经典就是 popover-busy 那张
                let styles = name == "busy" ? PetStyle.allCases.filter { $0 != .classic } : []
                for (file, style) in [(name, PetStyle.classic)] + styles.map({ ($0.rawValue, $0) }) {
                    for dark in [false, true] {
                        let view = OverviewView(snapshot: snapshot, errorMessage: nil, mood: mood, line: status.line(0),
                                                pet: PetImage(picture: PetSprites.frames(for: mood, style: style)[0].portrait),
                                                claudeRunning: name != "stale", fixedNow: now)
                        write(render(view, dark: dark), to: dir.appendingPathComponent("popover-\(file)\(lang)\(dark ? "-dark" : "").png"))
                    }
                }
            }
            // 同时有 Codex：看 Claude（宠物跟着 Claude），和看 Codex（宠物跟着 Codex，换成龙娘）
            for (name, tabs, selected) in codexSamples(now: now) {
                let snapshot = tabs.first { $0.provider == selected }
                let status = sampleStatus(snapshot, now: now), mood = status.mood
                let style = PetStyle.of(selected, claudeStyle: .classic, codexStyle: .dragon)
                for dark in [false, true] {
                    let view = OverviewView(snapshot: snapshot, errorMessage: nil, mood: mood, line: status.line(0),
                                            pet: PetImage(picture: PetSprites.frames(for: mood, style: style)[0].portrait),
                                            tabs: tabs, focus: UsageSnapshot.focus(of: tabs)?.provider, fixedNow: now)
                    write(render(view, dark: dark), to: dir.appendingPathComponent("popover-\(name)\(lang)\(dark ? "-dark" : "").png"))
                }
            }
            let estimation = EstimationInfo(sessionUSDPerPercent: 0.33, weeklyUSDPerPercent: 2.41, learnedIntervals: 86,
                                            recordedIntervals: 214, learnedUntil: now.addingTimeInterval(-300))
            // 设置页三个分页：settings（通用）、settings-claude、settings-codex
            for (name, page) in [("", SettingsView.Page.general), ("-claude", .claude), ("-codex", .codex)] {
                let view = SettingsView(settings: settings, suggestedWeeklyReset: nil, estimation: estimation, hasCodex: true,
                                        codexReadingAt: now.addingTimeInterval(-12 * 60), watchesCodex: true,
                                        cliProbeStatus: .idle, onConnectCLI: {}, claudeReadingAt: now.addingTimeInterval(-9 * 60), onBack: {}, page: page)
                write(renderInWindow(view, dark: false), to: dir.appendingPathComponent("settings\(name)\(lang).png"))
                if page == .claude {  // 「官方读数」打开之后：查到了 / 命令行还没登录
                    for (suffix, status) in [("-probe", ClaudeCLIProbeStatus.ok(at: now.addingTimeInterval(-9 * 60))),
                                             ("-probe-login", .notLoggedIn)] {
                        let probeView = SettingsView(settings: probeSettings, suggestedWeeklyReset: nil, estimation: estimation,
                                                     hasCodex: true, codexReadingAt: now.addingTimeInterval(-12 * 60), watchesCodex: true,
                                                     cliProbeStatus: status, onConnectCLI: {},
                                                     claudeReadingAt: now.addingTimeInterval(-9 * 60),
                                                     onBack: {}, page: .claude)
                        write(renderInWindow(probeView, dark: false), to: dir.appendingPathComponent("settings\(suffix)\(lang).png"))
                    }
                }
                if page == .general {
                    write(renderInWindow(view, dark: true), to: dir.appendingPathComponent("settings\(lang)-dark.png"))
                }
            }
            // 没装桌面端：「什么时候出现」下面说明为什么一直显示
            let noDesktop = SettingsView(settings: settings, suggestedWeeklyReset: nil, estimation: estimation, hasCodex: true,
                                         codexReadingAt: now.addingTimeInterval(-12 * 60), watchesCodex: true,
                                         canFollowApp: false, onBack: {})
            write(renderInWindow(noDesktop, dark: false), to: dir.appendingPathComponent("settings-nodesktop\(lang).png"))
        }
        print("预览图已写入 \(dir.path)")
    }

    /// 假数据的面板图不看是几点渲染的：半夜出图也不说「这么晚还在忙」
    private static func sampleStatus(_ snapshot: UsageSnapshot?, now: Date) -> PetStatus {
        PetStatus.of(snapshot, now: now, lateNight: false)
    }

    // MARK: - 宠物动画表：每行一种心情，每列一帧

    /// poked：改成画被戳的反应，每行第一格是这个心情平时的第一帧，后面是反应；会闹别扭的心情最后再加上连戳之后的反应
    static func spriteSheet(style: PetStyle, poked: Bool = false) -> Data? {
        func frames(_ mood: PetMood) -> [PetFrame] {
            let frames = PetSprites.frames(for: mood, style: style)
            guard poked else { return frames }
            let reaction = PetSprites.reaction(for: mood, style: style), annoyed = PetSprites.reaction(for: mood, style: style, annoyed: true)
            return [frames[0]] + reaction + (annoyed == reaction ? [] : annoyed)
        }
        let moods = PetMood.allCases
        let side: CGFloat = 96                                  // 头像放大到 96 点
        let cell = side + 16
        let labelWidth: CGFloat = 104
        let columns = moods.map { frames($0).count }.max() ?? 1
        let width = labelWidth + CGFloat(columns) * cell + 8
        let height = CGFloat(moods.count) * cell + 8
        let ink = NSColor(white: 0.15, alpha: 1)
        return bitmap(width: Int(width), height: Int(height)) {
            NSColor(white: 0.98, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for (row, mood) in moods.enumerated() {
                let y = 4 + CGFloat(row) * cell
                ("\(mood.title)\n\(mood.rawValue)" as NSString).draw(
                    at: CGPoint(x: 10, y: y + cell / 2 - 16),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink])
                for (col, frame) in frames(mood).enumerated() {
                    let origin = CGPoint(x: labelWidth + CGFloat(col) * cell + 8, y: y + 8)
                    NSColor(white: 0.92, alpha: 1).setFill()
                    NSRect(x: origin.x - 4, y: origin.y - 4, width: cell - 8, height: cell - 8).fill()
                    PetRenderer.draw(frame.icon, in: NSRect(origin: origin, size: NSSize(width: side, height: side)))
                }
            }
        }
    }

    // MARK: - 所有形象并排：一行 Claude 的，一行 Codex 的（2 倍分辨率）

    static func styleStrip(dark: Bool) -> Data? {
        let groups: [(name: String, styles: [PetStyle])] = [("Claude", PetStyle.claudeChoices), ("Codex", PetStyle.codexChoices)]
        let side: CGFloat = 96, gap: CGFloat = 12, labelHeight: CGFloat = 22, header: CGFloat = 64, scale: CGFloat = 2
        let columns = groups.map(\.styles.count).max() ?? 1
        let width = header + CGFloat(columns) * (side + gap)
        let rowHeight = side + labelHeight + gap
        let height = CGFloat(groups.count) * rowHeight + gap
        let ink: NSColor = dark ? .white : NSColor(white: 0.15, alpha: 1)
        return bitmap(width: Int(width * scale), height: Int(height * scale), scale: scale) {
            (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.98, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            for (row, group) in groups.enumerated() {
                let y = gap + CGFloat(row) * rowHeight
                (group.name as NSString).draw(at: CGPoint(x: gap, y: y + side / 2 - 9),
                                              withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: ink])
                for (col, style) in group.styles.enumerated() {
                    let tile = NSRect(x: header + CGFloat(col) * (side + gap), y: y, width: side, height: side)
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: tile, xRadius: 18, yRadius: 18).addClip()
                    (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
                    tile.fill()
                    PetRenderer.draw(PetSprites.frames(for: .normal, style: style)[0].portrait, in: tile)
                    NSGraphicsContext.restoreGraphicsState()
                    let label = NSAttributedString(string: style.label, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ink])
                    label.draw(at: CGPoint(x: tile.midX - label.size().width / 2, y: tile.maxY + 4))
                }
            }
        }
    }

    // MARK: - 模拟菜单栏（2 倍分辨率）：浅色、深色各一行

    static func menuBarStrip(style: PetStyle) -> Data? {
        let items: [(PetMood, String, NSColor?)] = [
            (.energetic, "27%", nil), (.normal, "63%", nil), (.tired, "82%", .systemOrange),
            (.exhausted, "96%", .systemRed), (.sleeping, "1h23m", nil), (.confused, "", nil),
        ]
        let barHeight: CGFloat = 24, itemWidth: CGFloat = 78, scale: CGFloat = 2
        let width = CGFloat(items.count) * itemWidth + 16
        return bitmap(width: Int(width * scale), height: Int(barHeight * 2 * scale), scale: scale) {
            for (r, dark) in [false, true].enumerated() {
                let y = CGFloat(r) * barHeight
                (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: width, height: barHeight).fill()
                let ink: NSColor = dark ? .white : .black
                for (i, item) in items.enumerated() {
                    let x = 10 + CGFloat(i) * itemWidth
                    let icon = PetSprites.frames(for: item.0, style: style)[0].icon
                    PetRenderer.draw(icon, in: NSRect(x: x, y: y + (barHeight - icon.points) / 2, width: icon.points, height: icon.points))
                    (item.1 as NSString).draw(
                        at: CGPoint(x: x + icon.points + 3, y: y + 4.5),
                        withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                         .foregroundColor: item.2 ?? ink])
                }
            }
        }
    }

    /// 同时显示两家时的菜单栏：宠物后面跟着那家的小图标。用的是 App 里画菜单栏的同一段代码（MenuBarIcon）
    static func menuBarGlyphStrip() -> Data? {
        let items: [(PetStyle, PetMood, ProviderID, String, NSColor?)] = [
            (.classic, .tired, .claude, "86%", .systemOrange), (.dragon, .exhausted, .codex, "93%", .systemRed),
            (.dragon, .normal, .codex, "55%", nil), (.classic, .energetic, .claude, "27%", nil),
        ]
        let barHeight: CGFloat = 24, itemWidth: CGFloat = 92, scale: CGFloat = 2
        let width = CGFloat(items.count) * itemWidth + 16
        return bitmap(width: Int(width * scale), height: Int(barHeight * 2 * scale), scale: scale) {
            for (r, dark) in [false, true].enumerated() {
                let y = CGFloat(r) * barHeight
                (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: width, height: barHeight).fill()
                let ink: NSColor = dark ? .white : .black
                NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                    for (i, item) in items.enumerated() {
                        let x = 10 + CGFloat(i) * itemWidth
                        let image = MenuBarIcon.image(PetSprites.frames(for: item.1, style: item.0)[0].icon,
                                                      glyph: MenuBarIcon.glyph(for: item.2))
                        let rect = NSRect(x: x, y: y + (barHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
                        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                        (" " + item.3 as NSString).draw(
                            at: CGPoint(x: rect.maxX, y: y + 4.5),
                            withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                             .foregroundColor: item.4 ?? ink])
                    }
                }
            }
        }
    }

    // MARK: - 面板

    static func render<V: View>(_ view: V, dark: Bool) -> Data? {
        let content = view
            .frame(width: 340)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        var data: Data?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            if let image = renderer.cgImage {
                data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            }
        }
        return data
    }

    /// 放进一个离屏窗口里渲染，开关、分段控件这些 AppKit 控件也能画出来
    static func renderInWindow<V: View>(_ view: V, dark: Bool) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: 340).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))  // 等 SwiftUI 画完
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    static func sampleSnapshots(now: Date) -> [(String, UsageSnapshot)] {
        /// readAgo：官方读数是多久前的
        func window(_ id: String, _ title: String, _ duration: TimeInterval, _ percent: Double, official: Double?,
                    resetIn: TimeInterval, burn: Double, other: Double = 0, otherBurn: Double? = nil,
                    readAgo: TimeInterval = 9 * 60) -> UsageWindow {
            UsageWindow(id: id, title: title, duration: duration, percent: percent, official: official,
                        officialAt: official.map { _ in now.addingTimeInterval(-readAgo) }, startedAt: now.addingTimeInterval(resetIn - duration),
                        resetsAt: now.addingTimeInterval(resetIn), otherPercent: other, burnPerHour: burn, otherBurnPerHour: otherBurn,
                        burnLookback: duration > 86400 ? 86400 : 1800)
        }
        let today = ActivitySummary(
            requests: 262, tokens: 21_400_000, usd: 21.15,
            byFamily: [FamilyUsage(family: "Opus", requests: 174, usd: 14.40), FamilyUsage(family: "Sonnet", requests: 48, usd: 5.78),
                       FamilyUsage(family: "Haiku", requests: 40, usd: 0.97)])
        let week = 7 * 86400.0
        /// quiet：多久没用了
        func snapshot(_ windows: [UsageWindow], quiet: TimeInterval = 0, readAgo: TimeInterval = 9 * 60) -> UsageSnapshot {
            UsageSnapshot(provider: .claude, windows: windows, generatedAt: now, officialAt: now.addingTimeInterval(-readAgo),
                          today: today, lastActiveAt: now.addingTimeInterval(-quiet))
        }
        let session = UsageWindow.sessionTitle, weekly = UsageWindow.weeklyTitle
        return [
            ("calm", snapshot([window("five_hour", session, 5 * 3600, 27.3, official: 24, resetIn: 2 * 3600 + 14 * 60, burn: 6),
                               window("seven_day", weekly, week, 25.4, official: 25, resetIn: 4 * 86400 + 19 * 3600, burn: 0.5)])),
            // busy：35 分钟后用完，还没进半小时的预警，她只是累；再快一点就哭了
            ("busy", snapshot([window("five_hour", session, 5 * 3600, 86.2, official: 80, resetIn: 3 * 3600 + 5 * 60, burn: 24,
                                     other: 14, otherBurn: 8),
                               window("seven_day", weekly, week, 38.9, official: 38, resetIn: 4 * 86400 + 19 * 3600, burn: 0.9)])),
            // 心情的趋势：才 58% 但烧得快（先冒汗）；50 分钟没用了（歇着）
            ("rush", snapshot([window("five_hour", session, 5 * 3600, 58.4, official: 52, resetIn: 3 * 3600 + 5 * 60, burn: 45),
                               window("seven_day", weekly, week, 36.2, official: 36, resetIn: 4 * 86400 + 19 * 3600, burn: 0.9)])),
            ("idle", snapshot([window("five_hour", session, 5 * 3600, 27, official: 27, resetIn: 2 * 3600 + 14 * 60, burn: 0),
                               window("seven_day", weekly, week, 25.4, official: 25, resetIn: 4 * 86400 + 19 * 3600, burn: 0.5)],
                              quiet: 50 * 60)),
            ("limited", snapshot([window("five_hour", session, 5 * 3600, 100, official: 100, resetIn: 83 * 60, burn: 0),
                                  window("seven_day", weekly, week, 47, official: 47, resetIn: 4 * 86400 + 19 * 3600, burn: 0)])),
            ("empty", UsageSnapshot(provider: .claude, windows: [], generatedAt: now, notes: [ClaudeProvider.missingHistoryNote],
                                    hasData: false)),
            // 官方读数停在一天前（新版桌面端开着也可能停掉后台刷新），渲染时当作桌面端没开：底部提醒打开它
            ("stale", snapshot([window("five_hour", session, 5 * 3600, 4, official: nil, resetIn: 4 * 3600 + 10 * 60, burn: 3.6),
                                window("seven_day", weekly, week, 63.2, official: 62, resetIn: 2 * 86400, burn: 0.4,
                                       readAgo: 26 * 3600)],
                               quiet: 5 * 60, readAgo: 26 * 3600)),
        ]
    }

    /// Claude + Codex：(文件名, 两家的快照, 正在看哪家)
    static func codexSamples(now: Date) -> [(String, [UsageSnapshot], ProviderID)] {
        let claude = Dictionary(uniqueKeysWithValues: sampleSnapshots(now: now))
        let week = 7 * 86400.0
        func codex(_ percent: Double, agoMinutes: Double, resetIn: TimeInterval, burn: Double, stale: Bool = false) -> UsageSnapshot {
            let readAt = now.addingTimeInterval(-agoMinutes * 60)
            let window = UsageWindow(id: "seven_day", title: UsageWindow.weeklyTitle, duration: week, percent: percent,
                                     official: percent, officialAt: readAt,
                                     startedAt: now.addingTimeInterval(resetIn - week), resetsAt: now.addingTimeInterval(resetIn),
                                     burnPerHour: burn, burnLookback: 86400)
            return UsageSnapshot(provider: .codex, windows: [window], generatedAt: now, officialAt: readAt,
                                 lastActiveAt: readAt, notes: stale ? [CodexProvider.staleNote(readAt: readAt, now: now)] : [])
        }
        return [
            ("codex", [claude["busy"]!, codex(55, agoMinutes: 12, resetIn: 2 * 86400 + 5 * 3600, burn: 0.6)], .claude),
            ("codex-tab", [claude["calm"]!, codex(93, agoMinutes: 4, resetIn: 86400 + 3 * 3600, burn: 0.9)], .codex),
            // 读数停了几小时：Dot 等云端任务的用量还没记进来
            ("codex-stale", [claude["calm"]!, codex(61, agoMinutes: 5 * 60, resetIn: 2 * 86400, burn: 0.4, stale: true)], .codex),
        ]
    }

    // MARK: - 工具

    /// 在 y 轴朝下的位图上下文里画图，返回 PNG
    static func bitmap(width: Int, height: Int, scale: CGFloat = 1, draw: () -> Void) -> Data? {
        PetRenderer.rasterize(width: width, height: height, scale: scale, draw)?.representation(using: .png, properties: [:])
    }

    static func write(_ data: Data?, to url: URL) {
        guard let data else {
            print("渲染失败：\(url.lastPathComponent)")
            return
        }
        try? data.write(to: url)
    }
}
