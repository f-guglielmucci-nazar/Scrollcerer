import AppKit
import Carbon
import CoreGraphics

/// A keyboard shortcut recorded by the user.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt64   // CGEventFlags raw value
    var display: String
}

/// Everything a mouse button can be turned into.
enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case passthrough, disabled, middleClick
    case back, forward, nextTab, previousTab, closeTab, reopenTab
    case missionControl, appExpose, showDesktop, spaceLeft, spaceRight
    case copy, paste, undo, screenshot, spotlight
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute
    case custom

    var id: String { rawValue }

    /// Grouping used for the pop-up menus (a divider goes between groups).
    static let groups: [[ActionKind]] = [
        [.passthrough, .disabled, .middleClick],
        [.back, .forward, .nextTab, .previousTab, .closeTab, .reopenTab],
        [.missionControl, .appExpose, .showDesktop, .spaceLeft, .spaceRight],
        [.copy, .paste, .undo, .screenshot, .spotlight],
        [.playPause, .nextTrack, .previousTrack, .volumeUp, .volumeDown, .mute],
        [.custom],
    ]

    var title: String {
        switch self {
        case .passthrough:    return "Default (no change)"
        case .disabled:       return "Do nothing"
        case .middleClick:    return "Middle click"
        case .back:           return "Back  ⌘["
        case .forward:        return "Forward  ⌘]"
        case .nextTab:        return "Next tab  ⌃⇥"
        case .previousTab:    return "Previous tab  ⌃⇧⇥"
        case .closeTab:       return "Close tab/window  ⌘W"
        case .reopenTab:      return "Reopen closed tab  ⇧⌘T"
        case .missionControl: return "Mission Control"
        case .appExpose:      return "App windows (App Exposé)"
        case .showDesktop:    return "Show Desktop"
        case .spaceLeft:      return "Desktop to the left  ⌃←"
        case .spaceRight:     return "Desktop to the right  ⌃→"
        case .copy:           return "Copy  ⌘C"
        case .paste:          return "Paste  ⌘V"
        case .undo:           return "Undo  ⌘Z"
        case .screenshot:     return "Screenshot area  ⇧⌘4"
        case .spotlight:      return "Spotlight  ⌘Space"
        case .playPause:      return "Play / Pause"
        case .nextTrack:      return "Next track"
        case .previousTrack:  return "Previous track"
        case .volumeUp:       return "Volume up"
        case .volumeDown:     return "Volume down"
        case .mute:           return "Mute"
        case .custom:         return "Custom shortcut…"
        }
    }
}

struct ButtonAction: Codable, Equatable {
    var kind: ActionKind
    var shortcut: Shortcut? = nil
}

enum Actions {
    // Virtual key codes (US layout positions; letters are re-resolved for the current layout).
    private static let kLeftBracket: CGKeyCode = 33, kRightBracket: CGKeyCode = 30
    private static let kC: CGKeyCode = 8, kV: CGKeyCode = 9, kZ: CGKeyCode = 6
    private static let kW: CGKeyCode = 13, kT: CGKeyCode = 17, k4: CGKeyCode = 21
    private static let kTab: CGKeyCode = 48, kSpace: CGKeyCode = 49, kF11: CGKeyCode = 103
    private static let kLeft: CGKeyCode = 123, kRight: CGKeyCode = 124, kDown: CGKeyCode = 125, kUp: CGKeyCode = 126

    // NX_KEYTYPE_* media key identifiers.
    private static let mediaVolumeUp: Int32 = 0, mediaVolumeDown: Int32 = 1, mediaMute: Int32 = 7
    private static let mediaPlay: Int32 = 16, mediaNext: Int32 = 17, mediaPrevious: Int32 = 18

