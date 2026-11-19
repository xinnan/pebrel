import CoreText
import PebrelGhostty
import SwiftUI
import UIKit

/// SwiftUI bridge hosting the CoreGraphics/CoreText terminal canvas (`PebrelTerminalUIView`).
/// Used for both live SSH `GhosttyCore` sessions and Desktop mirror `TerminalFrame` snapshots.
struct TerminalCanvasView: UIViewRepresentable {
    let frame: TerminalFrame?
    let fontFamily: String
    let fontSize: CGFloat
    let cursorStyle: String
    let cursorBlink: Bool
    let pinchZoomEnabled: Bool
    let directInputEnabled: Bool
    let focusTrigger: Int
    let isSnapshotMirror: Bool
    let onGridSizeChanged: ((Int, Int, Int, Int) -> Void)?
    let onTextInput: ((String) -> Void)?
    let onKeyInput: ((Int32, Int32, String, UInt32) -> Void)?
    let onScrollLines: ((Int, Int, Int) -> Void)?
    let onScrollOffset: ((Int) -> Void)?
    let onFontSizeChanged: ((CGFloat) -> Void)?
    let onZoomGestureActive: ((Bool, CGFloat) -> Void)?
    let onCopyText: ((String) -> Void)?

    func makeUIView(context: Context) -> PebrelTerminalUIView {
        let view = PebrelTerminalUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: PebrelTerminalUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: PebrelTerminalUIView) {
        view.isSnapshotMirror = isSnapshotMirror
        view.cursorStylePref = cursorStyle
        view.cursorBlinkPref = cursorBlink
        view.pinchZoomEnabled = pinchZoomEnabled
        view.directInputEnabled = directInputEnabled
        view.onGridSizeChanged = onGridSizeChanged
        view.onTextInput = onTextInput
        view.onKeyInput = onKeyInput
        view.onScrollLines = onScrollLines
        view.onScrollOffset = onScrollOffset
        view.onFontSizeChanged = onFontSizeChanged
        view.onZoomGestureActive = onZoomGestureActive
        view.onCopyText = onCopyText
        view.updateFont(family: fontFamily, size: fontSize)
        view.updateFrame(frame)
        if focusTrigger != view.lastFocusTrigger {
            view.lastFocusTrigger = focusTrigger
            if directInputEnabled {
                view.becomeFirstResponder()
            } else {
                view.resignFirstResponder()
            }
        }
    }
}

final class PebrelTerminalUIView: UIView, UIKeyInput {
    var isSnapshotMirror = false
    var cursorStylePref = TerminalPreferenceValues.blockCursor { didSet { setNeedsDisplay() } }
    var cursorBlinkPref = true { didSet { updateBlinkTimer() } }
    var pinchZoomEnabled = true
    var directInputEnabled = true
    var lastFocusTrigger = 0

