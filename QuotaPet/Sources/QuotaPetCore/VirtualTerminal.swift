import Foundation

/// 一块内存里的终端屏幕：把官方 CLI 的输出（光标移动、清行、局部重画）还原成每一行实际显示的文字。
/// 只实现交互式 CLI 用到的那一小部分 VT100 控制序列；认不得的序列忽略，不会把它们当成文字。
/// 行列数要和启动 CLI 时伪终端的窗口大小一致。
public struct VirtualTerminal: Sendable {
    public let rows: Int
    public let columns: Int
    private var screen: [[Character]]
    private var row = 0
    private var column = 0
    private var saved = (0, 0)
    /// 切入备用屏幕（?1049h / ?47h / ?1047h）时暂存主屏幕内容与光标，退出备用屏时还原
    private var primaryBuffer: (screen: [[Character]], row: Int, column: Int, saved: (Int, Int))?
    /// 上一次没处理完的字节（一个控制序列或 UTF-8 字符被切成两段送来）
    private var pending: [UInt8] = []

    public init(rows: Int = 60, columns: Int = 160) {
        self.rows = rows
        self.columns = columns
        screen = Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    private func blankScreen() -> [[Character]] {
        Array(repeating: Array(repeating: " ", count: columns), count: rows)
    }

    /// 屏幕上的每一行（去掉行尾空格）
    public var lines: [String] { screen.map { String($0).replacingOccurrences(of: "\u{0}", with: "").trimmingTrailing() } }

    /// 整屏文字，空行去掉，连续空白压成一个空格：用来判断现在停在哪个画面
    public var normalizedText: String {
        lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }

    public mutating func feed(_ data: Data) { feed(Array(data)) }

    public mutating func feed(_ text: String) { feed(Array(text.utf8)) }

    public mutating func feed(_ bytes: [UInt8]) {
        let input = pending + bytes
        pending = []
        var i = 0
        while i < input.count {
            let byte = input[i]
            if byte == 0x1B {
                guard let used = escape(input, from: i) else {
                    pending = Array(input[i...])  // 序列还没收完
                    return
                }
                i += used
                continue
            }
            switch byte {
            case 0x0D: column = 0; i += 1; continue
            case 0x0A: lineFeed(); i += 1; continue
            case 0x08: column = max(0, column - 1); i += 1; continue
            case 0x09: column = min(columns - 1, (column / 8 + 1) * 8); i += 1; continue
            case 0..<0x20, 0x7F: i += 1; continue
            default: break
            }
            // 一个 UTF-8 字符
            let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
            guard i + length <= input.count else {
                pending = Array(input[i...])
                return
            }
            let character = String(decoding: input[i..<(i + length)], as: UTF8.self)
            i += length
            for scalar in character.unicodeScalars { put(Character(scalar)) }
        }
    }

    private mutating func put(_ character: Character) {
        if column >= columns {
            column = 0
            lineFeed()
        }
        screen[row][column] = character
        column += 1
        // 中日韩等全角字符占两格
        if let scalar = character.unicodeScalars.first, Self.isWide(scalar), column < columns {
            screen[row][column] = "\u{0}"
            column += 1
        }
    }

    private mutating func lineFeed() {
        if row == rows - 1 {
            screen.removeFirst()
            screen.append(Array(repeating: " ", count: columns))
        } else {
            row += 1
        }
    }

    /// 处理从 start 开始的一个控制序列，返回它占了几个字节；还没收完时返回 nil
    private mutating func escape(_ input: [UInt8], from start: Int) -> Int? {
        guard start + 1 < input.count else { return nil }
        let kind = input[start + 1]
        switch kind {
        case UInt8(ascii: "["):
            var end = start + 2
            while end < input.count, !(0x40...0x7E).contains(input[end]) { end += 1 }
            guard end < input.count else { return nil }
            let parameters = String(decoding: input[(start + 2)..<end], as: UTF8.self)
            csi(parameters, final: input[end])
            return end - start + 1
        case UInt8(ascii: "]"):
            // OSC：到 BEL 或 ESC \ 为止
            var end = start + 2
            while end < input.count {
                if input[end] == 0x07 { return end - start + 1 }
                if input[end] == 0x1B, end + 1 < input.count, input[end + 1] == UInt8(ascii: "\\") { return end - start + 2 }
                end += 1
            }
            return nil
        case UInt8(ascii: "7"):
            saved = (row, column)
            return 2
        case UInt8(ascii: "8"):
            (row, column) = saved
            return 2
        case UInt8(ascii: "M"):
            if row == 0 {
                screen.removeLast()
                screen.insert(blankRow(), at: 0)
            } else {
                row -= 1
            }
            return 2
        case UInt8(ascii: "("), UInt8(ascii: ")"):
            return start + 2 < input.count ? 3 : nil
        default:
            return 2
        }
    }

    private func blankRow() -> [Character] { Array(repeating: " ", count: columns) }

    private mutating func csi(_ parameters: String, final: UInt8) {
        // 私有模式（?、>、=）：只处理备用屏幕切换（?1049 / ?47 / ?1047），其余开关屏幕内容不变
        if let first = parameters.first, "?>=<".contains(first) {
            if first == "?", final == UInt8(ascii: "h") || final == UInt8(ascii: "l") {
                for mode in parameters.dropFirst().split(separator: ";") {
                    switch (final, mode) {
                    case (UInt8(ascii: "h"), "1049"):
                        if primaryBuffer == nil { primaryBuffer = (screen, row, column, saved) }
                        screen = blankScreen(); row = 0; column = 0; saved = (0, 0)
                    case (UInt8(ascii: "h"), "47"), (UInt8(ascii: "h"), "1047"):
                        if primaryBuffer == nil { primaryBuffer = (screen, row, column, saved) }
                        screen = blankScreen(); row = 0; column = 0
                    case (UInt8(ascii: "l"), "1049"), (UInt8(ascii: "l"), "47"), (UInt8(ascii: "l"), "1047"):
                        if let savedPrimary = primaryBuffer {
                            screen = savedPrimary.screen; row = savedPrimary.row
                            column = savedPrimary.column; saved = savedPrimary.saved
                            primaryBuffer = nil
                        }
                    default: break
                    }
                }
            }
            return
        }
        let numbers = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        func arg(_ index: Int, _ fallback: Int = 1) -> Int {
            index < numbers.count && numbers[index] > 0 ? numbers[index] : fallback
        }
        func raw(_ index: Int) -> Int { index < numbers.count ? numbers[index] : 0 }
        switch final {
        case UInt8(ascii: "A"): row = max(0, row - arg(0))
        case UInt8(ascii: "B"), UInt8(ascii: "e"): row = min(rows - 1, row + arg(0))
        case UInt8(ascii: "C"), UInt8(ascii: "a"): column = min(columns - 1, column + arg(0))
        case UInt8(ascii: "D"): column = max(0, column - arg(0))
        case UInt8(ascii: "E"): row = min(rows - 1, row + arg(0)); column = 0
        case UInt8(ascii: "F"): row = max(0, row - arg(0)); column = 0
        case UInt8(ascii: "G"), UInt8(ascii: "`"): column = min(columns - 1, arg(0) - 1)
        case UInt8(ascii: "d"): row = min(rows - 1, arg(0) - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            row = min(rows - 1, arg(0) - 1)
            column = min(columns - 1, arg(1) - 1)
        case UInt8(ascii: "L"):
            let n = min(rows - row, arg(0))
            for _ in 0..<n { screen.removeLast(); screen.insert(blankRow(), at: row) }
            column = 0
        case UInt8(ascii: "M"):
            let n = min(rows - row, arg(0))
            for _ in 0..<n { screen.remove(at: row); screen.append(blankRow()) }
            column = 0
        case UInt8(ascii: "S"):
            let n = min(rows, arg(0))
            for _ in 0..<n { screen.removeFirst(); screen.append(blankRow()) }
        case UInt8(ascii: "T"):
            let n = min(rows, arg(0))
            for _ in 0..<n { screen.removeLast(); screen.insert(blankRow(), at: 0) }
        case UInt8(ascii: "K"):
            switch raw(0) {
            case 0: clear(row: row, from: column, to: columns)
            case 1: clear(row: row, from: 0, to: min(columns, column + 1))
            default: clear(row: row, from: 0, to: columns)
            }
        case UInt8(ascii: "J"):
            switch raw(0) {
            case 0:
                clear(row: row, from: column, to: columns)
                for r in (row + 1)..<rows { clear(row: r, from: 0, to: columns) }
            case 1:
                for r in 0..<row { clear(row: r, from: 0, to: columns) }
                clear(row: row, from: 0, to: min(columns, column + 1))
            default:
                for r in 0..<rows { clear(row: r, from: 0, to: columns) }
            }
        case UInt8(ascii: "X"):
            clear(row: row, from: column, to: min(columns, column + arg(0)))
        case UInt8(ascii: "s"): saved = (row, column)
        case UInt8(ascii: "u"): (row, column) = saved
        default: break  // 颜色（m）、滚动区域（r）等不影响文字
        }
    }

    private mutating func clear(row: Int, from: Int, to: Int) {
        guard from < to else { return }
        for c in from..<to { screen[row][c] = " " }
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

private extension String {
    func trimmingTrailing() -> String {
        var s = self
        while let last = s.last, last == " " { s.removeLast() }
        return s
    }
}
