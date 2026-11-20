import AppKit
import QuotaPetCore

// 命令行参数：
//   --demo                   演示模式（假数据，75 秒看完宠物的所有状态）
//   --enable-login-item      打开「开机自动启动」（make install 用）
//   --watch-bundle-id <id>   调试用：把「Claude 打开时显示」盯的 Claude 桌面端换成别的 App
//   --dump                   在终端打印当前额度（只读本机文件），和 usage_lab.py 对账用
//   --probe-cli              用 Claude 命令行查一次官方读数（会联网、占一个最小请求），调试用
//   --render-previews <dir>  把宠物和面板渲染成 PNG
//   --render-relay-previews <dir>  双宠接力和面板顶部信息的三张预览图（只用合成数据，不读本机数据和设置）
//   --render-icon <dir>      生成 App 图标的 .iconset
let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

if arguments.contains("--probe-cli") {
    MainActor.assumeIsolated { DumpCommand.probe() }
    exit(0)
}

if arguments.contains("--dump") {
    DumpCommand.run()
    exit(0)
}

MainActor.assumeIsolated {
    if let dir = value(after: "--render-previews") {
        PreviewRenderer.renderAll(to: URL(fileURLWithPath: dir))
        exit(0)
    }
    if let dir = value(after: "--render-relay-previews") {
        RelayPreviews.renderAll(to: URL(fileURLWithPath: dir))
        exit(0)
    }
    if let dir = value(after: "--render-icon") {
        IconRenderer.writeIconset(to: URL(fileURLWithPath: dir))
        exit(0)
    }

    let app = NSApplication.shared
    let delegate = AppDelegate(demo: arguments.contains("--demo"),
                               watchBundleID: value(after: "--watch-bundle-id"),
                               enableLoginItem: arguments.contains("--enable-login-item"))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)  // 不在 Dock 里显示
    app.run()
}
