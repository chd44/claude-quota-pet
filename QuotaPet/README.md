# QuotaPet 额度宠物

住在 macOS 菜单栏里的二次元小人（橙色长发、别着橙色花饰），实时显示 Claude 的额度：额度越紧张，她越累；用完了就睡着，并显示恢复倒计时。
本机用过 Codex 的话，Codex 的额度也会一起显示，由另一只宠物看着（龙娘、汉服、极客三款可选）。

截图和功能总览见[仓库首页](../README.md)，产品规划见 [docs/PRODUCT_PLAN.md](../docs/PRODUCT_PLAN.md)。

## 快速开始

需要 macOS 14+ 和 Swift 6。装了命令行工具（`xcode-select --install`）就够，不需要 Xcode。

```bash
make run        # 打包成 build/QuotaPet.app 并启动
make demo       # 演示模式：假数据，75 秒看完宠物的所有状态
make install    # 装到 ~/Applications 并开机自启：以后一打开 Claude，宠物就出现
make release    # 发 Release 用：Apple 芯片 + Intel 通用版，压成 build/QuotaPet-<版本>.zip
make dump       # 在终端打印当前额度推算，和 usage_lab.py 对账
make check      # 跑自检
make previews   # 把宠物、菜单栏、面板渲染成 PNG，放到 build/previews（面板、设置页中英各一套）
```

第一次启动时，macOS 会问要不要允许「额度宠物」发通知，选允许才能收到用量提醒。选了不允许的话，设置页的「提醒」下面会提示，点「打开通知设置」就能改。

## 怎么用

- 默认**跟着 Claude 桌面端走**：打开 Claude 宠物就出现，关掉 Claude 就藏起来（后台照常发额度恢复提醒）。
  设置里可以改成「一直显示」；只用命令行、没装桌面端时自动按一直显示算，装好后恢复跟着桌面端走。宠物藏着的时候想看额度，在 Spotlight 里再打开一次 QuotaPet 就会弹出面板。
- 要跟着 Claude 自动出现，QuotaPet 得开机自启（`make install` 会打开；下载版放进「应用程序」后第一次打开也会）。想关掉：QuotaPet 设置 → 通用，或者「系统设置 → 通用 → 登录项」。
- **左键**点宠物弹出面板，**右键**是刷新、设置、退出。
- 菜单栏显示 5 小时额度（可以在设置里改成「5h + 周」或「最紧张的窗口」）；75% 以上数字变橙，90% 以上变红。
- 宠物心情先看最紧张的那个窗口：< 50% 元气满满 → 50% 状态不错 → 75% 有点累 → 90% 快撑不住 → 100% 睡着。再看趋势：照最近的速度快用完了会提前哭，5 小时额度撑不到重置会先慌起来，额度刚恢复开心一阵，不紧张又半小时没用就歇着。只有真的用完了才会睡着。
- 面板上她说的话跟着实际情况走（几点见底、这周的节奏、别处是不是也在用…），每次点开换一句；点她一下，她会做个表情、回你一句；连着戳个不停，她会闹别扭。
- 被限流时菜单栏改显示恢复倒计时，比如 `1h23m`；额度恢复时会提醒。
- 除了跨过阈值，照最近的速度快用完时也会提前提醒一次（5 小时额度提前约半小时，每周额度提前约一天），设置里可以关。
- 面板里每周额度的进度条上有一条小竖线：按平均节奏现在应该用到这里。下面一行写着比平均节奏多用或少用了几个点、之后每天还能用多少（多用 10 个点以上标橙）。Claude 的每周重置时间还没看准时（刚装好、还没看到过一次重置）不显示，也可以在设置里手动指定重置时间。
- **同时用 Codex**（命令行或桌面端）时自动接进来：面板顶部有 Claude / Codex 切换条，每次点开先看更紧张的那家；宠物和菜单栏数字跟着两家里更紧张的那个，数字前面加一个小图标（星号是 Claude，终端是 Codex）。两家的宠物各选各的：Claude 五款，Codex 三款（龙娘、汉服、极客），互不重叠。
  「Claude 打开时出现」这时也看 Codex 桌面端。不想看 Codex，在「设置 → Codex」里关掉就行。
- 界面有简体中文和英文，默认跟随系统语言（系统语言不是这两种时用英文），可以在设置 → 通用 → 语言里改。

设置页（右键 → 设置…）顶部按「通用 / Claude / Codex」分页：

