# QuotaPet

[English](README.en.md)

QuotaPet 启动后立即通过官方 CLI 的交互式 `/usage` 读取 agy 和 Claude 的真实额度，此后每 15 分钟刷新，三家都在后台保持读数，切换页签不清空、不重读；最近一次可用读数缓存在本机设置里，有效期内重启也先显示；只执行专用斜杠命令，不把 `/usage` 交给模型，不调用私有端点。Claude 和 Codex 也显示官方读数（2026-11-20/21 用户同意放开）：Claude 通过官方 Claude Code CLI 的交互式 `/usage` 读取（`--safe-mode --strict-mcp-config --tools ""`，专用空目录，只发这一条斜杠命令，给这次查询指定会话编号，读完只删除这个编号的会话文件，共享的会话文件夹保留；CLI 版本过旧、不认这个参数时立即提示更新，不删任何文件；CLI 最后显示的是登录提示时提示登录，屏幕上残留的旧额度文字不算读数），之后每 15 分钟一次；`~/.claude/projects` 里有对话文件写入（只看文件事件，不读内容）时，活动停下 45 秒后自动再读，连续干活时最多每 3 分钟一次；手动刷新两次之间至少 30 秒；超过 15 分钟的读数即未知；Codex 逐行解析 `~/.codex` 会话日志，只提取服务器给的 `rate_limits`（百分比和重置时间）、每轮开始记录和用量事件的时间（用来判断正在用），不保存、不展示正文，日志一写入就更新；超过 1 小时的读数仍显示上次的数字，但整体变灰并标明时间，宠物用中性表情。自动跟随正在用的那家（设置页可关，默认开）：Claude 看 `~/.claude/projects` 里会话文件的真实写入和 `~/.claude/history.jsonl`（提交提示词时追加，只看元数据），Codex 看会话日志里每轮的开始记录和用量记录（只取记录类型和时间，带不带额度都算），agy 看 `~/.gemini/antigravity-cli/conversations` 与 `~/.gemini/antigravity/conversations` 里的真实写入（Claude 和 agy 只看文件事件和元数据：文件编号、大小、修改时间和系统的内容代号，不读内容；改权限、只改修改时间、建目录、删除、移走旧文件、只改名字、.DS_Store 等隐藏文件、插件缓存等维护写入不算；整个会话文件夹移进来时核对里面的文件；conversations 是符号链接时跟着它指向的目录），按写入或记录发生的时间算，修改时间在未来的不算，最近 10 分钟有动静的算正在用；同一时刻的按 Claude、Codex、agy 的固定顺序；只有一家时跟它，几家同时在用时跟最近「主动开始」的那家（Codex 新一轮开始、Claude 提交提示词、新建 Claude/agy 会话，新会话按它出生的时间算；已有会话里的后台回复、子任务写入、Codex 子代理和旧任务的用量、旧通知抢不走），只要那家还在用（10 分钟内有动静，长任务也算）就一直跟它，它停下后跟最近有动静的那家；QuotaPet 自己查额度的 CLI 进程运行期间写下的不算主动开始，查询结束后才写的照算；agy 另外逐行读各会话步骤记录 `brain/<会话>/.system_generated/logs/transcript.jsonl` 新追加的行，只看正文（content）之前的来源、类型和时间，正文不解析、不保存：用户自己发的消息（`USER_EXPLICIT`/`USER_INPUT`）算主动开始，回到原会话续聊也认得出，模型回复、系统通知和后台步骤不算（2026-11-22 用户同意放开）；面板或右键菜单开着时不切换，收起后马上按当时的状态补判一次（右键菜单的「立即刷新」刷打开菜单时那家）；重新打开跟随开关、各家读数变化时也会重新判断；手动选择后 10 分钟内不切换；每家最近一次主动开始的时间（只有服务名和时间）记在本机设置里，重启后长任务仍按原来的开始时间排先后；QuotaPet 没运行期间提交的 Claude 提示词、发的 agy 消息即使早于 10 分钟，只要这家在本次运行里有会话写入（启动时仍在写，或之后才恢复写入），也按提交时间算作这家最近一次主动开始（24 小时以内；启动时、第一次查 Claude 额度之前先记下 `history.jsonl` 的修改时间，agy 第一次有会话写入时按 24 小时回看一次步骤记录；只有 QuotaPet 自己查询时 CLI 改写 `history.jsonl` 不算会话写入）；时间在未来的开始记录永久丢弃（先验时间再占保留名额；Codex 的按会话文件名的指纹和记录时间逐条记在本机设置里，最多 512 条、保留 7 天，不存路径和内容，重扫和重启后都不读回来，同一会话之后真正新写的照常算）；QuotaPet 自己查 Claude 额度的起止时间也存在本机，启动时固定上一次运行的那次，本次查询覆盖设置后，重启后的补扫仍不会把那次查询留下的写入当成用户的提示词。agy 有动静时也像 Claude 一样在停下后自动重读。QuotaPet 自己不联网、不读凭据和对话内容，不做本机估算。缺少读数、读取失败或读数过期时显示未知并使用中性形象；不通过手动选择额度或模拟数据驱动正常模式。

