import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var statusBar: StatusBarController!
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would fight over the helper connection and the fans.
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: current.bundleIdentifier ?? "")
            .filter { $0 != current }
        if let other = others.first {
            other.activate()
            NSApp.terminate(nil)
            return
        }

        guard let model = AppModel() else {
            let alert = NSAlert()
            alert.messageText = "Coolant cannot read this Mac's SMC."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.model = model
        applyDockPolicy()
        statusBar = StatusBarController(model: model) { [weak self] in self?.showWindow() }
        model.onRefresh = { [weak self] in
            self?.statusBar.refresh()
            self?.applyDockPolicy()
        }
        model.start()
        model.notch.prepare()
        if CommandLine.arguments.contains("--demo-notch") {
            model.notch.show(NotchMessage(title: "CPU hot", detail: "CPU hottest 93° · Cooling", symbol: "thermometer.high", tint: .orange))
            model.notch.show(NotchMessage(title: "Autopilot: back to normal", detail: "Fans 34%", symbol: "checkmark.circle.fill", tint: .green))
        }
        if CommandLine.arguments.contains("--open") || model.config.showDockIcon { showWindow() }
    }

    func applicationWillTerminate(_ notification: Notification) { model?.releaseFans() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    private func applyDockPolicy() {
        let policy: NSApplication.ActivationPolicy = model.config.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Coolant"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: RootView(model: model))
            window.setFrameAutosaveName("CoolantMain")
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
