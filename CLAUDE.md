# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 环境

- 本机只有 Command Line Tools，**没有 Xcode**：不要用 `xcodebuild`、iOS 模拟器，也没有 XCTest / swift-testing。
- Swift 命令都在 `QuotaPet/` 目录下跑。工具链是 Swift 6，但 `Package.swift` 里的语言模式是 v5。

## 常用命令（在 `QuotaPet/` 下）

```bash
make check      # = swift run QuotaPetChecks，唯一的测试
swift build     # 只编译
make previews   # 把宠物、菜单栏、面板渲染成 PNG 到 build/previews（面板、设置页中英各一套；每款形象另有 popover-<形象>）；改界面后用它验证，不用启动 App
make dump       # 在终端打印当前额度推算（读真实数据）
make run / make demo / make install
make release    # Apple 芯片 + Intel 通用版 zip（build/QuotaPet-<版本>.zip），版本号取 Resources/Info.plist
```

- 自检是 `Sources/QuotaPetChecks/main.swift` 里的一串顶层 `check(...)`，按 `// MARK:` 分组，**不能单独跑某一项**，失败时会打印行号。它用了 `@testable import`，只能 debug 构建，不要加 `-c release`。
- GitHub Actions（`.github/workflows/ci.yml`）每次 push 和 PR 都在 macOS 上跑 `swift build`、`make check`、渲染预览图（在 Actions 页面的 `previews` 附件里），另外按 `.githooks/pre-commit` 的规则查一遍隐私。云端会话没有 Swift：改了 Swift 代码推上去，用 `gh run list` 看结果。云端打不开 Actions 的日志，编译错误和自检失败都写成了注解：`gh api repos/{owner}/{repo}/check-runs/<job id>/annotations`（job id 用 `gh run view <run id> --json jobs` 查）。
- 仓库根目录下的 `usage_lab.py` 是做 App 之前的实验工具，只用标准库：`python3 usage_lab.py summary|snap|ratio|calibrate|backtest`。

## 架构

数据流：`UsageProvider`（`QuotaPetCore/Models.swift`）→ `UsageStore`（FSEvents 触发，另外每分钟兜底刷新，几家数据源在同一个后台串行队列上依次算快照）→ 菜单栏、面板、`NotificationManager`。宠物、菜单栏、通知只认 `UsageSnapshot`，不关心是哪家 AI；接入新的 AI 就实现一个 `UsageProvider`（例子见 `QuotaPet/README.md`）。

- 现在有 Claude（`ClaudeProvider`）和 Codex（`CodexProvider`）两家。`UsageSnapshot.visible` 决定显示哪几家：Claude 一直在，别的有数据、用户又没在设置里关掉（`AppSettings.hiddenProviders`）才出现，所以没用过 Codex 时界面和只有 Claude 时一样。关掉的那家不显示、不发提醒（提醒的记录照常更新，重新打开时不会补发一堆）。
  - 设置页按「通用 / Claude / Codex」分页（`SettingsView.Page`），本机有 Codex 的记录时才有 Codex 页（和「显示」开关无关，不然关掉后就打不开了）。`UsageSnapshot.focus` 是宠物和菜单栏跟着的那家（最紧张的，一样时 Claude 优先）。
  - 面板不止一家时顶部有切换条（`ProviderTabs`），每次打开先选 focus 那家；看的是 focus 时面板和菜单栏共用一个 `PetAnimator`，切到另一家时换成 `headerAnimator`。面板每次重画都把算出来的心情交给它用的那个 animator（`PetLook.onMenuBar`），表情和标签、台词才对得上。
  - 菜单栏不止一家时，数字前面加一个 SF Symbol 小图标（`MenuBarIcon`：星号是 Claude，终端是 Codex），和宠物画在同一张图里。
  - `@Published` 在赋值前就通知，`StatusItemController` 的订阅里要用传进来的新值，不能去读 `store` 的属性。
