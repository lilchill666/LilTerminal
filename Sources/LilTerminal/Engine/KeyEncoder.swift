import Foundation
import AppKit
import CGhosttyVT

/// Turns AppKit key events into terminal bytes using Ghostty's encoder.
///
/// Encoding is not a lookup table: it depends on terminal modes the app does
/// not track (cursor-key application mode, Kitty keyboard protocol). The
/// encoder is synced from the terminal so those modes are honoured for free.
final class KeyEncoder {
    private var encoder: GhosttyKeyEncoder?
    private var event: GhosttyKeyEvent?

    init?() {
        guard ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS else { return nil }
    }

    deinit {
        if let event { ghostty_key_event_free(event) }
        if let encoder { ghostty_key_encoder_free(encoder) }
    }

    /// Picks up modes the running program may have changed.
    func sync(with terminal: GhosttyTerminal?) {
        guard let encoder, let terminal else { return }
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
    }

    func encode(_ nsEvent: NSEvent) -> [UInt8]? {
        guard let encoder, let event else { return nil }

        ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(event, Self.key(for: nsEvent))
        ghostty_key_event_set_mods(event, Self.mods(for: nsEvent.modifierFlags))

        if let scalar = nsEvent.charactersIgnoringModifiers?.unicodeScalars.first {
            ghostty_key_event_set_unshifted_codepoint(event, scalar.value)
        }

        // The text AppKit already resolved (dead keys, IME, shifted symbols).
        // Control combinations carry no useful characters, so they are left to
        // the encoder to derive from the key itself.
        let wantsText = !nsEvent.modifierFlags.contains(.control)
            && (nsEvent.characters?.unicodeScalars.allSatisfy { $0.value >= 0x20 } ?? false)
        var utf8 = wantsText ? Array((nsEvent.characters ?? "").utf8).map { CChar(bitPattern: $0) } : []

        var buffer = [CChar](repeating: 0, count: 128)
        var length = 0
        var status = GHOSTTY_INVALID_VALUE

        // The event only borrows this pointer, so it has to stay alive until
        // encode() has run. Setting it inside a closure that then returns left
        // the encoder reading freed memory, which came back as a NUL byte —
        // every printable key typed nothing at all.
        func runEncode() {
            status = buffer.withUnsafeMutableBufferPointer {
                ghostty_key_encoder_encode(encoder, event, $0.baseAddress, $0.count, &length)
            }
        }

        if utf8.isEmpty {
            ghostty_key_event_set_utf8(event, nil, 0)
            runEncode()
        } else {
            utf8.withUnsafeBufferPointer { raw in
                ghostty_key_event_set_utf8(event, raw.baseAddress, raw.count)
                runEncode()
            }
        }

        guard status == GHOSTTY_SUCCESS, length > 0 else { return nil }
        return buffer.prefix(length).map { UInt8(bitPattern: $0) }
    }

