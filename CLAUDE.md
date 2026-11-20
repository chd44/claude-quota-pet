# CLAUDE.md

本仓库当前产品边界（2026-11-20，0.4.3 / build 16）：QuotaPet 启动后立即通过官方 CLI 的交互式 `/usage` 读取 agy 和 Claude 的真实额度，此后每 15 分钟刷新，三家都在后台保持读数，切换页签不清空、不重读；最近一次可用读数缓存在本机设置里，有效期内重启也先显示；只执行专用斜杠命令，不把 `/usage` 交给模型，不调用私有端点。Claude 和 Codex 也显示官方读数（2026-11-20/21 用户同意放开）：Claude 通过官方 Claude Code CLI 的交互式 `/usage` 读取（`--safe-mode --strict-mcp-config --tools ""`，专用空目录，只发这一条斜杠命令，读完删除这次产生的会话文件），之后每 15 分钟一次；`~/.claude/projects` 里有对话文件写入（只看文件事件，不读内容）时，活动停下 45 秒后自动再读，连续干活时最多每 3 分钟一次；手动刷新两次之间至少 30 秒；超过 15 分钟的读数即未知；Codex 只取 `~/.codex` 会话日志里服务器给的 `rate_limits`（百分比和重置时间），日志一写入就更新；超过 1 小时的读数仍显示上次的数字，但整体变灰并标明时间，宠物用中性表情。QuotaPet 自己不联网、不读凭据和对话内容，不做本机估算。缺少读数、读取失败或读数过期时显示未知并使用中性形象；不通过手动选择额度或模拟数据驱动正常模式。 不读取第三方额度或凭据，不猜套餐/五小时窗口是否存在（以官方读数里出现的窗口为准）。旧的估算、命令行补查、提醒等实现只用于合成演示和自检，不得接回正常模式。

## 环境与命令

本机只有 Command Line Tools，没有完整 Xcode；不要用 `xcodebuild` 或 iOS 模拟器。Swift 命令在 `QuotaPet/` 下运行；SwiftPM 语言模式以 `Package.swift` 为准。

```bash
swift build
make check                    # debug 自检，不加 -c release
make app                      # 仅构建 bundle
make dump                     # 只列官方入口
make demo                     # 合成额度与动态宠物演示
make relay-previews           # 合成接力预览
```

`--probe-cli`（旧的命令行补查：给模型发请求读响应头）必须拒绝执行，不得恢复。正常模式读 Claude 额度只用交互式 `/usage`（见上），不发模型请求。`--dump` 不读取真实额度。旧 `usage_lab.py`、providers、估算、提醒与动态心情是历史实验/演示代码，不是正常运行的数据流。不要因兼容旧文档而恢复它们。

构建缓存可放 `QuotaPet/.build/<任务名>`，避免并发争用且保留图片资源发现路径。改代码后运行相称自检；预览使用合成数据并查看产物。`make install` 会安装/替换 App 并打开新版，`make release` 会生成通用包，均不等于只读验证；没有请求不要安装、提交、推送或发布。

## 官方入口与额度规则

- Claude：<https://claude.ai/settings/usage>
- Codex：<https://chatgpt.com/codex/settings/usage>
- agy：<https://antigravity.google/docs/cli/commands/usage>；可打开已安装的 Antigravity 桌面 App，或在官方 CLI 内输入 `/usage`，QuotaPet 启动后及每 15 分钟执行官方 CLI 交互式 `/usage`。

QuotaPet 启动后立即通过官方 CLI 的交互式 `/usage` 读取 agy 和 Claude 的真实额度，此后每 15 分钟刷新，三家都在后台保持读数，切换页签不清空、不重读；最近一次可用读数缓存在本机设置里，有效期内重启也先显示；只执行专用斜杠命令，不把 `/usage` 交给模型，不调用私有端点。Claude 和 Codex 也显示官方读数（2026-11-20/21 用户同意放开）：Claude 通过官方 Claude Code CLI 的交互式 `/usage` 读取（`--safe-mode --strict-mcp-config --tools ""`，专用空目录，只发这一条斜杠命令，读完删除这次产生的会话文件），之后每 15 分钟一次；`~/.claude/projects` 里有对话文件写入（只看文件事件，不读内容）时，活动停下 45 秒后自动再读，连续干活时最多每 3 分钟一次；手动刷新两次之间至少 30 秒；超过 15 分钟的读数即未知；Codex 只取 `~/.codex` 会话日志里服务器给的 `rate_limits`（百分比和重置时间），日志一写入就更新；超过 1 小时的读数仍显示上次的数字，但整体变灰并标明时间，宠物用中性表情。QuotaPet 自己不联网、不读凭据和对话内容，不做本机估算。缺少读数、读取失败或读数过期时显示未知并使用中性形象；不通过手动选择额度或模拟数据驱动正常模式。

五小时限制不适用于所有账户。依据[OpenAI 定价](https://learn.chatgpt.com/docs/pricing)及[Claude Help](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)，部分账户没有五小时窗口。套餐变更和切换账号后仍以官方界面为准，正常模式不缓存或推算本地套餐状态。

## 启动与 shell 集成

- 手动打开主程序即可用：左键额度面板，右键操作菜单；新用户不应被静默注册登录项。
- 桌面联动须在「宠物菜单 → 启动方式」主动开启。系统要求批准时提供明确说明/入口；成功切换后注销旧登录项，待批准时保留原选择。
- 后台助手只等待 `NSWorkspace` 事件；不轮询进程、日志或网络。桌面自动带起的主程序随最后一个相关桌面端关闭；手动或 CLI 激活后保活。
- 主动退出暂停桌面自动带起，下一次手动/CLI 激活恢复；后台助手是否启用仍由用户开关控制。
- 用户主动 source 实际 bundle 的 `Contents/Resources/quotapet-shell.sh`，支持 `/Applications` 与 `~/Applications`；不写用户 rc 文件、不从 PATH 选择任意助手、不覆盖既有 alias/function。
- 保留 CLI 参数、标准输入输出、TTY 和退出码；助手失败不阻塞真实 CLI。测试使用临时假程序，覆盖并发唤醒和桌面关闭竞态。

## 隐私与维护

仓库公开。不要读取真实日志/凭据来做测试，不提交 `.jsonl`、真实截图、邮箱或本机路径；使用合成 fixtures。保留 `.githooks` 隐私检查，不使用 `--no-verify` 绕过。发包前验证最终 archive 不含真实数据及本机路径。

功能、命令与启动设置变化时同步 `README.md`、`README.en.md` 和 `QuotaPet/README.md`。当前用法见[开发说明](QuotaPet/README.md)。旧估算架构与美术工作流请查[历史 CLAUDE.md](https://github.com/chd44/claude-quota-pet/blob/8d155d6/CLAUDE.md)，不要把历史行为当成当前需求。

## 什么时候用哪个技能

| 场景 | 技能 |
|---|---|
| 改完代码要确认能用 | `quotapet-verify`（编译 + 自检 + 渲染预览图并查看） |
| 更新模型价格或加新模型 | `claude-api`（查当前价格），然后同步改 `usage_lab.py` |
| 一个功能写完 | `/simplify`；改动较大就用 `/code-review` |
| push 之前 | `/security-review`：重点看有没有联网、读凭据、真实数据进 git |