- 提醒的判断和措辞在 `QuotaPetCore/UsageAlerts.swift`（能进自检），`NotificationManager` 只发通知、把每个窗口的记录（`last`、`notified`、`warned`、`cycleEnd`）存进 UserDefaults。每个窗口每个周期，每个阈值和「快用完」各只提醒一次；用量掉到 5% 以下，或者重置时间往后跳了半个窗口以上，算新周期。只提醒这次刚跨过的阈值：上次就已经在它上面、没提醒过的（刚在设置里打开的、提醒关着时跨过的）记上不补发。改设置（实时估算、自动学习、每周重置时间）引起的变化不是真的用量变化：`UsageStore` 把那次结果标成 `settingsChanged`，只更新提醒记录、不发提醒，也不记成「刚恢复」。发不出去的提醒（还没问过权限、系统没收下）不记成提醒过；`NotificationManager` 是通知中心的代理，App 在前台（面板开着）时也弹。「快用完」= `projectedExhaustion` 落在 `warningLead` 以内（5 小时窗口半小时，一天以上的窗口一天），归在「用量提醒」总开关下面；和阈值提醒同时发生时并成一条。
- 宠物现在的样子用 `PetStatus.of(snapshot, failed:, memory:, now:)` 一次算出来（`QuotaPetCore/Pet/PetTalk.swift`，能进自检）：心情、说话的由头、这种情况下轮着说的几句。菜单栏（`StatusItemController`）和面板（`PopoverRoot`）都用它，不要各算各的，表情、标签和台词才对得上。通知里的话还是 `PetMood.line`。
  - 心情 = 档位 + 趋势（规则在 `PetTrend.mood`）：快用完了先哭、5 小时额度烧得快先慌（`nervous`，已经用到七成半就还是累）、刚恢复开心一阵（`revived`）、不紧张又半小时没用就歇着（`resting`）。`PetMood.from(percent:)` 只看档位。
  - **不变量**：只有档位能让她睡着（100% 只能来自官方读数或限流消息），趋势再急也只到「快撑不住」。
  - 台词按实际情况挑（`PetTalk.Situation`，从上到下就是优先级：用完了、刚恢复、眼看要用完、烧得快、每周节奏、别处在用、闲着、深夜…），同一种情况有几句。
  - 记忆（`PetMemory`，每家一份，`UsageStore.memory` 在拿到新快照时更新，只在内存里）：恢复的是哪个窗口、什么时候（标准和「额度恢复」提醒一样；之后 10 分钟内、那个窗口还没用到 20% 才算刚恢复）；最近一次看到的「快用完」「烧得快」警报，没再看到之后还留 3 分钟（`hold`），不然消耗速度在门槛附近时心情会来回跳。
  - 心情和时间有关，所以除了新快照，`UsageStore.tick`（每分钟）也会让菜单栏和面板重算；读取一直出错时也不会卡住。
  - 聊天的状态在 `PetChat`（Core，`PopoverState.chat` 拿着）：每打开一次面板换一句、「这么晚还在忙」一晚只说一次、连着戳的计数。
  - 点面板里的宠物（`OverviewView` 的 `onPoke`）：`PetChat.poke` 给出她回的话（`PetTalk.poked`，显示 3 秒，然后是这种情况的下一句），`PetAnimator.react(mood:annoyed:)` 把 `PetSprites.reaction` 播一遍再回到原来的动画（没开动画也播）；反应按面板上显示的心情播。看的是 focus 那家时菜单栏上的宠物是同一个 `PetAnimator`，会跟着一起动。3 秒内又戳算连戳，心情好的时候（`PetMood.pouts`）连戳到第 5 下开始闹别扭：表情换成 `pout`，说生气的话。反应的第一帧要和这个心情平时的第一帧不一样（自检会查）。
  - 加心情：`PetMood` 加 case，播哪几个表情（`PetSprites.frames`）、被戳的反应（`reaction`）、标题、颜色（`Level.mood`）都要补；没开动画时停在第一帧，第一帧要能代表这个心情。
  - 加台词或加情况：中英都要写；自检「宠物说的话」一节每种情况都要试到（有一条检查会数），试过的输入会在「多语言」一节再查一遍英文。
- 消耗速度按 `UsageWindow.burnUnit` 说：一天以上的窗口按天（每天 20%），5 小时窗口按小时；`projectedExhaustion` 的门槛也是每个单位 1%。
- `UsageWindow.pace`：一天以上的窗口（每周额度等）和平均节奏比，画成面板进度条上的刻度和下面那行「比平均节奏多用 N 个点 · 之后每天可用约 X%」。5 小时窗口从第一次使用才开始计时，不看节奏；Claude 每周额度还没看到过重置时（`scheduleKnown` 为 false，重置时间是按第一次使用猜的）也不看。

