// 自检：swift run QuotaPetChecks
// 命令行工具（CLT）里没有 XCTest / swift-testing，所以用一个小可执行文件代替。
import Foundation
import ImageIO
@testable import QuotaPetCore

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        print("✗ 第 \(line) 行：\(message)")
    }
}

func near(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-6) -> Bool {
    guard let a else { return false }
    return abs(a - b) <= tolerance
}

/// 2026 年 9 月某天的本地时间
func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
}

let hour: TimeInterval = 3600
let fiveHours = 5 * hour
let week = 7 * 86400.0
typealias S = UsageSample

// 下面按中文文案比对，不受这台机器系统语言的影响；英文在「多语言」一节单独查
L10n.language = .zhHans

// MARK: - 格式化

check(Fmt.duration(2 * hour + 14 * 60) == "2 小时 14 分", "duration")
check(Fmt.duration(30) == "不到 1 分钟", "duration < 1 分钟")
check(Fmt.duration(3 * 86400 + 4 * hour) == "3 天 4 小时", "duration 天")
check(Fmt.compactDuration(hour + 5 * 60) == "1h05m", "compactDuration")
check(Fmt.compactDuration(20) == "1m", "compactDuration 不到 1 分钟")
check(Fmt.clock(at(25, 15, 5), now: at(25, 12)) == "15:05", "clock 当天")
check(Fmt.clock(at(26, 9), now: at(25, 12)) == "明天 09:00", "clock 明天")
check(Fmt.clock(at(30, 17, 45), now: at(25, 12)) == "周三 17:45", "clock 一周内")
check(Fmt.ago(at(25, 11, 45), now: at(25, 12)) == "15 分钟前", "ago")
check(Fmt.fromNow(2 * hour + 14 * 60) == "约 2 小时 14 分后", "fromNow")
check(Fmt.fromNow(30) == "不到 1 分钟后", "fromNow 不到 1 分钟时不说「约」")
check(Fmt.percent(27.4) == "27%" && Fmt.percent(27.5) == "28%", "percent 四舍五入")
check(Fmt.percent(99.6) == "99%" && Fmt.percent(99.99) == "99%", "还没到 100 的不显示成 100%：\(Fmt.percent(99.6))")
check(Fmt.percent(100) == "100%" && Fmt.percent(103) == "103%", "真用完了才是 100%")

// MARK: - 宠物

/// 图片的像素宽高；读不出来时是 nil
func pixelSize(_ url: URL) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
}

for style in PetStyle.allCases {
    // 导出的表情都用上了、用到的都导出过。被戳的反应里用的也算
    let shown = PetMood.allCases.flatMap { mood in
        PetSprites.frames(for: mood, style: style) + [false, true].flatMap { PetSprites.reaction(for: mood, style: style, annoyed: $0) }
    }
    check(Set(shown.map(\.portrait.face)) == Set(PaintedArt.faces), "\(style.label)导出的表情正好都用上")
    check(shown.allSatisfy { $0.icon.style == style && $0.portrait.style == style && $0.icon.face == $0.portrait.face
              && $0.icon.part == .icon && $0.portrait.part == .portrait }, "\(style.label)每一帧的头像和半身像是同一款、同一个表情")
    // 每张图都在（和 App 用同一套办法找 Resources/Pets），而且是显示尺寸的 2 倍
    for face in PaintedArt.faces {
        for part in [PetPicture.Part.icon, .portrait] {
            let picture = PetPicture(style: style, part: part, face: face)
            let pixels = Int(picture.points * 2)
            check(picture.url.flatMap(pixelSize).map { $0 == (pixels, pixels) } == true,
                  "Resources/Pets/\(picture.file) 存在，\(pixels)×\(pixels)")
        }
    }
    for mood in PetMood.allCases {
        let frames = PetSprites.frames(for: mood, style: style)
        check(!frames.isEmpty, "\(style.label) \(mood) 至少一帧")
        check(frames.allSatisfy { $0.duration > 0 }, "\(style.label) \(mood) 帧时长 > 0")
    }
}
check(PetSprites.iconPoints == 22 && PetSprites.portraitPoints == 96, "菜单栏头像 22pt，面板半身像 96pt")
check(PetSprites.frames(for: .energetic)[0] != PetSprites.frames(for: .normal)[0], "不同心情的表情不一样")
check(PetSprites.frames(for: .normal, style: .neko)[0] != PetSprites.frames(for: .normal)[0], "不同形象画出来不一样")
check(Set(PetStyle.claudeChoices).isDisjoint(with: PetStyle.codexChoices)
      && Set(PetStyle.claudeChoices + PetStyle.codexChoices) == Set(PetStyle.allCases), "两家的形象各一组，不重叠、不漏")
check(PetStyle.of(.codex, claudeStyle: .neko, codexStyle: .geek) == .geek && PetStyle.of(.claude, claudeStyle: .neko, codexStyle: .geek) == .neko,
      "两家各用自己选的形象")
check(PetStyle.of(.codex, claudeStyle: .neko, codexStyle: .neko) == .dragon && PetStyle.of(.claude, claudeStyle: .hanfu, codexStyle: .geek) == .classic,
      "选到别家那组的形象时退回自己那组的第一款")
check(PetSprites.frames(for: .normal, style: .dragon)[0] != PetSprites.frames(for: .normal, style: .neko)[0], "龙娘和猫耳画出来不一样")
check(PetMood.from(percent: 10) == .energetic, "< 50% 元气满满")
check(PetMood.from(percent: 50) == .normal, "50% 状态不错")
check(PetMood.from(percent: 80) == .tired, "80% 累了")
check(PetMood.from(percent: 95) == .exhausted, "95% 快撑不住")
check(PetMood.from(percent: 100) == .sleeping, "100% 睡觉")
check(PetStatus.of(nil, now: Date()).mood == .loading && PetStatus.of(nil, failed: true, now: Date()).mood == .confused,
      "还没数据时在加载；还没数据又读取出错了是疑惑")
check(PetStatus.of(UsageSnapshot(provider: .claude, windows: [], generatedAt: Date(), hasData: false), now: Date()).mood == .confused,
      "没数据时疑惑")

// MARK: - 桌面端读数

let historyJSON = """
{"version": 2, "samples": [
  {"t": 1790325603721, "org": "old", "u": {"fh": 50, "sd": 10}},
  {"t": 1790326504168, "org": "A", "u": {}},
  {"t": 1790327403783, "org": "A", "u": {"fh": 24, "sd": 24}},
  {"t": 1790326000000, "org": "A", "u": {"fh": 23, "sd": 24}}
]}
"""
let parsed = try! ClaudeDesktopHistory.parse(Data(historyJSON.utf8))
check(parsed.count == 2, "跳过空读数和旧组织：\(parsed.count)")
check(parsed.first?.session == 23 && parsed.last?.session == 24, "按时间排序")
check(parsed.last?.weekly == 24, "sd 是每周额度")
check((try? ClaudeDesktopHistory.parse(Data("[]".utf8))) == nil, "格式不对要报错")

// MARK: - Claude Code 日志（规则和 usage_lab.py 一致）

func logLine(_ id: String, _ ts: String, _ model: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite1h: Int = 0) -> String {
    #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheWrite1h),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":\#(cacheWrite1h)}}}}"#
}

/// Claude Code 被限流时写的 synthetic 消息，resetsAt = 2026-09-25T06:00:00Z
func limitLine(_ id: String, _ ts: String) -> String {
    #"{"type":"assistant","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"You've hit your session limit"}]},"quotaLimits":{"status":"rejected","resetsAt":1790316000,"rateLimitType":"five_hour"},"error":"rate_limit","isApiErrorMessage":true}"#
}

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-check-\(UUID().uuidString)")
let project = tmp.appendingPathComponent("-Users-me-demo")
try! FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
let file = project.appendingPathComponent("session.jsonl")
let sonnetLine = logLine("m4", "2026-09-25T02:04:00.000Z", "claude-sonnet-5", output: 10_000)
let content = [
    logLine("m1", "2026-09-25T02:00:00.000Z", "claude-opus-5-5", input: 10, output: 100),
    logLine("m1", "2026-09-25T02:00:05.000Z", "claude-opus-5-5", input: 10, output: 1000, cacheRead: 5000, cacheWrite1h: 2000),
    #"{"type":"user","timestamp":"2026-09-25T02:01:00.000Z","message":{"role":"user","content":"how is my \"usage\""}}"#,
    logLine("m2", "2026-09-25T02:02:00.000Z", "<synthetic>", input: 1, output: 1),
    logLine("m3", "2026-09-25T02:03:00.000Z", "claude-haiku-4-5", input: 1000, output: 2000),
    limitLine("m5", "2026-09-25T02:05:00.000Z"),
    limitLine("m6", "2026-09-25T02:06:00.000Z"),  // 限流中又重试了一次
    #"{"type":"user","timestamp":"2026-09-25T02:07:00.000Z","message":{"role":"user","content":"\"quotaLimits\":{\"status\":\"rejected\"}"}}"#,
    String(sonnetLine.prefix(40)),  // Claude Code 还没写完的半行
].joined(separator: "\n")
try! content.write(to: file, atomically: true, encoding: .utf8)

let scanner = ClaudeTranscriptScanner(root: tmp, retention: 365 * 86400)
var requests = scanner.refresh(now: at(25, 23))
check(requests.count == 2, "按 message.id 去重，跳过 synthetic 和半行：\(requests.count)")
let m1 = requests.first { $0.id == "m1" }
check(m1?.tokens == TokenCounts(input: 10, cacheWrite1h: 2000, cacheRead: 5000, output: 1000), "同一响应各字段取最大值")
// opus：10×4 + 2000×8 + 5000×0.2 + 1000×20 = 37040 / 1e6
check(near(m1?.usd, 0.03704), "opus 成本：\(m1?.usd ?? -1)")
check(near(m1?.cacheReadUSD, 0.001) && near(m1?.quotaUSD, 0.03654), "额度加权花费：缓存读 $0.001 按半价算：\(m1?.quotaUSD ?? -1)")
check(scanner.limitEvents == [ClaudeLimitEvent(time: ClaudeTranscriptScanner.parseDate("2026-09-25T02:05:00.000Z")!, window: "five_hour",
                                               resetsAt: Date(timeIntervalSince1970: 1790316000))],
      "限流消息：重试的去重、留最早那条，用户消息里的同名文字不算：\(scanner.limitEvents)")

let handle = try! FileHandle(forWritingTo: file)
handle.seekToEndOfFile()
handle.write(Data((String(sonnetLine.dropFirst(40)) + "\n").utf8))
try! handle.close()
requests = scanner.refresh(now: at(25, 23))
check(requests.count == 3 && requests.last?.family == .sonnet, "增量读取：半行写完后被读到")
check(near(requests.last?.usd, 0.10), "sonnet 1 万输出 tokens = $0.10")
try? FileManager.default.removeItem(at: tmp)

// 按模型版本定价：同一族里老版本的价格不一样（和 usage_lab.py 的 price() 一致）
for (model, family, version) in [
    ("claude-opus-5-5", ModelFamily.opus, (5, 5)), ("claude-opus-4-20250514", .opus, (4, 0)), ("claude-opus-4-8[1m]", .opus, (4, 8)),
    ("claude-haiku-4-5-20251001", .haiku, (4, 5)), ("claude-3-7-sonnet-20250219", .sonnet, (3, 7)), ("us.anthropic.claude-sonnet-4-5-v1:0", .sonnet, (4, 5)),
    ("claude-mythos-5", .fable, (5, 0)),
] {
    let v = ClaudePricing.version(of: model, family: family)
    check(v.map { $0 == version } ?? false, "\(model) 的版本号：\(String(describing: v))")
}
check(ClaudePricing.version(of: "claude-opus", family: .opus) == nil && ClaudePricing.version(of: "opus", family: .opus) == nil,
      "没有版本号的模型名")
check(ModelFamily.of(model: "claude-mythos-5-1") == .fable, "Mythos 和 Fable 同一档，按 Fable 算")
for (model, input, cacheRead, output) in [
    ("claude-opus-5-5", 4.0, 0.2, 20.0), ("claude-opus-5", 5, 0.5, 25), ("claude-opus-4-8", 5, 0.5, 25), ("claude-opus-4-1-20250805", 15, 1.5, 75),
    ("claude-opus-6", 4, 0.2, 20),  // 还没收录的新版本按当前这一代算
    ("claude-fable-5-1", 10, 0.25, 50), ("claude-fable-5", 10, 1, 50), ("claude-mythos-5-1", 10, 0.25, 50),
    ("claude-sonnet-5", 2, 0.2, 10), ("claude-sonnet-4-6", 3, 0.3, 15), ("claude-3-7-sonnet-20250219", 3, 0.3, 15),
    ("claude-sonnet-5-5", 2, 0.2, 10),
    ("claude-haiku-5-5", 0.1, 0.01, 0.5), ("claude-haiku-4-5-20251001", 1, 0.1, 5), ("anthropic.claude-3-5-haiku-20241022-v1:0", 0.8, 0.08, 4),
] {
    let p = ClaudePricing.price(model: model, family: ModelFamily.of(model: model)!)
    check(p.input == input && p.cacheRead == cacheRead && p.output == output, "\(model) 的价格：\(p)")
}
do {  // 日志里是老版本时，扫描出来的请求按老价格算
    let scanner = ClaudeTranscriptScanner(root: tmp, retention: 365 * 86400)
    scanner.ingest(line: Data(logLine("o5", "2026-09-25T02:00:00.000Z", "claude-opus-5", output: 10_000, cacheRead: 1_000_000).utf8), path: "x")
    let r = scanner.refresh(now: at(25, 23)).first
    check(r?.family == .opus && near(r?.usd, 0.75) && near(r?.cacheReadUSD, 0.5), "Opus 5：1 万输出 $0.25 + 100 万缓存读 $0.5：\(r?.usd ?? -1)")
}

do {  // Haiku 5.5 按提示词（输入 + 缓存写 + 缓存读）长短分两档：10 万 token 以内 $0.10 / $0.50，超过的整个请求 5 倍
    let p = ClaudePricing.price(model: "claude-haiku-5-5", family: .haiku)
    let short = TokenCounts(cacheRead: 100_000, output: 10_000)
    check(near(ClaudePricing.cost(p, short), 0.006) && near(ClaudePricing.cacheReadCost(p, short), 0.001),
          "Haiku 5.5：提示词正好 10 万还按低档：\(ClaudePricing.cost(p, short))")
    let long = TokenCounts(input: 1, cacheRead: 100_000, output: 10_000)
    check(near(ClaudePricing.cost(p, long), 0.0300005) && near(ClaudePricing.cacheReadCost(p, long), 0.005),
          "Haiku 5.5：提示词超过 10 万，整个请求按高档：\(ClaudePricing.cost(p, long))")
    let haiku45 = ClaudePricing.price(model: "claude-haiku-4-5", family: .haiku)
    check(near(ClaudePricing.cost(haiku45, long), 0.060001), "Haiku 4.5 不分档")
    // 同一个响应拆成几行时取各字段最大值，合起来超过 10 万就按高档
    let scanner = ClaudeTranscriptScanner(root: tmp, retention: 365 * 86400)
    scanner.ingest(line: Data(logLine("h55", "2026-09-25T02:00:00.000Z", "claude-haiku-5-5", output: 10_000, cacheRead: 90_000).utf8), path: "x")
    scanner.ingest(line: Data(logLine("h55", "2026-09-25T02:00:01.000Z", "claude-haiku-5-5", input: 20_000, cacheRead: 90_000).utf8), path: "x")
    let r = scanner.refresh(now: at(25, 23))
    check(r.count == 1 && near(r.first?.usd, 0.0045 + 0.01 + 0.025), "Haiku 5.5：合并后的提示词 11 万按高档：\(r.first?.usd ?? -1)")
}

check(ClaudeRates.starting.usdPerSessionPercent == 0.27 && ClaudeRates.starting.usdPerWeeklyPercent == 2.0,
      "起始换算率：5 小时 $0.27 / 1%，每周 $2.0 / 1%")
/// 下面的估算测试用 $0.117 / 1%，数字好算
let testRate = 0.117

// MARK: - 窗口推算

do {  // 自然到期
    let r1 = WindowInference.infer(samples: [], activity: [at(25, 10), at(25, 10, 30), at(25, 11)], duration: fiveHours, now: at(25, 14))
    check(r1.current == InferredWindow(start: at(25, 10), end: at(25, 15)), "第一次使用开启 5 小时窗口")
    let r2 = WindowInference.infer(samples: [], activity: [at(25, 10)], duration: fiveHours, now: at(25, 15, 30))
    check(r2.current == nil && r2.lastReset == at(25, 15), "5 小时后自然结束")
    let r3 = WindowInference.infer(samples: [], activity: [at(25, 10), at(25, 15, 10)], duration: fiveHours, now: at(25, 16))
    check(r3.current?.start == at(25, 15, 10), "结束后的第一次使用开启新窗口")
}

do {  // 88% → 0%：以读数跳变为准（真实数据 09-25 下午的形状）
    let samples = [S(time: at(25, 10, 16), value: 0), S(time: at(25, 10, 21), value: 6), S(time: at(25, 14, 55), value: 88),
                   S(time: at(25, 15, 10), value: 0), S(time: at(25, 15, 25), value: 6)]
    let activity = [at(25, 10, 19), at(25, 12), at(25, 14, 50), at(25, 15, 12), at(25, 15, 20)]
    let r = WindowInference.infer(samples: samples, activity: activity, duration: fiveHours, now: at(25, 15, 30))
    check(r.current?.start == at(25, 15, 12), "重置后的第一个请求开启新窗口：\(String(describing: r.current))")
    check(r.lastReset.map { $0 > at(25, 14, 55) && $0 <= at(25, 15, 10) } == true, "重置发生在两次读数之间")
}

