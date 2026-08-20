import Foundation
import CGhosttyVT

/// A colour resolved by the engine.
struct EngineColor: Equatable {
    var r: UInt8, g: UInt8, b: UInt8
}

/// One rendered cell: the grapheme cluster to draw and its resolved colours.
/// Nil colours mean "use the terminal default", which is what lets the caller
/// leave the background unpainted — and therefore transparent.
struct EngineCell: Equatable {
    var text: String
    var foreground: EngineColor?
    var background: EngineColor?
    var selected: Bool
}

struct EngineRow: Equatable {
    var index: Int
    var cells: [EngineCell]
}

/// Where the caret is and how it should look.
struct EngineCursor: Equatable {
    var column: Int
    var row: Int
    var visible: Bool
    var blinking: Bool
    var wideTail: Bool
}

/// One frame's worth of everything the renderer needs.
struct EngineFrame {
    var rows: [EngineRow]
    var cursor: EngineCursor?
    var columns: Int
}

/// Swift wrapper over libghostty-vt: Ghostty's terminal state machine and
/// render state, with no renderer attached.
///
/// This is deliberately the whole engine surface the app needs. Drawing lives
/// elsewhere, which is the entire point of the move — owning the draw is what
/// makes a transparent background possible.
final class GhosttyCore {
    private var terminal: GhosttyTerminal?
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    /// Reused across rows; the API binds it to the current row per iteration
    /// rather than allocating one each time.
    private var cellsHandle: GhosttyRenderStateRowCells?

    private(set) var columns: UInt16
    private(set) var rows: UInt16

    /// Exposed so the key encoder can sync terminal modes from it.
    var terminalHandle: GhosttyTerminal? { terminal }

    /// Guards the terminal instance.
    ///
    /// Bytes arrive on the pty's queue while the renderer snapshots on the main
    /// thread. libghostty-vt requires exclusive access during an update — the
    /// header says so explicitly — and without this the render state is read
    /// mid-mutation, which shows up as text drawn at the wrong rows and columns.
    private let lock = NSLock()

