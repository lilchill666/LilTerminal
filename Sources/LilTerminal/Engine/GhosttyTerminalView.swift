import AppKit
import CoreText
import CGhosttyVT
import TerminalCore

/// A terminal view drawn by this app on top of Ghostty's VT engine.
///
/// The whole reason this exists: cells that carry no explicit background are
/// simply not painted, so whatever sits behind the view shows through. That is
/// what makes a transparent, blurred terminal possible.
final class GhosttyTerminalView: NSView {
    // MARK: Engine

    private let core: GhosttyCore
    private var pty: TerminalTransport = PTY()
    private let encoder = KeyEncoder()
    private let mouse = MouseEncoder()

    // MARK: Appearance

    var font: NSFont { didSet { measureCell(); reflow() } }
    var backgroundColor: NSColor = .black { didSet { needsDisplay = true } }
    var foregroundColor: NSColor = .white { didSet { needsDisplay = true } }
    var cursorColor: NSColor = .white { didSet { needsDisplay = true } }
    var selectionColor: NSColor = .selectedTextBackgroundColor { didSet { needsDisplay = true } }
    /// 0 leaves the background unpainted entirely — fully transparent.
    var backgroundOpacity: CGFloat = 1 { didSet { needsDisplay = true } }
    var padding: CGFloat = 12 { didSet { reflow() } }

    // MARK: Callbacks

    var onTitleChange: ((String) -> Void)?
    var onDirectoryChange: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    /// Fires when output arrives, so a tab can mark itself unread.
    var onOutput: (() -> Void)?
    /// Fires on real keyboard or mouse input, for the idle heuristic.
    var onUserInput: (() -> Void)?
    /// Fires with the command line the shell was showing when Return was hit.
    var onCommandSubmitted: ((String) -> Void)?

    // MARK: State

    private var cellSize = CGSize(width: 8, height: 16)
    private var baselineOffset: CGFloat = 12
    private var frameData = EngineFrame(rows: [], cursor: nil, columns: 80)
    private var needsFrameRefresh = false
    /// Local selection, in cells. The engine tracks its own selection for
    /// programs that ask for it; this is the user dragging with a mouse.
    private var selectionAnchor: (row: Int, column: Int)?
    private var selectionHead: (row: Int, column: Int)?
    /// The clickable thing under the pointer, if any.
    private var hoveredTarget: (range: Range<Int>, row: Int, target: ClickTarget)?
    /// Absolute rows (counted from the top of scrollback) where commands were
    /// submitted. Recorded at submit time rather than found by scanning,
    /// because the prompt's appearance is not something we can reliably parse.
    private var promptMarks: [Int] = []
    private let promptMarkLimit = 400
    private var lastTitle: String?
    private var lastDirectory: String?
    private static let debug = ProcessInfo.processInfo.environment["LILTERM_DEBUG"] != nil
    private var drawCount = 0
    private var rowsDrawn = 0

    var isRunning: Bool { pty.isRunning }
    var childPID: pid_t { pty.processID }