do {  // 15% → 3%：重置后马上又用了（网页端，没有本机请求）
    let samples = [S(time: at(23, 17, 52), value: 0), S(time: at(23, 18, 10), value: 6), S(time: at(23, 22, 40), value: 15),
                   S(time: at(23, 22, 55), value: 3), S(time: at(23, 23, 10), value: 1)]
    let r = WindowInference.infer(samples: samples, activity: [], duration: fiveHours, now: at(23, 23, 30))
    let start = r.current?.start
    check(start.map { $0 > at(23, 22, 40) && $0 <= at(23, 22, 55) } == true, "新窗口开始于跳变区间：\(String(describing: start))")
    check(!WindowInference.isReset(from: 3, to: 1), "3 → 1 是噪声，不算重置")
    check(WindowInference.isReset(from: 88, to: 0) && WindowInference.isReset(from: 15, to: 3), "明显下跌是重置")
}

do {  // 每周：桌面端最早的读数是 0，说明更早的窗口都结束了
    let samples = [S(time: at(23, 17, 52), value: 0), S(time: at(23, 18, 10), value: 0), S(time: at(23, 19, 40), value: 1)]
    let activity = [at(17, 10), at(20, 9), at(23, 17, 58), at(24, 12)]
    let r = WindowInference.infer(samples: samples, activity: activity, duration: week, now: at(25, 23))
    check(r.current?.start == at(23, 17, 58), "每周窗口从读数为 0 之后的第一次使用开始：\(String(describing: r.current))")
    let fixed = WindowInference.infer(samples: samples, activity: activity, duration: week, now: at(25, 23), fixedCadence: true)
    check(fixed == r && !fixed.fromCadence, "固定周期：还没看到过重置时，照样按第一次使用推")
}

do {  // 每周额度按固定时间重置，不管有没有用：前几天没用，周二晚上才第一次用
    let samples = [S(time: at(22, 20, 10), value: 0), S(time: at(22, 21, 30), value: 2), S(time: at(28, 5, 50), value: 70),
                   S(time: at(28, 6, 5), value: 0)]
    let activity = [at(22, 21, 5), at(28, 8)]
    let r = WindowInference.infer(samples: samples, activity: activity, duration: week, now: at(28, 12), fixedCadence: true)
    check(r.current == InferredWindow(start: at(28, 6, 5), end: at(28, 6, 5) + week) && r.lastReset == at(28, 6, 5) && r.fromCadence,
          "重置之后的窗口从重置时刻（跳变区间里最晚的时刻）开始，不等第一次使用：\(r)")
    let later = WindowInference.infer(samples: samples, activity: activity, duration: week, now: at(28, 12) + 2 * week, fixedCadence: true)
    check(later.current?.start == at(28, 6, 5) + 2 * week, "之后没有用量也每 7 天重置一次")

    // 桌面端夜里没开，这次只知道重置在 01:00–10:00 之间；上周看到过 05:50–06:10，合起来是 05:50–06:10。
    // 重置是每 7×24 小时一次（绝对时间），期望值从上周的时刻加 week 算，不写成 at(28, …)：那一周本地时间可能跨夏令时
    let wide = [S(time: at(21, 5, 50), value: 70), S(time: at(21, 6, 10), value: 0), S(time: at(28, 1), value: 50),
                S(time: at(28, 10), value: 2)]
    let narrowed = WindowInference.infer(samples: wide, activity: [], duration: week, now: at(28, 11), fixedCadence: true)
    check(narrowed.lastReset == at(21, 6, 10) + week, "多次跳变取交集，收窄重置时间：\(narrowed)")
    let exact = WindowInference.infer(samples: Array(wide.suffix(2)), activity: [], duration: week, now: at(28, 11),
                                      knownResets: [at(21, 6, 3)], fixedCadence: true)
    check(exact.lastReset == at(21, 6, 3) + week, "限流消息的精确时间也能推到之后的每一周：\(exact)")
    // 上周的跳变在 15:00 左右，和这周对不上：重置时间变过，只信最近的
    let moved = [S(time: at(21, 15), value: 70), S(time: at(21, 15, 20), value: 0), S(time: at(28, 5, 50), value: 50),
                 S(time: at(28, 6, 10), value: 0)]
    let r2 = WindowInference.infer(samples: moved, activity: [], duration: week, now: at(28, 11), fixedCadence: true)
    check(r2.lastReset == at(28, 6, 10), "重置时间变过时用最近的一次：\(r2)")

    // 定不了重置时刻的跳变不用，照样按第一次使用推：1 → 0 可能是噪声；桌面端关了一周以上
    let noise = [S(time: at(22, 20, 10), value: 0), S(time: at(22, 21, 30), value: 1), S(time: at(24, 9), value: 0)]
    check(WindowInference.infer(samples: noise, activity: activity, duration: week, now: at(25, 12), fixedCadence: true)
            == WindowInference.infer(samples: noise, activity: activity, duration: week, now: at(25, 12)), "1 → 0 不用来定周期")
    let closed = [S(time: at(10, 9), value: 60), S(time: at(22, 9), value: 3)]
    check(WindowInference.infer(samples: closed, activity: [at(22, 8)], duration: week, now: at(25, 12), fixedCadence: true)
            == WindowInference.infer(samples: closed, activity: [at(22, 8)], duration: week, now: at(25, 12)), "空档一周以上的跳变不用来定周期")
}

do {  // 限流消息给出精确的重置时间：14:00（按第一次使用推的话是 14:15）
    let activity = [at(20, 9, 15), at(20, 11), at(20, 14, 5)]
    let r = WindowInference.infer(samples: [], activity: activity, duration: fiveHours, now: at(20, 14, 10), knownResets: [at(20, 14)])
    check(r.lastReset == at(20, 14) && r.current?.start == at(20, 14, 5), "14:00 重置后，14:05 的使用开启新窗口：\(r)")
    let guess = WindowInference.infer(samples: [], activity: activity, duration: fiveHours, now: at(20, 14, 10))
    check(guess.current?.start == at(20, 9, 15), "没有限流消息时，14:05 还算在旧窗口里")
    // 桌面端读数 100 → 0 只能说明重置在两次读数之间（取中点 13:10），有精确时间就用精确的
    let samples = [S(time: at(20, 12), value: 100), S(time: at(20, 14, 20), value: 0)]
    let r2 = WindowInference.infer(samples: samples, activity: [at(20, 9, 15)], duration: fiveHours, now: at(20, 14, 30),
                                   knownResets: [at(20, 14)])
    check(r2.lastReset == at(20, 14) && r2.current == nil, "读数跳变区间里的精确重置时间：\(r2)")
    // 桌面端关了 12 小时（80 → 3），中间撞了两次限流：14:00 和 19:05 各重置一次（窗口都是从网页上先开始的，比本机第一次请求早）
    let gap = [S(time: at(20, 10), value: 80), S(time: at(20, 22), value: 3)]
    let r3 = WindowInference.infer(samples: gap, activity: [at(20, 9, 30), at(20, 14, 20), at(20, 19, 10)], duration: fiveHours,
                                   now: at(20, 22, 10), knownResets: [at(20, 14), at(20, 19, 5)])
    check(r3.lastReset == at(20, 19, 5) && r3.current?.start == at(20, 19, 10), "一段空档里的两次精确重置都用上：\(r3)")
}

do {  // 隔了一个窗口以上的读数还不是 0（5 小时额度隔夜 50 → 30）：之前的窗口早就结束了，早上的读数是另一个窗口的
    let overnight = [S(time: at(24, 18), value: 50), S(time: at(25, 9), value: 30)]
    let r = WindowInference.infer(samples: overnight, activity: [at(24, 14), at(24, 17), at(25, 15)], duration: fiveHours,
                                  now: at(25, 15, 10))
    check(r.current?.start == at(25, 15) && r.lastReset.map { $0 > at(25, 9) } == true, "早上那个窗口在下午用之前就结束了：\(r)")

    // 每周额度还没看到过重置：从之前推出来的窗口开始时间（origin）接着推。日志只留 8 天，周一 10:00 开始的窗口，
    // 到了周二中午最早的请求已经是上周四的了，从它推的话窗口会变成从上周四开始
    let retained = [at(10, 9), at(14, 10), at(15, 10)]
    let drifted = WindowInference.infer(samples: [], activity: retained, duration: week, now: at(15, 12), fixedCadence: true)
    let kept = WindowInference.infer(samples: [], activity: retained, duration: week, now: at(15, 12), fixedCadence: true, origin: at(14, 10))
    check(drifted.current?.start == at(10, 9) && kept.current?.start == at(14, 10) && kept.lastReset == at(14, 10),
          "从 origin 接着推，起点不跟着日志往后挪：\(kept)")
    let after = WindowInference.infer(samples: [], activity: retained + [at(21, 11)], duration: week, now: at(21, 12), fixedCadence: true,
                                      origin: at(14, 10))
    check(after.current?.start == at(21, 11) && after.lastReset == at(14, 10) + week, "origin 的窗口结束后照常从下一次使用开始：\(after)")
}

// MARK: - 官方读数 + 实时估算

do {
    let provider = ClaudeProvider(historyURL: URL(fileURLWithPath: "/nonexistent/h.json"),
                                  projectsURL: URL(fileURLWithPath: "/nonexistent/projects"), archiveURL: nil)
    func opus(_ t: Date, usd: Double) -> ClaudeRequest {
        ClaudeRequest(id: UUID().uuidString, time: t, family: .opus, tokens: TokenCounts(output: Int((usd / 20 * 1e6).rounded())))
    }
    let series = [S(time: at(25, 22, 54), value: 0), S(time: at(25, 23, 25), value: 20)]
    let reqs = [opus(at(25, 23, 0), usd: 0.117 * 5), opus(at(25, 23, 30), usd: 0.117 * 3)]
    let percentOf: (ClaudeRequest) -> Double = { $0.usd / testRate }
    let live = provider.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: series,
                                    requests: reqs, scale: 1, percentOf: percentOf, resetAnchor: nil, live: true, now: at(25, 23, 40))
    check(near(live.official, 20) && near(live.percent, 23, 1e-3), "官方 20% + 之后本机 3%：\(live.percent)")
    check(live.startedAt == at(25, 23, 0) && live.resetsAt == at(26, 4, 0), "窗口从 23:00 的请求开始")
    let off = provider.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: series,
                                   requests: reqs, scale: 1, percentOf: percentOf, resetAnchor: nil, live: false, now: at(25, 23, 40))
    check(near(off.percent, 20), "关掉实时估算时只显示官方读数")

    // 窗口 23:20 才开始（回看的半小时被窗口开始截断）：开启窗口的那个 5% 也算进速度，(5 + 3)% ÷ 20 分钟 = 每小时 24%
    let opening = provider.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: [],
                                       requests: [opus(at(25, 23, 20), usd: 0.117 * 5), opus(at(25, 23, 30), usd: 0.117 * 3)],
                                       scale: 1, percentOf: percentOf, resetAnchor: nil, live: true, now: at(25, 23, 40))
    check(opening.startedAt == at(25, 23, 20) && near(opening.percent, 8, 1e-3) && near(opening.burnPerHour, 24, 1e-3),
          "开启窗口的请求也算进消耗速度：\(opening.percent) \(opening.burnPerHour ?? -1)")

    let heavy = [opus(at(25, 23, 30), usd: 0.117 * 90)]  // 20% + 90% 会冲过 100%
    let capped = provider.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: series,
                                      requests: heavy, scale: 1, percentOf: percentOf, resetAnchor: nil, live: true, now: at(25, 23, 40))
    check(near(capped.percent, 99), "估算不能宣布用完：官方没到 100% 时最多 99%：\(capped.percent)")

    // 撞线：14:30 官方 85%，14:45 Claude Code 报告限流，18:00 恢复
    let before = [S(time: at(20, 14, 30), value: 85)]
    let work = [opus(at(20, 14, 35), usd: 0.117 * 5)]
    let hit = ClaudeLimitEvent(time: at(20, 14, 45), window: "five_hour", resetsAt: at(20, 18))
    func limited(_ series: [S], _ reqs: [ClaudeRequest], _ limits: [ClaudeLimitEvent], now: Date) -> UsageWindow {
        provider.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: series, requests: reqs,
                             scale: 1, percentOf: percentOf, resetAnchor: nil, limits: limits, live: true, now: now)
    }
    let asleep = limited(before, work, [hit], now: at(20, 14, 50))
    check(near(asleep.percent, 100) && asleep.official == 100 && asleep.officialAt == at(20, 14, 45) && asleep.limitReported,
          "限流消息能宣布用完：\(asleep.percent)")
    check(asleep.startedAt == at(20, 13) && asleep.resetsAt == at(20, 18), "窗口按限流消息里的恢复时间算")
    check(near(limited(before, work, [], now: at(20, 14, 50)).percent, 90, 1e-3), "没有限流消息时还是 85% + 本机 5%")
    let bought = limited(before + [S(time: at(20, 14, 55), value: 60)], work, [hit], now: at(20, 15))
    check(near(bought.percent, 60), "限流之后官方读数明显不到 100（别的账号 / 额度变了）就以官方为准：\(bought.percent)")
    let stale = limited(before + [S(time: at(20, 14, 48), value: 97)], work, [hit], now: at(20, 14, 50))
    check(near(stale.percent, 100) && stale.limitReported, "限流之后的读数只差一点（取整、读得早）还是算用完")
    let confirmed = limited(before + [S(time: at(20, 14, 46), value: 100)], work, [hit], now: at(20, 14, 50))
    check(near(confirmed.percent, 100) && confirmed.officialAt == at(20, 14, 46) && !confirmed.limitReported, "桌面端也读到 100 时用桌面端的读数")
    let other = limited([S(time: at(20, 14, 30), value: 20)], work, [hit], now: at(20, 14, 50))
    check(near(other.percent, 25, 1e-3) && other.resetsAt == at(20, 19, 35), "官方 20% + 本机 5% 离 100 太远：多半是别的账号撞线，不用：\(other.percent)")
    let closed = limited([], work, [hit], now: at(20, 14, 50))
    check(near(closed.percent, 100) && closed.resetsAt == at(20, 18), "这个窗口里没有官方读数时没法核对，相信限流消息")
    let olderReading = limited([S(time: at(20, 13, 30), value: 20)], work, [hit], now: at(20, 14, 50))
    check(near(olderReading.percent, 100) && olderReading.limitReported,
          "限流前最近的读数是一个多小时前的（桌面端停了）：之后网页、手机用了多少看不到，不拿它否定限流消息：\(olderReading.percent)")
    let later = limited(before, work + [opus(at(20, 18, 2), usd: 0.117 * 2)], [hit], now: at(20, 18, 10))
    check(later.official == nil && near(later.percent, 2, 1e-3) && later.startedAt == at(20, 18, 2), "恢复之后从新窗口重新算：\(later)")
    let bogus = ClaudeLimitEvent(time: at(20, 14, 45), window: "five_hour", resetsAt: at(20, 20))
    check(near(limited(before, work, [bogus], now: at(20, 14, 50)).percent, 90, 1e-3), "恢复时间比限流晚 5 小时以上的不可信，不用")

    // 官方读数所在的窗口已经结束了，不能当成现在的：5 小时额度隔夜 50 → 30、下午才用 Claude Code；隔夜 100 → 100；每周读数停在 9 天前
    func five(_ series: [S], _ reqs: [ClaudeRequest], now: Date) -> UsageWindow {
        provider.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: series, requests: reqs, scale: 1,
                             percentOf: percentOf, resetAnchor: nil, live: true, now: now)
    }
    let overnight = [S(time: at(24, 18), value: 50), S(time: at(25, 9), value: 30)]
    let yesterday = [opus(at(24, 14), usd: 0.117 * 20), opus(at(24, 17), usd: 0.117 * 20)]
    let afternoon = five(overnight, yesterday + [opus(at(25, 15), usd: 0.117 * 2), opus(at(25, 15, 5), usd: 0.117)], now: at(25, 15, 10))
    check(afternoon.official == nil && near(afternoon.percent, 3, 1e-3), "早上读数的窗口已经结束：只算下午的本机用量：\(afternoon.percent)")
    check(near(five(overnight, yesterday, now: at(25, 14, 30)).percent, 0), "那个窗口结束后还没用：0%")
    let maxed = [S(time: at(24, 21, 30), value: 90), S(time: at(24, 21, 45), value: 100), S(time: at(25, 9), value: 100)]
    let night = [opus(at(24, 17), usd: 0.117 * 40), opus(at(24, 21, 40), usd: 0.117 * 50)]
    check(near(five(maxed, night, now: at(25, 12)).percent, 100), "早上又用满了：那个窗口里照样是 100%")
    let woke = five(maxed, night + [opus(at(26, 10), usd: 0.117)], now: at(26, 10, 5))
    check(woke.official == nil && near(woke.percent, 1, 1e-3), "第二天再用：不是 100 + 1 = 101%（宠物误睡、误报用完）：\(woke.percent)")
    let lastWeek = provider.buildWindow(id: "seven_day", title: "", duration: week,
                                        series: [S(time: at(10, 9), value: 40), S(time: at(10, 9, 15), value: 40)],
                                        requests: [opus(at(19, 10), usd: 0.117 * 3)], scale: 1, percentOf: percentOf,
                                        resetAnchor: nil, fixedCadence: true, live: true, now: at(19, 10, 5))
    check(lastWeek.official == nil && near(lastWeek.percent, 3, 1e-3), "每周读数停在 9 天前：不再当成这一周的：\(lastWeek.percent)")

    let manual = provider.buildWindow(id: "seven_day", title: "", duration: week, series: [], requests: [],
                                      scale: 0.124, percentOf: percentOf, resetAnchor: at(16, 18), live: true, now: at(25, 23))
    check(manual.startedAt == at(16, 18) + week && manual.resetsAt == at(16, 18) + 2 * week, "手动指定的每周重置时间每 7 天循环")

    // 固定周期：上周看到过 06:10 前后的重置，这周到点之后还没有新的官方读数，就只按本机用量从头算
    let weekly = [S(time: at(14, 5, 50), value: 70), S(time: at(14, 6, 10), value: 0), S(time: at(20, 12), value: 40)]
    let cadence = provider.buildWindow(id: "seven_day", title: "", duration: week, series: weekly,
                                       requests: [opus(at(21, 7), usd: 0.117 * 2)], scale: 1, percentOf: percentOf,
                                       resetAnchor: nil, fixedCadence: true, live: true, now: at(21, 8))
    check(cadence.startedAt == at(21, 6, 10) && cadence.official == nil && near(cadence.percent, 2, 1e-3),
          "每周窗口到点重置，之前的官方读数不再算：\(cadence)")
    // 重置时间靠不靠得住（决定面板上看不看节奏）：看到过重置、手动指定的靠得住；还没看到过重置时是按第一次使用猜的
    let guessed = provider.buildWindow(id: "seven_day", title: "", duration: week, series: Array(weekly.suffix(1)),
                                       requests: [opus(at(21, 7), usd: 0.117 * 2)], scale: 1, percentOf: percentOf,
                                       resetAnchor: nil, fixedCadence: true, live: true, now: at(21, 8))
    check(cadence.scheduleKnown && manual.scheduleKnown && !guessed.scheduleKnown, "每周重置时间是不是猜的：\(guessed)")
}

