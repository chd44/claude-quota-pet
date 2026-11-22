# QuotaPet

[中文](README.md)

At startup QuotaPet reads agy and Claude usage through each official CLI’s interactive `/usage` command, then refreshes every 15 minutes; all three services keep their readings in the background, so switching tabs never clears or reloads them, and the last usable reading is cached locally so a relaunch within its validity shows it at once. It executes only that dedicated slash command, never sends `/usage` to a model, and never calls private endpoints. Claude and Codex show official readings too: QuotaPet runs the official Claude Code CLI’s interactive `/usage` (`--safe-mode --strict-mcp-config --tools ""` in a dedicated empty folder, sending only that slash command and giving the query its own session ID and deleting only that session’s file afterwards, keeping the shared session folder; if the CLI is too old for that option it reports this at once and deletes nothing; if the CLI’s last screen is a sign-in prompt it asks you to sign in, and leftover usage text on screen is not taken as a reading), then every 15 minutes, and again 45 seconds after Claude Code activity stops (it watches only file events in `~/.claude/projects`, never contents; at most every 3 minutes during continuous work); manual refreshes are at least 30 seconds apart; a reading older than 15 minutes is unknown. For Codex it parses the local session logs line by line and extracts only the `rate_limits` (percentages and reset times) its server reports and the times of turn-start and usage events (to tell it is in use), without storing or showing any message text, updating whenever the logs change; a reading older than an hour still shows its numbers, greyed out with its age, and the pet stays neutral. It follows the service in use (switchable in Settings, on by default): real writes to Claude Code session files in `~/.claude/projects` plus `~/.claude/history.jsonl` (appended when a prompt is submitted; metadata only), each Codex turn recorded in its session logs (only the record type and time, with or without quota data), and real writes in `~/.gemini/antigravity-cli/conversations` and `~/.gemini/antigravity/conversations` for agy count as activity within 10 minutes, timed by when the write or record happened (for Claude and agy it checks only file events and metadata — file ID, size, modification time and the system’s content generation ID — never contents; permission changes, modification-time-only touches, new folders, deletions, moving old files out, pure renames, hidden files such as .DS_Store, and maintenance writes such as plugins or caches don’t count; a whole session folder moved in is checked file by file; a symlinked conversations folder is followed; modification times in the future don’t count; ties go to Claude, Codex, agy in that order); with one service active it follows that one, with several it follows the one the user most recently started something in (a new Codex turn, a submitted Claude prompt, a new Claude or agy session, timed by when the session was created; background replies, subagent writes, Codex sub-agents and old-task usage, and late notifications can’t take it back) for as long as that service stays active (activity within 10 minutes, long tasks included), then falls back to the latest activity; writes made while QuotaPet’s own usage query process is running never count as a start, writes after it ends do; for agy it also reads newly appended lines of each conversation’s step log `brain/<conversation>/.system_generated/logs/transcript.jsonl`, looking only at the source, type and time that precede the content (the content is never parsed or stored): a message the user sent (`USER_EXPLICIT`/`USER_INPUT`) counts as a start, including when continuing an existing conversation, while model replies, system notices and background steps don’t; it never switches while the panel or the right-click menu is open (it re-checks as soon as they close, and again when you turn following back on or a reading changes; the menu’s Refresh Now refreshes the service shown when the menu opened), or within 10 minutes of a manual choice. The time of each service’s latest active start (service name and time only) is kept in local settings, so a long task keeps its original start order after a restart; a Claude prompt submitted or an agy message sent while QuotaPet was not running still counts as that service’s latest active start at its submission time, even if older than 10 minutes, once that service has session writes during this run (still writing at startup, or resuming later), within 24 hours (at startup, before the first Claude usage query, QuotaPet notes the modification time of `history.jsonl`; agy step records are searched once with a 24-hour look-back at its first session write; the CLI rewriting `history.jsonl` during QuotaPet’s own query is not a session write); start records dated in the future are dropped for good (time is checked before a record takes a kept slot; for Codex each dropped record is remembered in local settings by a fingerprint of its session file name plus its time, at most 512 for 7 days, with no paths or contents, so neither a rescan nor a restart reads it back, while genuinely new records in that session still count); the start and end times of QuotaPet’s own Claude queries are kept locally too, and the previous run’s query is pinned at startup, so even after this run’s query overwrites the setting, writes left by the previous query are not taken for a user prompt after a restart. agy is also re-read after its activity stops. QuotaPet itself makes no network calls, reads no credentials or conversation content, and estimates nothing locally. Missing, failed, or expired readings are unknown and use the neutral appearance; manually selected quotas and simulated data never drive normal mode.

