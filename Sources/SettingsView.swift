import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var config = Config.shared
    @ObservedObject var status = AppStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !status.trusted {
                VStack(alignment: .leading, spacing: 6) {
                    Text("One more step: let Scrollmate see your mouse")
                        .font(.headline)
                    Text("Open System Settings → Privacy & Security → Accessibility and switch Scrollmate on. This window updates by itself once it's allowed.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Accessibility Settings") { Permissions.openAccessibilitySettings() }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
            }

            Toggle("Remapping on", isOn: $config.enabled)

            GroupBox(label: Text("Buttons")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(config.buttons, id: \.self) { button in
                        ButtonRow(button: button)
                    }
                    Text("Press a button or tilt the wheel and its dot lights up. If your mouse sends a tilt as a button instead, a new \"Button\" row appears; set that one. \"Default\" on a tilt keeps sideways scrolling. The DPI button is handled inside the mouse itself, so macOS never sees it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(label: Text("Scroll wheel")) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Reverse scroll direction for the mouse wheel (trackpad stays as it is)",
                           isOn: $config.reverseWheel)
                    Toggle("Smooth scrolling: each notch glides instead of jumping",
                           isOn: $config.smoothScroll)
                    Toggle("Turn off scroll acceleration for the mouse wheel",
                           isOn: $config.linearWheel)
                    HStack(spacing: 8) {
                        Text("Lines per wheel notch")
                        Picker("", selection: $config.wheelLines) {
                            Text("macOS default").tag(0)
                            Divider()
                            ForEach([1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 20], id: \.self) { n in
                                Text("\(n)").tag(n)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    Text(config.linearWheel
                         ? "Every notch scrolls exactly this many lines (1 with \"macOS default\"), however fast you spin."
                         : "Each notch scrolls this many times more than usual; spinning faster still speeds up.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Toggle("Zoom in and out with", isOn: $config.wheelZoom)
                        Picker("", selection: $config.zoomWithCommand) {
                            Text("⌃ Control + wheel").tag(false)
                            Text("⌘ Command + wheel").tag(true)
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .disabled(!config.wheelZoom)
                    }
                    Text("These only change the mouse wheel; the trackpad stays as it is.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if config.usesAutoscroll {
                        HStack(spacing: 8) {
                            Text("Autoscroll speed")
                            Text("Slower").font(.caption).foregroundColor(.secondary)
                            Slider(value: $config.autoscrollSpeed, in: 0.3...3)
                            Text("Faster").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Toggle("Open at login", isOn: Binding(
                    get: { status.loginEnabled },
                    set: { on in status.loginEnabled = Permissions.setLaunchAtLogin(on) }))
                Spacer()
                Button("Restore defaults") { config.resetDefaults() }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

struct ButtonRow: View {
    let button: Int
    @ObservedObject var config = Config.shared
    @ObservedObject var status = AppStatus.shared
    @ObservedObject var recorder = ShortcutRecorder.shared

    private let labelWidth: CGFloat = 150

    var body: some View {
        let action = config.action(for: button)
        let selection = Binding<ActionKind>(
            get: { config.action(for: button).kind },
            set: { kind in
                if kind == .custom {
                    recorder.start(for: button)
                } else {
                    recorder.stop()
                    config.setAction(ButtonAction(kind: kind), for: button)
                }
            })

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(status.lastPressed == button ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 9, height: 9)
                Text(Config.name(for: button))
                    .frame(width: labelWidth, alignment: .leading)
                Picker("", selection: selection) {
                    ForEach(ActionKind.groups.indices, id: \.self) { i in
                        if i > 0 { Divider() }
                        ForEach(ActionKind.groups[i].filter { $0 != .autoscroll || !Config.isTilt(button) }) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            if recorder.recordingButton == button {
                Text("Press the shortcut now… (Esc to cancel)")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .padding(.leading, labelWidth + 19)
            } else if action.kind == .custom, let shortcut = action.shortcut {
                HStack(spacing: 8) {
                    Text("Sends \(shortcut.display)")
                    Button("Change…") { recorder.start(for: button) }
                }
                .font(.caption)
                .padding(.leading, labelWidth + 19)
            } else if action.kind == .autoscroll {
                Text("Click to toggle, or hold and move. Links and tabs still get a normal middle click.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, labelWidth + 19)
            }
        }
    }
}

/// Captures the next key combination typed while the Settings window is in front.
final class ShortcutRecorder: ObservableObject {
    static let shared = ShortcutRecorder()

    @Published private(set) var recordingButton: Int? = nil
    private var monitor: Any?

    func start(for button: Int) {
        stop()
        recordingButton = button
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let target = self.recordingButton else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let relevant = mods.intersection([.command, .shift, .option, .control])
            if event.keyCode == 53 && relevant.isEmpty { // Esc cancels
                self.stop()
                return nil
            }
            let shortcut = Shortcut(keyCode: event.keyCode,
                                    modifiers: ShortcutRecorder.cgFlags(relevant).rawValue,
                                    display: ShortcutRecorder.describe(event, relevant))
            Config.shared.setAction(ButtonAction(kind: .custom, shortcut: shortcut), for: target)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recordingButton = nil
    }

    static func cgFlags(_ mods: NSEvent.ModifierFlags) -> CGEventFlags {
        var f = CGEventFlags()
        if mods.contains(.command) { f.insert(.maskCommand) }
        if mods.contains(.shift)   { f.insert(.maskShift) }
        if mods.contains(.option)  { f.insert(.maskAlternate) }
        if mods.contains(.control) { f.insert(.maskControl) }
        return f
    }

    static func describe(_ event: NSEvent, _ mods: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }

        let named: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "Esc", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15",
        ]
        if let name = named[event.keyCode] {
            s += name
        } else if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            s += chars.uppercased()
        } else {
            s += "Key \(event.keyCode)"
        }
        return s
    }
}