| 分页 | 设置项 |
|---|---|
| 通用 | 菜单栏：什么时候出现（Claude 打开时，在用 Codex 时也看 Codex / 一直显示）、宠物旁边显示什么、宠物动画。提醒：用量提醒和阈值（50 / 75 / 90 / 100%，默认 75 / 90 / 100）、快用完时提前提醒、额度恢复时提醒。其他：语言（跟随系统 / 简体中文 / English）、开机自动启动 |
| Claude | 宠物形象（经典 / 猫耳 / 青春 / 魔女 / 墨镜）。实时估算：用本机日志实时估算、自动学习换算率（能看到当前学到的值）、手动指定每周重置时间。官方读数：用 Claude 命令行补官方读数（默认开启，会联网） |
| Codex（本机有记录时才有这页） | 显示 Codex 的额度、宠物形象（龙娘 / 汉服 / 极客）、数据从哪来和最近一次读数的时间 |

## 菜单栏里看不到宠物？

刘海屏 MacBook 的菜单栏图标一多，放不下的会被藏到刘海后面，而且系统默认把新图标放在最左边，最先被挡住。
QuotaPet 第一次启动时会把自己放到最右边、紧挨着时钟，所以一般能看到，代价是别的 App 可能被挤到刘海后面。解决办法：

- 按住 ⌘ 拖动菜单栏图标，可以调整顺序（系统会记住位置）；
- 在「系统设置 → 菜单栏」里关掉不常用 App 的菜单栏图标；
- 在 QuotaPet 设置里把菜单栏显示改成「仅宠物」，能省下一半宽度。

## 数据从哪来（不读登录凭据，只有命令行补查会联网）

| 数据 | 来源 |
|---|---|
| 官方 5 小时 / 每周 % | Claude 桌面端运行时每 15 分钟写一次的 `~/Library/Application Support/Claude/plan-usage-history.json` |
| 两次官方读数之间的变化 | `~/.claude/projects/**/*.jsonl` 里 Claude Code 每个请求的 token，按 API 价格折算，再用自动学到的换算率换成百分比 |
| 重置时间 | 推算：窗口从上一个窗口结束后的第一次使用开始计时，读数明显下跌的地方视为重置；Claude Code 被限流时，用日志里服务器给的精确恢复时间 |
| 官方读数的备用来源（默认开启，可关） | 设置 → Claude → 官方读数里的「用 Claude 命令行补官方读数」：QuotaPet 让桌面端自带的 `claude` 命令行发一个最小请求（`-p`、haiku、`--safe-mode`、不带工具、不存会话），从输出里 `rate_limit_event` 的 `unifiedWindows` 读出 5 小时和每周的已用百分比和重置时间，追加到 `~/Library/Application Support/QuotaPet/cli-readings.jsonl`（只留 8 天） |
| Codex 的 % 和重置时间 | Codex 每轮对话结束时写进 `~/.codex/sessions/**/*.jsonl`（归档的在 `archived_sessions/`）的 `rate_limits`：服务器给的已用百分比、窗口长度和重置时间，不用估算 |

几点说明：

