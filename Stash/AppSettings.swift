import AppKit
import Foundation
import Carbon.HIToolbox

// MARK: - Notification names used by the Settings system

extension Notification.Name {
    static let quickPanelHotkeyChanged      = Notification.Name("QuickPanelHotkeyChanged")
    static let quickPanelClearClipboard     = Notification.Name("QuickPanelClearClipboard")
    static let quickPanelClearNotes         = Notification.Name("QuickPanelClearNotes")
    static let quickPanelClearDroppedFiles  = Notification.Name("QuickPanelClearDroppedFiles")
}

// MARK: - Layout style

enum QuickPanelLayoutStyle: String, CaseIterable, Identifiable {
    /// Full-width three-column panel (default).
    case panel
    /// Three stacked frosted cards that expand on hover.
    case cards
    var id: String { rawValue }
}

// MARK: - Shared settings store

/// Singleton that persists all user-facing settings to UserDefaults.
/// UI binds directly via @ObservedObject; PanelController observes via Combine.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let ud = UserDefaults.standard

    // MARK: Layout mode

    @Published var layoutStyle: QuickPanelLayoutStyle = .panel {
        didSet { ud.set(layoutStyle.rawValue, forKey: Keys.layoutStyle) }
    }

    // MARK: Hotkey (stored as Carbon key-code + modifier bitmask)

    @Published var hotKeyCode: UInt32 {
        didSet { ud.set(Int(hotKeyCode), forKey: Keys.hotKeyCode) }
    }
    @Published var hotKeyModifiers: UInt32 {
        didSet { ud.set(Int(hotKeyModifiers), forKey: Keys.hotKeyModifiers) }
    }

    // MARK: Auto-hide timer (0 = Never)

    @Published var autoHideSeconds: Double {
        didSet { ud.set(autoHideSeconds, forKey: Keys.autoHideSeconds) }
    }

    // MARK: Panel dimensions

    @Published var panelWidth: CGFloat {
        didSet { ud.set(Double(panelWidth), forKey: Keys.panelWidth) }
    }
    @Published var panelHeight: CGFloat {
        didSet { ud.set(Double(panelHeight), forKey: Keys.panelHeight) }
    }

    // MARK: Launch at login

    @Published var launchAtLogin: Bool {
        didSet { ud.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }

    // MARK: - Init

    private init() {
        let savedCode = ud.object(forKey: Keys.hotKeyCode) as? Int
        hotKeyCode = UInt32(savedCode ?? kVK_Space)

        let savedMods = ud.object(forKey: Keys.hotKeyModifiers) as? Int
        hotKeyModifiers = UInt32(savedMods ?? (cmdKey | shiftKey))

        let savedHide = ud.object(forKey: Keys.autoHideSeconds) as? Double
        autoHideSeconds = savedHide ?? 7.0

        let savedWidth = ud.object(forKey: Keys.panelWidth) as? Double
        panelWidth = CGFloat(savedWidth ?? 640)

        let savedHeight = ud.object(forKey: Keys.panelHeight) as? Double
        panelHeight = CGFloat(savedHeight ?? 360)

        let savedLogin = ud.object(forKey: Keys.launchAtLogin) as? Bool
        launchAtLogin = savedLogin ?? false

        if let raw = ud.string(forKey: Keys.layoutStyle),
           let style = QuickPanelLayoutStyle(rawValue: raw) {
            layoutStyle = style
        }
    }

    // MARK: - UserDefaults keys

    private enum Keys {
        static let layoutStyle      = "qp.layoutStyle"
        static let hotKeyCode       = "qp.hotKeyCode"
        static let hotKeyModifiers  = "qp.hotKeyModifiers"
        static let autoHideSeconds  = "qp.autoHideSeconds"
        static let panelWidth       = "qp.panelWidth"
        static let panelHeight      = "qp.panelHeight"
        static let launchAtLogin    = "qp.launchAtLogin"
    }
}

// MARK: - Hotkey display helpers

/// Format a hotkey as a human-readable badge string, e.g. "⌘⇧Space".
func hotkeyBadgeString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
    var s = ""
    if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
    if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
    if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
    if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
    s += keyCodeDisplayName(keyCode)
    return s
}

func keyCodeDisplayName(_ code: UInt32) -> String {
    let map: [Int: String] = [
        kVK_Space:            "Space",
        kVK_Return:           "↩",
        kVK_Delete:           "⌫",
        kVK_ForwardDelete:    "⌦",
        kVK_Tab:              "⇥",
        kVK_Escape:           "⎋",
        kVK_UpArrow:          "↑",
        kVK_DownArrow:        "↓",
        kVK_LeftArrow:        "←",
        kVK_RightArrow:       "→",
        kVK_Home:             "↖",
        kVK_End:              "↘",
        kVK_PageUp:           "⇞",
        kVK_PageDown:         "⇟",
        kVK_F1: "F1",  kVK_F2: "F2",  kVK_F3: "F3",  kVK_F4: "F4",
        kVK_F5: "F5",  kVK_F6: "F6",  kVK_F7: "F7",  kVK_F8: "F8",
        kVK_F9: "F9",  kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus:        "-",
        kVK_ANSI_Equal:        "=",
        kVK_ANSI_LeftBracket:  "[",
        kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash:    "\\",
        kVK_ANSI_Semicolon:    ";",
        kVK_ANSI_Quote:        "'",
        kVK_ANSI_Comma:        ",",
        kVK_ANSI_Period:       ".",
        kVK_ANSI_Slash:        "/",
        kVK_ANSI_Grave:        "`",
    ]
    return map[Int(code)] ?? "Key\(code)"
}

/// Convert NSEvent modifier flags → Carbon modifier bitmask.
func nsToCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var c: UInt32 = 0
    if flags.contains(.command) { c |= UInt32(cmdKey)     }
    if flags.contains(.shift)   { c |= UInt32(shiftKey)   }
    if flags.contains(.option)  { c |= UInt32(optionKey)  }
    if flags.contains(.control) { c |= UInt32(controlKey) }
    return c
}
