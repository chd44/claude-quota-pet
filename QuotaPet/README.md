# QuotaPet 开发说明

QuotaPet 启动后立即通过官方 CLI 的交互式 `/usage` 读取 agy 和 Claude 的真实额度，此后每 15 分钟刷新，三家都在后台保持读数，切换页签不清空、不重读；最近一次可用读数缓存在本机设置里，有效期内重启也先显示；只执行专用斜杠命令，不把 `/usage` 交给模型，不调用私有端点。Claude 和 Codex 也显示官方读数（2026-11-20/21 用户同意放开）：Claude 通过官方 Claude Code CLI 的交互式 `/usage` 读取（`--safe-mode --strict-mcp-config --tools ""`，专用空目录，只发这一条斜杠命令，读完删除这次产生的会话文件），之后每 15 分钟一次；`~/.claude/projects` 里有对话文件写入（只看文件事件，不读内容）时，活动停下 45 秒后自动再读，连续干活时最多每 3 分钟一次；手动刷新两次之间至少 30 秒；超过 15 分钟的读数即未知；Codex 只取 `~/.codex` 会话日志里服务器给的 `rate_limits`（百分比和重置时间），日志一写入就更新；超过 1 小时的读数仍显示上次的数字，但整体变灰并标明时间，宠物用中性表情。QuotaPet 自己不联网、不读凭据和对话内容，不做本机估算。缺少读数、读取失败或读数过期时显示未知并使用中性形象；不通过手动选择额度或模拟数据驱动正常模式。

## 正常模式与演示边界

- Claude：[官方用量页](https://claude.ai/settings/usage)。
- Codex：[官方用量页](https://chatgpt.com/codex/settings/usage)。
- agy：[官方 `/usage` 文档](https://antigravity.google/docs/cli/commands/usage)，装有官方桌面 App 时也可以打开它的设置查看额度。启动后及之后每 15 分钟通过官方 CLI 交互式 `/usage` 获取读数（和 Claude 共用 `CLIQuotaMonitor` 调度）。
- Claude：`ClaudeQuotaProbe` 在伪终端里运行官方 Claude Code CLI（固定位置：`~/.local/bin/claude` 等，或桌面端自带且带 `.verified` 的最新版本），用 `VirtualTerminal` 还原屏幕，只在认得的画面上按键（主题、安全须知、只对专用空目录的信任框），读到「Refreshing」消失后的最终面板再由 `ClaudeUsageParser` 解析。agy 和 Claude 共用 `CLIQuotaMonitor` 调度。Codex：`UsageStore` 只跑 `CodexProvider`。不放旧 `ClaudeProvider`，不读 Claude Code 对话日志、不做实时估算，也不接额度提醒。
- `--dump` 只输出入口；`--probe-cli` 拒绝执行。不要为兼容旧参数恢复额度查询。
- `--demo`、relay previews、`--render-official-previews` 使用合成数据。旧的估算、命令行补查和提醒逻辑只供自检与演示。

「5 小时」不是跨账户不变量。套餐规则及是否存在该窗口以各家官方账户界面为准。agy 使用官方交互式 `/usage`；不得回退为模型提示、CLI 消耗请求、本机日志、第三方中间层或私有端点。

## agy 静态美术与发布

0.4.2（build 15）在 `Resources/Pets/agy` 下包含三款的六张中性 PNG：默认棱镜礼装（Prism Regalia）的 `menu.png` / `panel.png`，反重力飞行员（Zero-G Pilot）的 `pilot-menu.png` / `pilot-panel.png`，绣球花匠（Hydrangea Gardener）的 `gardener-menu.png` / `gardener-panel.png`。每组分别用于菜单栏头像和额度面板半身像。图片在本地加载；有效 agy 真实读数可切换额度状态。切换官方入口时更新，Claude 和 Codex 各自记住选过的形象，切回 agy 也恢复上次 agy 款式。agy 形象参考 ZipZipPipe 的「Gemini 娘」。[角色原设](https://www.bilibili.com/opus/1233069202138464289)

agy 的额度以 Gemini 组为准（`AgyQuotaPresentation.primaryWindow`：这组里用得最多的窗口），菜单栏数字、切换条和宠物表情都用它；面板里仍列出全部模型组。补充状态图（刚恢复、歇着、有点慌、有点懵、醒过来中、被戳、闹别扭）和需要重画的「元气满满」「快撑不住」见 [design/agy-states](../design/agy-states/README.md)，用 `scripts/import-agy-art.sh` 导入；缺图或登记过的坏图（`OfficialPetChoice.brokenArtDigests`）退回这款的基础图。

`scripts/agy-asset-names.sh` 是打包、归档检查与 CI fixture 共用的唯一清单：三款前缀（空、`pilot-`、`gardener-`）× `menu` / `panel` × 中性或 `energetic` / `tired` / `exhausted` / `sleeping` 后缀，共 30 张必需 PNG；`--optional` 列出 42 张可补充的状态图，有就打包，没有不报错。例如 `pilot-menu-tired.png`。`build-app.sh` 按共享清单显式复制至 App 的 `Contents/Resources/Pets/agy/`，不复制参考图或其他中间产物。`check-release-archive.sh` 在解压后的最终 zip 中检查 30 图存在且格式为 PNG，agy 目录拒绝其他文件，旧形象的 portrait/icon 文件规则保留。发包时还需核对源图与包内图的 SHA-256 一致，并在图形会话查看三款菜单栏和面板实际显示，以及切换服务后是否恢复所选款式。此处版本与图形验收不代表已发布。

## 启动方式

正常模式由 `OfficialMenuController` 管理：左键弹出 `OfficialOverviewView`（沿用旧总览的布局与 `UsageBar` 进度条），右键弹出操作菜单；图标不可见时 `reveal()` 改用当前屏幕的浮动面板。可用 `swift run QuotaPet --render-official-previews <dir>` 渲染合成读数的面板预览。桌面联动在「宠物菜单 → 启动方式」主动开启，需要时由用户在系统登录项中批准后台助手；成功启用新方式后会关闭旧登录项，待批准时可单独关闭旧选项。

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