- **换算率自动学习**：「多少美元的 API 用量 ≈ 1% 额度」，所有模型用同一个数。实测额度和 API 价格大致成正比；思考程度（effort）不用单独算，它的影响已经体现在思考 token 里，而思考 token 按输出计费；唯一的例外是缓存读，在额度里只算一半左右（回归细节见产品规划第 7 节）。App 从持续记录里自动学这个数，越近的记录权重越大（半衰期 3 小时），起始值是 $0.27。设置页能看到当前学到的值。
- **持续记录**：每 15 分钟一段（官方涨了多少、本机按「模型/思考程度」花了多少）存在 `~/Library/Application Support/QuotaPet/intervals.jsonl`，一行一条 JSON，只追加。Claude Code 清理旧日志也不影响。以后数据多了，可以直接用它重新做回归。每周额度还没看到过重置时，按第一次使用推出来的窗口开始时间也存在同一个文件夹（`weekly-origin.json`）：本机日志只留 8 天，重启后从它接着推，重置时间不会每天往后挪。
- **只有官方读数或限流消息能宣布「用完了」**：官方读数没到 100% 之前，估算值最多显示 99%，免得宠物误睡、误发提醒。Claude Code 被限流时会在日志里记下服务器的回复（哪个额度用完、几点恢复），QuotaPet 读到就马上显示用完，倒计时也按这个时间算。
- 需要 Claude 桌面端在运行，官方读数是它记录的；桌面端没开时只能靠本机估算，面板里会提示。新版桌面端有时会停掉后台刷新（Anthropic 的服务端开关控制），开着也会停在最后一次读数；重启 Claude 桌面端会记一次新读数。
- 聊天（含桌面端）、网页端和手机端的用量不在本机日志里，要等下一次官方读数（最多 15 分钟）才会体现。读数到了以后，官方增量里本机日志解释不了的部分算作「其他端」用量：面板会标出每个窗口里其他端用了多少，消耗速度和「几点用完」也会算上它。
- 重置时间是推算的，每周重置时间不准的话，可以在设置里手动指定。命令行读数里有官方给的重置时间，有的话两个窗口都直接用它（比手动指定的优先）。
- **用 Claude 命令行补官方读数**（默认开启，唯一会联网的功能）：联网的是命令行本身，用它自己的登录；QuotaPet 不读钥匙串和 `~/.claude` 里的凭据，只看 `claude auth status` 的 `loggedIn`、`authMethod`（必须是 claude.ai 订阅，API Key 的不查）和 `orgId`（和桌面端的组织对不上就不查、读数也不用）。每次查询是一个真实请求，会占一点额度，所以只在「5 小时窗口已经在跑、窗口里有官方读数没看到的本机用量、官方读数超过 17 分钟没来」时自动查（桌面端正常刷新时不会多查），失败了按倍数往后退，最多 2 小时；手动刷新会立刻查一次（30 秒内连点不重复）。不在用时不查，是因为 5 小时窗口从第一次请求才开始计时，会让窗口提前开始。命令行没登录时，设置页给出登录命令。`QuotaPet --probe-cli` 在终端里跑同一段代码，调试用。
- **Codex**：只看 Codex 的总额度（`limit_id` 是 `codex` 的那组；个别模型单独的额度不显示）。读数只在本机用 Codex 时更新，网页或云端任务的用量要等下次在本机用时才看得到，读数超过 1 小时没更新时面板会提示（Dot 等云端任务可以在你不动时花额度）。读数之后窗口已经过了重置时间的，算 0%、等下次使用再开始计时。日志可能有几百 MB，第一次只从最近的文件往前读到 25 小时前的那次读数（算消耗速度要往回看 24 小时），之后每个文件只读新追加的部分。只读对话日志里的额度字段，不碰 `~/.codex/auth.json` 等登录凭据。

## 代码结构

```
Sources/
  QuotaPetCore/                 纯逻辑，不依赖 AppKit
    Models.swift                UsageProvider 协议、UsageWindow、UsageSnapshot
    Localization.swift          界面语言，tr("中文", "English")
    Formatting.swift            时间格式（跟着界面语言）、菜单栏文字
    UsageAlerts.swift           用量提醒：什么时候提醒、怎么说（发通知在 App 的 NotificationManager）
    Claude/
      ClaudeDesktopHistory      解析桌面端的官方读数
      ClaudeTranscripts         增量读取 Claude Code 日志（规则同 usage_lab.py）
      ClaudePricing             API 价格和起始换算率
      WindowInference           推算窗口开始 / 重置时间
      UsageIntervals            切出每 15 分钟的区间，持续记录到本机
      RateLearner               从记录里学换算率
      ClaudeCLIReadings         命令行读数：解析、记录、和桌面端读数合并、找命令行、什么时候查
      ClaudeProvider            把以上组合成一个快照
    Codex/
      CodexLogs                 增量读取 Codex 对话日志里的额度读数
      CodexProvider             把读数组合成快照（窗口、消耗速度）
    Pet/                        宠物心情、形象、说的话（PetTalk、PetStatus）、记忆和聊天状态；PaintedArt.swift 是表情清单（导出的，别手改）
    DemoProvider.swift          演示数据（Claude 和 Codex）
  QuotaPet/                     菜单栏 App
    StatusItemController        菜单栏上的宠物、文字和弹出面板
    MenuBarIcon                 菜单栏上的图：宠物头像 + 几家同时显示时的小图标
    AppWatcher                  盯着 Claude / Codex 桌面端有没有开
    UsageStore                  几家数据源一起算；FSEvents + 每分钟兜底的刷新调度
    CLIProbe                    用 Claude 命令行查官方读数（默认开启，可关）
    NotificationManager         发通知、存每个窗口的提醒记录（判断在 UsageAlerts）
    Pet/                        动画播放、读图（图在 Resources/Pets）
    Views/                      SwiftUI 面板和设置页
    Tools/                      --dump、--probe-cli、--render-previews、--render-icon
  QuotaPetChecks/               自检（命令行工具里没有 XCTest，用可执行文件代替）
```

## 改宠物形象

八款形象都是这样做的：用 GPT 出图，再用脚本切成 App 用的图。原图放在不进 git 的地方，`design/painted/<形象>.json` 是这一款的配置。
脚本要用 Pillow 和 NumPy（`pip3 install pillow numpy`），对比图放在 `design/out/`，不进 git。