- `QuotaPetCore` 是纯逻辑，不能依赖 AppKit，这样自检才跑得起来。界面代码都在 `QuotaPet` target 里。
- `ClaudeProvider.snapshot` 的算法：当前 % = 最近一次官方读数（桌面端每 15 分钟写一次 `plan-usage-history.json`）+ 读数之后本机日志里请求的额度加权花费（API 价格，但缓存读按半价）÷ 换算率。
  - 换算率由 `RateLearner` 从 `IntervalArchive` 学出来（`~/Library/Application Support/QuotaPet/intervals.jsonl`，只追加，半衰期 3 小时），起始值 $0.27 / 1%。
  - 窗口的开始和重置时间由 `WindowInference` 推算：5 小时窗口从第一次使用开始；每周额度按固定时间重置（`fixedCadence`），看到过一次重置（读数掉了至少 3 个点，或限流消息）后就按它每 7 天循环，多次跳变取交集收窄时间、取最晚的时刻。用户手动指定了每周重置时间时，按它往后每 7 天算一次。还没看到过重置时，按第一次使用推出来的窗口开始时间存在 `weekly-origin.json`（和 `intervals.jsonl` 在一起），下次从它接着推（`origin`）：日志只留 8 天，不然起点每天往后挪。
  - 官方读数要属于当前窗口才用：在最近一次重置之后，也不比一个窗口还旧。隔了一个窗口以上还不是 0 的读数（比如 5 小时额度隔夜 50 → 30）算新窗口里的使用，不当成上一个窗口的。
  - 命令行读数（可选，默认关闭）：`CLIProbe`（App 里）让官方命令行发一个最小请求，`ClaudeCLIReadings.parse` 从 stream-json 输出的 `rate_limit_event` 里取 `unifiedWindows` 的 `utilization`（0–1 小数）和 `resetsAt`（秒），存进 `cli-readings.jsonl`（`CLIReadingArchive`，留 8 天，和 `intervals.jsonl` 在一起）。`ClaudeProvider` 把它们和桌面端读数合并（`ClaudeCLIReadings.merge`：组织以桌面端最近一次为准，对不上的不用），所以换算率学习、其他端用量、窗口推算都不用管读数从哪来。官方给的 `resetsAt` 比手动指定的和推算的优先（`buildWindow` 的 `officialReset`；限流中仍以限流消息为准）：每周窗口按它每 7 天往后推，5 小时窗口只有还没到的才算当前窗口的结束，已经过了的当成一次精确重置（进 `knownResets`），不往后接着排一个 5 小时。
  - 什么时候查在 `ClaudeCLIProbePolicy`（Core，进自检）：5 小时窗口已经在跑、官方读数之后有本机用量、官方读数超过 17 分钟没来，才自动查；失败按倍数退避、最多 2 小时。**不在用的时候不查**：窗口从第一次请求才开始计时，空闲时查会让它提前开始。手动刷新、刚打开开关会立刻查一次。只认 `authMethod == claude.ai` 的订阅登录，进程环境里的 API Key 和第三方云开关会去掉。
  - Claude Code 被限流时会在日志里写一条 synthetic 消息，带 `quotaLimits`（`rateLimitType`、秒级 `resetsAt`）。扫描器把它记成 `ClaudeLimitEvent`：没到恢复时间前这个窗口直接算用完，重置时间以它为准。
  - 其他端（网页、手机、桌面端聊天）用量由 `OtherUsage` 算：相邻两次官方读数之间，官方增量比本机估算多出门槛以上的部分。`RateLearner` 学换算率时也用同一个门槛，跳过这种混用的区间。
  - **不变量**：官方读数没到 100 时，估算值最多 99%。只有官方读数或限流消息能宣布「用完了」，免得宠物误睡、误发提醒。
