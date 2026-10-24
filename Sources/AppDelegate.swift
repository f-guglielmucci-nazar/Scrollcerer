import AppKit
import ApplicationServices
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app used to be called MouseRemap; two copies would remap every event twice.
        for old in NSRunningApplication.runningApplications(withBundleIdentifier: "local.mouseremap") {
            old.terminate()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Scrollmate") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "M"
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Remapper.shared.onButton = { button in AppStatus.shared.buttonPressed(button) }

        let defaults = UserDefaults.standard
        if startTap() {
            if !defaults.bool(forKey: "launchedBefore") { showSettings() }
        } else {
            Permissions.promptForAccessibility()
            showSettings()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
                if self?.startTap() == true { timer.invalidate() }
            }
        }
        defaults.set(true, forKey: "launchedBefore")
    }

    /// Opening the app again from Finder/Spotlight shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @discardableResult
    private func startTap() -> Bool {
        let ok = AXIsProcessTrusted() && Remapper.shared.start()
        if AppStatus.shared.trusted != ok { AppStatus.shared.trusted = ok }
        return ok
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = Config.shared

        if !AppStatus.shared.trusted {
            menu.addItem(item("Needs Accessibility permission…", #selector(openAccessibility)))
            menu.addItem(.separator())
        }

        let enabled = item("Remapping On", #selector(toggleEnabled))
        enabled.state = config.enabled ? .on : .off
        menu.addItem(enabled)

        let reverse = item("Reverse Scroll Wheel", #selector(toggleReverse))
        reverse.state = config.reverseWheel ? .on : .off
        menu.addItem(reverse)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Scrollmate", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() { Config.shared.enabled.toggle() }
    @objc private func toggleReverse() { Config.shared.reverseWheel.toggle() }
    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize] // window grows/shrinks with the content
            let window = NSWindow(contentViewController: host)
            window.title = "Scrollmate"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
