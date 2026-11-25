# QuotaPet 开发说明

QuotaPet 启动后立即通过官方 CLI 的交互式 `/usage` 读取 agy 和 Claude 的真实额度，此后每 12 分钟刷新，三家都在后台保持读数，切换页签不清空、不重读；最近一次可用读数缓存在本机设置里，有效期内重启也先显示；只执行专用斜杠命令，不把 `/usage` 交给模型，不调用私有端点。Claude 和 Codex 也显示官方读数（2026-11-20/21 用户同意放开）：Claude 通过官方 Claude Code CLI 的交互式 `/usage` 读取（`--safe-mode --strict-mcp-config --tools ""`，专用空目录，只发这一条斜杠命令，给这次查询指定会话编号，读完只删除这个编号的会话文件，共享的会话文件夹保留；CLI 版本过旧、不认这个参数时立即提示更新，不删任何文件；CLI 最后显示的是登录提示时提示登录，屏幕上残留的旧额度文字不算读数），之后每 12 分钟一次；`~/.claude/projects` 里有对话文件写入（只看文件事件，不读内容）时，活动停下 45 秒后自动再读，连续干活时最多每 3 分钟一次；手动刷新两次之间至少 30 秒；读失败（超时、面板没认出）时，有效期内的上一次读数照常显示，并在 1、2、4、8 分钟后重试，最长回到 12 分钟一次；agy 启动时若明确停在登录交互界面直接判为未登录，发出 `/usage` 后只认新出现的登录提示内容，启动横幅里的「not signed in」不算；超过 15 分钟的读数即未知；Codex 逐行解析 `~/.codex` 会话日志，只提取服务器给的 `rate_limits`（百分比和重置时间）、每轮开始记录和用量事件的时间（用来判断正在用），不保存、不展示正文，日志一写入就更新；超过 1 小时的读数仍显示上次的数字，但整体变灰并标明时间，宠物用中性表情。自动跟随正在用的那家（设置页可关，默认开）：Claude 看 `~/.claude/projects` 里会话文件的真实写入和 `~/.claude/history.jsonl`（提交提示词时追加，只看元数据），Codex 看会话日志里每轮的开始记录和用量记录（只取记录类型和时间，带不带额度都算），agy 看 `~/.gemini/antigravity-cli/conversations` 与 `~/.gemini/antigravity/conversations` 里的真实写入（Claude 和 agy 只看文件事件和元数据：文件编号、大小、修改时间和系统的内容代号，不读内容；改权限、只改修改时间、建目录、删除、移走旧文件、只改名字、.DS_Store 等隐藏文件、插件缓存等维护写入不算；整个会话文件夹移进来时核对里面的文件；conversations 是符号链接时跟着它指向的目录），按写入或记录发生的时间算，修改时间在未来的不算，最近 10 分钟有动静的算正在用；同一时刻的按 Claude、Codex、agy 的固定顺序；只有一家时跟它，几家同时在用时跟最近「主动开始」的那家（Codex 新一轮开始、Claude 提交提示词、新建 Claude/agy 会话，新会话按它出生的时间算；已有会话里的后台回复、子任务写入、Codex 子代理和旧任务的用量、旧通知抢不走），只要那家还在用（10 分钟内有动静，长任务也算）就一直跟它，它停下后跟最近有动静的那家；QuotaPet 自己查额度的 CLI 进程运行期间写下的不算主动开始，查询结束后才写的照算；agy 另外逐行读各会话步骤记录 `brain/<会话>/.system_generated/logs/transcript.jsonl` 新追加的行，只看正文（content）之前的来源、类型和时间，正文不解析、不保存：用户自己发的消息（`USER_EXPLICIT`/`USER_INPUT`）算主动开始，回到原会话续聊也认得出，模型回复、系统通知和后台步骤不算（2026-11-22 用户同意放开）；面板或右键菜单开着时不切换，收起后马上按当时的状态补判一次（右键菜单的「立即刷新」刷打开菜单时那家）；重新打开跟随开关、各家读数变化时也会重新判断；手动选择后 10 分钟内不切换；每家最近一次主动开始的时间（只有服务名和时间）记在本机设置里，重启后长任务仍按原来的开始时间排先后；QuotaPet 没运行期间提交的 Claude 提示词、发的 agy 消息即使早于 10 分钟，只要这家在本次运行里有会话写入（启动时仍在写，或之后才恢复写入），也按提交时间算作这家最近一次主动开始（24 小时以内；启动时、第一次查 Claude 额度之前先记下 `history.jsonl` 的修改时间，agy 第一次有会话写入时按 24 小时回看一次步骤记录；只有 QuotaPet 自己查询时 CLI 改写 `history.jsonl` 不算会话写入）；时间在未来的开始记录永久丢弃（先验时间再占保留名额；Codex 的按会话文件名的指纹和记录时间逐条记在本机设置里，最多 512 条、保留 7 天，不存路径和内容，重扫和重启后都不读回来，同一会话之后真正新写的照常算）；QuotaPet 自己查 Claude 额度的起止时间也存在本机，启动时固定上一次运行的那次，本次查询覆盖设置后，重启后的补扫仍不会把那次查询留下的写入当成用户的提示词。agy 有动静时也像 Claude 一样在停下后自动重读。QuotaPet 自己不读凭据和对话内容，不做本机估算；它自己只联网做一件事：每天最多一次向 GitHub 查询本仓库的最新正式版本号（`api.github.com/repos/chd44/claude-quota-pet/releases/latest`，不带本机信息，设置页可关，默认开；2026-11-24 用户同意放开），有新版时面板和右键菜单出现更新按钮，用户点了才从这个仓库的 Release 下载安装包，核对大小和 GitHub 给的 SHA-256、解开后核对 App 标识、版本号和签名，退出后由脚本替换并重新打开，失败就还原旧版；任何一项不符（含缺指纹、App 不可写或在系统临时隔离位置）就只打开发布页。缺少读数、读数过期，或读取失败且没有有效期内的上一次读数时显示未知并使用中性形象；不通过手动选择额度或模拟数据驱动正常模式。

