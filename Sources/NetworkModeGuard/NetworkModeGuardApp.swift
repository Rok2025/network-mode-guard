import AppKit
import SwiftUI

@main
struct NetworkModeGuardApp: App {
    var body: some Scene {
        MenuBarExtra("Network Mode Guard", systemImage: "network") {
            Text("网络状态采集尚未启用")
            Divider()
            Text("v0.1：诊断与安全切换")
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
