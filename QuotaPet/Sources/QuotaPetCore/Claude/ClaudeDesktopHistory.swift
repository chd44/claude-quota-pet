import Foundation

/// Claude 桌面端记录的一次官方额度读数
public struct PlanUsageSample: Equatable, Sendable {
    public var time: Date
    public var org: String?
    /// 原始字段，目前见过 fh（5 小时）和 sd（每周），都是整数百分比
    public var values: [String: Double]

    public init(time: Date, org: String?, values: [String: Double]) {
        self.time = time
        self.org = org
        self.values = values
    }

    public var session: Double? { values["fh"] }
    public var weekly: Double? { values["sd"] }
}

/// 读取 ~/Library/Application Support/Claude/plan-usage-history.json。
/// 桌面端运行时大约每 15 分钟追加一条：{"t": 毫秒时间戳, "org": 组织, "u": {"fh": 23, "sd": 24}}
public enum ClaudeDesktopHistory {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
    }

    public enum ParseError: LocalizedError {
        case unexpectedFormat

        public var errorDescription: String? {
            tr("文件格式和预期不一样（桌面端可能更新了）", "unexpected file format (the desktop app may have been updated)")
        }
    }

    /// 返回有读数的样本（按时间排序），只保留最近一次出现的组织，切换账号时不会混在一起
    public static func parse(_ data: Data) throws -> [PlanUsageSample] {
        current(try parseAll(data), now: .distantFuture)
    }

    /// 现在能用的样本：时间不晚于 now 的（未来时间戳的读数等时间追上了才参与），只保留其中最近一次出现的组织。
    /// 组织要在按时间筛过之后再定：不然一条未来的、别的账号的读数会把真正的账号挤掉
    public static func current(_ samples: [PlanUsageSample], now: Date) -> [PlanUsageSample] {
        var result = samples.filter { $0.time <= now }
        if let org = result.last?.org { result = result.filter { $0.org == org } }
        return result
    }

    /// 文件里的全部读数（按时间排序），不筛时间也不筛组织：这两样要按使用时的现在来筛，见 current
    public static func parseAll(_ data: Data) throws -> [PlanUsageSample] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["samples"] as? [[String: Any]] else { throw ParseError.unexpectedFormat }
        var samples: [PlanUsageSample] = []
        for item in raw {
            guard let t = (item["t"] as? NSNumber)?.doubleValue, let u = item["u"] as? [String: Any] else { continue }
            var values: [String: Double] = [:]
            for (key, value) in u {
                if let n = value as? NSNumber { values[key] = n.doubleValue }
            }
            if values.isEmpty { continue }
            samples.append(PlanUsageSample(time: Date(timeIntervalSince1970: t / 1000), org: item["org"] as? String, values: values))
        }
        samples.sort { $0.time < $1.time }
        return samples
    }
}
