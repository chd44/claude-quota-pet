import AppKit

@MainActor
enum StatusItemPlacement {
    private static let name = "QuotaPet"
    private static let positionKey = "NSStatusItem Preferred Position \(name)"
    private static let backupKey = "statusItemPosition"

    static func makeItem(length: CGFloat) -> NSStatusItem {
        restore()
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = name
        return item
    }

    /// AppKit may remove the position when hiding the item. Only seed a missing
    /// position so a user's Command-dragged placement survives an upgrade.
    static func restore(_ defaults: UserDefaults = .standard) {
        if defaults.object(forKey: positionKey) == nil {
            defaults.set(defaults.object(forKey: backupKey) ?? 0, forKey: positionKey)
        }
    }

    static func remember(_ defaults: UserDefaults = .standard) {
        if let position = defaults.object(forKey: positionKey) {
            defaults.set(position, forKey: backupKey)
        }
    }
}
