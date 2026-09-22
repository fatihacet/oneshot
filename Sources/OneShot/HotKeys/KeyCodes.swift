import AppKit
import Carbon.HIToolbox

/// Display names and menu key equivalents for virtual key codes.
enum KeyCodes {
    struct Key {
        /// Shown in Settings, e.g. "A", "F5", "←".
        let display: String
        /// Used for NSMenuItem.keyEquivalent; empty if the key can't be shown in menus.
        let menuEquivalent: String
    }

    static func key(for keyCode: UInt32) -> Key? { table[Int(keyCode)] }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool { functionKeyCodes.contains(Int(keyCode)) }

    private static let functionKeyCodes: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let table: [Int: Key] = {
        var table: [Int: Key] = [:]

        let characters: [(Int, String)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"),
            (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"),
            (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"), (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"),
            (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
            (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"), (kVK_ANSI_Y, "y"),
            (kVK_ANSI_Z, "z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_ANSI_Minus, "-"), (kVK_ANSI_Equal, "="), (kVK_ANSI_LeftBracket, "["),
            (kVK_ANSI_RightBracket, "]"), (kVK_ANSI_Backslash, "\\"), (kVK_ANSI_Semicolon, ";"),
            (kVK_ANSI_Quote, "'"), (kVK_ANSI_Comma, ","), (kVK_ANSI_Period, "."), (kVK_ANSI_Slash, "/"),
            (kVK_ANSI_Grave, "`"),
        ]
        for (code, character) in characters {
            table[code] = Key(display: character.uppercased(), menuEquivalent: character)
        }

        func functionKey(_ value: Int) -> String { String(UnicodeScalar(UInt16(value)).map(Character.init) ?? " ") }

        for (index, code) in functionKeyCodes.enumerated() {
            table[code] = Key(display: "F\(index + 1)", menuEquivalent: functionKey(NSF1FunctionKey + index))
        }

        table[kVK_Space] = Key(display: "Space", menuEquivalent: " ")
        table[kVK_Return] = Key(display: "↩", menuEquivalent: "\r")
        table[kVK_Tab] = Key(display: "⇥", menuEquivalent: "\t")
        table[kVK_Delete] = Key(display: "⌫", menuEquivalent: functionKey(NSBackspaceCharacter))
        table[kVK_ForwardDelete] = Key(display: "⌦", menuEquivalent: functionKey(NSDeleteFunctionKey))
        table[kVK_Escape] = Key(display: "⎋", menuEquivalent: "\u{1b}")
        table[kVK_LeftArrow] = Key(display: "←", menuEquivalent: functionKey(NSLeftArrowFunctionKey))
        table[kVK_RightArrow] = Key(display: "→", menuEquivalent: functionKey(NSRightArrowFunctionKey))
        table[kVK_UpArrow] = Key(display: "↑", menuEquivalent: functionKey(NSUpArrowFunctionKey))
        table[kVK_DownArrow] = Key(display: "↓", menuEquivalent: functionKey(NSDownArrowFunctionKey))
        table[kVK_Home] = Key(display: "↖", menuEquivalent: functionKey(NSHomeFunctionKey))
        table[kVK_End] = Key(display: "↘", menuEquivalent: functionKey(NSEndFunctionKey))
        table[kVK_PageUp] = Key(display: "⇞", menuEquivalent: functionKey(NSPageUpFunctionKey))
        table[kVK_PageDown] = Key(display: "⇟", menuEquivalent: functionKey(NSPageDownFunctionKey))
        return table
    }()
}