- `CodexProvider`：Codex（命令行和桌面端）每轮对话结束时把服务器给的额度写进 `~/.codex/sessions/**/*.jsonl`（归档的在 `archived_sessions/`）的 `token_count` 事件（`payload.rate_limits`：`primary` / `secondary` 各有 `used_percent`、`window_minutes`、秒级 `resets_at`；老版本是 `resets_in_seconds`）。
  - 读数就是官方百分比，不用估算；只看总额度（`limit_id` 是 `codex` 或没有），个别模型单独的额度桶不显示。300 分钟和 10080 分钟的窗口用和 Claude 一样的 id（`five_hour`、`seven_day`），菜单栏的「5 小时」「5h + 周」对两家都管用；某家没有这种窗口时退回最紧张的窗口。
  - 最近一次读数之后已经过了重置时间的窗口算 0%、没有重置时间（等下次使用）。消耗速度用同一个窗口里的历次读数算，回看时长和 Claude 一样（5 小时窗口 30 分钟，其他 24 小时）。
  - 日志可能有几百 MB：`CodexLogScanner` 第一次从最近改过的文件往前读，读到一次比「现在 − 25 小时」还早的读数（算每周消耗速度的起点）为止，更早的文件只从末尾往后跟。两家的扫描器都用 `LineCursor` 增量读：分块读、每块包在 `autoreleasepool` 里，不然第一次扫描时内存会涨几百 MB。
  - `UsageStore` 按数据源分开刷新：文件变了只重算那一家（`providersAffected`），每分钟兜底全部重算，也顺便给启动后才出现的目录补上监听。
  - 只解析带 `rate_limits` 的行，只取时间和额度字段；`~/.codex` 下别的文件（`auth.json` 登录凭据、数据库）都不碰。
- **和 `usage_lab.py` 要保持一致的地方**，改一边就要改另一边（只涉及 Claude；Codex 不用估算，usage_lab 里没有它）：
  - `ClaudePricing.currentPrice` 对应 `PRICES`（各族当前这一代），`olderPrices` 对应 `OLDER_PRICES`（同一族里价格不一样的老版本），按提示词长短分档（`ModelPrice.longPromptAbove` / `longPromptMultiplier`，现在只有 Haiku 5.5：输入 + 缓存写 + 缓存读超过 10 万 token 的整个请求 5 倍）对应 `PRICES` 元组的后两项和 `applied()`，`cacheReadQuotaWeight` 对应 `CACHE_READ_WEIGHT`，`ClaudeRates.starting` 对应 `STARTING`，`OtherUsage.threshold` 对应 `OTHER_THRESHOLD`
  - `ModelFamily.of` 对应 `family()`：按模型名里的子串匹配（Mythos 算 Fable），名字里不含 fable、mythos、opus、sonnet、haiku 的新模型族不会计价，要加 case 和价格
  - `ClaudePricing.version` / `price(model:family:)` 对应 `version()` / `price()`：每个请求按模型名里的版本号定价（`claude-opus-5` 按 Opus 5 的价格，不是 Opus 5.5 的）。出了新一代、价格变了时，把旧的当前价挪进老版本表，再改当前价
  - 改价格会让已经存下的区间花费不对（`intervals.jsonl` 只追加）：改价格表时给 `ClaudePricing.basis` 加一，区间记录里存着当时的版本（`UsageInterval.priceBasis`，旧记录没有就当 1）；新切出来的区间会换掉旧版本的，换不掉的、花费里有 Haiku 的不拿来学换算率。其他族的价格改了要不要排除，照 `hasHaikuSpend` 的写法改。
  - `ClaudeTranscripts` 的解析规则：按 `message.id` 去重、同一个响应的各字段取最大值、跳过 synthetic 和写到一半的行（限流消息只有 App 读，usage_lab 不需要）
