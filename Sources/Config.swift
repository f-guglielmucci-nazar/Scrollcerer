import AppKit
import ApplicationServices
import Combine
import ServiceManagement

/// Saved settings (UserDefaults).
final class Config: ObservableObject {
    static let shared = Config()

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "enabled") }
    }
    @Published var reverseWheel: Bool {
        didSet { UserDefaults.standard.set(reverseWheel, forKey: "reverseWheel") }
    }
    /// Multiplier on autoscroll speed (Settings slider).
    @Published var autoscrollSpeed: Double {
        didSet { UserDefaults.standard.set(autoscrollSpeed, forKey: "autoscrollSpeed") }
    }
    @Published private(set) var mappings: [Int: ButtonAction]
    @Published private(set) var extraButtons: [Int]

    static let defaultMappings: [Int: ButtonAction] = [
        2: ButtonAction(kind: .autoscroll),
        3: ButtonAction(kind: .back),
        4: ButtonAction(kind: .forward),
    ]

    private init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "enabled") as? Bool ?? true
        reverseWheel = d.bool(forKey: "reverseWheel")
        autoscrollSpeed = d.object(forKey: "autoscrollSpeed") as? Double ?? 1.0
        if let data = d.data(forKey: "mappings"),
           let saved = try? JSONDecoder().decode([Int: ButtonAction].self, from: data) {
            var saved = saved
            // Settings saved before autoscroll existed: a wheel click never set gets the new default.
            if saved[2] == nil { saved[2] = Config.defaultMappings[2] }
            mappings = saved
        } else {
            mappings = Config.defaultMappings
        }
        extraButtons = d.array(forKey: "extraButtons") as? [Int] ?? []
    }

    /// Pseudo button numbers for tilting the wheel (these arrive as sideways scrolling).
    static let tiltLeft = 100
    static let tiltRight = 101

    /// Buttons shown in Settings: wheel click, wheel tilt, the two side buttons,
    /// plus any other button seen.
    var buttons: [Int] {
        let fixed = [2, Config.tiltLeft, Config.tiltRight, 3, 4]
        let others = Set(extraButtons + Array(mappings.keys)).subtracting(fixed).sorted()
        return fixed + others
    }

    func action(for button: Int) -> ButtonAction {
        mappings[button] ?? ButtonAction(kind: .passthrough)
    }

    var usesAutoscroll: Bool {
        mappings.values.contains { $0.kind == .autoscroll }
    }

    static func isTilt(_ button: Int) -> Bool {
        button == tiltLeft || button == tiltRight
    }

    func setAction(_ action: ButtonAction, for button: Int) {
        mappings[button] = action
        save()
    }

    func noteButton(_ button: Int) {
        guard button > 4, button < Config.tiltLeft, !extraButtons.contains(button) else { return }
        extraButtons.append(button)
        UserDefaults.standard.set(extraButtons, forKey: "extraButtons")
    }

    func resetDefaults() {
        mappings = Config.defaultMappings
        reverseWheel = false
        autoscrollSpeed = 1.0
        enabled = true
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(mappings) {
            UserDefaults.standard.set(data, forKey: "mappings")
        }
    }

    static func name(for button: Int) -> String {
        switch button {
        case 2: return "Wheel click"
        case Config.tiltLeft: return "Wheel tilt left"
        case Config.tiltRight: return "Wheel tilt right"
        case 3: return "Rear side button"
        case 4: return "Front side button"
        default: return "Button \(button + 1)"
        }
    }
}

/// Live state shown in the UI.
final class AppStatus: ObservableObject {
    static let shared = AppStatus()

    @Published var trusted = false
    @Published var lastPressed: Int? = nil
    @Published var loginEnabled: Bool = Permissions.launchAtLogin
    private var clearWork: DispatchWorkItem?

    func buttonPressed(_ button: Int) {
        Config.shared.noteButton(button)
        lastPressed = button
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lastPressed = nil }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}

enum Permissions {
    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static var launchAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the resulting state.
    static func setLaunchAtLogin(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("MouseRemap: login item change failed: \(error)")
        }
        return launchAtLogin
    }
}
