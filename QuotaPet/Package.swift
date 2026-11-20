// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaPet",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuotaPet", targets: ["QuotaPet"]),
    ],
    targets: [
        // 纯逻辑：数据解析、窗口推算、宠物的心情和表情。不依赖 AppKit，方便自检。
        .target(name: "QuotaPetCore"),
        .executableTarget(name: "QuotaPetLauncher", dependencies: ["QuotaPetCore"]),
        // 菜单栏 App 本体
        .executableTarget(name: "QuotaPet", dependencies: ["QuotaPetCore"]),
        // 命令行工具里没有 XCTest / swift-testing，用一个可执行目标做自检：swift run QuotaPetChecks
        .executableTarget(name: "QuotaPetChecks", dependencies: ["QuotaPetCore"]),
    ],
    swiftLanguageModes: [.v5]
)