1. 在配置里写 `label`（中文名）、`source`（原图目录）和 `character`（角色描述：头发、眼睛、饰品、服装、表情），然后生成出图包：提示词，加上一张画风参考图（已经做好的那款的底图）。

```bash
python3 design/painted/make_pack.py <形象>   # → 原图目录的上一级：提示词.md、参考图
```

2. 按提示词让 GPT 先出一张底图（`open-small.png`）：正方形，纯绿背景（`#00FF00`），画到胸口，头顶和两侧的头发不要被画面切掉。
3. 再让 GPT 在底图上只改表情，每个表情一张，文件名见 `design/painted/export_painted.py` 里的 `FACES`。每次都在底图上改，不要在上一张表情图上接着改。汗珠、眼泪直接画在表情里。
4. 图存进原图目录后跑流水线：检查原图，自动定位脸的椭圆、面板和菜单栏头像的取景（写进配置），再导出。

```bash
python3 design/painted/pipeline.py <形象>    # → Resources/Pets/<形象>/ 和 Sources/QuotaPetCore/Pet/PaintedArt.swift
```

5. 看三张图：定位图 `design/out/painted-<形象>-locate.png`、脸部放大图 `-faces.png`（看接缝）、对比图 `painted-<形象>.png`（看菜单栏头像）。位置不准就改配置里的数字再跑一次，配置里已有的位置不会被覆盖（要重新定位加 `--relocate`）。自动定位的头像框常常太紧，要手动放大到带上头顶的饰品（猫耳、帽子、蝴蝶结）和头发的外轮廓，不然缩到菜单栏上认不出是谁。
6. `make previews`，看 `pet-sheet-<形象>`、`menubar-<形象>`、`popover-<形象>`。

给做好的形象补表情：在 `FACES`（`export_painted.py`）和 `EXPRESSIONS`（`make_pack.py`）里加上，`python3 design/painted/make_pack.py --prompt <表情…>` 打印这几个的提示词，附上各款的底图去出图。表情清单是所有形象共用的，要每一款的图都齐了再导出，不然自检会报缺图。

只想重新导出、不重新定位时直接跑 `python3 design/painted/export_painted.py`。缺表情图、或者用 `--src <目录>` 试别的原图时，只出对比图，不动 `Resources/Pets` 里已经提交的图；确定要写进 App 就加 `--write`（缺的表情先用底图代替）。

脚本先拿头发和衣服把每张表情图对齐到底图，再只取脸那一块（边缘羽化）盖上去，所以各个表情的头发、衣服完全一样，切换时不会抖。
脸以外的小块（比如太阳穴上的汗珠）写在配置的 `patches` 里：只让 GPT 画一次，脚本复制到别的表情上，位置一模一样。

人物身上有绿色时在配置里写 `keepGreen`：默认的抠图按「绿不绿」整张抠，会把这些地方抠掉、变色。绿色只在里面（绿眼睛）写 `"inside"`；轮廓上也有绿（薄荷绿的头发、荧光绿的饰品）写 `true`。

不往图上叠小道具（漫画符号浮在精绘的脸上很突兀），也没有单色版（缩成剪影很难看）。各种心情播哪几个表情在 `PetSprites.frames`，被戳的反应在 `PetSprites.reaction`。
加一款：配置文件名用新形象的 rawValue，在 `PetStyle` 里加 case 和名字，再放进 `claudeChoices` 或 `codexChoices`。

App 图标用的是经典款：配置里写了 `"appIcon": true` 的那一款，导出时另外生成 1024 像素的 `Resources/AppIcon.png`，只在打包时用来画图标，不进 App 包。

## 接入别的 AI

实现一个 `UsageProvider`，返回若干个 `UsageWindow` 就行，宠物、菜单栏、通知都是通用的。Codex 就是这么接进来的，可以照着 `QuotaPetCore/Codex/CodexProvider.swift` 写：

```swift
final class CursorProvider: UsageProvider, @unchecked Sendable {
    let id = ProviderID.cursor            // 先在 ProviderID 里加一个 case 和显示名
    let pollInterval: TimeInterval = 60
    var watchPaths: [String] { … }        // 相关文件一变就刷新
    func isRelevantChange(path: String) -> Bool { path.hasSuffix(".jsonl") }
    func snapshot(now: Date) throws -> UsageSnapshot { … }
}
```

然后在 `AppDelegate` 里把它加进数据源列表，在 `MenuBarIcon.glyph(for:)` 给它挑一个小图标，想让它有自己的宠物就在 `PetStyle.of` 里指定形象。没有数据的数据源不会出现在面板和菜单栏上。