do {  // 整条链路：日志里的限流消息经过 snapshot() 分到各自的窗口
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-limits-\(UUID().uuidString)")
    let projects = dir.appendingPathComponent("projects/-Users-me-demo")
    try! FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter()
    let history = #"{"version":2,"samples":[{"t":\#(Int(at(20, 14, 30).timeIntervalSince1970 * 1000)),"org":"A","u":{"fh":85,"sd":90}}]}"#
    try! history.write(to: dir.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
    func limit(_ t: Date, _ type: String, resets: Date) -> String {
        #"{"type":"assistant","timestamp":"\#(iso.string(from: t))","message":{"id":"\#(type)","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}},"quotaLimits":{"status":"rejected","resetsAt":\#(Int(resets.timeIntervalSince1970)),"rateLimitType":"\#(type)"}}"#
    }
    let log = [logLine("w1", iso.string(from: at(20, 14, 35)), "claude-opus-5-5", output: 10_000),
               limit(at(20, 14, 45), "five_hour", resets: at(20, 18)), limit(at(20, 14, 46), "seven_day", resets: at(24, 9))]
    try! (log.joined(separator: "\n") + "\n").write(to: projects.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    let provider = ClaudeProvider(historyURL: dir.appendingPathComponent("history.json"),
                                  projectsURL: dir.appendingPathComponent("projects"), archiveURL: nil)
    let snap = try! provider.snapshot(now: at(20, 15))
    let session = snap.window("five_hour"), weekly = snap.window("seven_day")
    check(session?.limitReported == true && near(session?.percent, 100) && session?.resetsAt == at(20, 18),
          "5 小时的限流消息进了 5 小时窗口：\(String(describing: session))")
    check(weekly?.limitReported == true && near(weekly?.percent, 100) && weekly?.resetsAt == at(24, 9),
          "每周的限流消息进了每周窗口：\(String(describing: weekly))")
    try? FileManager.default.removeItem(at: dir)
}

do {  // 每周窗口推出来的开始时间存下来，重启后接着推：日志只留 8 天，旧请求滚出去后起点不会跟着往后挪
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-origin-\(UUID().uuidString)")
    let projects = dir.appendingPathComponent("projects/-Users-me-demo")
    try! FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    let log = [logLine("o1", "2026-09-07T01:00:00.000Z", "claude-opus-5-5", output: 1_000),
               logLine("o2", "2026-09-10T01:00:00.000Z", "claude-opus-5-5", output: 1_000),
               logLine("o3", "2026-09-14T02:00:00.000Z", "claude-opus-5-5", output: 1_000),
               logLine("o4", "2026-09-15T02:00:00.000Z", "claude-opus-5-5", output: 1_000)]
    try! (log.joined(separator: "\n") + "\n").write(to: projects.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
    func provider() -> ClaudeProvider {
        ClaudeProvider(historyURL: dir.appendingPathComponent("none.json"), projectsURL: dir.appendingPathComponent("projects"),
                       archiveURL: dir.appendingPathComponent("intervals.jsonl"))
    }
    let first = try! provider().snapshot(now: Date(timeIntervalSince1970: 1_789_354_800))     // 09-14 03:00Z：最早的请求还在
    let o3 = ISO8601DateFormatter().date(from: "2026-09-14T02:00:00Z")!
    check(first.window("seven_day")?.startedAt == o3, "每周窗口从上一个窗口结束后的第一次使用开始：\(String(describing: first.window("seven_day")?.startedAt))")
    let later = try! provider().snapshot(now: Date(timeIntervalSince1970: 1_789_444_800))     // 09-15 04:00Z：09-07 的请求滚出去了
    check(later.window("seven_day")?.startedAt == o3, "重启后从存下来的起点接着推，不会变成从 09-10 开始：\(String(describing: later.window("seven_day")?.startedAt))")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 其他端用量

do {
    /// 值 pct 个百分点的请求（percentOf = usd × 100）
    func req(_ t: Date, _ pct: Double) -> ClaudeRequest {
        ClaudeRequest(id: UUID().uuidString, time: t, family: .opus, tokens: TokenCounts(output: Int(pct * 500)))
    }
    let percentOf: (ClaudeRequest) -> Double = { $0.usd * 100 }
    let reqs = [req(at(20, 10), 3), req(at(20, 10, 38), 5), req(at(20, 11, 15), 2)]
    let readings = [S(time: at(20, 10, 10), value: 3), S(time: at(20, 10, 25), value: 9), S(time: at(20, 10, 40), value: 15),
                    S(time: at(20, 10, 55), value: 16), S(time: at(20, 11, 10), value: 20), S(time: at(20, 11, 25), value: 30)]
    let segments = OtherUsage.segments(start: at(20, 10), readings: readings, requests: reqs, percentOf: percentOf)
    // 10:10 本机 3 对上；10:25 本机没有请求，+6 全是其他端；10:40 本机 5、官方 6，差 1 是误差；
    // 10:55 +1 紧跟在 10:38 的请求后面，是服务器计数慢；11:10 本机没有请求，+4；11:25 本机 2、官方 10，多出 8
    check(segments.count == 3 && zip(segments, [6.0, 4, 8]).allSatisfy { near($0.percent, $1) } && segments.first?.start == at(20, 10, 10),
          "逐段找出其他端用量：\(segments.map(\.percent))")
    check(near(OtherUsage.burnPerHour(segments, from: at(20, 10, 55), now: at(20, 11, 25), minSpan: 600), 24, 1e-6),
          "其他端每小时：半小时里 4 + 8 = 12")
    check(near(OtherUsage.burnPerHour(segments, from: at(20, 11), now: at(20, 11, 30), minSpan: 600), 21.3333, 1e-3),
          "跨边界的段按时间比例摊，最近一次读数之后看不到的按 0 算：(4 × 2/3 + 8) ÷ 30 分钟")
    let wobble = [S(time: at(20, 10, 10), value: 5), S(time: at(20, 10, 25), value: 3), S(time: at(20, 10, 40), value: 5)]
    let wobbled = OtherUsage.segments(start: at(20, 10), readings: wobble, requests: [], percentOf: percentOf)
    check(wobbled.count == 1 && near(wobbled.first?.percent, 5), "读数往回掉又回来，不算新用量")
    let twin = OtherUsage.segments(start: at(20, 10), readings: [S(time: at(20, 10, 10), value: 3), S(time: at(20, 10, 10), value: 5)],
                                   requests: [], percentOf: percentOf)
    check(twin.count == 1 && OtherUsage.burnPerHour(twin, from: at(20, 10), now: at(20, 10, 30), minSpan: 600).isFinite,
          "同一时刻的两条读数不会产生长度为 0 的段")

    let provider = ClaudeProvider(historyURL: URL(fileURLWithPath: "/nonexistent/h.json"),
                                  projectsURL: URL(fileURLWithPath: "/nonexistent/projects"), archiveURL: nil)
    func window(_ series: [S], live: Bool = true) -> UsageWindow {
        provider.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: series,
                             requests: [reqs[0]], scale: 1, percentOf: percentOf, resetAnchor: nil, live: live, now: at(20, 10, 30))
    }
    let zero = [S(time: at(20, 9, 30), value: 0)]  // 窗口开始前读数确实是 0
    let w = window(zero + [S(time: at(20, 10, 10), value: 10), S(time: at(20, 10, 25), value: 16)])
    // 总速度 = 本机（开启窗口的那个 3%）+ 其他端 13，正好是官方从 0 涨到 16 的速度
    check(near(w.otherPercent, 13) && near(w.otherBurnPerHour, 26, 1e-6) && near(w.burnPerHour, 32, 1e-6),
          "从 0 算起：10:10 本机 3、官方 10，多 7；10:25 本机没有请求，+6；速度 (3 + 13) ÷ 30 分钟：\(w.otherPercent) \(w.burnPerHour ?? -1)")
    let midway = window([S(time: at(20, 10, 10), value: 40), S(time: at(20, 10, 25), value: 46)])
    check(near(midway.otherPercent, 6), "开始前没有 0 的读数（记录从窗口中间开始）：第一次读数之前的 40% 不算其他端：\(midway.otherPercent)")
    check(window(zero + Array(readings.prefix(2)), live: false).otherPercent == 0, "关掉实时估算时也不算其他端")
}

// MARK: - Codex 日志

/// Codex 日志里的一行 token_count 事件（数字都是编的）
func codexLine(_ time: Date, limit: String? = "codex", _ windows: [(minutes: Int, used: Double, resets: Date)],
               type: String = "token_count") -> String {
    var limits: [String: Any] = ["limit_id": limit ?? NSNull(), "secondary": NSNull(), "plan_type": "plus"]
    for (key, w) in zip(["primary", "secondary"], windows) {
        limits[key] = ["used_percent": w.used, "window_minutes": w.minutes, "resets_at": Int(w.resets.timeIntervalSince1970)]
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let obj: [String: Any] = ["timestamp": formatter.string(from: time), "type": "event_msg",
                              "payload": ["type": type, "info": ["total_token_usage": ["total_tokens": 1234]], "rate_limits": limits]]
    return String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
}

do {
    let line = codexLine(at(20, 10), [(300, 20, at(20, 14)), (10080, 40, at(24, 9))])
    let reading = CodexRateReading.parse(line: Data(line.utf8))
    check(reading?.time == at(20, 10) && reading?.isMain == true, "解析时间和额度桶")
    check(reading?.windows == [.init(minutes: 300, usedPercent: 20, resetsAt: at(20, 14)), .init(minutes: 10080, usedPercent: 40, resetsAt: at(24, 9))],
          "解析 5 小时和每周两个窗口")
    let legacy = #"{"timestamp":"2026-09-20T02:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.5,"window_minutes":300,"resets_in_seconds":3600}}}}"#
    let old = CodexRateReading.parse(line: Data(legacy.utf8))
    check(old?.limitID == nil && old?.isMain == true && old?.windows.first?.resetsAt == old.map { $0.time.addingTimeInterval(3600) },
          "老版本：没有 limit_id、给的是 resets_in_seconds")
    check(CodexRateReading.parse(line: Data(codexLine(at(20, 10), [(300, 20, at(20, 14))], type: "agent_message").utf8)) == nil,
          "不是 token_count 事件不算")
    check(CodexRateReading.parse(line: Data(codexLine(at(20, 10), limit: "premium", []).utf8)) == nil, "没有窗口的额度桶跳过")
    check(CodexRateReading.parse(line: Data(codexLine(at(20, 10), limit: "codex_other", [(300, 20, at(20, 14))]).utf8))?.isMain == false,
          "别的额度桶不是总额度")
    check(CodexRateReading.parse(line: Data(#"{"timestamp":"2026-09-20T02:00:00Z","type":"session_meta","payload":{"id":"x"}}"#.utf8)) == nil,
          "别的行不看")
    // 重置时间要在这条记录之后一个窗口以内：换成毫秒之类的格式变化不能让窗口永远不重置
    let millis = #"{"timestamp":"2026-09-20T02:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12,"window_minutes":300,"resets_at":1790000000000},"secondary":{"used_percent":30,"window_minutes":10080,"resets_at":1790000000}}}}"#
    check(CodexRateReading.parse(line: Data(millis.utf8))?.windows.map(\.minutes) == [10080], "重置时间离谱的窗口不要（只剩每周）")
    let twice = codexLine(at(20, 10), [(300, 20, at(20, 14)), (300, 25, at(20, 14))])
    check(CodexRateReading.parse(line: Data(twice.utf8))?.windows.count == 1, "同样长的两个窗口只留一个")
    let huge = #"{"timestamp":"2026-09-20T02:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1e300,"window_minutes":300,"resets_at":1789880400},"secondary":{"used_percent":5,"window_minutes":200000000000000000,"resets_at":1790000000}}}}"#
    check(CodexRateReading.parse(line: Data(huge.utf8))?.windows == [.init(minutes: 300, usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 1789880400))],
          "离谱的数字不能让 App 崩：百分比限制到 100，超长的窗口不要")

    // 增量读取：新文件先读；比最新读数早一天以上的旧文件第一次不读，只跟后面追加的
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-codex-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let day20 = home.appendingPathComponent("sessions/2026/09/20"), day18 = home.appendingPathComponent("sessions/2026/09/18")
    let archived = home.appendingPathComponent("archived_sessions")
    for dir in [day20, day18, archived] { try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    func write(_ url: URL, _ lines: [String], modified: Date, newline: Bool = true) {
        try! (lines.joined(separator: "\n") + (newline ? "\n" : "")).write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    func append(_ url: URL, _ text: String, modified: Date) {
        let handle = try! FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try! handle.close()
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    let recent = day20.appendingPathComponent("rollout-a.jsonl"), stale = day18.appendingPathComponent("rollout-b.jsonl")
    write(recent, [#"{"timestamp":"2026-09-20T01:00:00Z","type":"session_meta","payload":{"id":"x"}}"#,
                   codexLine(at(19, 12), [(300, 60, at(19, 15)), (10080, 30, at(24, 9))]),
                   codexLine(at(20, 10), [(300, 20, at(20, 14)), (10080, 40, at(24, 9))]),
                   codexLine(at(20, 12, 30), [(300, 35, at(20, 14)), (10080, 44, at(24, 9))]),
                   codexLine(at(20, 12, 45), limit: "codex_other", [(300, 90, at(20, 16))])], modified: at(20, 12, 45))
    write(stale, [codexLine(at(18, 9), [(300, 5, at(18, 13)), (10080, 10, at(24, 9))])], modified: at(18, 9))
    try! #"{"rate_limits": "登录凭据不在 sessions 里，不会被读到"}"#.write(to: home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    let scanner = CodexLogScanner(home: home)
    var readings = scanner.refresh(now: at(20, 13))
    check(readings.map(\.time) == [at(19, 12), at(20, 10), at(20, 12, 30), at(20, 12, 45)], "读到新文件里的 4 次读数，旧文件先不读：\(readings.map(\.time))")
    check(scanner.trackedFiles == 2, "两个文件都在跟：\(scanner.trackedFiles)")
    append(stale, codexLine(at(20, 12, 50), [(300, 36, at(20, 14)), (10080, 45, at(24, 9))]) + "\n", modified: at(20, 12, 50))
    readings = scanner.refresh(now: at(20, 13))
    check(readings.last?.time == at(20, 12, 50) && !readings.contains { $0.time == at(18, 9) }, "旧文件只读后面追加的")
    let half = codexLine(at(20, 12, 55), [(300, 37, at(20, 14)), (10080, 46, at(24, 9))])
    append(recent, String(half.prefix(40)), modified: at(20, 12, 55))
    check(scanner.refresh(now: at(20, 13)).count == 5, "写到一半的行先不算")
    append(recent, String(half.dropFirst(40)) + "\n", modified: at(20, 12, 56))
    check(scanner.refresh(now: at(20, 13)).last?.time == at(20, 12, 55), "写完了再算")
    try! FileManager.default.copyItem(at: recent, to: archived.appendingPathComponent("rollout-a.jsonl"))
    check(scanner.refresh(now: at(20, 13)).count == 6, "归档挪过去的同一个对话不重复算")

    // 快照：只看总额度，读数就是官方百分比
    let provider = CodexProvider(home: home)
    let snap = try! provider.snapshot(now: at(20, 13))
    let session = snap.window("five_hour"), weekly = snap.window("seven_day")
    check(snap.provider == .codex && snap.hasData && snap.windows.map(\.id) == ["five_hour", "seven_day"], "5 小时 + 每周两个窗口")
    check(session?.title == "5 小时会话" && weekly?.title == "本周额度", "窗口名和 Claude 的一样")
    check(near(session?.percent, 37) && session?.official == 37 && session?.officialAt == at(20, 12, 55) && session?.estimatedExtra == 0,
          "百分比 = 最新一次总额度读数（别的额度桶的 90% 不算）：\(String(describing: session?.percent))")
    check(session?.startedAt == at(20, 9) && session?.resetsAt == at(20, 14), "窗口开始 = 重置时间往前 5 小时")
    // 每周：24 小时前（19 号 13 点）之前最后一次是 30%，现在 46% → 16 个点 / 24 小时
    check(near(weekly?.burnPerHour, 16.0 / 24), "每周的消耗速度看最近 24 小时：\(String(describing: weekly?.burnPerHour))")
    // 5 小时：30 分钟前（12:30）是 35%，现在 37% → 30 分钟涨了 2 个点
    check(near(session?.burnPerHour, 2.0 * 2), "5 小时的消耗速度看最近 30 分钟：\(String(describing: session?.burnPerHour))")
    check(snap.notes.isEmpty, "读数是新的，没有提示")

    let later = try! provider.snapshot(now: at(20, 15))
    check(later.window("five_hour")?.percent == 0 && later.window("five_hour")?.resetsAt == nil && later.window("five_hour")?.official == nil,
          "读数之后已经重置的窗口算 0，等下次使用再开始")
    check(near(later.window("seven_day")?.percent, 46), "每周还没重置")
    check(try! provider.snapshot(now: at(20, 13, 50)).notes.isEmpty, "读数不到 1 小时：没有提示")
    check(later.notes.contains { $0.contains("Dot") }, "读数 2 小时没更新：提醒云端任务（Dot）的用量要等下次本机使用")
    let staleSnap = try! provider.snapshot(now: at(21, 3))
    check(staleSnap.notes.contains { $0.contains("Codex 的读数停在") }, "读数太久没更新时提醒：\(staleSnap.notes)")

    let empty = try! CodexProvider(home: home.appendingPathComponent("none")).snapshot(now: at(20, 13))
    check(!empty.hasData && empty.notes == [CodexProvider.missingNote], "没用过 Codex：没有数据")
    check(CodexProvider.windowID(minutes: 43200) == "codex_43200m" && UsageWindow.title(minutes: 43200) == "30 天额度", "免费版的 30 天窗口")
    check(CodexProvider.burn([], windowStart: at(20, 9), lookback: 1800, now: at(20, 13)) == nil, "没有读数就没有速度")
    check(near(CodexProvider.burn([S(time: at(20, 12, 50), value: 10)], windowStart: at(20, 12, 40), lookback: 1800, now: at(20, 13)), 10.0 * 3),
          "窗口是最近 30 分钟里才开始的：从 0 算起（按 20 分钟算）")
}

do {  // 第一次扫描（刚启动）也要读到「现在 − 24 小时」之前的最后一次读数：算每周消耗速度的起点。
    // 昨天的对话最后一次读数在 25 小时前多一点，按「比最新读数早 25 小时」跳过的话，速度只按今天的几次读数算，偏高好几倍
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-codex-base-\(UUID().uuidString)")
    let sessions = home.appendingPathComponent("sessions/2026/09")
    try! FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    func write(_ name: String, _ lines: [String], modified: Date) {
        let url = sessions.appendingPathComponent(name)
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    write("rollout-yesterday.jsonl", [codexLine(at(19, 7), [(300, 5, at(19, 11)), (10080, 60, at(24, 9))]),
                                      codexLine(at(19, 11, 50), [(300, 9, at(19, 12)), (10080, 62, at(24, 9))])],
          modified: at(19, 11, 50))
    write("rollout-today.jsonl", [codexLine(at(20, 11), [(300, 3, at(20, 15)), (10080, 63, at(24, 9))]),
                                  codexLine(at(20, 12), [(300, 8, at(20, 15)), (10080, 70, at(24, 9))]),
                                  codexLine(at(20, 12, 54), [(300, 12, at(20, 15)), (10080, 75, at(24, 9))])],
          modified: at(20, 12, 54))
    let weekly = try! CodexProvider(home: home).snapshot(now: at(20, 13)).window("seven_day")
    check(near(weekly?.burnPerHour, 13.0 / 24), "刚启动时每周的消耗速度也从 24 小时前的 62% 算起：\(String(describing: weekly?.burnPerHour))")
    try? FileManager.default.removeItem(at: home)
}

// MARK: - 几家一起显示

do {
    func snap(_ provider: ProviderID, _ percent: Double?, windowID: String = "five_hour") -> UsageSnapshot {
        let windows = percent.map { [UsageWindow(id: windowID, title: "", duration: fiveHours, percent: $0)] } ?? []
        return UsageSnapshot(provider: provider, windows: windows, generatedAt: at(20, 12), hasData: percent != nil)
    }
    check(UsageSnapshot.focus(of: [snap(.claude, 86), snap(.codex, 55)])?.provider == .claude, "Claude 更紧张就跟着 Claude")
    check(UsageSnapshot.focus(of: [snap(.claude, 27), snap(.codex, 93)])?.provider == .codex, "Codex 更紧张就跟着 Codex")
    check(UsageSnapshot.focus(of: [snap(.claude, 50), snap(.codex, 50)])?.provider == .claude, "一样紧张时排前面的优先")
    check(UsageSnapshot.focus(of: [snap(.claude, nil), snap(.codex, 40)])?.provider == .codex, "Claude 没数据时跟着 Codex")
    check(UsageSnapshot.focus(of: [snap(.claude, nil), snap(.codex, nil)])?.provider == .claude, "都没数据时是 Claude（由它说明）")
    check(UsageSnapshot.focus(of: []) == nil, "还没有快照")
    check(UsageSnapshot.visible([snap(.claude, nil), snap(.codex, nil)]).map(\.provider) == [.claude], "Codex 没数据就不显示")
    check(UsageSnapshot.visible([snap(.claude, 10), snap(.codex, 20)]).map(\.provider) == [.claude, .codex], "两家都显示")
    check(UsageSnapshot.visible([snap(.claude, 10), snap(.codex, 20)], hidden: [.codex]).map(\.provider) == [.claude], "设置里关掉 Codex 就不显示")
    check(UsageSnapshot.visible([snap(.claude, nil)], hidden: [.claude]).map(\.provider) == [.claude], "Claude 关不掉（没数据时由它说明）")
    check(MenuBarText.make(snap(.codex, 55, windowID: "seven_day"), mode: .session, now: at(20, 12)).text == "55%",
          "只有每周额度时，「5 小时」显示方式退回最紧张的窗口")
}

// MARK: - 什么时候显示

check(MenuBarVisibility.withClaude.shouldShow(appRunning: true, pinned: false), "Claude 开着就显示")
check(!MenuBarVisibility.withClaude.shouldShow(appRunning: false, pinned: false), "Claude 关了就藏起来")
check(MenuBarVisibility.withClaude.shouldShow(appRunning: false, pinned: true), "用户临时叫出来时显示")
check(MenuBarVisibility.always.shouldShow(appRunning: false, pinned: false), "一直显示")
check(MenuBarVisibility.withClaude.shouldShow(appRunning: false, canFollow: false, pinned: false),
      "没装桌面端（只用命令行）时按一直显示算，不然永远看不到宠物")
check(MenuBarVisibility.countsAsInstalled(appPath: "/Applications/Claude.app", home: "/Users/a")
      && MenuBarVisibility.countsAsInstalled(appPath: "/Users/a/Applications/Claude.app", home: "/Users/a"), "装在应用程序文件夹里的算")
check(!MenuBarVisibility.countsAsInstalled(appPath: "/Users/a/.Trash/Claude.app", home: "/Users/a")
      && !MenuBarVisibility.countsAsInstalled(appPath: "/Volumes/Claude/Claude.app", home: "/Users/a")
      && !MenuBarVisibility.countsAsInstalled(appPath: "/Users/a/Downloads/Claude.app", home: "/Users/a")
      && !MenuBarVisibility.countsAsInstalled(appPath: "/private/var/folders/x/T/AppTranslocation/1/d/Claude.app", home: "/Users/a"),
      "废纸篓、安装盘、下载文件夹、临时目录里的副本不算装了，不然删了桌面端的人宠物会一直藏着")
check(MenuBarVisibility.withClaude.note(codex: false, canFollow: false).contains("没装 Claude 桌面端")
      && MenuBarVisibility.withClaude.note(codex: false, canFollow: true).contains("关掉后就藏起来")
      && MenuBarVisibility.always.note(codex: false, canFollow: false) == "一直待在菜单栏里",
      "设置页的说明跟着有没有桌面端变")
check(MenuBarVisibility.withClaude.label == "Claude 打开时" && MenuBarVisibility.withClaude.label(codex: true) == "Claude/Codex 打开时",
      "在用 Codex 时选项里写上 Codex")

// MARK: - 第一次启动

check(FirstLaunch.isFirst(storedKeys: []), "什么设置都没有：第一次启动")
check(FirstLaunch.isFirst(storedKeys: ["NSStatusItem Preferred Position QuotaPet"]),
      "只有 AppKit 自己记的（跑过演示模式留下的图标位置）也算第一次")
check(!FirstLaunch.isFirst(storedKeys: ["NSStatusItem Preferred Position QuotaPet", "notify.claude.five_hour.last"]),
      "老版本升级上来（有提醒记录、没有 launchedBefore）不算第一次")
check(!FirstLaunch.isFirst(storedKeys: [FirstLaunch.launchedKey]), "启动过")
check(FirstLaunch.isInApplicationsFolder("/Applications/QuotaPet.app")
      && FirstLaunch.isInApplicationsFolder("/Users/someone/Applications/QuotaPet.app"), "应用程序文件夹（系统的和自己的）")
check(!FirstLaunch.isInApplicationsFolder("/Users/someone/Downloads/QuotaPet.app")
      && !FirstLaunch.isInApplicationsFolder("/private/var/folders/xy/T/AppTranslocation/1234/d/QuotaPet.app"),
      "下载文件夹、被 macOS 挪到临时目录运行时不开开机自启")
check(FirstLaunch.clearsLoginItemPending(enabling: true, succeeded: true, bundlePath: "/Applications/QuotaPet.app")
      && FirstLaunch.clearsLoginItemPending(enabling: false, succeeded: true, bundlePath: "/Users/someone/Downloads/QuotaPet.app"),
      "在应用程序文件夹里打开成功、用户自己关掉：不再替用户打开开机自启")
check(!FirstLaunch.clearsLoginItemPending(enabling: true, succeeded: false, bundlePath: "/Applications/QuotaPet.app")
      && !FirstLaunch.clearsLoginItemPending(enabling: true, succeeded: true,
                                             bundlePath: "/private/var/folders/xy/T/AppTranslocation/1234/d/QuotaPet.app"),
      "打开失败、在临时目录里打开的（路径之后用不了）：留着，挪进应用程序文件夹后再开")
check(FirstLaunch.launchedEarlier((at(25, 12), 900), than: (at(25, 12, 1), 100)), "几个 QuotaPet 同时在跑：留先启动的（不看 pid，pid 会循环使用）")
check(FirstLaunch.launchedEarlier((at(25, 12), 100), than: (at(25, 12), 900)) && !FirstLaunch.launchedEarlier((at(25, 12), 900), than: (at(25, 12), 100))
      && FirstLaunch.launchedEarlier((at(25, 12), 900), than: (nil, 100)),
      "同时启动的按 pid，两边的结论一致（只走一个）；不知道启动时间的算晚")

// MARK: - 区间记录 & 学习换算率

do {
    func opus(_ t: Date, usd: Double, effort: String = "max") -> ClaudeRequest {
        ClaudeRequest(id: UUID().uuidString, time: t, family: .opus,
                      tokens: TokenCounts(output: Int((usd / 20 * 1e6).rounded())), effort: effort, thinkingTokens: 100)
    }
    func sample(_ t: Date, _ session: Double, _ weekly: Double) -> PlanUsageSample {
        PlanUsageSample(time: t, org: "A", values: ["fh": session, "sd": weekly])
    }
    let samples = [sample(at(25, 10), 10, 20), sample(at(25, 10, 15), 14, 20), sample(at(25, 10, 30), 20, 21),
                   sample(at(25, 10, 45), 3, 21),  // 5 小时窗口重置了
                   sample(at(25, 13), 5, 22)]      // 桌面端关了一阵，间隔太长
    let reqs = [opus(at(25, 10, 5), usd: 1.2), opus(at(25, 10, 20), usd: 1.8), opus(at(25, 10, 40), usd: 3.0, effort: "high")]
    let intervals = UsageInterval.extract(samples: samples, requests: reqs, now: at(25, 14))
    check(intervals.count == 3, "间隔太长的不算：\(intervals.count)")
    check(near(intervals.first?.usd, 1.2) && intervals.first?.sessionDelta == 4 && intervals.first?.usdByGroup["opus/max"] != nil,
          "区间里的花费、官方增量、按模型/思考程度分的花费")
    check(intervals.last?.sessionDelta == nil && intervals.last?.weeklyDelta == 0, "重置过的区间没有 5 小时增量")
    check(UsageInterval.extract(samples: samples, requests: reqs, now: at(25, 10, 19)).isEmpty
          && UsageInterval.extract(samples: samples, requests: reqs, now: at(25, 10, 20)).count == 1,
          "刚结束 5 分钟内的区间先不记：一个响应的几行隔几分钟才写完时，按最后一行的时间算，切早了会在两段里各算一次")
    check(UsageInterval.extract(samples: samples, requests: reqs, since: at(25, 10, 10), now: at(25, 14)).map(\.start)
              == [at(25, 10, 15), at(25, 10, 30)],
          "本机日志还没覆盖到的区间不切，免得把本机花费记成 0")

    // opus：100 万缓存读 $0.2 + 1 万输出 $0.2 = $0.4，缓存读半价 → 额度加权 $0.3
    let cached = ClaudeRequest(id: "c", time: at(25, 10, 5), family: .opus, tokens: TokenCounts(cacheRead: 1_000_000, output: 10_000))
    let withCache = UsageInterval.extract(samples: Array(samples.prefix(2)), requests: [cached], now: at(25, 14)).first
    check(near(withCache?.usd, 0.4) && near(withCache?.cacheReadUSD, 0.2) && near(withCache?.quotaUSD, 0.3), "区间的额度加权花费：\(String(describing: withCache))")
    var legacy = intervals[0]
    legacy.cacheReadUSD = nil
    check(legacy.quotaUSD == nil && RateLearner.learn([legacy], delta: \.sessionDelta, prior: 0.31).intervals == 0,
          "旧版本记下的区间没有缓存读花费，不参与学习")

    let fit = RateLearner.learn(intervals, delta: \.sessionDelta, prior: 0.31, priorUSD: 0.0001)
    check(near(fit.usdPerPercent, 0.30, 1e-3) && fit.intervals == 2, "换算率 = 本机花费 $3 ÷ 官方增量 10%：\(fit)")
    let cold = RateLearner.learn([], delta: \.sessionDelta, prior: 0.31)
    check(cold.usdPerPercent == 0.31 && cold.intervals == 0, "还没有记录时用起始值")
    var older = intervals[0], newer = intervals[1]
    older.end = at(20, 10); older.usd = 2.0; older.sessionFrom = 0; older.sessionTo = 4   // 5 天前：$0.5 / 1%
    newer.end = at(25, 10); newer.usd = 0.8; newer.sessionFrom = 0; newer.sessionTo = 4   // 最近：$0.2 / 1%
    let recency = RateLearner.learn([older, newer], delta: \.sessionDelta, prior: 0.31, priorUSD: 0.0001)
    check(recency.usdPerPercent < 0.21, "越近的记录权重越大：\(recency.usdPerPercent)")
    older.end = at(25, 4)  // 早 6 小时 = 两个半衰期，权重 1/4：(0.5 + 0.8) ÷ (1 + 4)
    let halfLife = RateLearner.learn([older, newer], delta: \.sessionDelta, prior: 0.31, priorUSD: 0.0001)
    check(near(halfLife.usdPerPercent, 0.26, 1e-4), "半衰期 3 小时：\(halfLife.usdPerPercent)")
    var pure = intervals[0], mixed = intervals[1]
    pure.end = at(25, 10); pure.usd = 3; pure.sessionFrom = 0; pure.sessionTo = 10           // $0.3 / 1%
    mixed.end = at(25, 10, 15); mixed.usd = 0.3; mixed.sessionFrom = 10; mixed.sessionTo = 20 // 本机只够 1%，官方涨了 10%
    let skip = RateLearner.learn([pure, mixed], delta: \.sessionDelta, prior: 0.31, priorUSD: 0.0001)
    check(near(skip.usdPerPercent, 0.3, 1e-3) && skip.intervals == 1, "同时在其他端用过的区间不拿来学：\(skip)")
    // 10 段里有 4 段混用（官方 +15，本机只够 +10）：简单平均会被拉到 $0.25、一段都挑不出来；中位数 + 反复挑能找全
    let crowded = (0..<10).map { i -> UsageInterval in
        var interval = intervals[0]
        interval.end = at(25, 10).addingTimeInterval(Double(i) * 900)
        interval.usd = 3
        interval.sessionFrom = 0
        interval.sessionTo = [1, 4, 6, 8].contains(i) ? 15 : 10
        return interval
    }
    let robust = RateLearner.learn(crowded, delta: \.sessionDelta, prior: 0.31, priorUSD: 0.0001)
    check(near(robust.usdPerPercent, 0.3, 1e-3) && robust.intervals == 6, "混用的区间多的时候也挑得出来：\(robust)")
    let flagged = crowded.filter { OtherUsage.isOther(excess: $0.sessionDelta! - $0.usd / robust.usdPerPercent, local: $0.usd / robust.usdPerPercent) }
    check(flagged.count == 4, "学换算率时挑掉的，正好是按学到的换算率会被面板算成其他端的那几段")
    var stale = intervals[0]
    stale.end = at(22, 10); stale.usd = 3; stale.sessionFrom = 0; stale.sessionTo = 10
    check(RateLearner.learn([stale, pure], delta: \.sessionDelta, prior: 0.31).intervals == 1, "两天以前的区间不再算")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-archive-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("intervals.jsonl")
    let archive = IntervalArchive(url: url)
    check(archive.merge(intervals) == 3 && archive.merge(intervals) == 0, "同一段只记一次")
    let reopened = IntervalArchive(url: url)
    check(reopened.intervals == intervals, "重启后记录能原样读回来")
    check(reopened.merge(intervals) == 0, "重启后也不会重复记录")
    var old = intervals[0], other = intervals[1]
    old.cacheReadUSD = nil
    other.cacheReadUSD = nil
    other.usd += 1  // 本机日志已经对不上了
    let legacyURL = dir.appendingPathComponent("legacy.jsonl")
    IntervalArchive(url: legacyURL).merge([old, other])
    let upgraded = IntervalArchive(url: legacyURL)
    check(upgraded.merge(intervals) == 2, "补全旧记录（1 条）+ 新记录（1 条），对不上的旧记录不动")
    let reread = IntervalArchive(url: legacyURL).intervals
    check(reread.count == 3 && reread[0] == intervals[0] && reread[1].cacheReadUSD == nil, "读回来时以补全后的那行为准")

    // 文件写坏了：时间离谱的行（读回来算毫秒时会溢出崩溃）跳过；最后一行写到一半时，新记录另起一行，不跟着作废
    let brokenURL = dir.appendingPathComponent("broken.jsonl")
    let good = String(decoding: try! JSONEncoder().encode(intervals[0]), as: UTF8.self)
    let huge = good.replacingOccurrences(of: #""end":[-0-9.e]+"#, with: #""end":1e300"#, options: .regularExpression)
    try! (huge + "\n" + String(good.prefix(30))).write(to: brokenURL, atomically: true, encoding: .utf8)
    let broken = IntervalArchive(url: brokenURL)
    check(huge != good && broken.intervals.isEmpty && broken.merge([intervals[1]]) == 1, "时间离谱的行、写到一半的行都跳过")
    check(IntervalArchive(url: brokenURL).intervals == [intervals[1]], "写到一半的行后面追加的记录读得回来")

    // 写不进去（比如没权限）：先留在内存里照样用，下次能写了再补上，不当成已经记过
    let lockedURL = dir.appendingPathComponent("locked.jsonl")
    FileManager.default.createFile(atPath: lockedURL.path, contents: nil, attributes: [.posixPermissions: 0o444])
    let locked = IntervalArchive(url: lockedURL)
    check(locked.merge([intervals[0]]) == 0 && locked.intervals == [intervals[0]], "写失败：返回 0，内存里还有")
    try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedURL.path)
    check(locked.merge([]) == 1 && IntervalArchive(url: lockedURL).intervals == [intervals[0]], "能写了再补上")
    try? FileManager.default.removeItem(at: dir)
}

// MARK: - 命令行读数

do {
    let now = at(20, 14, 40)
    func epoch(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }
    func event(_ info: String) -> String { #"{"type":"rate_limit_event","rate_limit_info":\#(info),"session_id":"s"}"# }
    func unified(five: Double, sevenDay: Double, fiveReset: Date, weekReset: Date, status: String = "allowed", type: String = "five_hour") -> String {
        event(#"{"status":"\#(status)","resetsAt":\#(epoch(fiveReset)),"rateLimitType":"\#(type)","unifiedWindows":{"five_hour":{"utilization":\#(five),"resetsAt":\#(epoch(fiveReset))},"seven_day":{"utilization":\#(sevenDay),"resetsAt":\#(epoch(weekReset))}}}"#)
    }
    let fiveReset = at(20, 17), weekReset = at(25, 10)
    let output = ["{\"type\":\"system\",\"subtype\":\"init\"}", "{\"type\":\"assistant\"}",
                  unified(five: 0.09, sevenDay: 0.06, fiveReset: fiveReset, weekReset: weekReset),
                  "{\"type\":\"result\",\"result\":\"ok\"}"].joined(separator: "\n")
    let parsed = ClaudeCLIReadings.parse(output, org: "A", now: now)
    check(near(parsed?.session, 9) && near(parsed?.weekly, 6) && parsed?.org == "A" && parsed?.time == now,
          "命令行输出里的 utilization（0–1）换成百分比：\(String(describing: parsed))")
    check(parsed?.sessionResetsAt == fiveReset && parsed?.weeklyResetsAt == weekReset, "官方给的重置时间")
    check(parsed?.sample?.values["fh"] == 9 && parsed?.sample?.values["sd"] == 6 && parsed?.sample?.org == "A", "转成和桌面端一样的读数")
    check(near(ClaudeCLIReadings.parse(unified(five: 0.07, sevenDay: 0.29, fiveReset: fiveReset, weekReset: weekReset), org: nil, now: now)?.weekly, 29),
          "0.29 × 100 的浮点误差不留在数里")

    // 快到限额时的老格式：只有 rateLimitType + utilization；被拒绝就是用完了
    let legacy = event(#"{"status":"allowed_warning","resetsAt":\#(epoch(fiveReset)),"rateLimitType":"five_hour","utilization":0.82}"#)
    let old = ClaudeCLIReadings.parse(legacy, org: nil, now: now)
    check(near(old?.session, 82) && old?.weekly == nil && old?.sessionResetsAt == fiveReset, "老格式的读数：\(String(describing: old))")
    let rejected = ClaudeCLIReadings.parse(event(#"{"status":"rejected","resetsAt":\#(epoch(fiveReset)),"rateLimitType":"five_hour"}"#),
                                           org: nil, now: now)
    check(near(rejected?.session, 100), "被拒绝：这个窗口用完了")
    let rejectedWeek = ClaudeCLIReadings.parse(unified(five: 0.4, sevenDay: 1, fiveReset: fiveReset, weekReset: weekReset, status: "rejected",
                                                        type: "seven_day"), org: nil, now: now)
    check(near(rejectedWeek?.weekly, 100) && near(rejectedWeek?.session, 40), "被拒绝的是每周额度：只有每周算 100")
    check(near(ClaudeCLIReadings.parse(event(#"{"unifiedWindows":{"five_hour":{"utilization":37,"resetsAt":\#(epoch(fiveReset))}}}"#),
                                       org: nil, now: now)?.session, 37), "大于 1 的当成已经是百分比")

    // 认不出来的退回估算，不抛错
    check(ClaudeCLIReadings.parse("", org: nil, now: now) == nil, "空输出")
    check(ClaudeCLIReadings.parse("Not logged in · Please run /login\n{\"type\":\"result\"}", org: nil, now: now) == nil, "没登录的输出")
    check(ClaudeCLIReadings.parse(event(#"{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":"x"}}}"#), org: nil, now: now) == nil,
          "字段类型变了")
    check(ClaudeCLIReadings.parse(String(unified(five: 0.1, sevenDay: 0.2, fiveReset: fiveReset, weekReset: weekReset).dropLast(20)),
                                  org: nil, now: now) == nil, "写到一半的行")
    let crazy = ClaudeCLIReadings.parse(unified(five: 0.1, sevenDay: 0.2, fiveReset: at(20, 12), weekReset: at(30, 10)), org: nil, now: now)
    check(near(crazy?.session, 10) && crazy?.sessionResetsAt == nil && crazy?.weeklyResetsAt == nil,
          "重置时间不在窗口说得通的范围里（已经过去、比一个窗口还远）：读数照用，时间不用")

    // 合并：命令行读数和桌面端读数按时间排在一起；对不上组织的不用
    func desk(_ t: Date, _ fh: Double, _ sd: Double, org: String = "A") -> PlanUsageSample {
        PlanUsageSample(time: t, org: org, values: ["fh": fh, "sd": sd])
    }
    let desktop = [desk(at(20, 12), 30, 40), desk(at(20, 12, 15), 33, 40)]
    let cli = [CLIReading(time: at(20, 12, 5), org: "A", session: 31, weekly: 40), CLIReading(time: at(20, 14), org: "A", session: 10, weekly: 41),
               CLIReading(time: at(20, 13), org: "B", session: 99, weekly: 99)]
    let merged = ClaudeCLIReadings.merge(desktop: desktop, cli: cli)
    check(merged.map(\.time) == [at(20, 12), at(20, 12, 5), at(20, 12, 15), at(20, 14)] && merged.last?.session == 10,
          "合并后按时间排序，别的账号的读数不用：\(merged.map(\.time))")
    check(ClaudeCLIReadings.merge(desktop: [], cli: cli).map(\.time) == [at(20, 12, 5), at(20, 14)],
          "桌面端没有读数时以命令行最近一次的组织为准")
    check(ClaudeCLIReadings.merge(desktop: desktop, cli: []) == desktop, "没有命令行读数时原样")
    check(ClaudeCLIReadings.usable(cli, desktopOrg: "A").map(\.time) == [at(20, 12, 5), at(20, 14)]
          && ClaudeCLIReadings.usable(cli, desktopOrg: "B").map(\.time) == [at(20, 13)], "能用的读数按桌面端的组织筛")

    // 记录文件：追加、读回、保留期、写坏的行
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-cli-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = CLIReadingArchive(url: dir.appendingPathComponent("sub/cli-readings.jsonl"))
    check(archive.readings(now: now).isEmpty && archive.modificationDate == nil, "没有文件时是空的")
    check(archive.append(CLIReading(time: at(20, 12), org: "A", session: 5, weekly: 40, sessionResetsAt: at(20, 17), weeklyResetsAt: at(25, 10)),
                         now: now), "第一条（目录还不存在）")
    check(archive.append(CLIReading(time: at(20, 13), org: "A", session: 8, weekly: 41), now: now), "追加")
    let back = archive.readings(now: now)
    check(back.count == 2 && back[0].sessionResetsAt == at(20, 17) && back[1].weekly == 41 && back[1].sessionResetsAt == nil,
          "读回来的内容一样：\(back)")
    // 写到一半的行：跳过，下一次追加前补换行
    let handle = try! FileHandle(forWritingTo: archive.url)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data(#"{"time":1"#.utf8))
    try! handle.close()
    check(archive.readings(now: now).count == 2, "写坏的行跳过")
    check(archive.append(CLIReading(time: at(20, 14), org: "A", session: 9, weekly: 41), now: now) && archive.readings(now: now).count == 3,
          "写坏的行后面再追加不受影响")
    // 过了保留期的旧读数：追加时清掉
    check(archive.append(CLIReading(time: at(30, 11), org: "A", session: 10), now: at(30, 12)), "追加（旧的过期了）")
    check(archive.readings(now: at(30, 12)).map(\.time) == [at(30, 11)], "过了 8 天的读数清掉：\(archive.readings(now: at(30, 12)).count)")
    check(try! String(contentsOf: archive.url, encoding: .utf8).split(separator: "\n").count == 1, "文件也重写成只剩没过期的")

    // 找命令行：版本最高的优先，不是可执行文件的不算，没有桌面端自带的时看常见位置
    let root = dir.appendingPathComponent("claude-code")
    func makeBinary(_ version: String, _ hash: String, executable: Bool = true) -> URL {
        let url = root.appendingPathComponent("\(version)/\(hash)/claude.app/Contents/MacOS/claude")
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        return url
    }
    check(ClaudeCLI.locate(desktopRoot: root, home: dir, extraCandidates: []) == nil, "什么都没有")
    let v9 = makeBinary("2.1.9", "aaa"), v30 = makeBinary("2.1.30", "bbb")
    check(ClaudeCLI.locate(desktopRoot: root, home: dir, extraCandidates: []) == v30, "版本按数字比：2.1.30 比 2.1.9 新")
    _ = makeBinary("2.1.100", "ccc", executable: false)
    check(ClaudeCLI.locate(desktopRoot: root, home: dir, extraCandidates: []) == v30, "最新那份不能执行就用上一份")
    try! FileManager.default.removeItem(at: root)
    let fallback = dir.appendingPathComponent("bin/claude")
    try! FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: fallback.path, contents: Data(), attributes: [.posixPermissions: 0o755])
    check(ClaudeCLI.locate(desktopRoot: root, home: dir, extraCandidates: [fallback.path]) == fallback, "桌面端没有自带的，用常见位置的")
    _ = v9

    check(ClaudeCLI.loginCommand(URL(fileURLWithPath: "/a b/it's/claude")) == "'/a b/it'\\''s/claude' auth login", "登录命令的路径加引号")

    // 什么时候探测：窗口在跑、有官方读数没看到的本机用量、读数旧了
    typealias P = ClaudeCLIProbePolicy
    let ends = now.addingTimeInterval(2 * hour)
    func should(official: Date? = at(20, 14), active: Date? = at(20, 14, 30), ends: Date? = ends, last: Date? = nil, failures: Int = 0,
                now: Date = now) -> Bool {
        P.shouldProbe(now: now, sessionEndsAt: ends, officialAt: official, lastActiveAt: active, lastAttempt: last, failures: failures)
    }
    check(should(), "窗口在跑、14:00 之后还在用、读数 40 分钟没来：查")
    check(!should(ends: nil) && !should(ends: now.addingTimeInterval(-60)), "5 小时窗口没在跑：不查（会让窗口提前开始）")
    check(!should(active: nil) && !should(active: at(20, 13, 30)), "官方读数之后没有本机用量：不查")
    check(!should(official: at(20, 14, 30), active: at(20, 14, 35)), "官方读数才 10 分钟：桌面端的下一次快到了，不查")
    check(should(official: nil) , "一次官方读数都没有，但在用：查")
    check(!should(last: now.addingTimeInterval(-10 * 60)) && should(last: now.addingTimeInterval(-16 * 60)), "两次至少隔 15 分钟")
    check(!should(last: now.addingTimeInterval(-20 * 60), failures: 1) && should(last: now.addingTimeInterval(-31 * 60), failures: 1),
          "失败一次后等 30 分钟")
    check(P.retryDelay(failures: 0) == 15 * 60 && P.retryDelay(failures: 10) == 2 * hour, "失败多了也最多等 2 小时")
    check(P.shouldProbeManually(now: now, lastAttempt: nil) && !P.shouldProbeManually(now: now, lastAttempt: now.addingTimeInterval(-10))
          && P.shouldProbeManually(now: now, lastAttempt: now.addingTimeInterval(-40)), "手动刷新只防连点")

    // 接进 ClaudeProvider：命令行的读数当官方读数用，官方给的重置时间当窗口的开始和结束
    /// 返回提供者本身时（provider），可以用同一个再算一次
    func makeProvider(cli readings: [CLIReading], desktop: [PlanUsageSample], now: Date,
                      config: ClaudeProvider.Config = .init()) -> ClaudeProvider {
        let d = dir.appendingPathComponent("p-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let rows = desktop.map { #"{"t":\#(Int($0.time.timeIntervalSince1970 * 1000)),"org":"\#($0.org ?? "")","u":{"fh":\#($0.session ?? 0),"sd":\#($0.weekly ?? 0)}}"# }
        try! #"{"version":2,"samples":[\#(rows.joined(separator: ","))]}"#.write(to: d.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
        let store = CLIReadingArchive(url: d.appendingPathComponent("cli-readings.jsonl"))
        for r in readings { store.append(r, now: now) }
        let provider = ClaudeProvider(historyURL: d.appendingPathComponent("history.json"), projectsURL: d.appendingPathComponent("projects"),
                                      archiveURL: d.appendingPathComponent("intervals.jsonl"))
        provider.config = config
        return provider
    }
    func snapshot(cli readings: [CLIReading], desktop: [PlanUsageSample], now: Date, config: ClaudeProvider.Config = .init()) -> UsageSnapshot {
        try! makeProvider(cli: readings, desktop: desktop, now: now, config: config).snapshot(now: now)
    }
    let base = [desk(at(20, 12), 30, 40)]
    let withCLI = snapshot(cli: [CLIReading(time: at(20, 14, 30), org: "A", session: 12, weekly: 41, sessionResetsAt: at(20, 17), weeklyResetsAt: at(25, 10))],
                           desktop: base, now: at(20, 14, 40))
    check(near(withCLI.window("five_hour")?.official, 12) && withCLI.officialAt == at(20, 14, 30), "命令行的读数比桌面端新就用它")
    check(withCLI.window("five_hour")?.startedAt == at(20, 12) && withCLI.window("five_hour")?.resetsAt == at(20, 17),
          "5 小时窗口按官方给的重置时间：\(String(describing: withCLI.window("five_hour")))")
    check(withCLI.window("seven_day")?.resetsAt == at(25, 10) && withCLI.window("seven_day")?.scheduleKnown == true
          && near(withCLI.window("seven_day")?.official, 41), "每周窗口按官方给的重置时间")
    let nextWeek = snapshot(cli: [CLIReading(time: at(20, 14, 30), org: "A", session: 12, weekly: 41, weeklyResetsAt: at(25, 10))],
                            desktop: base, now: at(27, 9))
    check(nextWeek.window("seven_day")?.resetsAt == at(25, 10) + week && nextWeek.window("seven_day")?.startedAt == at(25, 10),
          "每周额度固定时间重置：过去的重置时间也按 7 天往后推")
    let overFive = snapshot(cli: [CLIReading(time: at(20, 14, 30), org: "A", session: 12, sessionResetsAt: at(20, 17))],
                            desktop: base, now: at(20, 18))
    check(overFive.window("five_hour")?.startedAt == nil && overFive.window("five_hour")?.resetsAt == nil,
          "5 小时窗口的重置时间已经过了：窗口没在跑，等下次使用才开始（不是往后接着一个 5 小时）")
    let otherAccount = snapshot(cli: [CLIReading(time: at(20, 14, 30), org: "B", session: 90, weekly: 90, sessionResetsAt: at(20, 18),
                                                 weeklyResetsAt: at(23, 10))], desktop: base, now: at(20, 14, 40))
    check(near(otherAccount.window("five_hour")?.official, 30) && otherAccount.officialAt == at(20, 12)
          && otherAccount.window("seven_day")?.resetsAt != at(23, 10), "命令行登的是另一个账号：读数和重置时间都不用")
    let cliOnly = snapshot(cli: [CLIReading(time: at(20, 14, 30), org: "A", session: 12, weekly: 41)], desktop: [], now: at(20, 14, 40))
    check(near(cliOnly.window("five_hour")?.official, 12) && cliOnly.hasData && cliOnly.notes.isEmpty,
          "没有桌面端的记录、只有命令行的读数：照常用，不提示缺桌面端：\(cliOnly.notes)")

    // 优先级：限流消息 > 官方给的重置时间 > 手动指定的；关掉开关就当没有命令行的读数；过了保留期的读数不用
    let reading = CLIReading(time: at(20, 14, 30), org: "A", session: 12, weekly: 41, sessionResetsAt: at(20, 17), weeklyResetsAt: at(25, 10))
    var manualConfig = ClaudeProvider.Config()
    manualConfig.weeklyResetAnchor = at(22, 8)
    let manual = snapshot(cli: [reading], desktop: base, now: at(20, 14, 40), config: manualConfig)
    check(manual.window("seven_day")?.resetsAt == at(25, 10), "官方给的重置时间比手动指定的优先：\(String(describing: manual.window("seven_day")?.resetsAt))")
    let noCLI = ClaudeProvider(historyURL: URL(fileURLWithPath: "/nonexistent/h.json"), projectsURL: URL(fileURLWithPath: "/nonexistent/p"),
                               archiveURL: nil)
    let limitHit = ClaudeLimitEvent(time: at(20, 14, 45), window: "five_hour", resetsAt: at(20, 18))
    let both = noCLI.buildWindow(id: "five_hour", title: "", duration: fiveHours, series: [S(time: at(20, 14, 30), value: 85)], requests: [],
                                 scale: 1, percentOf: { _ in 0 }, resetAnchor: nil, officialReset: at(20, 19), limits: [limitHit],
                                 live: true, now: at(20, 14, 50))
    check(both.resetsAt == at(20, 18), "限流中：限流消息给的恢复时间比命令行读数里的优先：\(String(describing: both.resetsAt))")
    var off = ClaudeProvider.Config()
    off.useCLIReadings = false
    let disabled = snapshot(cli: [reading], desktop: base, now: at(20, 14, 40), config: off)
    check(near(disabled.window("five_hour")?.official, 30) && disabled.officialAt == at(20, 12)
          && disabled.window("seven_day")?.scheduleKnown == false && disabled.window("seven_day")?.resetsAt != at(25, 10),
          "关掉开关：命令行的读数和重置时间都不用：\(String(describing: disabled.window("five_hour")?.official))")
    let aging = makeProvider(cli: [reading], desktop: base, now: at(20, 14, 40))
    check(try! aging.snapshot(now: at(20, 14, 40)).officialAt == at(20, 14, 30), "读数还在保留期内")
    check(try! aging.snapshot(now: at(30, 12)).officialAt != at(20, 14, 30), "文件没变、读数过了 8 天：不再用（缓存也要过期）")

    // 命令行没给组织：桌面端的组织已知时核对不了是不是同一个账号，不用；桌面端的组织也不知道时都用
    let anonymous = CLIReading(time: at(20, 14), org: nil, session: 90, weekly: 90)
    check(ClaudeCLIReadings.merge(desktop: desktop, cli: [anonymous]) == desktop
          && ClaudeCLIReadings.usable([anonymous], desktopOrg: "A").isEmpty, "桌面端的组织已知、读数没有组织：不用")
    check(ClaudeCLIReadings.usable([anonymous], desktopOrg: nil).count == 1
          && ClaudeCLIReadings.merge(desktop: [], cli: [anonymous]).count == 1, "桌面端的组织不知道：没法核对，用")

    // 价格表改过之后：新切出来的区间带着价格版本；旧价格算的换掉；换不掉的、花费里有 Haiku 的不拿来学
    let fresh = UsageInterval.extract(samples: [desk(at(20, 10), 10, 20), desk(at(20, 10, 15), 14, 20)],
                                      requests: [ClaudeRequest(id: "r", time: at(20, 10, 5), family: .haiku, tokens: TokenCounts(output: 100_000))],
                                      now: at(20, 14)).first
    check(fresh?.priceBasis == ClaudePricing.basis && fresh?.isCurrentPriceBasis == true && fresh?.hasHaikuSpend == true,
          "新区间带着价格版本：\(String(describing: fresh?.priceBasis))")
    var legacyHaiku = fresh!
    legacyHaiku.priceBasis = nil
    legacyHaiku.usd *= 10
    let priceArchive = IntervalArchive(url: dir.appendingPathComponent("price/intervals.jsonl"))
    priceArchive.merge([legacyHaiku])
    check(priceArchive.intervals.first.map { !$0.isCurrentPriceBasis } == true, "旧版本记下的区间没有价格版本，算旧价格")
    priceArchive.merge([fresh!])
    check(priceArchive.intervals.count == 1 && priceArchive.intervals.first?.priceBasis == ClaudePricing.basis
          && near(priceArchive.intervals.first?.usd, fresh!.usd), "本机日志还在：旧价格算的区间换成新价格重算的")
    // 日志已经不在了换不掉：花费里有 Haiku 的区间不学，别的照学
    let lines = [legacyHaiku, { () -> UsageInterval in var o = legacyHaiku; o.usdByGroup = ["opus/max": o.usd]; o.end = o.end.addingTimeInterval(900); o.start = o.start.addingTimeInterval(900); return o }()]
    let learnDir = dir.appendingPathComponent("learn")
    try! FileManager.default.createDirectory(at: learnDir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .millisecondsSince1970
    try! lines.map { String(decoding: try! enc.encode($0), as: UTF8.self) }.joined(separator: "\n")
        .write(to: learnDir.appendingPathComponent("intervals.jsonl"), atomically: true, encoding: .utf8)
    let learned = try! ClaudeProvider(historyURL: URL(fileURLWithPath: "/nonexistent/h.json"), projectsURL: URL(fileURLWithPath: "/nonexistent/p"),
                                      archiveURL: learnDir.appendingPathComponent("intervals.jsonl")).snapshot(now: at(20, 14))
    check(learned.estimation?.recordedIntervals == 2 && learned.estimation?.learnedIntervals == 1,
          "旧价格记下的 Haiku 区间不拿来学：\(String(describing: learned.estimation))")
}

// MARK: - 菜单栏文字 & 预测

do {
    let session = UsageWindow(id: "five_hour", title: "", duration: fiveHours, percent: 27.4)
    let weekly = UsageWindow(id: "seven_day", title: "", duration: week, percent: 81)
    let snap = UsageSnapshot(provider: .claude, windows: [session, weekly], generatedAt: at(25, 12))
    check(MenuBarText.make(snap, mode: .session, now: at(25, 12)).text == "27%", "只显示 5 小时")
    check(MenuBarText.make(snap, mode: .sessionAndWeekly, now: at(25, 12)).text == "27% · 81%", "5 小时 + 每周")
    check(MenuBarText.make(snap, mode: .tightest, now: at(25, 12)).text == "81%", "最紧张的窗口")
    check(MenuBarText.make(snap, mode: .petOnly, now: at(25, 12)).text == "", "只显示宠物")
    var limited = snap
    limited.windows[0].percent = 100
    limited.windows[0].resetsAt = at(25, 13, 23)
    check(MenuBarText.make(limited, mode: .session, now: at(25, 12)).text == "1h23m", "限流时显示恢复倒计时")
    check(PetStatus.of(limited, now: at(25, 12)).mood == .sleeping, "限流时宠物睡觉")

    let fast = UsageWindow(id: "x", title: "", duration: fiveHours, percent: 60, resetsAt: at(25, 16), burnPerHour: 20)
    check(fast.projectedExhaustion(now: at(25, 12)) == at(25, 14), "60% + 20%/小时 → 2 小时后用完")
    let slow = UsageWindow(id: "x", title: "", duration: fiveHours, percent: 60, resetsAt: at(25, 13), burnPerHour: 20)
    check(slow.projectedExhaustion(now: at(25, 12)) == nil, "重置前用不完就不预警")
}

// MARK: - 配速 & 用量提醒

do {
    // 每周额度正好过了一半，用了 62%。开始和重置时间从 now 往前后推，不用 at()：那一周本地时间可能跨夏令时（比如新西兰）
    let now = at(24, 12), day = 86400.0
    let weekly = UsageWindow(id: "seven_day", title: "", duration: week, percent: 62,
                             startedAt: now - 3.5 * day, resetsAt: now + 3.5 * day)
    let pace = weekly.pace(now: now)
    check(near(pace?.expected, 50) && near(pace?.ahead, 12), "过了一半时间用了 62%：比平均节奏多用 12 个点")
    check(near(pace?.perDay, 38 / 3.5), "剩下的 38% 平摊到 3.5 天")
    let late = weekly.pace(now: now + 3 * day)
    check(late != nil && late?.perDay == nil, "离重置不到一天：只比节奏，不算每天能用多少")
    check(weekly.pace(now: now - 4 * day) == nil && weekly.pace(now: now + 4 * day) == nil, "窗口外不算节奏")
    var full = weekly, unknown = weekly, guessed = weekly
    full.percent = 100
    unknown.resetsAt = nil
    guessed.scheduleKnown = false
    check(full.pace(now: now) == nil && unknown.pace(now: now) == nil, "用完了、不知道重置时间都不算节奏")
    check(guessed.pace(now: now) == nil, "重置时间是按第一次使用猜的：不算节奏（会偏晚，每天能用多少会算多）")
    let session = UsageWindow(id: "five_hour", title: "", duration: fiveHours, percent: 40, startedAt: at(24, 10), resetsAt: at(24, 15))
    check(session.pace(now: at(24, 12)) == nil, "5 小时窗口不看节奏")
    check(session.warningLead == 1800 && weekly.warningLead == 86400, "预警提前量：5 小时窗口半小时，每周额度一天")

    // 消耗速度的门槛按单位算：5 小时窗口每小时 1%，每周额度每天 1%
    var steady = weekly
    steady.percent = 85
    steady.burnPerHour = 0.75  // 每天 18%：剩下的 15% 20 小时用完，比重置早两天多
    check(steady.projectedExhaustion(now: now) == now + 20 * hour, "每周额度每小时不到 1% 也会预测用完")
    let crawl = UsageWindow(id: "five_hour", title: "", duration: fiveHours, percent: 99.5, resetsAt: at(24, 15), burnPerHour: 0.75)
    check(crawl.projectedExhaustion(now: at(24, 12)) == nil, "5 小时窗口每小时不到 1% 不预测")
    let open = UsageWindow(id: "seven_day", title: "", duration: week, percent: 30, burnPerHour: 1.0 / 24)
    check(open.projectedExhaustion(now: now) == nil, "不知道重置时间时，一个窗口长度以外的不预测")
    check(weekly.burnUnit == 86400 && session.burnUnit == 3600 && near(weekly.perUnit(0.75), 18), "速度的单位")
}

do {
    let options = UsageAlerts.Options(usage: true, thresholds: [75, 90, 100], runningOut: true, reset: true)
    /// 5 小时窗口，15 点重置
    func session(_ percent: Double, burn: Double?) -> UsageWindow {
        UsageWindow(id: "five_hour", title: UsageWindow.sessionTitle, duration: fiveHours, percent: percent,
                    startedAt: at(25, 10), resetsAt: at(25, 15), burnPerHour: burn)
    }
    // 12:00 跨过 75%，每小时 20% → 13:00 用完：阈值提醒里顺带说，还没到半小时内，不算预警过
    var r = UsageAlerts.evaluate(session(80, burn: 20), state: .init(last: 70), options: options, now: at(25, 12))
    check(r.alerts == [.threshold(75, runsOutAt: at(25, 13))] && !r.state.warned, "跨过 75%：\(r.alerts)")
    // 12:30 到 85%，每小时 60% → 12:45 用完，半小时内：预警
    r = UsageAlerts.evaluate(session(85, burn: 60), state: r.state, options: options, now: at(25, 12, 30))
    check(r.alerts == [.runningOut(at(25, 12, 45))] && r.state.warned, "快用完了：\(r.alerts)")
    r = UsageAlerts.evaluate(session(88, burn: 48), state: r.state, options: options, now: at(25, 12, 35))
    check(r.alerts.isEmpty, "同一个周期只预警一次：\(r.alerts)")
    r = UsageAlerts.evaluate(session(92, burn: 32), state: r.state, options: options, now: at(25, 12, 40))
    check(r.alerts == [.threshold(90, runsOutAt: at(25, 12, 55))], "预警过也照常提醒阈值：\(r.alerts)")
    r = UsageAlerts.evaluate(session(0, burn: nil), state: r.state, options: options, now: at(25, 15, 5))
    check(r.alerts == [.reset] && r.state.notified.isEmpty && !r.state.warned && r.state.last == 0,
          "重置了：说一声，记录清空：\(r.alerts) \(r.state)")

    // App 没开着时跨过了重置，重新打开时新窗口（18:00–23:00）已经用了 20%：看重置时间往后跳了，记录照样清空
    let stale = UsageAlerts.State(last: 92, notified: [75, 90], warned: true, cycleEnd: at(25, 15))
    func next(_ percent: Double) -> UsageWindow {
        UsageWindow(id: "five_hour", title: "", duration: fiveHours, percent: percent, startedAt: at(25, 18), resetsAt: at(25, 23))
    }
    r = UsageAlerts.evaluate(next(20), state: stale, options: options, now: at(25, 19))
    check(r.alerts.isEmpty && r.state.notified.isEmpty && !r.state.warned && r.state.cycleEnd == at(25, 23),
          "重置时间跳到下一个周期：清空记录，不补发恢复提醒：\(r.alerts) \(r.state)")
    r = UsageAlerts.evaluate(next(80), state: r.state, options: options, now: at(25, 20))
    check(r.alerts == [.threshold(75, runsOutAt: nil)], "新周期里 75% 照常提醒：\(r.alerts)")
    var nudged = stale
    nudged.cycleEnd = at(25, 22, 40)  // 推算的重置时间挪了 20 分钟，还是同一个周期
    r = UsageAlerts.evaluate(next(92), state: nudged, options: options, now: at(25, 20))
    check(r.alerts.isEmpty && r.state.notified == [75, 90], "重置时间只挪了一点：不算新周期：\(r.alerts)")

    // 一下子跨过 90%、又半小时内会用完：只发一条阈值提醒，里面说几点用完
    r = UsageAlerts.evaluate(session(90, burn: 40), state: .init(last: 70), options: options, now: at(25, 12))
    check(r.alerts == [.threshold(90, runsOutAt: at(25, 12, 15))] && r.state.warned && r.state.notified == [75, 90],
          "跨阈值和快用完同时发生：\(r.alerts)")
    var off = options
    off.runningOut = false
    r = UsageAlerts.evaluate(session(85, burn: 60), state: .init(last: 80, notified: [75]), options: off, now: at(25, 12, 30))
    check(r.alerts.isEmpty && !r.state.warned, "关掉预警：不提醒，也不记成提醒过（之后打开还能提醒）")
    var silent = options
    silent.usage = false
    r = UsageAlerts.evaluate(session(85, burn: 60), state: .init(last: 80), options: silent, now: at(25, 12, 30))
    check(r.alerts.isEmpty, "关掉用量提醒：快用完也不提醒")
    r = UsageAlerts.evaluate(session(85, burn: 5), state: .init(last: 80, notified: [75]), options: options, now: at(25, 12, 30))
    check(r.alerts.isEmpty, "来得及重置就不预警")

    // 每周额度提前一天预警：70%，每小时 1.5% → 20 小时后用完
    let now = at(24, 12)
    var weekly = UsageWindow(id: "seven_day", title: UsageWindow.weeklyTitle, duration: week, percent: 70,
                             startedAt: now - 3.5 * 86400, resetsAt: now + 3.5 * 86400, burnPerHour: 1.5)
    r = UsageAlerts.evaluate(weekly, state: .init(last: 69), options: options, now: now)
    check(r.alerts == [.runningOut(now + 20 * hour)], "每周额度一天内会用完：\(r.alerts)")
    weekly.burnPerHour = 1
    check(UsageAlerts.evaluate(weekly, state: .init(last: 69), options: options, now: now).alerts.isEmpty,
          "还要一天多才用完，先不提醒")

    // 用量已经 95% 了才在设置里打开 50% 的阈值、提醒关着时跨过了 75%：记上，不补发「已用 50%」这种旧消息
    var more = options
    more.thresholds = [50, 75, 90, 100]
    r = UsageAlerts.evaluate(session(95, burn: nil), state: .init(last: 95, notified: [75, 90]), options: more, now: at(25, 12))
    check(r.alerts.isEmpty && r.state.notified == [50, 75, 90], "新打开的阈值早就跨过了：不补发：\(r.alerts)")
    r = UsageAlerts.evaluate(session(96, burn: nil), state: r.state, options: more, now: at(25, 12, 5))
    check(r.alerts.isEmpty, "之后也不再补发")
    r = UsageAlerts.evaluate(session(80, burn: nil), state: .init(last: 80), options: options, now: at(25, 12))
    check(r.alerts.isEmpty && r.state.notified == [75], "提醒关着时跨过的阈值，打开后不补发：\(r.alerts)")
    r = UsageAlerts.evaluate(next(80), state: .init(last: 92, notified: [75, 90], cycleEnd: at(25, 15)), options: options, now: at(25, 19))
    check(r.alerts == [.threshold(75, runsOutAt: nil)], "App 没开着时进了新周期、已经用到 80%：新周期的 75% 照常提醒：\(r.alerts)")

    let w = session(85, burn: 60)
    check(UsageAlerts.title(.runningOut(at(25, 12, 45)), window: w, provider: .claude) == "Claude 5 小时会话快用完了", "预警标题")
    check(UsageAlerts.body(.runningOut(at(25, 12, 45)), window: w, now: at(25, 12, 30))
          == "照最近的速度，12:45 左右用完（约 15 分钟后），比重置早 2 小时 15 分。", "预警内容")
    var noReset = w
    noReset.resetsAt = nil
    check(UsageAlerts.body(.runningOut(at(25, 12, 45)), window: noReset, now: at(25, 12, 30))
          == "照最近的速度，12:45 左右用完（约 15 分钟后）。", "不知道重置时间就不说比重置早多少")
    check(UsageAlerts.body(.threshold(75, runsOutAt: at(25, 13)), window: w, now: at(25, 12))
          == "约 3 小时后重置（15:00）。照最近的速度 13:00 左右就会用完。" + PetMood.tired.line, "阈值提醒顺带说几点用完")
}

// MARK: - 宠物说的话 & 心情的趋势

/// 下面试过的每一种输入，「多语言」一节拿它们再查一遍英文
nonisolated(unsafe) var talkInputs: [(snapshot: UsageSnapshot?, failed: Bool, memory: PetMemory, now: Date, lateNight: Bool)] = []

/// 一个 5 小时窗口（两小时前开始、三小时后重置），可以再加一个正好过了一半的每周窗口。quiet：多久没用了，nil = 不知道
func talkSnapshot(_ session: Double, burn: Double? = nil, weekly: Double? = nil, weeklyBurn: Double? = nil, other: Double = 0,
                  otherBurn: Double? = nil, quiet: TimeInterval? = 0, now: Date) -> UsageSnapshot {
    var windows = [UsageWindow(id: "five_hour", title: "", duration: fiveHours, percent: session, startedAt: now - 2 * hour,
                               resetsAt: now + 3 * hour, otherPercent: other, burnPerHour: burn, otherBurnPerHour: otherBurn)]
    if let weekly {
        windows.append(UsageWindow(id: "seven_day", title: "", duration: week, percent: weekly, startedAt: now - week / 2,
                                   resetsAt: now + week / 2, burnPerHour: weeklyBurn, burnLookback: 86400))
    }
    return UsageSnapshot(provider: .claude, windows: windows, generatedAt: now,
                         lastActiveAt: quiet.map { now - $0 })
}

/// 记得「5 小时窗口在这个时候恢复过」
func recalling(_ recoveredAt: Date?) -> PetMemory {
    PetMemory(recovery: recoveredAt.map { .init(at: $0, window: "five_hour") })
}

/// 心情和台词一次算出来（和面板一样）。recovered：5 小时窗口什么时候恢复的
func talk(_ snapshot: UsageSnapshot?, now: Date, recovered: Date? = nil, lateNight: Bool = true, failed: Bool = false) -> PetStatus {
    talkInputs.append((snapshot, failed, recalling(recovered), now, lateNight))
    return PetStatus.of(snapshot, failed: failed, memory: recalling(recovered), now: now, lateNight: lateNight)
}

do {
    let now = at(25, 12)  // 5 小时窗口 10:00 开始、15:00 重置
    var t = talk(nil, now: now)
    check(t.situation == .loading && t.lines == ["正在看额度…"], "还没算出来：\(t)")
    t = talk(nil, now: now, failed: true)
    check(t.situation == .confused && t.lines.count == 2 && t.lines[0] == PetMood.confused.line, "读不到数据：\(t)")

    // 用完了
    t = talk(talkSnapshot(100, now: now), now: now)
    check(t.situation == .usedUp && t.lines == ["额度用完啦，15:00 见 zzz", "先睡一会儿，3 小时后叫我…"], "5 小时额度用完：\(t)")
    t = talk(talkSnapshot(100, weekly: 100, now: now), now: now)
    check(t.situation == .usedUp && t.lines[0].hasPrefix("这周的用完了，") && t.lines[1].hasPrefix("先睡一会儿，3 天"),
          "两个都用完：等最晚恢复的每周额度：\(t)")
    var noReset = talkSnapshot(100, now: now)
    noReset.windows[0].resetsAt = nil
    t = talk(noReset, now: now)
    check(t.situation == .usedUp && t.lines == [PetMood.sleeping.line], "不知道几点恢复：不说时间：\(t)")

    // 刚恢复
    let fresh = talkSnapshot(3, now: now)
    t = talk(fresh, now: now, recovered: now - 300)
    check(t.situation == .recovered && t.lines[0] == "满血复活！", "看到恢复 5 分钟：\(t)")
    check(talk(fresh, now: now, recovered: now - 660).situation == .ordinary, "恢复超过 10 分钟：照常说")
    check(talk(talkSnapshot(25, now: now), now: now, recovered: now - 300).situation == .ordinary,
          "恢复后已经又用了不少：照常说")
    check(talk(talkSnapshot(3, weekly: 92, now: now), now: now, recovered: now - 300).situation == .almostOut,
          "5 小时的恢复了，每周的还在九成：不说满血复活")
    let high = talkSnapshot(86, now: now)
    func recovery(_ old: UsageSnapshot?, _ new: UsageSnapshot) -> PetMemory.Recovery? { PetMemory().updated(from: old, to: new, now: now).recovery }
    check(recovery(high, fresh) == .init(at: now, window: "five_hour") && recovery(talkSnapshot(40, now: now), fresh) == nil
          && recovery(nil, fresh) == nil && recovery(high, talkSnapshot(20, now: now)) == nil,
          "从六成以上掉到 5% 以下才算恢复，记下是哪个窗口")
    // 恢复的是 5 小时窗口：它又用回去了就不算刚恢复，哪怕每周的还很低
    check(talk(talkSnapshot(40, weekly: 8, now: now), now: now, recovered: now - 300).situation != .recovered
          && talk(talkSnapshot(3, weekly: 8, now: now), now: now, recovered: now - 300).situation == .recovered,
          "刚恢复看的是恢复的那个窗口，不是随便哪个用得少的")

    // 眼看要用完：85%，每小时 60% → 12:15
    t = talk(talkSnapshot(85, burn: 60, now: now), now: now)
    check(t.situation == .runningOut && t.lines.count == 3 && t.lines[0] == "照这样 12:15 就见底了，慢一点！"
          && t.lines[1] == "只够再撑 15 分钟了…", "半小时内用完：\(t)")
    check(talk(talkSnapshot(92, burn: 32, now: now), now: now).situation == .runningOut, "九成以上又眼看要用完：先说几点用完")
    check(talk(talkSnapshot(30, weekly: 70, weeklyBurn: 1.5, now: now), now: now).situation == .runningOut, "每周额度一天内会用完")

    // 快撑不住
    let almost = talkSnapshot(93, now: now)
    t = talk(almost, now: now)
    check(t.situation == .almostOut && t.lines == ["只剩 7% 了，挑要紧的做！", "马上就要见底了！！"], "93%：\(t)")
    t = talk(almost, now: at(25, 14, 30))
    check(t.lines.count == 3 && t.lines[2] == "再撑 30 分钟就恢复了！", "九成多、半小时后重置：\(t)")
    check(talk(talkSnapshot(99.8, now: now), now: now).lines[0] == "只剩 1% 了，挑要紧的做！", "不说只剩 0%")

    // 烧得快：40%，每小时 42% → 13:25 用完，撑不到 15:00
    t = talk(talkSnapshot(40, burn: 42, now: now), now: now)
    check(t.situation == .burningFast && t.lines == ["今天好拼啊，照这样一小时要烧 42%…", "这个速度撑不到 15:00 重置哦", "慢点慢点，我快跟不上了"],
          "烧得快：\(t)")
    t = talk(talkSnapshot(20, weekly: 55, weeklyBurn: 1, now: now), now: now)
    check(t.situation == .ordinary && t.lines[1] == "过半啦，还剩 45%", "每周额度照这个速度撑不到重置：不算烧得快：\(t)")

    // 有点累
    t = talk(high, now: now)
    check(t.situation == .tired && t.lines == [PetMood.tired.line, "用了八成多，还剩 14%"], "86%：\(t)")
    check(talk(talkSnapshot(78, now: now), now: now).lines[1] == "用了七成多，还剩 22%", "78%")
    t = talk(high, now: at(25, 14, 25))
    check(t.lines.count == 3 && t.lines[2] == "还有 35 分钟就重置，放心用吧", "八成多、一小时内重置：\(t)")
    check(talk(talkSnapshot(76, burn: 20, now: now), now: now).situation == .tired, "已经在冒汗了就不另外说烧得快")

    // 每周节奏：过了一半时间
    t = talk(talkSnapshot(20, weekly: 65, now: now), now: now)
    check(t.situation == .pace && t.lines.count == 2 && t.lines[0] == "这周用得有点猛，比平均多 15 个点"
          && t.lines[1].hasPrefix("之后每天约 10% 才够用到"), "比平均节奏多用 15 个点：\(t)")
    t = talk(talkSnapshot(20, weekly: 38, now: now), now: now)
    check(t.situation == .pace && t.lines[0] == "这周省了 12 个点，可以放开用～", "比平均节奏少用 12 个点：\(t)")
    check(talk(talkSnapshot(20, weekly: 57, now: now), now: now).situation == .ordinary, "差不到 10 个点不说")
    var guessed = talkSnapshot(20, weekly: 65, now: now)
    guessed.windows[1].scheduleKnown = false
    check(talk(guessed, now: now).situation == .ordinary, "每周重置时间是猜的：不说节奏")

    // 别处也在用、闲着、深夜
    t = talk(talkSnapshot(30, burn: 10, other: 14, otherBurn: 8, now: now), now: now)
    check(t.situation == .elsewhere && t.lines[0] == "你在别处也在聊天吧？那边用了 14%", "聊天、网页正在用：\(t)")
    check(talk(talkSnapshot(30, other: 14, otherBurn: 0, now: now), now: now).situation == .ordinary, "别处之前用过、现在没在用：不说")
    check(talk(talkSnapshot(30, quiet: 2400, now: now), now: now).situation == .idle, "40 分钟没用：闲着")
    let codexWeek = UsageWindow(id: "seven_day", title: "", duration: week, percent: 55, startedAt: now - week / 2, resetsAt: now + week / 2)
    let codex = UsageSnapshot(provider: .codex, windows: [codexWeek], generatedAt: now, lastActiveAt: now - 2 * hour)
    check(talk(codex, now: now).situation == .idle, "只有每周额度的（比如 Codex）也看多久没用")
    let night = at(25, 2)
    check(talk(talkSnapshot(30, quiet: 120, now: night), now: night).situation == .lateNight, "凌晨两点还在用")
    check(talk(talkSnapshot(30, quiet: 120, now: night), now: night, lateNight: false).situation == .ordinary,
          "今晚说过了就不再说")
    check(talk(talkSnapshot(30, quiet: 900, now: night), now: night).situation == .ordinary, "凌晨两点，一刻钟没用了：不说")
    check(talk(talkSnapshot(30, quiet: 120, now: now), now: now).situation == .ordinary, "白天不说")
    check(talk(talkSnapshot(30, quiet: nil, now: night), now: night).situation == .ordinary, "不知道多久没用：不算闲着，也不算深夜在忙")

    // 平常
    t = talk(talkSnapshot(27, now: now), now: now)
    check(t.situation == .ordinary && t.lines == ["额度多着呢，放心用！", "才用了 27%，随便造～", "状态满分！"], "27%：\(t)")
    check(talk(talkSnapshot(0, now: now), now: now).lines == ["额度多着呢，放心用！", "状态满分！"], "不说才用了 0%")
    check(talk(talkSnapshot(63, now: now), now: now).lines == ["用掉一半了，稳着点～", "过半啦，还剩 37%", "节奏不错，继续～"], "63%")

    // 面板每打开一次换一句
    let calm = talkSnapshot(27, now: now)
    let said = (0...3).map { PetStatus.of(calm, now: now).line($0) }
    check(said == ["额度多着呢，放心用！", "才用了 27%，随便造～", "状态满分！", "额度多着呢，放心用！"], "轮着说：\(said)")
    func status(_ input: (snapshot: UsageSnapshot?, failed: Bool, memory: PetMemory, now: Date, lateNight: Bool)) -> PetStatus {
        PetStatus.of(input.snapshot, failed: input.failed, memory: input.memory, now: input.now, lateNight: input.lateNight)
    }
    check(Set(talkInputs.map { status($0).situation }) == Set(PetTalk.Situation.allCases), "每种情况都试到了")

    // 心情 = 档位 + 趋势
    func mood(_ snapshot: UsageSnapshot, recoveredAt: Date? = nil) -> PetMood {
        PetStatus.of(snapshot, memory: recalling(recoveredAt), now: now).mood
    }
    check(mood(talkSnapshot(40, burn: 42, now: now)) == .nervous, "才 40%，但照这个速度撑不到重置：先慌")
    check(mood(talkSnapshot(76, burn: 20, now: now)) == .tired, "已经用到七成半：是累，不是慌")
    check(mood(talkSnapshot(60, burn: 85, now: now)) == .exhausted, "才 60%，但半小时内就用完：先哭")
    check(mood(talkSnapshot(30, weekly: 70, weeklyBurn: 1.5, now: now)) == .exhausted, "每周额度一天内会用完：哭")
    check(mood(talkSnapshot(20, weekly: 55, weeklyBurn: 1, now: now)) == .normal, "每周额度只是撑不到重置：不算烧得快，心情照档位")
    check(mood(talkSnapshot(40, burn: 10, now: now)) == .energetic, "来得及重置：心情照档位")
    check(mood(talkSnapshot(99, burn: 300, now: now)) == .exhausted && mood(talkSnapshot(100, quiet: 2400, now: now), recoveredAt: now) == .sleeping,
          "只有档位能说睡着了：烧得再快、没到 100% 也不睡，到了 100% 别的都不看")
    check(mood(talkSnapshot(30, quiet: 2400, now: now)) == .resting && mood(talkSnapshot(60, quiet: 2400, now: now)) == .resting,
          "40 分钟没用：歇着")
    check(mood(talkSnapshot(30, quiet: 1500, now: now)) == .energetic && mood(talkSnapshot(30, quiet: nil, now: now)) == .energetic,
          "才 25 分钟没用、不知道多久没用：不算歇着")
    check(mood(talkSnapshot(80, quiet: 2400, now: now)) == .tired, "额度紧张时闲着也不歇")
    check(mood(talkSnapshot(30, burn: 10, other: 14, otherBurn: 8, quiet: 2400, now: now)) == .energetic, "本机没用，但聊天、网页在用：不算歇着")
    check(mood(talkSnapshot(20, weekly: 65, quiet: 2400, now: now)) == .resting, "台词在说每周节奏，表情照样歇着")
    check(mood(fresh, recoveredAt: now - 300) == .revived && mood(fresh, recoveredAt: now - 660) == .energetic
          && mood(talkSnapshot(25, now: now), recoveredAt: now - 300) == .energetic, "刚恢复开心一阵：10 分钟以内、还没怎么用")
    check(mood(talkSnapshot(3, weekly: 55, now: now), recoveredAt: now - 300) == .revived, "5 小时的恢复了，每周的用了一半多：照样开心")
    check(mood(talkSnapshot(3, weekly: 92, now: now), recoveredAt: now - 300) == .exhausted, "5 小时的恢复了，每周的还在九成：不开心")
    // 表情和台词对得上
    let pairs: [PetTalk.Situation: PetMood] = [.usedUp: .sleeping, .recovered: .revived, .runningOut: .exhausted, .almostOut: .exhausted,
                                               .burningFast: .nervous, .tired: .tired, .idle: .resting]
    for input in talkInputs {
        let status = status(input)
        if let expected = pairs[status.situation] {
            check(status.mood == expected, "说的是 \(status.situation)，心情应该是 \(expected)，实际是 \(status.mood)")
        }
    }

    // 警报在门槛上一会儿有一会儿没有时，心情不来回跳：没再看到之后还留 3 分钟
    do {
        let fast = talkSnapshot(40, burn: 42, now: now), calm = talkSnapshot(40, burn: 10, now: now)
        func look(_ snapshot: UsageSnapshot, _ memory: PetMemory, after seconds: TimeInterval) -> PetStatus {
            PetStatus.of(snapshot, memory: memory, now: now + seconds)
        }
        var memory = PetMemory().updated(from: nil, to: fast, now: now)
        check(look(fast, memory, after: 0).mood == .nervous, "烧得快：有点慌")
        memory = memory.updated(from: fast, to: calm, now: now + 30)  // 半分钟后速度掉下来了
        let held = look(calm, memory, after: 30)
        check(held.mood == .nervous && held.situation == .burningFast && held.lines[0] == "今天好拼啊，照这样一小时要烧 42%…",
              "刚才还烧得快：先留着，表情和台词都不变：\(held)")
        check(look(calm, memory, after: 170).mood == .nervous && look(calm, memory, after: 190).mood == .energetic,
              "3 分钟都没再看到才放下")
        memory = memory.updated(from: calm, to: fast, now: now + 60)  // 又看到了：重新计时
        memory = memory.updated(from: fast, to: calm, now: now + 90)
        check(look(calm, memory, after: 230).mood == .nervous && look(calm, memory, after: 250).mood == .energetic, "又看到一次就从那时起再留 3 分钟")
        let kept = memory.updated(from: calm, to: calm, now: now + 300)
        check(look(calm, kept, after: 300).mood == .energetic && kept == PetMemory(), "过期的警报更新时清掉")
        // 窗口重置了（用量掉回去）：警报马上作废，不留
        let reset = PetMemory().updated(from: nil, to: fast, now: now).updated(from: fast, to: talkSnapshot(2, now: now), now: now + 30)
        check(look(talkSnapshot(2, now: now), reset, after: 30).mood == .energetic, "窗口重置后不再留着刚才的警报")
        // 快用完了也一样留着；当时预计的用完时间过了就不留
        let soon = talkSnapshot(85, burn: 60, now: now), slow = talkSnapshot(86, burn: 5, now: now)  // 预计 12:15 用完
        memory = PetMemory().updated(from: nil, to: soon, now: now).updated(from: soon, to: slow, now: now + 60)
        check(look(slow, memory, after: 60).mood == .exhausted && look(slow, memory, after: 60).situation == .runningOut
              && look(slow, memory, after: 200).mood == .tired, "快用完了的警报也留 3 分钟")
        let past = PetMemory().updated(from: nil, to: talkSnapshot(98, burn: 60, now: now), now: now)  // 预计 2 分钟后用完
        check(look(talkSnapshot(98, burn: 0.5, now: now), past, after: 100).situation == .runningOut
              && look(talkSnapshot(98, burn: 0.5, now: now), past, after: 150).situation == .almostOut, "预计的用完时间已经过了：不再说那个时间")
    }

    // 和她聊天的状态：每打开一次换一句，深夜那句一晚只说一次，连着戳会闹别扭
    do {
        var chat = PetChat(pick: 3)
        chat.opened(now: now)
        check(chat.pick == 4 && chat.lateNight, "打开一次换一句；没说过深夜那句时可以说")
        let first = at(25, 0, 30)
        chat.opened(now: first)
        chat.said(.lateNight, now: first)
        chat.opened(now: first + 600)
        check(!chat.lateNight, "十分钟后再打开：今晚说过了")
        chat.said(.ordinary, now: first + 600)
        // 第二晚 00:45 打开：可以说，说了就要重新记时间（哪怕两次打开之间情况一直是「深夜」），01:00 再打开不能再说
        chat.opened(now: first + 86400 + 900)
        check(chat.lateNight, "第二晚可以再说")
        chat.said(.lateNight, now: first + 86400 + 900)
        chat.opened(now: first + 86400 + 1800)
        check(!chat.lateNight, "第二晚也只说一次")

        var poking = PetChat()
        let replies = (0..<6).map { poking.poke(mood: .normal, now: now + Double($0)) }  // 一秒戳一下
        check(replies.map { $0?.annoyed } == [false, false, false, false, true, true] && replies[4]?.line == "哼，不理你了"
              && poking.pick == 6, "一秒一下连着戳：第 5 下开始生气，每戳一下换下一句：\(replies)")
        let later = poking.poke(mood: .normal, now: now + 20)
        check(later?.annoyed == false && later?.line == "有什么要我盯着的吗？", "隔了一阵再戳：不算连着，接着轮下一句：\(String(describing: later))")
        var idle = PetChat()
        check(idle.poke(mood: .loading, now: now) == nil && idle == PetChat(), "还没算出来时戳了没反应，什么都不记")
        check((0..<8).allSatisfy { _ in poking.poke(mood: .tired, now: now + 21)?.annoyed == false }, "累的时候连戳也不生气")
    }
    // 没开动画时停在第一帧：歇着是闭眼的，刚恢复是笑眯眼
    func face(_ frame: PetFrame?) -> String? { frame?.portrait.face }
    let faces = [PetMood.resting, .revived, .nervous, .loading].map { face(PetSprites.frames(for: $0, style: .classic)[0]) }
    check(faces == ["closed-small", "happy-open", "nervous", "drowsy"], "歇着、刚恢复、有点慌、刚醒的第一帧：\(faces)")

    // 戳一下：每种心情都有反应（还没算出来时除外），第一帧和平时不一样，说的话轮着来
    for style in PetStyle.allCases {
        for mood in PetMood.allCases where mood != .loading {
            let reaction = PetSprites.reaction(for: mood, style: style), annoyed = PetSprites.reaction(for: mood, style: style, annoyed: true)
            check(!reaction.isEmpty && reaction.first?.portrait != PetSprites.frames(for: mood, style: style)[0].portrait,
                  "\(style.label) \(mood) 被戳的反应，第一帧要和平时的第一帧不一样")
            check(!annoyed.isEmpty && annoyed.first?.portrait != PetSprites.frames(for: mood, style: style)[0].portrait,
                  "\(style.label) \(mood) 戳烦了的反应，第一帧也要和平时的第一帧不一样")
        }
        check(PetSprites.reaction(for: .loading, style: style).isEmpty, "\(style.label)还没算出来时戳了没反应")
    }
    check(PetTalk.poked(mood: .loading, count: 1) == nil, "还没算出来时戳了不说话")
    let pokes = (1...5).map { PetTalk.poked(mood: .normal, count: $0)?.line }
    check(pokes[0] == "在呢在呢！" && Set(pokes.prefix(4)).count == 4 && pokes[4] == pokes[0], "隔一会儿戳一下，轮着说：\(pokes)")
    check(PetTalk.poked(mood: .sleeping, count: 1)?.line == "唔…再睡一会儿…" && PetTalk.poked(mood: .tired, count: 1)?.line == "别戳啦，我在冒汗…",
          "被戳时说的话跟着心情")
    // 连着戳（上一句还没说完又戳）：心情好的时候第 5 下开始闹别扭，表情换成生气的；累了、睡着了不会
    let fourth = PetTalk.poked(mood: .normal, count: 4, streak: 4), fifth = PetTalk.poked(mood: .normal, count: 5, streak: 5)
    check(fourth?.annoyed == false && fifth?.annoyed == true && fifth?.line == "哼，不理你了", "连戳到第 5 下生气：\(String(describing: fifth))")
    check(PetTalk.poked(mood: .normal, count: 6, streak: 6)?.line == "戳够了没有！", "接着戳，生气的话也轮着说")
    check(PetTalk.poked(mood: .tired, count: 9, streak: 9)?.annoyed == false && PetTalk.poked(mood: .sleeping, count: 9, streak: 9)?.annoyed == false,
          "累了、睡着了连戳也不生气")
    check(face(PetSprites.reaction(for: .normal, style: .classic, annoyed: true).first) == "pout"
          && face(PetSprites.reaction(for: .normal, style: .classic).first) == "surprised"
          && face(PetSprites.reaction(for: .sleeping, style: .classic, annoyed: true).first) == "drowsy", "被戳：惊讶；戳烦了：生气；睡着时：迷糊")

    // 演示模式一轮下来（第二轮起，开头是刚恢复），有数据时的心情都看得到
    let demo = DemoProvider(), began = Date()
    let seen = Set((0..<75).map { second -> PetMood in
        let t = began + Double(second)
        return PetStatus.of(try! demo.snapshot(now: t), memory: recalling(began), now: t).mood
    })
    check(seen == Set(PetMood.allCases).subtracting([.confused, .loading]), "演示模式看得到的心情：\(seen.map(\.rawValue).sorted())")
}

// MARK: - 多语言

check(Language.preferred(["zh-Hans-CN", "en-US"]) == .zhHans, "系统首选简体中文")
check(Language.preferred(["zh-CN"]) == .zhHans, "zh-CN 算简体中文")
check(Language.preferred(["en-AU", "zh-Hans-CN"]) == .en, "系统首选英文")
check(Language.preferred(["ja-JP", "zh-Hans-CN"]) == .zhHans, "不支持的语言跳过，看下一个")
check(Language.preferred(["zh-Hant-TW"]) == .en && Language.preferred(["fr-FR"]) == .en, "都不支持时用英文")

do {
    L10n.language = .en
    defer { L10n.language = .zhHans }
    check(Fmt.duration(2 * hour + 14 * 60) == "2 hr 14 min", "英文 duration")
    check(Fmt.duration(86400 + 60) == "1 day" && Fmt.duration(3 * 86400 + 4 * hour) == "3 days 4 hr", "英文 duration 分单复数")
    check(Fmt.fromNow(2 * hour) == "in about 2 hr" && Fmt.fromNow(30) == "in under a minute", "英文 fromNow")
    check(Fmt.clock(at(26, 9), now: at(25, 12)) == "tomorrow 09:00", "英文 clock 明天")
    check(Fmt.clock(at(30, 17, 45), now: at(25, 12)) == "Wed 17:45", "英文 clock 一周内")
    check(Fmt.clock(at(10, 8), now: at(25, 12)) == "Sep 10 08:00", "英文 clock 日期")
    check(Fmt.ago(at(25, 11, 45), now: at(25, 12)) == "15 min ago" && Fmt.ago(at(24, 11), now: at(25, 12)) == "1 day ago", "英文 ago")
    check(plural(1_500, "token", shown: Fmt.tokens(1_500)) == "1.5K tokens" && plural(1, "token", shown: Fmt.tokens(1)) == "1 token",
          "数字换了写法也分单复数（面板「今天」那行的 tokens）")

    // 快照里的窗口名、说明文字在后台算，也要跟着语言走
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quotapet-l10n-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let history = #"{"version":2,"samples":[{"t":\#(Int(at(20, 12).timeIntervalSince1970 * 1000)),"org":"A","u":{"fh":30,"sd":40}}]}"#
    try! history.write(to: dir.appendingPathComponent("history.json"), atomically: true, encoding: .utf8)
    func snapshot(history: String) -> UsageSnapshot {
        try! ClaudeProvider(historyURL: dir.appendingPathComponent(history), projectsURL: dir.appendingPathComponent("projects"),
                            archiveURL: nil).snapshot(now: at(20, 15))
    }
    let stale = snapshot(history: "history.json"), missing = snapshot(history: "none.json")
    let codexHome = dir.appendingPathComponent("codex/sessions")
    try! FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    try! (codexLine(at(19, 12), [(300, 20, at(19, 14)), (10080, 40, at(24, 9))]) + "\n").write(
        to: codexHome.appendingPathComponent("rollout.jsonl"), atomically: true, encoding: .utf8)
    let codex = try! CodexProvider(home: dir.appendingPathComponent("codex")).snapshot(now: at(20, 15))
    check(codex.window("seven_day")?.title == "Weekly quota" && codex.notes.contains { $0.contains("1 day ago") }, "Codex 的英文：\(codex.notes)")
    check(stale.window("five_hour")?.title == "5-hour session", "英文窗口名")
    check(stale.notes.isEmpty, "官方读数停了不另外提示（卡片上写着是多久前的读数）：\(stale.notes)")
    check(missing.notes == [ClaudeProvider.missingHistoryNote], "没有桌面端记录的提示是英文")

    // 英文界面里不能混进中文：漏翻了，或者 tr 的两个参数写反了
    func hasChinese(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
    }
    let demo = try! DemoProvider().snapshot(now: Date())
    var english: [String] = PetMood.allCases.flatMap { [$0.title, $0.line] }
    english += PetStyle.allCases.map(\.label) + MenuBarTextMode.allCases.map(\.label) + MenuBarVisibility.allCases.map(\.label)
    english += MenuBarVisibility.allCases.map { $0.label(codex: true) }
    english += MenuBarVisibility.allCases.flatMap { v in [true, false].flatMap { c in [v.note(codex: c, canFollow: true), v.note(codex: c, canFollow: false)] } }
    // 分开写：连在一起时 Swift 6.1（CI 用的）类型推断会超时
    english += (stale.windows + demo.windows + codex.windows).map(\.title)
    english += stale.notes + missing.notes
    english += demo.notes + codex.notes
    english += [CodexProvider.missingNote, CodexProvider.staleNote(readAt: Date(timeIntervalSinceNow: -5 * 3600), now: Date()), UsageWindow.title(minutes: 43200), UsageWindow.title(minutes: 120)]
    english += [ClaudeCLIProbeStatus.idle, .querying, .ok(at: at(20, 12)), .failed(at: at(20, 12)), .notFound, .notLoggedIn, .wrongAccount]
        .map { $0.text(now: at(20, 13)) }
    english += [ClaudeDesktopHistory.ParseError.unexpectedFormat.localizedDescription,
                Fmt.clock(at(24, 9), now: at(25, 12)), Fmt.duration(30)]
    let alertWindow = UsageWindow(id: "five_hour", title: UsageWindow.sessionTitle, duration: fiveHours, percent: 85,
                                  startedAt: at(25, 10), resetsAt: at(25, 15), burnPerHour: 60)
    let alerts: [UsageAlerts.Alert] = [.reset, .threshold(75, runsOutAt: at(25, 13)), .threshold(100, runsOutAt: nil),
                                       .runningOut(at(25, 12, 45))]
    english += alerts.flatMap { [UsageAlerts.title($0, window: alertWindow, provider: .claude),
                                 UsageAlerts.body($0, window: alertWindow, now: at(25, 12, 30))] }
    check(UsageAlerts.body(.runningOut(at(25, 12, 45)), window: alertWindow, now: at(25, 12, 30))
          == "At the recent pace it runs out around 12:45 (in about 15 min), 2 hr 15 min before the reset.", "英文预警")
    english += talkInputs.flatMap { PetStatus.of($0.snapshot, failed: $0.failed, memory: $0.memory, now: $0.now, lateNight: $0.lateNight).lines }
    english += PetMood.allCases.flatMap { mood in (1...8).compactMap { PetTalk.poked(mood: mood, count: $0, streak: $0)?.line } }
    english += PetMood.allCases.flatMap { mood in (1...4).compactMap { PetTalk.poked(mood: mood, count: $0)?.line } }
    check(PetStatus.of(talkSnapshot(85, burn: 60, now: at(25, 12)), now: at(25, 12)).line(0)
          == "At this rate we're out by 12:15. Slow down!", "英文台词")
    check(PetStatus.of(talkSnapshot(40, burn: 42, now: at(25, 12)), now: at(25, 12)).line(0) == "Going hard today: 42% an hour at this rate…",
          "英文的烧得快")
    check(!english.contains(where: hasChinese), "英文界面里有中文：\(english.filter(hasChinese))")

    // App 本体（面板、设置页、通知、菜单）的文字上面调不到：直接扫源码，每个 tr("中文", "English") 的英文参数里都不能有中文
    /// 从 i（开头的引号）读一个字符串字面量，返回结束位置和去掉插值后的文字
    func literal(_ s: [Unicode.Scalar], _ i: Int) -> (end: Int, text: String)? {
        guard i < s.count, s[i] == "\"" else { return nil }
        var j = i + 1, text = ""
        while j < s.count {
            if s[j] == "\\", j + 1 < s.count, s[j + 1] == "(" {  // 插值：跳过配对的括号，里面可能还有字符串
                var depth = 0
                j += 1
                repeat {
                    if s[j] == "\"", let inner = literal(s, j) { j = inner.end; continue }
                    if s[j] == "(" { depth += 1 } else if s[j] == ")" { depth -= 1 }
                    j += 1
                } while depth > 0 && j < s.count
            } else if s[j] == "\\" {
                j += 2
            } else if s[j] == "\"" {
                return (j + 1, text)
            } else {
                text.unicodeScalars.append(s[j])
                j += 1
            }
        }
        return nil
    }
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var pairs = 0
    var untranslated: [String] = []
    for case let file as URL in FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
    where file.pathExtension == "swift" {
        let s = Array(try! String(contentsOf: file, encoding: .utf8).unicodeScalars)
        for i in s.indices where i + 2 < s.count && s[i] == "t" && s[i + 1] == "r" && s[i + 2] == "(" {
            if i > 0, s[i - 1].properties.isAlphabetic || s[i - 1] == "_" || s[i - 1] == "." { continue }
            var j = i + 3
            while j < s.count, s[j].properties.isWhitespace { j += 1 }
            guard let zh = literal(s, j) else { continue }
            j = zh.end
            while j < s.count, s[j].properties.isWhitespace || s[j] == "," { j += 1 }
            guard let en = literal(s, j) else { continue }  // 英文参数不是字面量（比如 plural(...)）就不查
            pairs += 1
            if hasChinese(en.text) { untranslated.append("\(file.lastPathComponent)：\(en.text)") }
        }
    }
    check(pairs >= 100, "源码里只扫到 \(pairs) 个 tr()，扫描可能坏了")
    check(untranslated.isEmpty, "tr() 的英文参数里有中文：\(untranslated)")
}

print(failed == 0 ? "✓ 全部 \(passed) 项自检通过" : "✗ \(failed) 项失败，\(passed) 项通过")
exit(failed == 0 ? 0 : 1)
