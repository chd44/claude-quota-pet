import SwiftUI
import QuotaPetCore

@MainActor
final class PopoverState: ObservableObject {
    enum Page { case overview, settings }
    @Published var page: Page = .overview
    /// 同时有几家时，面板上看的是哪家；每次打开面板先看宠物跟着的那家
    @Published var selected: ProviderID = .claude
    /// 这次打开后用户自己点过切换条：之后不再跟着宠物换
    @Published var picked = false
    @Published var isShown = false
    /// 面板最高多高：菜单栏所在的屏幕放得下多少。小屏幕上设置页放不下，超出的部分滚动
    @Published var maxHeight: CGFloat = .infinity
    /// 下面几个由 StatusItemController 在同一处算好填进来，菜单栏显不显示和设置页的说明用的是同一份
    /// 在用 Codex：有它的数据，又没在设置里关掉
    @Published var usesCodex = false
    /// 有桌面端可以跟（见 MenuBarVisibility.shouldShow）
    @Published var canFollowApp = true
    /// Claude 桌面端开着：官方读数停了、它又没开时，面板底部提醒打开它
    @Published var claudeRunning = true
    /// 和她聊天的状态：这次说第几句、能不能说「这么晚还在忙」、连着戳了几下。从随机的一句开始，重启 App 后不会总是同一句
    @Published private(set) var chat = PetChat(pick: .random(in: 0..<6))

    func opened() { chat.opened(now: Date()) }
    func said(_ situation: PetTalk.Situation) { chat.said(situation, now: Date()) }
    func poke(mood: PetMood) -> (line: String, annoyed: Bool)? { chat.poke(mood: mood, now: Date()) }
}

struct PopoverRoot: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var state: PopoverState
    /// 不用 @ObservedObject：动画每秒好几帧，只让宠物那一小块跟着刷新。
    /// animator 是菜单栏上的宠物；面板切到另一家时换成 headerAnimator
    let animator: PetAnimator
    let headerAnimator: PetAnimator
    var onQuit: () -> Void

    var body: some View {
        ScrollView {  // 内容放得下时 ScrollView 和内容一样高，不会出现滚动条
            pages
        }
        .frame(width: 340)
        .frame(maxHeight: state.maxHeight)
    }

    private var pages: some View {
        Group {
            switch state.page {
            case .overview:
                let shown = store.shown
                let focus = store.focus?.provider
                // 选中的那家没数据了（比如 Codex 的记录过期了）就回到宠物跟着的那家
                let selected = shown.contains { $0.provider == state.selected } ? state.selected : focus ?? .claude
                let snapshot = store.snapshot(for: selected)
                // 心情和台词一次算出来。面板每次重画都按当前时间算；快照每分钟至少变一次（读取出错时还有 store.tick），和菜单栏同步
                let status = PetStatus.of(snapshot, failed: store.errors[selected] != nil, memory: store.memory[selected] ?? PetMemory(),
                                          now: Date(), lateNight: state.chat.lateNight)
                let onMenuBar = selected == focus
                let pet = onMenuBar ? animator : headerAnimator
                let look = PetLook(mood: status.mood,
                                   style: PetStyle.of(selected, claudeStyle: settings.petStyle, codexStyle: settings.codexPetStyle),
                                   onMenuBar: onMenuBar)
                OverviewView(
                    snapshot: snapshot,
                    errorMessage: store.errors[selected],
                    mood: look.mood,
                    line: status.line(state.chat.pick),
                    pet: LivePet(animator: pet),
                    tabs: shown.count > 1 ? shown : [],
                    focus: focus,
                    onSelect: { state.selected = $0; state.picked = true },
                    onRefresh: { store.refreshNow() },
                    onSettings: { state.page = .settings },
                    onQuit: onQuit,
                    claudeRunning: state.claudeRunning,
                    cliProbe: settings.claudeCLIProbe,
                    cliProbeStatus: store.cliProbeStatus,
                    said: OverviewView<LivePet>.Said(situation: status.situation, pick: state.chat.pick),
                    onSay: state.said,
                    onPoke: {
                        guard let poke = state.poke(mood: status.mood) else { return nil }
                        pet.react(mood: status.mood, annoyed: poke.annoyed)
                        return poke.line
                    })
                    // 表情也按这次算的心情：标签、台词、戳的反应都是按它来的。看的是菜单栏上那家时就是菜单栏的 animator，
                    // 它平时只在新快照、每分钟时重算，面板在别的时候重画（比如跨过「刚恢复」「歇着」的时间门槛）会对不上一会儿
                    .onChange(of: look, initial: true) { _, look in
                        (look.onMenuBar ? animator : headerAnimator).show(mood: look.mood, style: look.style)
                    }
            case .settings:
                let claude = store.snapshot(for: .claude)
                SettingsView(settings: settings,
                             suggestedWeeklyReset: claude?.window("seven_day")?.resetsAt,
                             estimation: claude?.estimation,
                             hasCodex: store.snapshot(for: .codex)?.hasData == true,
                             codexReadingAt: store.snapshot(for: .codex)?.officialAt,
                             watchesCodex: state.usesCodex,
                             canFollowApp: state.canFollowApp,
                             cliProbeStatus: store.cliProbeStatus,
                             cliLoginCommand: store.cliProbeStatus?.needsLogin == true ? store.cliBinary.map(ClaudeCLI.loginCommand) : nil,
                             onBack: { state.page = .overview })
            }
        }
        .id(settings.language)  // 换语言时整个面板重建：输入没变的子视图 SwiftUI 不会重画，文字会停在旧语言
    }
}

/// 面板上的宠物长什么样：哪种心情、哪个形象，用的是不是菜单栏上那只（同一个 animator）
struct PetLook: Equatable {
    var mood: PetMood
    var style: PetStyle
    var onMenuBar: Bool
}

/// 跟着动画走的宠物
struct LivePet: View {
    @ObservedObject var animator: PetAnimator

    var body: some View { PetImage(picture: animator.frame.portrait) }
}

/// 面板里的半身像，显示成 96pt
struct PetImage: View {
    var picture: PetPicture

    var body: some View {
        Image(nsImage: PetRenderer.image(picture))
            .frame(width: picture.points, height: picture.points)
            .accessibilityHidden(true)
    }
}

/// 使用率对应的颜色
enum Level {
    static func bar(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return Color(nsColor: .systemGreen)
        case ..<75: return Color(nsColor: .systemYellow)
        case ..<90: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    static func text(_ percent: Double) -> Color {
        switch percent {
        case ..<75: return .primary
        case ..<90: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    static func mood(_ mood: PetMood) -> Color {
        switch mood {
        case .energetic, .revived: return Color(nsColor: .systemGreen)
        case .normal: return Color(nsColor: .systemTeal)
        case .tired, .nervous: return Color(nsColor: .systemOrange)
        case .exhausted: return Color(nsColor: .systemRed)
        case .sleeping: return Color(nsColor: .systemIndigo)
        case .resting: return Color(nsColor: .systemBlue)
        case .confused, .loading: return Color(nsColor: .systemGray)
        }
    }
}

struct IconButton: View {
    var systemName: String
    var help: String
    /// 旋转角度（刷新按钮点一下转一圈）
    var rotation: Double = 0
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .rotationEffect(.degrees(rotation))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
    }
}
