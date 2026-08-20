import AppKit
import SwiftUI

@MainActor
final class StatusBarAppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Network Mode Guard")
        button.image?.isTemplate = true
        button.toolTip = "Network Mode Guard"
        button.target = self
        button.action = #selector(statusItemClicked(_:))

        let rootView = NetworkModeGuardView()
            .environmentObject(appState)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 430, height: 520)
        popover.behavior = .applicationDefined
        popover.animates = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopoverNotification(_:)),
            name: .closeNetworkModeGuardPopover,
            object: nil
        )
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    @objc private func closePopoverNotification(_ notification: Notification) {
        closePopover()
    }
}