    init?(columns: UInt16 = 80, rows: UInt16 = 24) {
        self.columns = columns
        self.rows = rows

        guard ghostty_terminal_new(nil, &terminal, columns, rows) == GHOSTTY_SUCCESS,
              ghostty_render_state_new(nil, &renderState) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &cellsHandle) == GHOSTTY_SUCCESS
        else { return nil }
    }

    deinit {
        if let cellsHandle { ghostty_render_state_row_cells_free(cellsHandle) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
        if let terminal { ghostty_terminal_free(terminal) }
    }

    func resize(columns: UInt16, rows: UInt16, cellWidth: UInt32, cellHeight: UInt32) {
        guard let terminal else { return }
        lock.lock()
        defer { lock.unlock() }
        self.columns = columns
        self.rows = rows
        _ = ghostty_terminal_resize(terminal, columns, rows, cellWidth, cellHeight)
    }

    /// Feeds bytes read from the pty into the parser.
    func feed(_ bytes: UnsafeRawBufferPointer) {
        guard let terminal, let base = bytes.baseAddress else { return }
        lock.lock()
        defer { lock.unlock() }
        ghostty_terminal_vt_write(terminal, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    /// Scrolls the viewport, in rows. Negative scrolls back into history.
    func scrollViewport(by delta: Int) {
        guard let terminal else { return }
        lock.lock()
        defer { lock.unlock() }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = delta
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// Jumps back to the live edge, which is what any keypress should do.
    func scrollToBottom() {
        guard let terminal else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        // A delta larger than any plausible scrollback clamps to the bottom.
        behavior.value.delta = Int(Int32.max)
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// Reads the cursor from the last `snapshot()` update.
    /// Called from `frame()` after `snapshot()` has released the lock; the
    /// render state is not mutated by reading it.
    private func readCursor() -> EngineCursor? {
        lock.lock()
        defer { lock.unlock() }
        guard let renderState else { return nil }
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        guard ghostty_render_state_get(renderState,
                                       GHOSTTY_RENDER_STATE_DATA_CURSOR,
                                       &cursor) == GHOSTTY_SUCCESS,
              cursor.viewport_has_value, cursor.visible else { return nil }
        return EngineCursor(column: Int(cursor.viewport_x),
                            row: Int(cursor.viewport_y),
                            visible: cursor.visible,
                            blinking: cursor.blinking,
                            wideTail: cursor.wide_tail)
    }

    /// True when a program has asked to receive mouse events.
    var wantsMouseTracking: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return false }
        var tracking = false
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING,
                                   &tracking) == GHOSTTY_SUCCESS else { return false }
        return tracking
    }

    /// Rows currently held in scrollback, above the viewport.
    var scrollbackRows: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return 0 }
        var value: Int = 0
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS,
                                   &value) == GHOSTTY_SUCCESS else { return 0 }
        return value
    }

    /// Scrolls so `row` (counted from the top of scrollback) is the first
    /// visible line.
    func scrollToRow(_ row: Int) {
        guard let terminal else { return }
        lock.lock()
        defer { lock.unlock() }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        behavior.value.row = Swift.max(0, row)
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    /// The title set by the program via OSC, if any.
    var title: String? { borrowedString(GHOSTTY_TERMINAL_DATA_TITLE) }

    /// The working directory reported via OSC 7, if any.
    var workingDirectory: String? { borrowedString(GHOSTTY_TERMINAL_DATA_PWD) }

    /// Reads a borrowed string field. The pointer is only valid until the next
    /// mutating call, so it is copied into a Swift String under the lock.
    private func borrowedString(_ kind: GhosttyTerminalData) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal else { return nil }
        var value = GhosttyString()
        guard ghostty_terminal_get(terminal, kind, &value) == GHOSTTY_SUCCESS,
              value.len > 0, let ptr = value.ptr else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: value.len),
                      as: UTF8.self)
    }

    /// Snapshots the visible viewport plus the cursor.
    func frame() -> EngineFrame {
        let rows = snapshot()
        return EngineFrame(rows: rows, cursor: readCursor(), columns: Int(columns))
    }

    /// Snapshots the visible viewport for drawing.
    ///
    /// The engine tracks dirty rows, so a future renderer can switch to
    /// `next_dirty` and redraw only what changed; this returns everything
    /// while the drawing layer is still being built.
    func snapshot() -> [EngineRow] {
        lock.lock()
        defer { lock.unlock() }
        guard let terminal, let renderState, let rowIterator, let cellsHandle,
              ghostty_render_state_update(renderState, terminal) == GHOSTTY_SUCCESS
        else { return [] }

        var iterator: GhosttyRenderStateRowIterator? = rowIterator
        guard ghostty_render_state_get(renderState,
                                       GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                                       &iterator) == GHOSTTY_SUCCESS
        else { return [] }

        var result: [EngineRow] = []
        var rowIndex = 0
        var utf8 = [UInt8](repeating: 0, count: 64)

        while ghostty_render_state_row_iterator_next(rowIterator) {
            var bound: GhosttyRenderStateRowCells? = cellsHandle
            guard ghostty_render_state_row_get(rowIterator,
                                               GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                                               &bound) == GHOSTTY_SUCCESS else {
                rowIndex += 1
                continue
            }

            var cells: [EngineCell] = []
            cells.reserveCapacity(Int(columns))

            // Addressing cells by column rather than walking with `_next`.
            // The iterator does not necessarily yield one entry per column, so
            // a running counter drifts out of step with the real grid and the
            // text lands in the wrong place.
            for column in 0..<columns {
                guard ghostty_render_state_row_cells_select(cellsHandle, column) == GHOSTTY_SUCCESS else {
                    cells.append(EngineCell(text: " ", foreground: nil, background: nil, selected: false))
                    continue
                }

                var text = ""
                utf8.withUnsafeMutableBufferPointer { raw in
                    var buffer = GhosttyBuffer(ptr: raw.baseAddress, cap: raw.count, len: 0)
                    if ghostty_render_state_row_cells_get(
                        cellsHandle,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8,
                        &buffer) == GHOSTTY_SUCCESS, buffer.len > 0 {
                        text = String(decoding: raw.prefix(buffer.len), as: UTF8.self)
                    }
                }

                // A missing colour is not an error: it means the cell uses the
                // terminal default, which the renderer may choose not to paint.
                var foreground: EngineColor?
                var rgb = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb) == GHOSTTY_SUCCESS {
                    foreground = EngineColor(r: rgb.r, g: rgb.g, b: rgb.b)
                }

                var background: EngineColor?
                var bgRgb = GhosttyColorRgb()
                if ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgRgb) == GHOSTTY_SUCCESS {
                    background = EngineColor(r: bgRgb.r, g: bgRgb.g, b: bgRgb.b)
                }

                var selected = false
                _ = ghostty_render_state_row_cells_get(
                    cellsHandle, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &selected)

                cells.append(EngineCell(text: text.isEmpty ? " " : text,
                                        foreground: foreground,
                                        background: background, selected: selected))
            }

            result.append(EngineRow(index: rowIndex, cells: cells))
            rowIndex += 1
        }
        return result
    }

    /// Round-trips a known string through the engine. Used to verify the
    /// vendored library links and parses before anything depends on it.
    static func selfTest() -> String? {
        guard let core = GhosttyCore(columns: 40, rows: 4) else { return nil }
        core.feed(Array("ok \u{1B}[31mRED\u{1B}[0m".utf8))
        guard let first = core.snapshot().first else { return nil }
        return first.cells.map(\.text).joined().trimmingCharacters(in: .whitespaces)
    }
}
