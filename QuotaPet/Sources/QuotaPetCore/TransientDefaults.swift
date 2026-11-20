import Foundation

public final class TransientDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private var fallback: [String: Any] = [:]
    public let domainName: String
    public init() {
        domainName = "dev.quotapet.volatile.\(UUID().uuidString)"
        super.init(suiteName: domainName)!
    }
    public override func set(_ value: Any?, forKey key: String) { values[key] = value }
    public override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    public override func object(forKey key: String) -> Any? { values[key] ?? fallback[key] }
    public override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    public override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    public override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    public override func register(defaults: [String: Any]) { fallback.merge(defaults) { _, new in new } }
    public override func synchronize() -> Bool { true }
}