    var onGridSizeChanged: ((Int, Int, Int, Int) -> Void)?
    var onTextInput: ((String) -> Void)?
    var onKeyInput: ((Int32, Int32, String, UInt32) -> Void)?
    var onScrollLines: ((Int, Int, Int) -> Void)?
    var onScrollOffset: ((Int) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onZoomGestureActive: ((Bool, CGFloat) -> Void)?
    var onCopyText: ((String) -> Void)?

    private var frameModel: TerminalFrame?
    private var selection: TerminalSelectionState?
    private var fontFamily = TerminalPreferenceValues.mapleFont
    private var fontSize: CGFloat = 16
    private var regularFont: UIFont = TerminalFontRegistry.uiFont(family: "maple", size: 16)
    private var boldFont: UIFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .bold)
    private var italicFont: UIFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private var cellWidth: CGFloat = 9.5
    private var cellHeight: CGFloat = 19
    private var baselineOffset: CGFloat = 14
    private var lastCols = 0
    private var lastRows = 0
    private var cursorPhaseVisible = true
    private var blinkTimer: Timer?
    private var scrollResidual: CGFloat = 0
    private var pinchBaseSize: CGFloat = 16
    private var draggingScrollbar = false
    private var draggingHandle: Int = 0 // 0=none, 1=start, 2=end

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        isMultipleTouchEnabled = true
        recomputeMetrics()
        installGestures()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        blinkTimer?.invalidate()
    }

    override var canBecomeFirstResponder: Bool { directInputEnabled }

    var hasText: Bool { true }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var keyboardType: UIKeyboardType = .asciiCapable

    func insertText(_ text: String) {
        clearSelection()
        if text == "\n" {
            onKeyInput?(Int32(PEBREL_KEY_ENTER.rawValue), 0, "", 0)
        } else {
            onTextInput?(text)
        }
    }

    func deleteBackward() {
        clearSelection()
        onKeyInput?(Int32(PEBREL_KEY_BACKSPACE.rawValue), 0, "", 0)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            var mods: Int32 = 0
            if key.modifierFlags.contains(.shift) { mods |= TerminalShortcut.modShift }
            if key.modifierFlags.contains(.control) { mods |= TerminalShortcut.modCtrl }
            if key.modifierFlags.contains(.alternate) { mods |= TerminalShortcut.modAlt }
            if key.modifierFlags.contains(.command) { mods |= TerminalShortcut.modMeta }

            if let sel = selection {
                if (mods & TerminalShortcut.modMeta) != 0 || (mods & TerminalShortcut.modCtrl) != 0 {
                    if key.charactersIgnoringModifiers.lowercased() == "c" {
                        copyCurrentSelection(sel)
                        handled = true
                        continue
                    }
                    if key.charactersIgnoringModifiers.lowercased() == "a", let f = frameModel {
                        selection = TerminalSelectionState.selectAll(in: f)
                        setNeedsDisplay()
                        handled = true
                        continue
                    }
                }
                if key.keyCode == .keyboardEscape {
                    clearSelection()
                    handled = true
                    continue
                }
            }

            if let code = mapUIKeyCode(key.keyCode) {
                let text = key.characters
                let unshifted = key.charactersIgnoringModifiers.unicodeScalars.first?.value ?? 0
                onKeyInput?(code, mods, text, unshifted)
                handled = true
            }
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    func updateFont(family: String, size: CGFloat) {
        let clamped = size.clamped(to: 8...32)
        guard family != fontFamily || abs(clamped - fontSize) > 0.05 else { return }
        fontFamily = family
        fontSize = clamped
        recomputeMetrics()
        notifyGridSizeIfNeeded()
        setNeedsDisplay()
    }

    func updateFrame(_ frame: TerminalFrame?) {
        guard frame != frameModel else { return }
        frameModel = frame
        if let frame {
            backgroundColor = PebrelPalette.uiColorFromARGB(frame.background)
        }
        updateBlinkTimer()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        notifyGridSizeIfNeeded()
    }

    private func recomputeMetrics() {
        regularFont = TerminalFontRegistry.uiFont(family: fontFamily, size: fontSize)
        if let desc = regularFont.fontDescriptor.withSymbolicTraits(.traitBold) {
            boldFont = UIFont(descriptor: desc, size: fontSize)
        } else {
            boldFont = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        }
        if let desc = regularFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
            italicFont = UIFont(descriptor: desc, size: fontSize)
        } else {
            italicFont = regularFont
        }
        let mSize = ("M" as NSString).size(withAttributes: [.font: regularFont])
        cellWidth = max(1, mSize.width)
        cellHeight = max(1, floor(fontSize * 1.25))
        let asc = regularFont.ascender
        let desc = regularFont.descender
        baselineOffset = (cellHeight - (asc - desc)) * 0.5 + asc
    }

    private func notifyGridSizeIfNeeded() {
        guard bounds.width > 16, bounds.height > 16 else { return }
        let cols = Int(floor(bounds.width / cellWidth)).clamped(to: 2...400)
        let rows = Int(floor(bounds.height / cellHeight)).clamped(to: 2...200)
        if cols != lastCols || rows != lastRows {
            lastCols = cols
            lastRows = rows
            selection = nil
            onGridSizeChanged?(cols, rows, Int(ceil(cellWidth)), Int(ceil(cellHeight)))
        }
    }

    private func updateBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorPhaseVisible = true
        guard !isSnapshotMirror, cursorBlinkPref, frameModel?.cursorVisible == true else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self, self.selection == nil else { return }
            self.cursorPhaseVisible.toggle()
            self.setNeedsDisplay()
        }
    }

    private func clearSelection() {
        guard selection != nil else { return }
        selection = nil
        draggingHandle = 0
        setNeedsDisplay()
    }

    private func copyCurrentSelection(_ sel: TerminalSelectionState) {
        let text = sel.selectedText()
        if !text.isEmpty {
            UIPasteboard.general.string = text
            onCopyText?(text)
        }
        clearSelection()
    }

    // MARK: - Gestures

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tripleTap = UITapGestureRecognizer(target: self, action: #selector(handleTripleTap(_:)))
        tripleTap.numberOfTapsRequired = 3
        tap.require(toFail: doubleTap)
        doubleTap.require(toFail: tripleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(tripleTap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
    }

    private func cellPoint(at location: CGPoint, in frame: TerminalFrame) -> TerminalCellPoint {
        let col = Int(floor(location.x / cellWidth)).clamped(to: 0...max(0, frame.columns - 1))
        let row = Int(floor(location.y / cellHeight)).clamped(to: 0...max(0, frame.rows.count - 1))
        return TerminalCellPoint(column: col, row: row)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if let sel = selection {
            copyCurrentSelection(sel)
            return
        }
        if directInputEnabled {
            becomeFirstResponder()
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let f = frameModel else { return }
        let pt = cellPoint(at: recognizer.location(in: self), in: f)
        selection = TerminalSelectionState.wordSelection(in: f, column: pt.column, row: pt.row)
        setNeedsDisplay()
    }

    @objc private func handleTripleTap(_ recognizer: UITapGestureRecognizer) {
        guard let f = frameModel else { return }
        let pt = cellPoint(at: recognizer.location(in: self), in: f)
        selection = TerminalSelectionState.lineSelection(in: f, row: pt.row)
        setNeedsDisplay()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let f = frameModel else { return }
        let pt = cellPoint(at: recognizer.location(in: self), in: f)
        switch recognizer.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            selection = TerminalSelectionState.wordSelection(in: f, column: pt.column, row: pt.row)
            setNeedsDisplay()
        case .changed:
            if var sel = selection {
                sel.focus = pt
                selection = sel
                setNeedsDisplay()
            }
        case .ended:
            if let sel = selection {
                presentCopyActionIfNeeded(sel)
            }
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let f = frameModel else { return }
        let location = recognizer.location(in: self)

        if recognizer.state == .began {
            scrollResidual = 0
            draggingScrollbar = f.scrollTotal > f.rows.count && location.x >= bounds.width - 28
            if let sel = selection {
                let startPt = handleCenter(sel.start)
                let endPt = handleCenter(sel.end)
                if hypot(location.x - startPt.x, location.y - startPt.y) <= 26 {
                    draggingHandle = 1
                } else if hypot(location.x - endPt.x, location.y - endPt.y) <= 26 {
                    draggingHandle = 2
                } else {
                    draggingHandle = 0
                    clearSelection()
                }
            }
        }

        if draggingHandle != 0, var sel = selection {
            let pt = cellPoint(at: location, in: f)
            if draggingHandle == 1 { sel.anchor = pt } else { sel.focus = pt }
            selection = sel
            setNeedsDisplay()
            if recognizer.state == .ended || recognizer.state == .cancelled {
                draggingHandle = 0
            }
            return
        }

        if draggingScrollbar {
            let maxOffset = max(0, f.scrollTotal - f.rows.count)
            let fraction = (location.y / max(1, bounds.height)).clamped(to: 0...1)
            onScrollOffset?(Int((fraction * CGFloat(maxOffset)).rounded()))
            if recognizer.state == .ended || recognizer.state == .cancelled {
                draggingScrollbar = false
                setNeedsDisplay()
            }
            return
        }

        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        scrollResidual += translation.y
        let lines = Int(trunc(scrollResidual / cellHeight))
        if lines != 0 {
            scrollResidual -= CGFloat(lines) * cellHeight
            let pt = cellPoint(at: location, in: f)
            // Dragging finger downward scrolls viewport upward into history (negative delta).
            onScrollLines?(-lines, pt.column, pt.row)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard pinchZoomEnabled else { return }
        switch recognizer.state {
        case .began:
            pinchBaseSize = fontSize
            onZoomGestureActive?(true, fontSize)
        case .changed:
            let target = (pinchBaseSize * recognizer.scale).rounded().clamped(to: 8...32)
            if abs(target - fontSize) >= 1 {
                UISelectionFeedbackGenerator().selectionChanged()
                updateFont(family: fontFamily, size: target)
                onFontSizeChanged?(target)
            }
            onZoomGestureActive?(true, fontSize)
        case .ended, .cancelled:
            onZoomGestureActive?(false, fontSize)
        default:
            break
        }
    }

    private func handleCenter(_ pt: TerminalCellPoint) -> CGPoint {
        CGPoint(x: (CGFloat(pt.column) + 0.5) * cellWidth, y: (CGFloat(pt.row) + 0.5) * cellHeight)
    }

    private func presentCopyActionIfNeeded(_ sel: TerminalSelectionState) {
        // Tapping selected text copies immediately; long-press release also keeps handles visible for adjustment.
        setNeedsDisplay()
    }

    // MARK: - CoreGraphics / CoreText Cell Painting

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard let f = selection?.frame ?? frameModel else {
            UIColor.black.setFill()
            ctx.fill(rect)
            return
        }

        let defaultBg = PebrelPalette.uiColorFromARGB(f.background)
        defaultBg.setFill()
        ctx.fill(bounds)

        let rowCount = f.rows.count
        let defaultBgBits = Int32(bitPattern: f.background)

        // Pass 1: RLE-merged cell backgrounds
        for y in 0..<rowCount {
            let row = f.rows[y]
            let cols = row.cells.count / 6
            let top = CGFloat(y) * cellHeight
            if top > rect.maxY || top + cellHeight < rect.minY { continue }

            var x = 0
            while x < cols {
                let bgBits = row.cells[x * 6 + 4]
                if bgBits == defaultBgBits {
                    x += 1
                    continue
                }
                var endX = x + 1
                while endX < cols && row.cells[endX * 6 + 4] == bgBits {
                    endX += 1
                }
                PebrelPalette.uiColorFromARGB(UInt32(bitPattern: bgBits)).setFill()
                ctx.fill(CGRect(x: CGFloat(x) * cellWidth, y: top, width: CGFloat(endX - x) * cellWidth + 0.5, height: cellHeight + 0.5))
                x = endX
            }
        }

        // Pass 2: Selection highlight
        if let sel = selection {
            let selColor = PebrelPalette.uiColorFromARGB(f.cursorColor).withAlphaComponent(0.28)
            selColor.setFill()
            let lo = sel.start
            let hi = sel.end
            for y in lo.row...min(hi.row, rowCount - 1) {
                let fromX = (y == lo.row) ? lo.column : 0
                let toX = (y == hi.row) ? hi.column : max(0, f.columns - 1)
                ctx.fill(CGRect(
                    x: CGFloat(fromX) * cellWidth,
                    y: CGFloat(y) * cellHeight,
                    width: CGFloat(toX - fromX + 1) * cellWidth,
                    height: cellHeight
                ))
            }
        }

        // Pass 3: Foreground glyphs (ASCII batching + vector box/block/braille + general glyphs)
        for y in 0..<rowCount {
            let row = f.rows[y]
            let cols = row.cells.count / 6
            let top = CGFloat(y) * cellHeight
            if top > rect.maxY || top + cellHeight < rect.minY { continue }

            var x = 0
            while x < cols {
                let base = x * 6
                let width = Int(row.cells[base + 2])
                let flags = Int(row.cells[base + 5])
                if width == 0 || (flags & 32) != 0 {
                    x += 1
                    continue
                }
                let start = Int(row.cells[base])
                let len = Int(row.cells[base + 1])
                let fgBits = row.cells[base + 3]

                // Fast path: batch contiguous printable ASCII cells with identical style
                if width == 1 && len == 1 && start < row.utf16.count && row.utf16[start] >= 33 && row.utf16[start] <= 126 {
                    var endX = x + 1
                    var scalars: [UInt16] = [row.utf16[start]]
                    while endX < cols {
                        let nb = endX * 6
                        let ns = Int(row.cells[nb])
                        let nl = Int(row.cells[nb + 1])
                        let nw = Int(row.cells[nb + 2])
                        if nw == 1 && nl == 1 && row.cells[nb + 3] == fgBits && row.cells[nb + 5] == flags &&
                           ns < row.utf16.count && row.utf16[ns] >= 32 && row.utf16[ns] <= 126 {
                            scalars.append(row.utf16[ns])
                            endX += 1
                        } else {
                            break
                        }
                    }
                    let runStr = String(utf16CodeUnits: scalars, count: scalars.count)
                    drawTextRun(runStr, atX: CGFloat(x) * cellWidth, top: top, allocatedWidth: CGFloat(endX - x) * cellWidth, fgBits: fgBits, flags: flags, ctx: ctx)
                    x = endX
                    continue
                }

                // Skip plain space without decoration
                if len == 1 && start < row.utf16.count && row.utf16[start] == 32 && (flags & 12) == 0 {
                    x += width
                    continue
                }

                // Procedural crisp vector drawing for Braille / Block / Box-drawing symbols
                if len == 1 && start < row.utf16.count {
                    let cp = UInt32(row.utf16[start])
                    if drawProceduralGlyph(cp, x: CGFloat(x) * cellWidth, y: top, w: CGFloat(width) * cellWidth, h: cellHeight, fgBits: fgBits, flags: flags, ctx: ctx) {
                        x += width
                        continue
                    }
                }

                let glyphStr = row.cellText(column: x)
                drawTextRun(glyphStr, atX: CGFloat(x) * cellWidth, top: top, allocatedWidth: CGFloat(width) * cellWidth, fgBits: fgBits, flags: flags, ctx: ctx)
                x += max(1, width)
            }
        }

        // Pass 4: Cursor
        if f.cursorVisible && selection == nil && (isSnapshotMirror || cursorPhaseVisible) {
            drawCursor(f, ctx: ctx)
        }

        // Pass 5: Selection knobs
        if let sel = selection {
            drawSelectionHandles(sel, color: PebrelPalette.uiColorFromARGB(f.cursorColor), ctx: ctx)
        }

        // Pass 6: Overlay scrollbar thumb
        if f.scrollTotal > f.rows.count {
            drawScrollbar(f, ctx: ctx)
        }
    }

    private func drawTextRun(
        _ text: String,
        atX x: CGFloat,
        top: CGFloat,
        allocatedWidth: CGFloat,
        fgBits: Int32,
        flags: Int,
        ctx: CGContext
    ) {
        var color = PebrelPalette.uiColorFromARGB(UInt32(bitPattern: fgBits))
        if (flags & 16) != 0 { color = color.withAlphaComponent(150.0 / 255.0) }
        let font: UIFont = (flags & 1) != 0 ? boldFont : ((flags & 2) != 0 ? italicFont : regularFont)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = text as NSString
        let measured = ns.size(withAttributes: attrs)

        ctx.saveGState()
        if measured.width > allocatedWidth + 0.5 && measured.width > 0 {
            let scaleX = allocatedWidth / measured.width
            ctx.clip(to: CGRect(x: x, y: top, width: allocatedWidth, height: cellHeight))
            ctx.translateBy(x: x, y: top)
            ctx.scaleBy(x: scaleX, y: 1.0)
            ns.draw(at: CGPoint(x: 0, y: baselineOffset - font.ascender), withAttributes: attrs)
        } else {
            ns.draw(at: CGPoint(x: x, y: top + baselineOffset - font.ascender), withAttributes: attrs)
        }
        ctx.restoreGState()

        if (flags & 4) != 0 { // Underline
            color.setFill()
            ctx.fill(CGRect(x: x, y: top + cellHeight - max(1, fontSize * 0.08), width: allocatedWidth, height: max(1, fontSize * 0.07)))
        }
        if (flags & 8) != 0 { // Strikethrough
            color.setFill()
            ctx.fill(CGRect(x: x, y: top + cellHeight * 0.5, width: allocatedWidth, height: max(1, fontSize * 0.07)))
        }
    }

    private func drawProceduralGlyph(
        _ cp: UInt32,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        h: CGFloat,
        fgBits: Int32,
        flags: Int,
        ctx: CGContext
    ) -> Bool {
        var color = PebrelPalette.uiColorFromARGB(UInt32(bitPattern: fgBits))
        if (flags & 16) != 0 { color = color.withAlphaComponent(150.0 / 255.0) }

        // Braille Patterns U+2800..U+28FF
        if cp >= 0x2800 && cp <= 0x28FF {
            let bits = cp - 0x2800
            color.setFill()
            let r = max(0.8, min(w, h) * 0.12)
            let cols: [CGFloat] = [x + w * 0.3, x + w * 0.7]
            let rows: [CGFloat] = [y + h * 0.16, y + h * 0.39, y + h * 0.62, y + h * 0.85]
            let dotMap: [(Int, Int, UInt32)] = [
                (0, 0, 0x01), (0, 1, 0x02), (0, 2, 0x04), (1, 0, 0x08),
                (1, 1, 0x10), (1, 2, 0x20), (0, 3, 0x40), (1, 3, 0x80),
            ]
            for (c, rowIdx, mask) in dotMap where (bits & mask) != 0 {
                ctx.fillEllipse(in: CGRect(x: cols[c] - r, y: rows[rowIdx] - r, width: r * 2, height: r * 2))
            }
            return true
        }

        // Shade / Full / Half blocks
        switch cp {
        case 0x2588: // Full block
            color.setFill(); ctx.fill(CGRect(x: x, y: y, width: w + 0.5, height: h + 0.5)); return true
        case 0x2580: // Upper half
            color.setFill(); ctx.fill(CGRect(x: x, y: y, width: w + 0.5, height: h * 0.5 + 0.5)); return true
        case 0x2584: // Lower half
            color.setFill(); ctx.fill(CGRect(x: x, y: y + h * 0.5, width: w + 0.5, height: h * 0.5 + 0.5)); return true
        case 0x2591: // Light shade
            color.withAlphaComponent(0.25).setFill(); ctx.fill(CGRect(x: x, y: y, width: w + 0.5, height: h + 0.5)); return true
        case 0x2592: // Medium shade
            color.withAlphaComponent(0.50).setFill(); ctx.fill(CGRect(x: x, y: y, width: w + 0.5, height: h + 0.5)); return true
        case 0x2593: // Dark shade
            color.withAlphaComponent(0.75).setFill(); ctx.fill(CGRect(x: x, y: y, width: w + 0.5, height: h + 0.5)); return true
        default:
            break
        }

        // Common light box-drawing lines (matching Android's TerminalCellPainter)
        let t = max(1.0, w / 9.0)
        let cx = x + (w - t) * 0.5
        let cy = y + (h - t) * 0.5
        func arm(left: Bool = false, right: Bool = false, up: Bool = false, down: Bool = false) -> Bool {
            color.setFill()
            if left { ctx.fill(CGRect(x: x, y: cy, width: cx - x + t, height: t)) }
            if right { ctx.fill(CGRect(x: cx, y: cy, width: x + w - cx + 0.5, height: t)) }
            if up { ctx.fill(CGRect(x: cx, y: y, width: t, height: cy - y + t)) }
            if down { ctx.fill(CGRect(x: cx, y: cy, width: t, height: y + h - cy + 0.5)) }
            return true
        }
        switch cp {
        case 0x2500: return arm(left: true, right: true)
        case 0x2502: return arm(up: true, down: true)
        case 0x250C: return arm(right: true, down: true)
        case 0x2510: return arm(left: true, down: true)
        case 0x2514: return arm(right: true, up: true)
        case 0x2518: return arm(left: true, up: true)
        case 0x251C: return arm(right: true, up: true, down: true)
        case 0x2524: return arm(left: true, up: true, down: true)
        case 0x252C: return arm(left: true, right: true, down: true)
        case 0x2534: return arm(left: true, right: true, up: true)
        case 0x253C: return arm(left: true, right: true, up: true, down: true)
        default: return false
        }
    }

    private func drawCursor(_ f: TerminalFrame, ctx: CGContext) {
        guard f.cursorX >= 0, f.cursorX < f.columns, f.cursorY >= 0, f.cursorY < f.rows.count else { return }
        let x = CGFloat(f.cursorX) * cellWidth
        let y = CGFloat(f.cursorY) * cellHeight
        let color = PebrelPalette.uiColorFromARGB(f.cursorColor)
        let style = isSnapshotMirror ? TerminalPreferenceValues.blockCursor : cursorStylePref
        switch style {
        case TerminalPreferenceValues.barCursor:
            color.withAlphaComponent(210.0 / 255.0).setFill()
            ctx.fill(CGRect(x: x, y: y, width: 2.0, height: cellHeight))
        case TerminalPreferenceValues.underlineCursor:
            color.withAlphaComponent(210.0 / 255.0).setFill()
            ctx.fill(CGRect(x: x, y: y + cellHeight - 2.0, width: cellWidth, height: 2.0))
        default:
            color.withAlphaComponent(isSnapshotMirror ? 110.0 / 255.0 : 92.0 / 255.0).setFill()
            ctx.fill(CGRect(x: x, y: y, width: cellWidth, height: cellHeight))
        }
    }

    private func drawSelectionHandles(_ sel: TerminalSelectionState, color: UIColor, ctx: CGContext) {
        color.setFill()
        for pt in [sel.start, sel.end] {
            let center = handleCenter(pt)
            let r: CGFloat = 6
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        }
    }

    private func drawScrollbar(_ f: TerminalFrame, ctx: CGContext) {
        let total = CGFloat(max(1, f.scrollTotal))
        let visible = CGFloat(max(1, f.rows.count))
        let trackH = max(1, bounds.height - 12)
        let thumbH = max(44, trackH * (visible / total))
        let maxOffset = max(1, total - visible)
        let progress = CGFloat(f.scrollOffset) / maxOffset
        let thumbY = 6 + progress * max(0, trackH - thumbH)
        let rect = CGRect(x: bounds.width - 6, y: thumbY, width: 4, height: thumbH)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 2)
        PebrelPalette.uiColorFromARGB(f.cursorColor)
            .withAlphaComponent(draggingScrollbar ? 0.82 : 0.45)
            .setFill()
        path.fill()
    }

    private func mapUIKeyCode(_ keyCode: UIKeyboardHIDUsage) -> Int32? {
        switch keyCode {
        case .keyboardA: return Int32(PEBREL_KEY_A.rawValue)
        case .keyboardB: return Int32(PEBREL_KEY_A.rawValue) + 1
        case .keyboardC: return Int32(PEBREL_KEY_A.rawValue) + 2
        case .keyboardD: return Int32(PEBREL_KEY_A.rawValue) + 3
        case .keyboardE: return Int32(PEBREL_KEY_A.rawValue) + 4
        case .keyboardF: return Int32(PEBREL_KEY_A.rawValue) + 5
        case .keyboardG: return Int32(PEBREL_KEY_A.rawValue) + 6
        case .keyboardH: return Int32(PEBREL_KEY_A.rawValue) + 7
        case .keyboardI: return Int32(PEBREL_KEY_A.rawValue) + 8
        case .keyboardJ: return Int32(PEBREL_KEY_A.rawValue) + 9
        case .keyboardK: return Int32(PEBREL_KEY_A.rawValue) + 10
        case .keyboardL: return Int32(PEBREL_KEY_A.rawValue) + 11
        case .keyboardM: return Int32(PEBREL_KEY_A.rawValue) + 12
        case .keyboardN: return Int32(PEBREL_KEY_A.rawValue) + 13
        case .keyboardO: return Int32(PEBREL_KEY_A.rawValue) + 14
        case .keyboardP: return Int32(PEBREL_KEY_A.rawValue) + 15
        case .keyboardQ: return Int32(PEBREL_KEY_A.rawValue) + 16
        case .keyboardR: return Int32(PEBREL_KEY_A.rawValue) + 17
        case .keyboardS: return Int32(PEBREL_KEY_A.rawValue) + 18
        case .keyboardT: return Int32(PEBREL_KEY_A.rawValue) + 19
        case .keyboardU: return Int32(PEBREL_KEY_A.rawValue) + 20
        case .keyboardV: return Int32(PEBREL_KEY_A.rawValue) + 21
        case .keyboardW: return Int32(PEBREL_KEY_A.rawValue) + 22
        case .keyboardX: return Int32(PEBREL_KEY_A.rawValue) + 23
        case .keyboardY: return Int32(PEBREL_KEY_A.rawValue) + 24
        case .keyboardZ: return Int32(PEBREL_KEY_Z.rawValue)
        case .keyboard0: return Int32(PEBREL_KEY_DIGIT_0.rawValue)
        case .keyboard1: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 1
        case .keyboard2: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 2
        case .keyboard3: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 3
        case .keyboard4: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 4
        case .keyboard5: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 5
        case .keyboard6: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 6
        case .keyboard7: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 7
        case .keyboard8: return Int32(PEBREL_KEY_DIGIT_0.rawValue) + 8
        case .keyboard9: return Int32(PEBREL_KEY_DIGIT_9.rawValue)
        case .keyboardUpArrow: return Int32(PEBREL_KEY_ARROW_UP.rawValue)
        case .keyboardDownArrow: return Int32(PEBREL_KEY_ARROW_DOWN.rawValue)
        case .keyboardLeftArrow: return Int32(PEBREL_KEY_ARROW_LEFT.rawValue)
        case .keyboardRightArrow: return Int32(PEBREL_KEY_ARROW_RIGHT.rawValue)
        case .keyboardTab: return Int32(PEBREL_KEY_TAB.rawValue)
        case .keyboardSpacebar: return Int32(PEBREL_KEY_SPACE.rawValue)
        case .keyboardReturnOrEnter: return Int32(PEBREL_KEY_ENTER.rawValue)
        case .keyboardDeleteOrBackspace: return Int32(PEBREL_KEY_BACKSPACE.rawValue)
        case .keyboardPageUp: return Int32(PEBREL_KEY_PAGE_UP.rawValue)
        case .keyboardPageDown: return Int32(PEBREL_KEY_PAGE_DOWN.rawValue)
        case .keyboardEscape: return Int32(PEBREL_KEY_ESCAPE.rawValue)
        case .keyboardDeleteForward: return Int32(PEBREL_KEY_DELETE.rawValue)
        case .keyboardHome: return Int32(PEBREL_KEY_HOME.rawValue)
        case .keyboardEnd: return Int32(PEBREL_KEY_END.rawValue)
        case .keyboardInsert: return Int32(PEBREL_KEY_INSERT.rawValue)
        case .keyboardF1: return Int32(PEBREL_KEY_F1.rawValue)
        case .keyboardF2: return Int32(PEBREL_KEY_F1.rawValue) + 1
        case .keyboardF3: return Int32(PEBREL_KEY_F1.rawValue) + 2
        case .keyboardF4: return Int32(PEBREL_KEY_F1.rawValue) + 3
        case .keyboardF5: return Int32(PEBREL_KEY_F1.rawValue) + 4
        case .keyboardF6: return Int32(PEBREL_KEY_F1.rawValue) + 5
        case .keyboardF7: return Int32(PEBREL_KEY_F1.rawValue) + 6
        case .keyboardF8: return Int32(PEBREL_KEY_F1.rawValue) + 7
        case .keyboardF9: return Int32(PEBREL_KEY_F1.rawValue) + 8
        case .keyboardF10: return Int32(PEBREL_KEY_F1.rawValue) + 9
        case .keyboardF11: return Int32(PEBREL_KEY_F1.rawValue) + 10
        case .keyboardF12: return Int32(PEBREL_KEY_F12.rawValue)
        default: return nil
        }
    }
}