Left-click the menu-bar pet for the usage panel; right-click for actions (official links, pet appearance, menu-bar percentage, startup, language, quit). The panel shows the pet and current state on top, then a Claude / Codex / agy switcher; the pet and menu bar follow the service you pick. The agy page draws every 5-hour and weekly window of each model group from the official `/usage` as a progress bar, shown as used = 100 − official remaining, with the tightest window marked; the menu bar shows that window’s used percentage beside the pet (orange from 75%, red from 90%). The Claude and Codex pages use the original cards: official percentage, reading time, reset time, even-pace marker and the rate computed from official readings; without a usable reading they show unknown and a button to the official usage page. The gear in the panel opens Settings (pet, menu bar, startup, language). Claude and Codex each remember their pet; switching back to agy restores your last agy choice. Under **Pet appearance**, choose the default **Prism Regalia** (棱镜礼装), **Zero-G Pilot** (反重力飞行员), or **Hydrangea Gardener** (绣球花匠). Version 0.4.2 (build 15) includes 30 local PNGs: six neutral images and 24 usage-state images. They are inspired by ZipZipPipe’s Gemini catgirl. [Original character design](https://www.bilibili.com/opus/1233069202138464289)

| Service | Official destination |
|---|---|
| Claude | [Settings → Usage](https://claude.ai/settings/usage) |
| Codex | [Settings → Usage](https://chatgpt.com/codex/settings/usage) |
| Antigravity (agy) | [Official `/usage` documentation](https://antigravity.google/docs/cli/commands/usage); run `/usage` inside the agy CLI for your account |

Links open in your default browser. The official page handles sign-in and readings. When Antigravity is installed, open the official app and view usage in Settings. The menu also links to the official CLI guide for `/usage`.

## Plans and five-hour windows

Five-hour limits are not universal. As checked on November 20, 2026, [OpenAI pricing](https://learn.chatgpt.com/docs/pricing) says Pro currently has no five-hour limit; [Claude Help](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work) says verified Ultra accounts have no five-hour limit. Your account's official usage page determines the limits that apply.

QuotaPet does not guess plans, quota windows, or percentages, and never treats expired readings as current usage. After switching accounts only the new account’s readings count; for plan changes, the official page is the reference. agy readings use only the official interactive CLI command described above; intermediary services, local logs, and internal endpoints are not substitutes.

## Using and starting the app

Requires macOS 14 or later. Install in `/Applications` or `~/Applications`, then open the app manually. New users are not silently enrolled in login items.

If QuotaPet is running and you can’t see its menu bar icon, reopen it in Finder: the usage panel opens under the icon when it is visible, or floats at the top right of the current screen when the notch or other icons hide it.

- Desktop auto-launch is opt-in under **pet menu → Startup**. Approve the background helper in system login settings if requested.
- The helper waits for `NSWorkspace` events from Claude/Codex desktop apps. It does not repeatedly scan processes or request quotas. A desktop-started main app exits after the last relevant desktop closes; manual and CLI activations keep it running.
- You can open the usage panel manually at any time. Enabling desktop startup turns off the old main-app login item once the helper is approved at registration. If approval is pending, you can turn the previous option off in the Startup menu.
- Explicitly quitting pauses desktop auto-launch until a manual or CLI activation resumes it. The startup switch still controls whether the helper is enabled.

For terminal activation, explicitly source the script inside your **actual installed bundle** from an interactive bash/zsh session:

```bash
source "/Applications/QuotaPet.app/Contents/Resources/quotapet-shell.sh"
# For a user Applications installation, use this instead:
source "$HOME/Applications/QuotaPet.app/Contents/Resources/quotapet-shell.sh"
```

The script requests an app launch when you invoke `claude` or `codex`, preserving arguments, input/output, and exit codes. Existing aliases or functions are kept, with a skip message. It does not edit shell startup files or invoke an official CLI to fetch quotas.

## Build and checks

SwiftPM and Command Line Tools are sufficient; full Xcode is not required. Run from `QuotaPet/`:

```bash
swift build
make check
make app       # build/QuotaPet.app
make dump      # official destinations only; no real usage reads
make demo      # synthetic data, not your account
make relay-previews  # synthetic relay previews
```

`--probe-cli` is disabled and refuses to run without issuing a probe. `--demo` and relay previews retain synthetic examples of the historical quota UI. Old screenshots do not represent normal mode or real readings. See the [developer guide](QuotaPet/README.md).

## History, contributing, and license

The historical estimator, quota alerts, and animated quota-driven pet are documented in the [old README](https://github.com/chd44/claude-quota-pet/blob/8d155d6/README.en.md). They are not normal-mode features. The [product plan](docs/PRODUCT_PLAN.md) marks the current boundary. Old scripts and core logic remain for historical research, checks, and synthetic demonstrations.

[Report an issue](https://github.com/chd44/claude-quota-pet/issues/new?template=feedback.yml) or open a PR with reproduction steps and synthetic tests. Do not include real logs, credentials, or account screenshots. Run the relevant checks. This project is not affiliated with Anthropic, OpenAI, or Google.

[MIT License](LICENSE)