## 正常模式与演示边界

- Claude：[官方用量页](https://claude.ai/settings/usage)。
- Codex：[官方用量页](https://chatgpt.com/codex/settings/usage)。
- agy：[官方 `/usage` 文档](https://antigravity.google/docs/cli/commands/usage)，装有官方桌面 App 时也可以打开它的设置查看额度。启动后及之后每 12 分钟通过官方 CLI 交互式 `/usage` 获取读数（和 Claude 共用 `CLIQuotaMonitor` 调度）。
- Claude：`ClaudeQuotaProbe` 在伪终端里运行官方 Claude Code CLI（固定位置：`~/.local/bin/claude` 等，或桌面端自带且带 `.verified` 的最新版本），用 `VirtualTerminal` 还原屏幕，只在认得的画面上按键（主题、安全须知、只对专用空目录的信任框），读到「Refreshing」消失后的最终面板再由 `ClaudeUsageParser` 解析。agy 和 Claude 共用 `CLIQuotaMonitor` 调度。Codex：`UsageStore` 只跑 `CodexProvider`。不放旧 `ClaudeProvider`，不读 Claude Code 对话日志、不做实时估算，也不接额度提醒。
- `--dump` 只输出入口；`--probe-cli` 拒绝执行。不要为兼容旧参数恢复额度查询。
- `--demo`、relay previews、`--render-official-previews` 使用合成数据。旧的估算、命令行补查和提醒逻辑只供自检与演示。

「5 小时」不是跨账户不变量。套餐规则及是否存在该窗口以各家官方账户界面为准。agy 使用官方交互式 `/usage`；不得回退为模型提示、CLI 消耗请求、本机日志、第三方中间层或私有端点。

## agy 静态美术与发布

0.4.2（build 15）在 `Resources/Pets/agy` 下包含三款的六张中性 PNG：默认棱镜礼装（Prism Regalia）的 `menu.png` / `panel.png`，反重力飞行员（Zero-G Pilot）的 `pilot-menu.png` / `pilot-panel.png`，绣球花匠（Hydrangea Gardener）的 `gardener-menu.png` / `gardener-panel.png`。每组分别用于菜单栏头像和额度面板半身像。图片在本地加载；有效 agy 真实读数可切换额度状态。切换官方入口时更新，Claude 和 Codex 各自记住选过的形象，切回 agy 也恢复上次 agy 款式。agy 形象参考 ZipZipPipe 的「Gemini 娘」。[角色原设](https://www.bilibili.com/opus/1233069202138464289)

agy 的额度以 Gemini 组为准（`AgyQuotaPresentation.primaryWindow`：这组里用得最多的窗口），菜单栏数字、切换条和宠物表情都用它，面板标题写明是哪个窗口（窗口行上不再另加「菜单栏显示」标签）；面板里仍列出全部模型组。三款的补充状态图（刚恢复、歇着、有点慌、有点懵、醒过来中、被戳、闹别扭）都已补齐，「元气满满」「快撑不住」也已重画；提示词见 [design/agy-states](../design/agy-states/README.md)，以后重画仍用 `scripts/import-agy-art.sh` 导入；缺图或登记过的坏图（`OfficialPetChoice.brokenArtDigests`）退回这款的基础图。

`scripts/agy-asset-names.sh` 是打包、归档检查与 CI fixture 共用的唯一清单：三款前缀（空、`pilot-`、`gardener-`）× `menu` / `panel` × 中性或 `energetic` / `tired` / `exhausted` / `sleeping` 后缀，共 30 张必需 PNG；`--optional` 列出 42 张可补充的状态图，有就打包，没有不报错。例如 `pilot-menu-tired.png`。`build-app.sh` 按共享清单显式复制至 App 的 `Contents/Resources/Pets/agy/`，不复制参考图或其他中间产物。`check-release-archive.sh` 在解压后的最终 zip 中检查 30 图存在且格式为 PNG，agy 目录拒绝其他文件，旧形象的 portrait/icon 文件规则保留。发包时还需核对源图与包内图的 SHA-256 一致，并在图形会话查看三款菜单栏和面板实际显示，以及切换服务后是否恢复所选款式。此处版本与图形验收不代表已发布。

## 启动方式

正常模式由 `OfficialMenuController` 管理：左键弹出 `OfficialOverviewView`（沿用旧总览的布局与 `UsageBar` 进度条），右键弹出操作菜单；图标不可见时 `reveal()` 改用当前屏幕的浮动面板。面板切换条 `OfficialTabs` 整条只有一颗胶囊：点击直接落位，拖动时按磁吸曲线跟手、过交界轻震，松手停在最近的那家；开了全键盘控制时各格可用 Tab 聚焦，空格 / 回车切换，左右方向键换到相邻那家。三家共用 `RefreshButton`（点了至少转一圈，读取中一直转）；刷新按钮只在点了之后、这次读取结束前转圈（`OfficialPanelState.manualRefreshing`），后台自动读取不转；点刷新的结果由 `RefreshNotice`（QuotaPetCore）判定，在页脚停 4 秒：Claude / agy 要点击之后读到可用读数才算已刷新，30 秒内重复点会提示还要等几秒，Codex 报日志里读数的时间。可用 `swift run QuotaPet --render-official-previews <dir>` 渲染合成读数的面板预览。桌面联动在「宠物菜单 → 启动方式」主动开启，需要时由用户在系统登录项中批准后台助手；成功启用新方式后会关闭旧登录项，待批准时可单独关闭旧选项。

`QuotaPetLauncher` 等待 `NSWorkspace` 进程事件，不循环扫描，不读取额度。只有桌面自动带起的会话随最后一个 Claude/Codex 桌面端关闭；手动或 CLI 唤起后保留运行。退出会暂停桌面自动带起，直到下次手动/CLI 激活。启用与暂停是不同状态。

CLI 集成由用户主动 `source` 当前安装 bundle 的 `Contents/Resources/quotapet-shell.sh`。系统 `/Applications` 与用户 `~/Applications` 均可；不要依赖 PATH 查找助手、写死另一份 App 路径，或自动改用户的 rc 文件。已有 alias/function 不覆盖，CLI 的参数、输入输出、TTY 和退出码必须保持；助手失败不阻塞真实命令。

## 构建与验证

在本目录执行，使用 Command Line Tools / SwiftPM，不需要 Xcode：

```bash
swift build
make check
make app
make dump
make demo
make relay-previews
```

在有图形会话的 Mac 上，先用 `make app` 打包，然后运行 `python3 scripts/check-launch-activation.py --run-gui`，可验证随包助手能够冷启动测试 App，并向已打开的同一进程递送第二次终端唤起事件。测试只使用临时 App。

`make check` 包含 shell 集成测试和 Swift debug 可执行自检，使用 `@testable import`，不要加 `-c release`。隔离构建目录宜放在本目录 `.build/` 下，便于图片资源发现。运行前先检查仓库的 `CLAUDE.md` 与当前脚本。

`make app` 生成 `build/QuotaPet.app`，不等于安装或启动。`make install` 是显式安装流程，会替换目标位置的旧 App 并打开新版；先查看 Makefile，不能把它当成无副作用的编译命令。`make release` 生成通用 zip，并要求干净工作树与隐私检查；未获请求不要发布。

修改启动逻辑时覆盖桌面关闭、手动保活、CLI 并发激活、待批准登录项与助手失败。shell 集成测试必须用临时假 CLI / 假助手，不启动用户的真实程序。UI 预览须使用合成数据，并检查实际产物。

## 历史与贡献

旧版完整架构、估算实验、重绘说明在[历史开发文档](https://github.com/chd44/claude-quota-pet/blob/8d155d6/QuotaPet/README.md)和[历史 CLAUDE.md](https://github.com/chd44/claude-quota-pet/blob/8d155d6/CLAUDE.md)。历史内容与源码中的旧实现不是正常模式的需求。

请使用合成 fixtures，不提交真实日志、凭据、账户截图或本机绝对路径。不绕过隐私钩子；修改相关规则后运行 `scripts/check-privacy-rules.sh`。反馈与许可证见[首页](../README.md)。