- 改换算相关的逻辑之前，先看 `docs/PRODUCT_PLAN.md` 第 7 节的回归结论：所有模型用一个系数，思考程度（effort）不单独算，缓存读按半价。改完用 `python3 usage_lab.py backtest` 回测，和改之前比一比。
- 宠物的八款形象都是 GPT 出图切成的图片，没有像素画，也没有单色模式（0.2.0 及以前有过，已经删掉）。`PetFrame` 里的图是 `PetPicture`（哪款形象、头像还是半身像、哪个表情），`PetRenderer` 只负责读图；各种心情播哪几个表情在 `PetSprites.frames`。
  - 两家各有一组形象，互不重叠：Claude 是 `PetStyle.claudeChoices`（经典、猫耳、青春、魔女、墨镜 `shades`），Codex 是 `codexChoices`（龙娘 `dragon`、汉服 `hanfu`、极客 `geek`）。`PetStyle.of(_:claudeStyle:codexStyle:)` 决定每家用哪个，存的形象不在那组里就用那组第一款。加一款：`PetStyle` 加 case 和名字，放进其中一组，配一份 `design/painted/<rawValue>.json`。
  - 图片：`design/painted/export_painted.py` 按 `design/painted/<形象>.json` 把原图切成 `Resources/Pets/<形象>/{portrait,icon}-<表情>.png`（192 / 44 像素的 2 倍图，面板 96pt、菜单栏 22pt），同时生成 `QuotaPetCore/Pet/PaintedArt.swift`（表情清单，**不要手改**）。流程见 `QuotaPet/README.md`「改宠物形象」。
  - 流水线：`make_pack.py <形象>`（按配置里的 `character`、`label` 生成提示词和画风参考图）→ 用户在 GPT 里出底图和 13 个表情 → `pipeline.py <形象>`（检查原图、自动定位并写进配置、导出，一款要跑几分钟）。配置里已有的位置不会被覆盖（`--relocate` 才重新定位）。汗珠、流出脸外的眼泪是按浅蓝色找的，偏白偏青的认不出来，要看脸部放大图、在配置的 `patches` 里手动写。自动定位的菜单栏头像框常常太紧，要手动放大到带上头顶的饰品和头发的外轮廓。
  - 原图在 `anime-sheet/精绘出图/<形象>/GPT出图/`，出图包（`提示词.md`、参考图）在它的上一级；只有墨镜在旧位置 `anime-sheet/精绘出图/GPT出图/`。`anime-sheet/` 是本机的素材文件夹，只写在 `.git/info/exclude` 里，里面的东西不能挪进会被跟踪的地方。
  - App 图标用经典款：配置里写了 `appIcon` 的那款，导出时另外生成 1024 像素的 `Resources/AppIcon.png`，`IconRenderer` 画大图标时用，`build-app.sh` 不把它拷进 App 包。
  - 表情图先对齐到底图，只取脸的椭圆盖上去，头发、衣服各表情一样；脸以外的小块（太阳穴的汗珠）用配置里的 `patches` 从一张复制到几张（`tired-wavy` 的汗珠复制到 `closed-wavy` 和 `nervous`）。
  - 抠背景：原图是纯绿背景，默认按「绿不绿」整张抠。人物身上有绿色时在配置里写 `keepGreen`，不然这些地方会被抠掉、变色：绿色只在里面（青春的绿眼睛）写 `"inside"`，离背景远的地方原样留着、轮廓照常抠；轮廓上也有绿（极客的薄荷绿头发、荧光绿耳机）写 `true`，这时头发边缘是硬边，不如默认的干净，没必要别用。
  - 每款 14 张表情图（`export_painted.FACES`，第一张是底图）。汗珠、眼泪画在表情里，不往图上叠小道具；睡着（`sleep`）、疑惑（`puzzled`）、迷糊（`drowsy`，刚启动、睡着或歇着时被戳）、紧张（`nervous`，「有点慌」）、惊讶（`surprised`，被戳）、生气（`pout`，戳烦了）都是单独的表情。
  - 加表情：`FACES` 和 `make_pack.py` 的 `EXPRESSIONS` 一起加，`make_pack.py --prompt <表情…>` 打印提示词。**每一款的图都齐了再跑导出**：`export_painted.py` 每次都会重写 `PaintedArt.swift` 的表情清单，哪款缺图自检就会失败。表情不能改变脸的轮廓（只取脸的椭圆盖到底图上），所以「生气」不能真的鼓脸。
  - 找图（`PaintedArt.root`，在 Core 里，App 和自检共用）：打包后在 `Contents/Resources/Pets`（`build-app.sh` 拷进去）；开发时从可执行文件往上找 `Resources/Pets`。不能用 `#filePath` 或 `Bundle.module`，它们会把本机绝对路径编进发布包。
  - 配置文件名就是 `PetStyle` 的 rawValue，图片尺寸是 `PetSprites.iconPoints` / `portraitPoints` 的 2 倍，自检拿导出的图核对。