    /// - Parameter transport: where the bytes come from. Defaults to a pty
    ///   this process owns; a daemon-backed one survives the app quitting.
    init?(font: NSFont, transport: TerminalTransport? = nil) {
        guard let core = GhosttyCore(columns: 80, rows: 24) else { return nil }
        self.core = core
        if let transport { self.pty = transport }
        self.font = font
        super.init(frame: .zero)
        wantsLayer = true
        // Never opaque: an opaque layer is exactly what defeated transparency
        // on the previous engine.
        layer?.isOpaque = false
        measureCell()

        pty.onOutput = { [weak self] bytes in
            guard let self else { return }
            self.core.feed(bytes)
            self.scheduleRefresh()
            DispatchQueue.main.async { self.onOutput?() }
        }
        pty.onExit = { [weak self] code in
            self?.onExit?(code)
            self?.needsDisplay = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// The window is movable by its background, and AppKit defaults this to
    /// true for a view that draws no opaque background — which hands every
    /// drag to window movement and makes text selection impossible.
    override var mouseDownCanMoveWindow: Bool { false }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: - Process

    func start(executable: String, args: [String], environment: [String],
               execName: String?, directory: String?) throws {
        let size = gridSize()
        try pty.start(executable: executable, args: args, environment: environment,
                      execName: execName, directory: directory,
                      columns: size.columns, rows: size.rows)
        core.resize(columns: size.columns, rows: size.rows,
                    cellWidth: UInt32(cellSize.width), cellHeight: UInt32(cellSize.height))
    }

    func terminate() { pty.terminate() }

    /// Leaves the shell running; used when quitting with persistence on.
    func detach() { pty.detach() }

    func send(_ bytes: [UInt8]) {
        core.scrollToBottom()
        pty.write(bytes)
    }

    func send(text: String) { send(Array(text.utf8)) }

    // MARK: - Layout

    private func measureCell() {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        // "M" is the reference advance; the font is monospaced so every cell
        // matches it.
        let advance = NSAttributedString(string: "M", attributes: attributes).size().width
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        cellSize = CGSize(width: ceil(advance),
                          height: ceil(ascent + descent + leading))
        baselineOffset = ceil(ascent)
    }

    private func gridSize() -> (columns: UInt16, rows: UInt16) {
        // The shell is started before SwiftUI has laid the view out, so bounds
        // are still zero. Spawning into a 2x1 grid mangles the first prompt;
        // a conventional default is used until the first real layout arrives.
        guard bounds.width > 1, bounds.height > 1 else { return (80, 24) }
        let usableWidth = max(0, bounds.width - padding * 2)
        let usableHeight = max(0, bounds.height - padding * 2)
        let columns = max(2, Int(usableWidth / cellSize.width))
        let rows = max(1, Int(usableHeight / cellSize.height))
        return (UInt16(min(columns, Int(UInt16.max))), UInt16(min(rows, Int(UInt16.max))))
    }

    private func reflow() {
        let size = gridSize()
        guard size.columns != core.columns || size.rows != core.rows else {
            scheduleRefresh()
            return
        }
        core.resize(columns: size.columns, rows: size.rows,
                    cellWidth: UInt32(cellSize.width), cellHeight: UInt32(cellSize.height))
        pty.resize(columns: size.columns, rows: size.rows)
        scheduleRefresh()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        reflow()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Output that arrived before the view was on screen has nothing else
        // to trigger a first paint.
        reflow()
        scheduleRefresh()
    }

    // MARK: - Refresh

    /// Coalesces bursts of output into one redraw per runloop turn; a redraw
    /// per read would spend all its time in drawing during heavy output.
    private func scheduleRefresh() {
        guard !needsFrameRefresh else { return }
        needsFrameRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needsFrameRefresh = false
            self.applyFrame(self.core.frame())
            self.publishMetadata()
            self.updateTrackingArea()
        }
    }

    /// Reports OSC-provided title and directory changes, only when they change.
    private func publishMetadata() {
        if let title = core.title, !title.isEmpty, title != lastTitle {
            lastTitle = title
            onTitleChange?(title)
        }
        if let directory = core.workingDirectory, !directory.isEmpty, directory != lastDirectory {
            lastDirectory = directory
            // Shells report this as a file:// URL via OSC 7.
            if let url = URL(string: directory), url.isFileURL {
                onDirectoryChange?(url.path)
            } else {
                onDirectoryChange?(directory)
            }
        }
    }

    /// Swaps in a new frame and repaints only what changed.
    ///
    /// A full-view repaint on every output batch spends most of its time
    /// redrawing rows that did not move — which matters exactly when it hurts
    /// most, during heavy output.
    private func applyFrame(_ frame: EngineFrame) {
        let previous = frameData
        let previousCursor = previous.cursor
        frameData = frame

        // Any structural change is cheaper to handle as a full repaint than to
        // reason about row by row.
        guard previous.rows.count == frame.rows.count,
              previous.columns == frame.columns else {
            needsDisplay = true
            return
        }

        var dirty: NSRect = .zero
        var isEmpty = true

        func invalidate(row: Int) {
            let rect = NSRect(x: 0, y: padding + CGFloat(row) * cellSize.height,
                              width: bounds.width, height: cellSize.height)
            dirty = isEmpty ? rect : dirty.union(rect)
            isEmpty = false
        }

        for (index, row) in frame.rows.enumerated() where row != previous.rows[index] {
            invalidate(row: row.index)
        }
        // The caret leaves a hole behind it; both ends need repainting.
        if previousCursor != frame.cursor {
            if let cursor = previousCursor { invalidate(row: cursor.row) }
            if let cursor = frame.cursor { invalidate(row: cursor.row) }
        }

        if !isEmpty { setNeedsDisplay(dirty) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Erase first. Filling with a translucent colour composites over the
        // previous frame instead of replacing it, so old glyphs pile up.
        context.clear(dirtyRect)
        if backgroundOpacity > 0 {
            context.setFillColor(backgroundColor.withAlphaComponent(backgroundOpacity).cgColor)
            context.fill(dirtyRect)
        }

        context.textMatrix = .identity
        let selection = normalizedSelection()

        for row in frameData.rows {
            let y = padding + CGFloat(row.index) * cellSize.height
            guard y < bounds.height, y + cellSize.height > 0 else { continue }
            // With a partial invalidation, only the affected rows are redrawn.
            guard y < dirtyRect.maxY, y + cellSize.height > dirtyRect.minY else { continue }
            if Self.debug { rowsDrawn += 1 }

            // Group adjacent cells sharing appearance into runs: one fill and
            // one text draw per run instead of per cell.
            var index = 0
            while index < row.cells.count {
                let cell = row.cells[index]
                let selected = isSelected(row: row.index, column: index, in: selection)
                var end = index + 1
                while end < row.cells.count,
                      row.cells[end].background == cell.background,
                      row.cells[end].foreground == cell.foreground,
                      isSelected(row: row.index, column: end, in: selection) == selected {
                    end += 1
                }

                let x = padding + CGFloat(index) * cellSize.width
                let width = CGFloat(end - index) * cellSize.width
                let rect = CGRect(x: x, y: y, width: width, height: cellSize.height)

                if selected {
                    context.setFillColor(selectionColor.cgColor)
                    context.fill(rect)
                } else if let background = cell.background {
                    // Explicit cell background only. A nil background is left
                    // unpainted so the layer behind shows through.
                    context.setFillColor(color(background).cgColor)
                    context.fill(rect)
                }

                drawCells(row.cells[index..<end], startColumn: index,
                          baseline: y + baselineOffset,
                          color: cell.foreground.map(color) ?? foregroundColor,
                          context: context)
                index = end
            }
        }

        drawHoveredLink(in: context)
        drawCursor(in: context)

        if Self.debug {
            drawCount += 1
            let fraction = frameData.rows.isEmpty ? 0
                : Double(rowsDrawn) / Double(drawCount * frameData.rows.count)
            if drawCount % 15 == 0 {
                FileHandle.standardError.write(
                    "draw #\(drawCount): rows/frame=\(String(format: "%.1f", Double(rowsDrawn) / Double(drawCount))) of \(frameData.rows.count) (\(String(format: "%.0f%%", fraction * 100)))\n"
                        .data(using: .utf8)!)
            }
        }
    }

    /// Draws a run of cells, each pinned to its own grid column.
    ///
    /// Drawing a run as one CTLine advances by the font's natural width, which
    /// is narrower than the rounded cell width — so glyphs drift left of their
    /// cells and the cursor stops lining up with the text. A terminal has to
    /// place every cell explicitly.
    private func drawCells(_ cells: ArraySlice<EngineCell>, startColumn: Int,
                           baseline: CGFloat, color: NSColor, context: CGContext) {
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        var complex: [(String, CGFloat)] = []

        for (offset, cell) in cells.enumerated() {
            let text = cell.text
            guard !text.isEmpty, text != " " else { continue }
            let x = padding + CGFloat(startColumn + offset) * cellSize.width

            let utf16 = Array(text.utf16)
            var glyph = CGGlyph()
            // The fast path covers the overwhelming majority: one UTF-16 unit
            // with a glyph in the base font. Everything else — emoji, combining
            // marks, anything needing fallback — goes through CTLine.
            if utf16.count == 1,
               CTFontGetGlyphsForCharacters(font, utf16, &glyph, 1), glyph != 0 {
                glyphs.append(glyph)
                positions.append(CGPoint(x: x, y: -baseline))
            } else {
                complex.append((text, x))
            }
        }

        context.saveGState()
        context.scaleBy(x: 1, y: -1)
        // Reset per run, not once per frame. CTLineDraw mutates the text
        // matrix, so a single fallback glyph (an emoji, say) silently
        // transforms every draw after it — which looks like rows landing at
        // the wrong position rather than a text-drawing problem.
        context.textMatrix = .identity

        if !glyphs.isEmpty {
            context.setFillColor(color.cgColor)
            CTFontDrawGlyphs(font, glyphs, positions, glyphs.count, context)
        }

        for (text, x) in complex {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: -baseline)
            CTLineDraw(line, context)
        }

        context.restoreGState()
    }

    private func drawHoveredLink(in context: CGContext) {
        guard let hovered = hoveredTarget else { return }
        let y = padding + CGFloat(hovered.row) * cellSize.height + cellSize.height - 1.5
        let x = padding + CGFloat(hovered.range.lowerBound) * cellSize.width
        let width = CGFloat(hovered.range.count) * cellSize.width
        context.setFillColor(cursorColor.withAlphaComponent(0.8).cgColor)
        context.fill(CGRect(x: x, y: y, width: width, height: 1))
    }

    private func drawCursor(in context: CGContext) {
        guard let cursor = frameData.cursor, window?.firstResponder === self || true else { return }
        let rect = CGRect(x: padding + CGFloat(cursor.column) * cellSize.width,
                          y: padding + CGFloat(cursor.row) * cellSize.height,
                          width: cellSize.width * (cursor.wideTail ? 2 : 1),
                          height: cellSize.height)
        let focused = window?.firstResponder === self
        if focused {
            context.setFillColor(cursorColor.withAlphaComponent(0.9).cgColor)
            context.fill(rect)
        } else {
            // Hollow when unfocused, matching every other macOS terminal.
            context.setStrokeColor(cursorColor.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1)
            context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func color(_ engine: EngineColor) -> NSColor {
        NSColor(srgbRed: CGFloat(engine.r) / 255, green: CGFloat(engine.g) / 255,
                blue: CGFloat(engine.b) / 255, alpha: 1)
    }

    /// Compares a fresh engine snapshot against the frame the renderer is
    /// actually drawing, so a mismatch between the two is immediately visible.
    func dumpRows() {
        func describe(_ label: String, _ frame: EngineFrame) -> String {
            var out = "\n\(label): rows=\(frame.rows.count) cols=\(frame.columns)\n"
            for row in frame.rows {
                let firstContent = row.cells.firstIndex { $0.text != " " && !$0.text.isEmpty }
                let text = row.cells.map(\.text).joined()
                let trimmed = String(text.reversed().drop { $0 == " " }.reversed())
                guard !trimmed.isEmpty else { continue }
                let x = padding + CGFloat(firstContent ?? 0) * cellSize.width
                let y = padding + CGFloat(row.index) * cellSize.height
                out += "  row=\(row.index) firstCol=\(firstContent ?? -1) x=\(x) y=\(y) |\(trimmed.prefix(40))|\n"
            }
            return out
        }
        var report = "cellSize=\(cellSize) padding=\(padding) bounds=\(bounds.size)"
        report += describe("FRESH from engine", core.frame())
        report += describe("CACHED used by draw", frameData)
        FileHandle.standardError.write(report.data(using: .utf8)!)
    }

    // MARK: - Input

    override func keyDown(with event: NSEvent) {
        onUserInput?()
        // Read the line before sending: once Return reaches the shell the line
        // is gone.
        if event.keyCode == 36 || event.keyCode == 76 {
            if let command = currentInputLine() { onCommandSubmitted?(command) }
            recordPromptMark()
        }
        encoder?.sync(with: core.terminalHandle)
        if let bytes = encoder?.encode(event) {
            send(bytes)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if forwardsMouse(event) {
            // Wheel is reported as buttons four and five, one event per line.
            let steps = Int(abs(event.scrollingDeltaY / cellSize.height).rounded())
            guard steps > 0 else { return }
            let button = event.scrollingDeltaY > 0
                ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
            for _ in 0..<min(steps, 10) {
                sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: button, event: event)
            }
            return
        }
        let lines = Int((event.scrollingDeltaY / cellSize.height).rounded())
        guard lines != 0 else { return }
        core.scrollViewport(by: -lines)
        scheduleRefresh()
    }

    // MARK: - Prompt marks

    private func recordPromptMark() {
        guard let cursor = frameData.cursor else { return }
        let absolute = core.scrollbackRows + cursor.row
        // Consecutive Returns on an empty prompt should not each add a mark.
        if let last = promptMarks.last, abs(last - absolute) <= 1 { return }
        promptMarks.append(absolute)
        if promptMarks.count > promptMarkLimit {
            promptMarks.removeFirst(promptMarks.count - promptMarkLimit)
        }
    }

    /// The first visible absolute row.
    private var viewportTop: Int { core.scrollbackRows }

    @discardableResult
    func jumpToPrompt(previous: Bool) -> Bool {
        guard !promptMarks.isEmpty else { return false }
        let current = viewportTop
        let target = previous
            ? promptMarks.last { $0 < current - 1 }
            : promptMarks.first { $0 > current + 1 }
        guard let target else { return false }
        // Land a couple of rows above so the prompt is not flush to the top.
        core.scrollToRow(max(0, target - 2))
        scheduleRefresh()
        return true
    }

    // MARK: - Clickable targets

    enum ClickTarget {
        case url(URL)
        case path(String, line: Int?)
    }

    /// Finds a URL or file path around a column in a line.
    ///
    /// Scanning on demand rather than indexing every line: this runs once per
    /// pointer move over a modifier-held terminal, not per frame.
    static func target(in line: String, at column: Int) -> (Range<Int>, ClickTarget)? {
        let characters = Array(line)
        guard column >= 0, column < characters.count, !characters[column].isWhitespace else { return nil }

        // Expand to the surrounding non-whitespace run, then trim punctuation
        // that is far more likely to be prose than part of the target.
        var start = column
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = column
        while end + 1 < characters.count, !characters[end + 1].isWhitespace { end += 1 }

        var token = String(characters[start...end])
        while let last = token.last, ",.;:)]}'\"".contains(last) {
            token.removeLast()
            end -= 1
        }
        while let first = token.first, "([{'\"".contains(first) {
            token.removeFirst()
            start += 1
        }
        guard token.count > 1 else { return nil }

        if token.hasPrefix("http://") || token.hasPrefix("https://"),
           let url = URL(string: token) {
            return (start..<(end + 1), .url(url))
        }

        // file.swift:42 and file.swift:42:9 both point at a line.
        var path = token
        var lineNumber: Int?
        let parts = token.split(separator: ":")
        if parts.count >= 2, let number = Int(parts[1]) {
            path = String(parts[0])
            lineNumber = number
        }
        guard path.contains("/") || path.contains(".") else { return nil }
        return (start..<(end + 1), .path(path, line: lineNumber))
    }

    /// Resolves a path against the shell's directory and opens it.
    private func open(_ target: ClickTarget) {
        switch target {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .path(let path, let line):
            let base = resolveDirectory?() ?? core.workingDirectory
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            let resolved = path.hasPrefix("/") ? path
                : (base as NSString).appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: resolved) else { return }
            if let line {
                // Ask the default editor to jump to the line where it can.
                let url = URL(fileURLWithPath: resolved)
                let selection = "\(url.path):\(line)"
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-a", "Xcode", "--args", selection]
                if (try? task.run()) == nil {
                    NSWorkspace.shared.open(url)
                }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
            }
        }
    }

    /// Cmd is the modifier, matching every other terminal and editor.
    private func updateHoveredTarget(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard modifiers.contains(.command) else {
            if hoveredTarget != nil { hoveredTarget = nil; needsDisplay = true }
            return
        }
        let cell = self.cell(at: point)
        guard let row = frameData.rows.first(where: { $0.index == cell.row }) else {
            hoveredTarget = nil
            return
        }
        let line = row.cells.map(\.text).joined()
        if let (range, target) = Self.target(in: line, at: cell.column) {
            let new = (range: range, row: cell.row, target: target)
            if hoveredTarget?.range != new.range || hoveredTarget?.row != new.row {
                hoveredTarget = new
                needsDisplay = true
            }
        } else if hoveredTarget != nil {
            hoveredTarget = nil
            needsDisplay = true
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateHoveredTarget(at: window?.mouseLocationOutsideOfEventStream ?? point,
                            modifiers: event.modifierFlags)
    }

    // MARK: - Selection

    private func cell(at point: NSPoint) -> (row: Int, column: Int) {
        let local = convert(point, from: nil)
        let column = Int((local.x - padding) / cellSize.width)
        let row = Int((local.y - padding) / cellSize.height)
        return (max(0, row), max(0, column))
    }

    /// Position inside the terminal's own pixel space, inset removed, which is
    /// the space the engine converts to cells.
    private func terminalPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: max(0, local.x - padding), y: max(0, local.y - padding))
    }

    /// Programs that enable mouse tracking take precedence — but holding Shift
    /// always reaches selection, which is the long-standing terminal convention
    /// for copying out of something like vim.
    private func forwardsMouse(_ event: NSEvent) -> Bool {
        !event.modifierFlags.contains(.shift) && core.wantsMouseTracking
    }

    private func sendMouse(_ action: GhosttyMouseAction, button: GhosttyMouseButton?,
                           event: NSEvent) {
        mouse?.sync(with: core.terminalHandle)
        if let bytes = mouse?.encode(action: action, button: button,
                                     modifiers: event.modifierFlags,
                                     point: terminalPoint(event)) {
            pty.write(bytes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        onUserInput?()
        window?.makeFirstResponder(self)
        // Cmd-click opens the thing under the pointer instead of selecting.
        if event.modifierFlags.contains(.command) {
            updateHoveredTarget(at: event.locationInWindow, modifiers: event.modifierFlags)
            if let hovered = hoveredTarget {
                open(hovered.target)
                return
            }
        }
        if forwardsMouse(event) {
            sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: MouseEncoder.button(for: event), event: event)
            return
        }
        selectionAnchor = cell(at: event.locationInWindow)
        selectionHead = selectionAnchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if forwardsMouse(event) {
            sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: MouseEncoder.button(for: event), event: event)
            return
        }
        selectionHead = cell(at: event.locationInWindow)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if forwardsMouse(event) {
            sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: MouseEncoder.button(for: event), event: event)
            return
        }
        if let anchor = selectionAnchor, let head = selectionHead,
           anchor.row == head.row, anchor.column == head.column {
            selectionAnchor = nil
            selectionHead = nil
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard forwardsMouse(event) else { super.rightMouseDown(with: event); return }
        sendMouse(GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT, event: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard forwardsMouse(event) else { super.rightMouseUp(with: event); return }
        sendMouse(GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_RIGHT, event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredTarget(at: event.locationInWindow, modifiers: event.modifierFlags)
        guard forwardsMouse(event) else { return }
        sendMouse(GHOSTTY_MOUSE_ACTION_MOTION, button: nil, event: event)
    }

    /// Motion tracking is only worth the event traffic while a program wants it.
    private func updateTrackingArea() {
        trackingAreas.forEach(removeTrackingArea)
        // Needed for cmd-hover link detection too, not only mouse reporting.
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self))
    }

    private func normalizedSelection() -> (start: (row: Int, column: Int), end: (row: Int, column: Int))? {
        guard let anchor = selectionAnchor, let head = selectionHead else { return nil }
        if anchor.row < head.row || (anchor.row == head.row && anchor.column <= head.column) {
            return (anchor, head)
        }
        return (head, anchor)
    }

    private func isSelected(row: Int, column: Int,
                            in selection: (start: (row: Int, column: Int),
                                           end: (row: Int, column: Int))?) -> Bool {
        guard let selection else { return false }
        if row < selection.start.row || row > selection.end.row { return false }
        if row == selection.start.row && column < selection.start.column { return false }
        if row == selection.end.row && column > selection.end.column { return false }
        return true
    }

    /// Searches the visible viewport for `term`, selects the match, and returns
    /// whether one was found. Search continues from the current selection so
    /// repeated calls walk through matches.
    @discardableResult
    func find(_ term: String, forward: Bool) -> Bool {
        guard !term.isEmpty else { return false }
        let needle = Array(term.lowercased())

        // Row text is rebuilt per search rather than cached: searches are rare
        // and a stale cache would silently match text no longer on screen.
        let haystack: [(row: Int, characters: [Character])] = frameData.rows.map {
            ($0.index, Array($0.cells.map(\.text).joined().lowercased()))
        }
        guard !haystack.isEmpty else { return false }

        let fromRow = selectionAnchor?.row
        let fromColumn = selectionAnchor?.column

        func match(in entry: (row: Int, characters: [Character]), bounded: Bool) -> Int? {
            let characters = entry.characters
            guard characters.count >= needle.count else { return nil }
            let starts = forward
                ? Array(0...(characters.count - needle.count))
                : Array((0...(characters.count - needle.count)).reversed())
            for start in starts {
                if bounded, let fromColumn, entry.row == fromRow {
                    if forward && start <= fromColumn { continue }
                    if !forward && start >= fromColumn { continue }
                }
                if Array(characters[start..<(start + needle.count)]) == needle { return start }
            }
            return nil
        }

        func scan(_ rows: [(row: Int, characters: [Character])], bounded: Bool) -> Bool {
            for entry in rows {
                if bounded, let fromRow {
                    if forward && entry.row < fromRow { continue }
                    if !forward && entry.row > fromRow { continue }
                }
                if let start = match(in: entry, bounded: bounded) {
                    selectionAnchor = (row: entry.row, column: start)
                    selectionHead = (row: entry.row, column: start + needle.count - 1)
                    needsDisplay = true
                    return true
                }
            }
            return false
        }

        let ordered = forward ? haystack : haystack.reversed()
        if scan(Array(ordered), bounded: true) { return true }
        // Wrap. Without this the search reports "no match" once past the last
        // hit, even while that hit is still highlighted on screen.
        return scan(Array(ordered), bounded: false)
    }

    /// The command on the cursor's line, with the prompt stripped.
    ///
    /// The prompt is found by looking for the last conventional terminator
    /// (`%`, `$`, `>`, `#` followed by a space). That is a heuristic — a prompt
    /// containing one of those characters in its text can fool it — and it is
    /// what OSC 133 shell integration replaces with an exact answer.
    private func currentInputLine() -> String? {
        guard let cursor = frameData.cursor,
              let row = frameData.rows.first(where: { $0.index == cursor.row }) else { return nil }
        let line = row.cells.map(\.text).joined()
        let trimmed = String(line.reversed().drop { $0 == " " }.reversed())
        guard !trimmed.isEmpty else { return nil }

        var best: String.Index?
        for terminator in ["% ", "$ ", "> ", "# "] {
            if let range = trimmed.range(of: terminator, options: .backwards) {
                if best == nil || range.upperBound > best! { best = range.upperBound }
            }
        }
        guard let start = best else { return trimmed }
        return String(trimmed[start...])
    }

    /// The visible screen as plain lines, for the AI features.
    func visibleLines() -> [String] {
        frameData.rows.map { $0.cells.map(\.text).joined() }
    }

    /// True when the running program has asked for mouse events.
    var mouseTrackingActive: Bool { core.wantsMouseTracking }

    /// For syncing encoders to this terminal's current modes.
    var terminalHandle: GhosttyTerminal? { core.terminalHandle }

    func clearSelection() {
        selectionAnchor = nil
        selectionHead = nil
        needsDisplay = true
    }

    /// The selected text, for copying.
    var selectedText: String? {
        guard let selection = normalizedSelection() else { return nil }
        var lines: [String] = []
        for row in frameData.rows where row.index >= selection.start.row && row.index <= selection.end.row {
            let first = row.index == selection.start.row ? selection.start.column : 0
            let last = row.index == selection.end.row ? selection.end.column : row.cells.count - 1
            guard first <= last, first < row.cells.count else { continue }
            let slice = row.cells[first...min(last, row.cells.count - 1)]
            lines.append(slice.map(\.text).joined())
        }
        let text = lines.map { $0.replacingOccurrences(of: "\0", with: " ") }
            .map { String($0.reversed().drop { $0 == " " }.reversed()) }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Consulted before every paste. Set by the session so the view does not
    /// need to know about preferences.
    var pasteFilter: ((String) -> String?)?
    /// Where to resolve relative paths from. Supplied by the session, which
    /// learns the real directory from the process rather than from OSC 7.
    var resolveDirectory: (() -> String?)?

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        guard let approved = pasteFilter?(text) ?? text as String? else { return }
        send(text: approved)
    }
}
