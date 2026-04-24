import Foundation

/// The modifier flags Pulse recognises when canonicalising a shortcut
/// combo. `shift` alone is not a "shortcut" — a combo always requires
/// at least one of `cmd` / `ctrl` / `opt` to be set. Kept platform-
/// independent so PulseCore can stay free of `CoreGraphics`.
public struct ShortcutModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let cmd   = ShortcutModifiers(rawValue: 1 << 0)
    public static let ctrl  = ShortcutModifiers(rawValue: 1 << 1)
    public static let opt   = ShortcutModifiers(rawValue: 1 << 2)
    public static let shift = ShortcutModifiers(rawValue: 1 << 3)

    /// A modifier set counts as a "shortcut trigger" only when at
    /// least one non-`shift` modifier is active — typing a capital A
    /// shouldn't register as a shortcut.
    public var hasShortcutTrigger: Bool {
        contains(.cmd) || contains(.ctrl) || contains(.opt)
    }
}

/// Canonicalises (`keyCode`, `ShortcutModifiers`) into a stable combo
/// string like `cmd+shift+s`. Returns `nil` when the keyCode isn't in
/// the recognised vocabulary or when the modifiers don't carry a
/// shortcut trigger. The vocabulary is deliberately the ASCII subset
/// every user shares — non-letter / non-digit keys that have no
/// commonly-named canonical form ("F17", numpad clear) are dropped
/// to avoid storing a long tail of noise combos.
///
/// Modifier order is fixed (`ctrl+opt+shift+cmd`) so two invocations
/// with the same logical combo produce byte-identical strings — F-33
/// groups on that string directly.
public enum ShortcutCombo {

    public static func canonical(
        keyCode: UInt16,
        modifiers: ShortcutModifiers
    ) -> String? {
        guard modifiers.hasShortcutTrigger else { return nil }
        guard let keyName = keyName(for: keyCode) else { return nil }
        var parts: [String] = []
        if modifiers.contains(.ctrl)  { parts.append("ctrl") }
        if modifiers.contains(.opt)   { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.cmd)   { parts.append("cmd") }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    /// macOS virtual-keycode → canonical key name (lowercase ASCII).
    /// Only the US-QWERTY alpha / digit / punctuation / common
    /// special keys are recognised; everything else returns `nil`.
    public static func keyName(for keyCode: UInt16) -> String? {
        switch keyCode {
        // Letters
        case 0:   return "a"
        case 11:  return "b"
        case 8:   return "c"
        case 2:   return "d"
        case 14:  return "e"
        case 3:   return "f"
        case 5:   return "g"
        case 4:   return "h"
        case 34:  return "i"
        case 38:  return "j"
        case 40:  return "k"
        case 37:  return "l"
        case 46:  return "m"
        case 45:  return "n"
        case 31:  return "o"
        case 35:  return "p"
        case 12:  return "q"
        case 15:  return "r"
        case 1:   return "s"
        case 17:  return "t"
        case 32:  return "u"
        case 9:   return "v"
        case 13:  return "w"
        case 7:   return "x"
        case 16:  return "y"
        case 6:   return "z"
        // Top-row digits
        case 29:  return "0"
        case 18:  return "1"
        case 19:  return "2"
        case 20:  return "3"
        case 21:  return "4"
        case 23:  return "5"
        case 22:  return "6"
        case 26:  return "7"
        case 28:  return "8"
        case 25:  return "9"
        // Common named keys
        case 36:  return "return"
        case 48:  return "tab"
        case 49:  return "space"
        case 51:  return "delete"
        case 53:  return "escape"
        case 117: return "forwardDelete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 50:  return "backtick"
        case 27:  return "minus"
        case 24:  return "equal"
        case 33:  return "leftBracket"
        case 30:  return "rightBracket"
        case 39:  return "quote"
        case 41:  return "semicolon"
        case 42:  return "backslash"
        case 43:  return "comma"
        case 44:  return "slash"
        case 47:  return "period"
        default:  return nil
        }
    }
}
