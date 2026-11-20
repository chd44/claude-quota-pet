import Foundation

/// Static artwork selection, separate from the synthetic animated pet families.
/// Existing style values remain valid in the original UserDefaults key.
public struct OfficialPetChoice: RawRepresentable, Equatable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard ["agy", "agy-aurora", "agy-stargazer"].contains(rawValue) || PetStyle(rawValue: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    public static let antigravity = OfficialPetChoice(rawValue: "agy")!
    public static let antigravityChoices = ["agy", "agy-aurora", "agy-stargazer"].map { OfficialPetChoice(rawValue: $0)! }
    public var isAntigravity: Bool { style == nil }
    /// The service whose panel page and menu-bar pet this choice belongs to.
    public var entry: OfficialQuotaEntry {
        guard let style else { return .antigravity }
        return PetStyle.claudeChoices.contains(style) ? .claude : .codex
    }
    public var style: PetStyle? { PetStyle(rawValue: rawValue) }
    public var label: String {
        if let style { return style.label }
        switch rawValue {
        case "agy-aurora": return tr("反重力飞行员", "Zero-G Pilot")
        case "agy-stargazer": return tr("绣球花匠", "Hydrangea Gardener")
        default: return tr("棱镜礼装", "Prism Regalia")
        }
    }
    private var antigravityFilePrefix: String {
        // Keep 0.4.1 preference IDs stable so both the current selection and
        // the separately remembered agy slot adopt their redesigned artwork.
        switch rawValue {
        case "agy-aurora": return "agy/pilot-"
        case "agy-stargazer": return "agy/gardener-"
        default: return "agy/"
        }
    }
    public var menuFile: String {
        style.map { PetSprites.frames(for: .normal, style: $0)[0].icon.file } ?? "\(antigravityFilePrefix)menu.png"
    }
    /// Unknown and neutral readings deliberately keep the original artwork.
    public func menuFile(mood: PetMood) -> String { moodFile(base: menuFile, mood: mood) }
    public func panelFile(mood: PetMood) -> String { moodFile(base: panelFile, mood: mood) }
    private func moodFile(base: String, mood: PetMood) -> String {
        guard isAntigravity, mood != .normal else { return base }
        return String(base.dropLast(4)) + "-\(mood.rawValue).png"
    }

    /// agy 每款都有的五张基础图之外，可以补充的状态图（GPT 补图后放进 Resources/Pets/agy 即生效，缺图时退回基础图）
    public static let optionalAntigravityStates: [String] = ["revived", "resting", "nervous", "confused", "loading", "poke", "pout"]

    /// agy 被戳时的反应图：-poke（被戳一下）/ -pout（连戳闹别扭）。Claude / Codex 用动画表里的反应帧，不走这里
    public func pokeFile(annoyed: Bool, panel: Bool) -> String? {
        guard isAntigravity else { return nil }
        let base = panel ? panelFile : menuFile
        return String(base.dropLast(4)) + (annoyed ? "-pout.png" : "-poke.png")
    }

    /// 0.4.3 带来的坏图：「元气满满」是切错的 2×2 拼图碎片，「快撑不住」是整张拼图或标错的表情。
    /// 按文件内容指纹认：这些图当作缺图（退回基础图）；用 scripts/import-agy-art.sh 重画后指纹变了就自动启用
    public static let brokenArtDigests: Set<String> = [
        "2891f250156205e20d85bfb9abaee9406d1dcf0cabfe2ef8c6ebd415e2a043e0",  // panel-energetic
        "1fad7934666ed784fc5404828b0cf3b071e07c20843d38a1d1c8de2596063884",  // menu-energetic
        "89025cae722ff0409a0247ef5a4e4441b3bbfab044790a247c09dcaf509cea16",  // panel-exhausted
        "c9b1095547ddfc99c4c3384d3ee3d5d55ac3eb1fc987d4daa73a607b6aeec450",  // menu-exhausted
        "29aeedb4ad4bce3dedd644f8cf3d40da27c4813dfa9a6a92237c679509e9153e",  // pilot-panel-energetic
        "74de5018fc9fdcf38a3bd3be86d2c9e7a0876a169763fd4f70e1dfaa3967a6ff",  // pilot-menu-energetic
        "7bbc7e8da9217600a0f2a60a3741a8dc4001bb3373e676fa2e1ffc734ffd928f",  // pilot-panel-exhausted
        "14e8193e8e81b5e2507d80ca91f66744867d803f76c069de3801a0294062430a",  // pilot-menu-exhausted
        "91e35aa6465a3895721f7589bfdd260bc336e4f2978ccafb1f77f6dd6a8b56ab",  // gardener-panel-energetic
        "b48a3ca98de0c35a2553cd94669cff0598ca9c19305035bd1fcd8b1029e0d666",  // gardener-menu-energetic
        "f5b3ad4c2c11685496f92422117c9a1ff2f03a114fec2a1bddaa0c2d75105f2b",  // gardener-panel-exhausted
        "003e2bd2878193dd094f2dc16b1bf2fc7e84976a28736ba9bed47c40648f9a80",  // gardener-menu-exhausted
    ]

    /// 文件不存在时退回这款的基础图（没补的状态图不会变成空白）
    public static func resolved(_ file: String, exists: (String) -> Bool) -> String {
        if exists(file) { return file }
        guard file.hasPrefix("agy/"), let dash = file.range(of: "-[a-z]+\\.png$", options: .regularExpression) else { return file }
        let base = String(file[..<dash.lowerBound]) + ".png"
        return exists(base) ? base : file
    }
    /// 按这家自己的读数算出的心情取图：Claude / Codex 用动画表里这个心情的第一帧，agy 用它的额度状态图
    public func file(mood: PetMood, panel: Bool) -> String {
        if let style {
            let frame = PetSprites.frames(for: mood, style: style)[0]
            return (panel ? frame.portrait : frame.icon).file
        }
        return panel ? panelFile(mood: mood) : menuFile(mood: mood)
    }
    public var panelFile: String {
        style.map { PetSprites.frames(for: .normal, style: $0)[0].portrait.file } ?? "\(antigravityFilePrefix)panel.png"
    }
}

/// Remembers each provider's ordinary pet across agy visits and application relaunches.
public struct OfficialPetSelection: Sendable {
    public private(set) var choice: OfficialPetChoice
    public private(set) var claudeStyle: PetStyle
    public private(set) var codexStyle: PetStyle
    public private(set) var antigravityChoice: OfficialPetChoice

    public init(choice: OfficialPetChoice, claudeStyle: PetStyle, codexStyle: PetStyle, antigravityChoice: OfficialPetChoice = .antigravity) {
        self.choice = choice
        self.claudeStyle = PetStyle.claudeChoices.contains(claudeStyle) ? claudeStyle : .classic
        self.codexStyle = PetStyle.codexChoices.contains(codexStyle) ? codexStyle : .dragon
        self.antigravityChoice = antigravityChoice.isAntigravity ? antigravityChoice : .antigravity
        select(choice)
    }

    public mutating func select(_ choice: OfficialPetChoice) {
        if let style = choice.style {
            if PetStyle.claudeChoices.contains(style) { claudeStyle = style }
            else { codexStyle = style }
        }
        if choice.isAntigravity { antigravityChoice = choice }
        self.choice = choice
    }

    public mutating func select(entry: OfficialQuotaEntry) {
        switch entry {
        case .antigravity: select(antigravityChoice)
        case .claude: select(OfficialPetChoice(rawValue: claudeStyle.rawValue)!)
        case .codex: select(OfficialPetChoice(rawValue: codexStyle.rawValue)!)
        }
    }
}