- 命令行参数（`--demo`、`--dump`、`--render-previews` 等）都在 `Sources/QuotaPet/main.swift` 里分发。
- 第一次启动（`QuotaPetCore/FirstLaunch.swift`，设置里只有 NS 开头的 AppKit 键才算）时宠物一直显示到退出，并弹出面板；开机自启先挂起（`loginItemPending`），等 App 在「应用程序」文件夹里运行时才打开（下载版第一次常在「下载」里被 macOS 挪到临时目录运行），用户自己开关成功过就不再管（`FirstLaunch.clearsLoginItemPending`：打开要在「应用程序」里才算，失败了留着）。要在系统设置「登录项」里允许时，用户自己点的会帮他打开那一页。同时有几个 QuotaPet 在跑时留最早启动的（`FirstLaunch.launchedEarlier`），后来的请它把宠物叫出来再退出。
- 界面支持简体中文和英文（`QuotaPetCore/Localization.swift`），默认跟随系统，设置 → 通用 → 语言可以改：
  - 每句界面文字都写成 `tr("中文", "English")`，两种语言写在一起；新加或改界面文字时两种都要写。英文里的数量用 `plural(n, "day")` 分单复数（数字要换写法时传 `shown:`，比如 `plural(n, "token", shown: Fmt.tokens(n))`）。
  - 当前语言在 `L10n.language`，由 `AppSettings.language` 在 willSet 里同步（订阅者要读到新语言）。快照里的窗口名、说明文字是后台按当前语言算的，换语言时 `UsageStore` 会重算，面板用 `.id(settings.language)` 整个重建。
  - 自检开头固定成中文；「多语言」一节查英文，并检查英文里没混进中文。App 本体的文字自检覆盖不到，改了要看 `make previews` 的 `-en` 图。
  - `--dump` 是对账工具，固定输出中文。App 在访达、通知里显示的名字在 `Resources/*.lproj/InfoPlist.strings`。
  - 仓库首页有中英两份：`README.md` 和 `README.en.md`（英文版还收了 `QuotaPet/README.md` 里的用法和设置项）。改了功能、设置项或截图，两份都要改。

## 隐私（仓库是公开的）

- 默认只读本机文件：不联网，不读任何登录凭据。「用凭据调官方 usage 接口」是刻意不做的。Codex 也一样：只读 `~/.codex` 下对话日志里的额度字段，不读 `~/.codex/auth.json`。
  - 唯一的例外是用户在设置里自己打开的「用 Claude 命令行补官方读数」（`CLIProbe`，默认关闭）：让桌面端自带的 `claude` 命令行用它自己的登录发一个最小请求，从输出的 `rate_limit_event` 读额度。QuotaPet 仍然不读钥匙串、`~/.claude` 里的凭据、命令行的 token，只看 `auth status` 的 `loggedIn` / `authMethod` / `orgId`，也不存邮箱。别把它改成默认开启，也别加别的联网功能。
  - `cli-readings.jsonl`、`cli-probe/` 和 `--probe-cli` 的输出一样是真实数据，不进 git。
- `make previews` 会额外生成 `popover-live.png` 和 `popover-live-dark.png`，用的是**本机真实额度数据**（Claude 和 Codex），不能复制进 `docs/images/` 或提交；其余预览图都是假数据。
- `make dump` 和 `usage_lab.py` 的输出、`snapshots.jsonl`、`intervals.jsonl` 都是真实数据，不进 git，也不贴进 issue 或 PR。
- `.githooks/pre-commit` 会在提交时拦住 `.jsonl` 文件、截图、`popover-live*`、本机绝对路径和不是 noreply 的邮箱。它是用 `git config core.hooksPath .githooks` 启用的，被拦了就改内容，不要加 `--no-verify` 绕过。
  - 云端会话（claude.ai/code）启动时 `.claude/hooks/session-start.sh` 先把这个 clone 的提交身份换成登录的 GitHub 账号的 noreply 地址（云端默认的 `noreply@anthropic.com` 会被它和 CI 拦下；`gh` 用不了时，本仓库用主人的地址），有了 noreply 身份才启用它。不要再把身份改回去。
- 发 Release 的包也不能带本机信息：`build-app.sh` 会 `strip -S` 去掉调试符号（里面记着编译时的本机绝对路径和用户名），`make release` 打完包会查一遍 `/Users/`，有就失败。

## 什么时候用哪个技能

| 场景 | 技能 |
|---|---|
| 改完代码要确认能用 | `quotapet-verify`（编译 + 自检 + 渲染预览图并查看） |
| 更新模型价格或加新模型 | `claude-api`（查当前价格），然后同步改 `usage_lab.py` |
| 一个功能写完 | `/simplify`；改动较大就用 `/code-review` |
| push 之前 | `/security-review`：重点看有没有联网、读凭据、真实数据进 git |