    private static func mods(for flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: UInt16 = 0
        if flags.contains(.shift)    { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control)  { mods |= UInt16(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option)   { mods |= UInt16(GHOSTTY_MODS_ALT) }
        if flags.contains(.command)  { mods |= UInt16(GHOSTTY_MODS_SUPER) }
        if flags.contains(.capsLock) { mods |= UInt16(GHOSTTY_MODS_CAPS_LOCK) }
        return mods
    }

    /// Maps an AppKit virtual key code to Ghostty's key identifier.
    ///
    /// Ghostty's key enum is physical-key based (W3C `code`), and the encoder
    /// needs the identifier even for ordinary letters — handing it
    /// `UNIDENTIFIED` and relying on the UTF-8 text makes it emit a NUL byte,
    /// which is why typing produced nothing at all. The whole ANSI layout is
    /// mapped rather than the handful of keys with special encodings.
    private static func key(for event: NSEvent) -> GhosttyKey {
        switch Int(event.keyCode) {
        // Letters, in macOS virtual-keycode order (not alphabetical).
        case 0:   return GHOSTTY_KEY_A
        case 11:  return GHOSTTY_KEY_B
        case 8:   return GHOSTTY_KEY_C
        case 2:   return GHOSTTY_KEY_D
        case 14:  return GHOSTTY_KEY_E
        case 3:   return GHOSTTY_KEY_F
        case 5:   return GHOSTTY_KEY_G
        case 4:   return GHOSTTY_KEY_H
        case 34:  return GHOSTTY_KEY_I
        case 38:  return GHOSTTY_KEY_J
        case 40:  return GHOSTTY_KEY_K
        case 37:  return GHOSTTY_KEY_L
        case 46:  return GHOSTTY_KEY_M
        case 45:  return GHOSTTY_KEY_N
        case 31:  return GHOSTTY_KEY_O
        case 35:  return GHOSTTY_KEY_P
        case 12:  return GHOSTTY_KEY_Q
        case 15:  return GHOSTTY_KEY_R
        case 1:   return GHOSTTY_KEY_S
        case 17:  return GHOSTTY_KEY_T
        case 32:  return GHOSTTY_KEY_U
        case 9:   return GHOSTTY_KEY_V
        case 13:  return GHOSTTY_KEY_W
        case 7:   return GHOSTTY_KEY_X
        case 16:  return GHOSTTY_KEY_Y
        case 6:   return GHOSTTY_KEY_Z

        case 29:  return GHOSTTY_KEY_DIGIT_0
        case 18:  return GHOSTTY_KEY_DIGIT_1
        case 19:  return GHOSTTY_KEY_DIGIT_2
        case 20:  return GHOSTTY_KEY_DIGIT_3
        case 21:  return GHOSTTY_KEY_DIGIT_4
        case 23:  return GHOSTTY_KEY_DIGIT_5
        case 22:  return GHOSTTY_KEY_DIGIT_6
        case 26:  return GHOSTTY_KEY_DIGIT_7
        case 28:  return GHOSTTY_KEY_DIGIT_8
        case 25:  return GHOSTTY_KEY_DIGIT_9

        case 27:  return GHOSTTY_KEY_MINUS
        case 24:  return GHOSTTY_KEY_EQUAL
        case 33:  return GHOSTTY_KEY_BRACKET_LEFT
        case 30:  return GHOSTTY_KEY_BRACKET_RIGHT
        case 42:  return GHOSTTY_KEY_BACKSLASH
        case 41:  return GHOSTTY_KEY_SEMICOLON
        case 39:  return GHOSTTY_KEY_QUOTE
        case 50:  return GHOSTTY_KEY_BACKQUOTE
        case 43:  return GHOSTTY_KEY_COMMA
        case 47:  return GHOSTTY_KEY_PERIOD
        case 44:  return GHOSTTY_KEY_SLASH

        case 49:  return GHOSTTY_KEY_SPACE
        case 36:  return GHOSTTY_KEY_ENTER
        case 76:  return GHOSTTY_KEY_NUMPAD_ENTER
        case 48:  return GHOSTTY_KEY_TAB
        case 51:  return GHOSTTY_KEY_BACKSPACE
        case 53:  return GHOSTTY_KEY_ESCAPE
        case 117: return GHOSTTY_KEY_DELETE
        case 114: return GHOSTTY_KEY_INSERT

        case 115: return GHOSTTY_KEY_HOME
        case 119: return GHOSTTY_KEY_END
        case 116: return GHOSTTY_KEY_PAGE_UP
        case 121: return GHOSTTY_KEY_PAGE_DOWN
        case 123: return GHOSTTY_KEY_ARROW_LEFT
        case 124: return GHOSTTY_KEY_ARROW_RIGHT
        case 125: return GHOSTTY_KEY_ARROW_DOWN
        case 126: return GHOSTTY_KEY_ARROW_UP

        case 122: return GHOSTTY_KEY_F1
        case 120: return GHOSTTY_KEY_F2
        case 99:  return GHOSTTY_KEY_F3
        case 118: return GHOSTTY_KEY_F4
        case 96:  return GHOSTTY_KEY_F5
        case 97:  return GHOSTTY_KEY_F6
        case 98:  return GHOSTTY_KEY_F7
        case 100: return GHOSTTY_KEY_F8
        case 101: return GHOSTTY_KEY_F9
        case 109: return GHOSTTY_KEY_F10
        case 103: return GHOSTTY_KEY_F11
        case 111: return GHOSTTY_KEY_F12

        case 82:  return GHOSTTY_KEY_NUMPAD_0
        case 83:  return GHOSTTY_KEY_NUMPAD_1
        case 84:  return GHOSTTY_KEY_NUMPAD_2
        case 85:  return GHOSTTY_KEY_NUMPAD_3
        case 86:  return GHOSTTY_KEY_NUMPAD_4
        case 87:  return GHOSTTY_KEY_NUMPAD_5
        case 88:  return GHOSTTY_KEY_NUMPAD_6
        case 89:  return GHOSTTY_KEY_NUMPAD_7
        case 91:  return GHOSTTY_KEY_NUMPAD_8
        case 92:  return GHOSTTY_KEY_NUMPAD_9
        case 65:  return GHOSTTY_KEY_NUMPAD_DECIMAL
        case 67:  return GHOSTTY_KEY_NUMPAD_MULTIPLY
        case 69:  return GHOSTTY_KEY_NUMPAD_ADD
        case 75:  return GHOSTTY_KEY_NUMPAD_DIVIDE
        case 78:  return GHOSTTY_KEY_NUMPAD_SUBTRACT
        case 81:  return GHOSTTY_KEY_NUMPAD_EQUAL
        case 71:  return GHOSTTY_KEY_NUMPAD_CLEAR

        default:  return GHOSTTY_KEY_UNIDENTIFIED
        }
    }
}