左键点菜单栏宠物打开额度面板，右键打开操作菜单（官方入口、宠物形象、菜单栏百分比、启动方式、语言、退出）。面板顶部是宠物和当前状态，下面用 Claude / Codex / agy 切换条选择查看哪家，宠物和菜单栏也跟着这家。agy 页按官方 `/usage` 把每个模型组的五小时和每周窗口都画成进度条，数字是「已用 = 100 − 官方剩余」，并标出最紧张的窗口；菜单栏在宠物旁显示最紧张窗口的已用百分比（75% 起标橙、90% 起标红）。Claude 和 Codex 页沿用旧版卡片：官方百分比、读数时间、重置时间、平均节奏，以及按官方读数算的速度；没有可用读数时显示未知并给官方用量页按钮。面板右上的齿轮打开设置页（宠物形象、菜单栏、启动方式、语言）。Claude 和 Codex 各自记住选过的形象，切回 agy 也恢复上次选择的款式。可以在「宠物形象」里选择三款 agy 形象：默认的棱镜礼装（Prism Regalia）、反重力飞行员（Zero-G Pilot）、绣球花匠（Hydrangea Gardener）。0.4.2（build 15）包含三款共 30 张本地 PNG（6 张中性图与 24 张额度状态图）；参考了 ZipZipPipe 的「Gemini 娘」。[角色原设](https://www.bilibili.com/opus/1233069202138464289)

| 服务 | 官方查看入口 |
|---|---|
| Claude | [设置 → 用量](https://claude.ai/settings/usage) |
| Codex | [设置 → 用量](https://chatgpt.com/codex/settings/usage) |
| Antigravity（agy） | [官方 `/usage` 文档](https://antigravity.google/docs/cli/commands/usage)，在 agy CLI 中输入 `/usage` 查看当前账户 |

网页由默认浏览器打开，登录和实际读数由官方页面负责。安装了 Antigravity 时可直接打开官方 App，在设置里查看用量。终端用户可打开 `/usage` 的官方说明。

## 为什么不固定显示「5 小时」

套餐和账户规则会变，五小时窗口并不适用于所有人。按 2026-11-20 核验的[OpenAI 定价说明](https://learn.chatgpt.com/docs/pricing)，Codex Pro 当前没有五小时限制；[Claude Help](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work) 也说明已验证的 Ultra 账户没有五小时限制。具体限制以当前账户的官方用量页为准。

QuotaPet 不猜测套餐、额度窗口和百分比，不把过期读数当作当前额度。切换账号后只看新账号的读数；升级或降级以官方页面为准。agy 仅使用上述官方 CLI 交互式命令；不使用中间服务、内部接口或本机日志替代。

## 使用与启动

需要 macOS 14 或以上。下载后将 App 放入 `/Applications` 或 `~/Applications`，手动打开即可使用。不会自动替新用户打开登录项。

菜单栏里找不到正在运行的宠物时，在 Finder 里再次打开 QuotaPet：图标可见时在它下面弹出额度面板；被刘海或其他图标挤掉时，同一个面板会浮现在当前屏幕右上角。

- 桌面联动需要主动在「宠物菜单 → 启动方式」开启；系统要求时，在登录项设置中批准后台助手。
- 助手通过 `NSWorkspace` 事件等待 Claude/Codex 桌面端启动，不循环扫描进程，也不查询额度。桌面自动带起的主程序在最后一个相关桌面端退出后关闭；手动或 CLI 唤起的程序保留运行。
- 额度面板可随时手动打开。开启桌面联动成功后，会关闭旧版主程序的登录自启；若 macOS 要求批准，旧设置先保留，可从菜单单独关闭。
- 点「退出」会暂停桌面自动带起；再次手动或 CLI 唤起后恢复。是否启用后台助手仍由启动方式开关决定。

终端用户可在当前交互式 bash/zsh 会话中，主动加载**实际安装的 bundle** 内脚本，例如：

```bash
source "/Applications/QuotaPet.app/Contents/Resources/quotapet-shell.sh"
# 如果装在用户 Applications，改用这一条：
source "$HOME/Applications/QuotaPet.app/Contents/Resources/quotapet-shell.sh"
```

脚本只在运行 `claude` / `codex` 时请求唤起 QuotaPet，保留参数、标准输入输出和返回码；已有同名 alias/function 时会跳过并提示。不会修改 `.zshrc`、`.bashrc` 等启动文件，也不会调用官方 CLI 查询额度。

## 构建与验证

SwiftPM + Command Line Tools 即可，不需要完整 Xcode。在仓库的 `QuotaPet/` 目录执行：

```bash
swift build
make check
make app       # 生成 build/QuotaPet.app
make dump      # 只列官方入口，不读取真实额度
make demo      # 合成数据演示，不代表当前账户
make relay-previews  # 合成数据接力预览
```

`--probe-cli` 已禁用并拒绝执行，不会发出探测请求。`--demo` 和 relay previews 保留旧额度界面的假数据演示；旧截图不能视为正常模式或真实读数。详见[开发说明](QuotaPet/README.md)。

## 历史、贡献与许可证

原日志估算、额度提醒、动态宠物等设计保留在[历史 README](https://github.com/chd44/claude-quota-pet/blob/8d155d6/README.md)，不代表当前正常模式；[产品规划](docs/PRODUCT_PLAN.md) 已注明新边界。旧实验脚本与核心逻辑供历史研究、自检和合成演示，不接入正常模式。

欢迎[反馈问题](https://github.com/chd44/claude-quota-pet/issues/new?template=feedback.yml)或提交 PR。请说明触发条件，使用合成测试数据，不提交真实日志、凭据或账户截图；修改后运行相关自检。项目与 Anthropic、OpenAI、Google 均无隶属关系。

[MIT License](LICENSE)