    static func perform(_ action: ButtonAction) {
        switch action.kind {
        case .passthrough, .disabled, .middleClick:
            break // handled directly in the event tap
        case .back:           appKey(kLeftBracket, .maskCommand, char: "[")
        case .forward:        appKey(kRightBracket, .maskCommand, char: "]")
        case .nextTab:        post(kTab, .maskControl)
        case .previousTab:    post(kTab, [.maskControl, .maskShift])
        case .closeTab:       appKey(kW, .maskCommand, char: "w")
        case .reopenTab:      appKey(kT, [.maskCommand, .maskShift], char: "t")
        case .missionControl: openApp("/System/Applications/Mission Control.app")
        case .appExpose:      post(kDown, .maskControl)
        case .showDesktop:    post(kF11, [])
        case .spaceLeft:      post(kLeft, .maskControl)
        case .spaceRight:     post(kRight, .maskControl)
        case .copy:           appKey(kC, .maskCommand, char: "c")
        case .paste:          appKey(kV, .maskCommand, char: "v")
        case .undo:           appKey(kZ, .maskCommand, char: "z")
        case .screenshot:     post(k4, [.maskCommand, .maskShift])
        case .spotlight:      post(kSpace, .maskCommand)
        case .playPause:      media(mediaPlay)
        case .nextTrack:      media(mediaNext)
        case .previousTrack:  media(mediaPrevious)
        case .volumeUp:       media(mediaVolumeUp)
        case .volumeDown:     media(mediaVolumeDown)
        case .mute:           media(mediaMute)
        case .custom:
            if let s = action.shortcut {
                post(CGKeyCode(s.keyCode), CGEventFlags(rawValue: s.modifiers))
            }
        }
    }

    // MARK: - Keyboard

    /// App menu shortcuts match on the typed character, so find which key types that
    /// character on the current keyboard layout (matters for AZERTY, QWERTZ, Italian…).
    private static func appKey(_ usCode: CGKeyCode, _ flags: CGEventFlags, char: Character) {
        if let code = keyCode(typing: char) {
            post(code, flags)
        } else {
            post(usCode, flags, text: String(char))
        }
    }

    static func post(_ code: CGKeyCode, _ flags: CGEventFlags, text: String? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        var f = flags
        let arrows: Set<CGKeyCode> = [123, 124, 125, 126]
        let functionKeys: Set<CGKeyCode> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]
        // Real arrow / F-key presses carry these flags; system shortcuts often expect them.
        if arrows.contains(code) { f.insert(.maskNumericPad); f.insert(.maskSecondaryFn) }
        if functionKeys.contains(code) { f.insert(.maskSecondaryFn) }

        for isDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown) else { continue }
            e.flags = f
            if let text = text {
                let units = Array(text.utf16)
                e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            e.post(tap: .cghidEventTap)
        }
    }

    /// Finds the key that types `char` (without modifiers) on the active keyboard layout.
    static func keyCode(typing char: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let target = String(char)
        let keyboardType = UInt32(LMGetKbdType())

        return layoutData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let base = buffer.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout,
                                            UInt16(code),
                                            UInt16(3),       // kUCKeyActionDisplay
                                            0,               // no modifiers
                                            keyboardType,
                                            OptionBits(1),   // kUCKeyTranslateNoDeadKeysMask
                                            &deadKeyState,
                                            4,
                                            &length,
                                            &chars)
                if status == 0, length > 0,
                   String(utf16CodeUnits: chars, count: length) == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }

    // MARK: - Media keys

    private static func media(_ key: Int32) {
        for isDown in [true, false] {
            let state: Int32 = isDown ? 0xA : 0xB
            let data1 = Int((key << 16) | (state << 8))
            let event = NSEvent.otherEvent(with: .systemDefined,
                                           location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                                           timestamp: 0,
                                           windowNumber: 0,
                                           context: nil,
                                           subtype: 8,
                                           data1: data1,
                                           data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Mouse

    /// Clicks the middle button at the pointer. Posted after this app's own event tap,
    /// so it isn't remapped again.
    static func middleClick() {
        let position = CGEvent(source: nil)?.location ?? .zero
        for type in [CGEventType.otherMouseDown, CGEventType.otherMouseUp] {
            if let e = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: position, mouseButton: .center) {
                e.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    // MARK: - Apps

    private static func openApp(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
