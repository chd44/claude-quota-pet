import Foundation

/// Destinations for end users. These URLs are opened in the browser only on demand.
public enum OfficialQuotaEntry: CaseIterable {
    case claude, codex, antigravity

    public var url: URL {
        switch self {
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        case .codex: return URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .antigravity: return URL(string: "https://antigravity.google/docs/cli/commands/usage")!
        }
    }

    public var title: String {
        switch self {
        case .claude: return tr("Claude 用量", "Claude usage")
        case .codex: return tr("Codex 用量", "Codex usage")
        case .antigravity: return tr("Antigravity (agy) · /usage 使用说明", "Antigravity (agy) · /usage guide")
        }
    }
}
