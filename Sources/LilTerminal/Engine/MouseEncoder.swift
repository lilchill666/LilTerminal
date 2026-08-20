import Foundation
import AppKit
import CGhosttyVT

/// Turns AppKit mouse events into terminal escape sequences.
///
/// Which encoding a program gets — X10, normal, button-event, any-event, SGR —
/// depends on modes it set at runtime. The encoder is synced from the terminal
/// so those are honoured rather than guessed, exactly like key encoding.
final class MouseEncoder {
    private var encoder: GhosttyMouseEncoder?
    private var event: GhosttyMouseEvent?

    init?() {
        guard ghostty_mouse_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS else { return nil }
    }

    deinit {
        if let event { ghostty_mouse_event_free(event) }
        if let encoder { ghostty_mouse_encoder_free(encoder) }
    }

    func sync(with terminal: GhosttyTerminal?) {
        guard let encoder, let terminal else { return }
        ghostty_mouse_encoder_setopt_from_terminal(encoder, terminal)
    }

    /// - Parameter point: position in the terminal's own pixel space, with the
    ///   text inset already removed. The engine converts to cells itself, so it
    ///   must agree with the size given to `resize`.
    func encode(action: GhosttyMouseAction, button: GhosttyMouseButton?,
                modifiers: NSEvent.ModifierFlags, point: CGPoint) -> [UInt8]? {
        guard let encoder, let event else { return nil }

        ghostty_mouse_event_set_action(event, action)
        if let button {
            ghostty_mouse_event_set_button(event, button)
        } else {
            // Motion with no button held still matters in any-event mode.
            ghostty_mouse_event_clear_button(event)
        }
        ghostty_mouse_event_set_mods(event, Self.mods(for: modifiers))
        ghostty_mouse_event_set_position(
            event, GhosttyMousePosition(x: Float(point.x), y: Float(point.y)))

        var buffer = [CChar](repeating: 0, count: 64)
        var length = 0
        let status = buffer.withUnsafeMutableBufferPointer {
            ghostty_mouse_encoder_encode(encoder, event, $0.baseAddress, $0.count, &length)
        }
        // Not every event produces bytes: in normal tracking mode, motion
        // without a held button encodes to nothing at all.
        guard status == GHOSTTY_SUCCESS, length > 0 else { return nil }
        return buffer.prefix(length).map { UInt8(bitPattern: $0) }
    }

    static func button(for event: NSEvent) -> GhosttyMouseButton {
        switch event.buttonNumber {
        case 0:  return GHOSTTY_MOUSE_BUTTON_LEFT
        case 1:  return GHOSTTY_MOUSE_BUTTON_RIGHT
        case 2:  return GHOSTTY_MOUSE_BUTTON_MIDDLE
        default: return GHOSTTY_MOUSE_BUTTON_UNKNOWN
        }
    }

    private static func mods(for flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var mods: UInt16 = 0
        if flags.contains(.shift)   { mods |= UInt16(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { mods |= UInt16(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option)  { mods |= UInt16(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { mods |= UInt16(GHOSTTY_MODS_SUPER) }
        return mods
    }
}
