import CoreText
import PebrelGhostty
import QuartzCore
import SwiftUI
import UIKit

/// SwiftUI bridge hosting the CoreGraphics/CoreText terminal canvas (`PebrelTerminalUIView`).
/// Used for both live SSH `GhosttyCore` sessions and Desktop mirror `TerminalFrame` snapshots.
struct TerminalCanvasView: UIViewRepresentable {
    let frame: TerminalFrame?
    let fontFamily: String
    let fontSize: CGFloat
    var snapshotZoom: CGFloat = 1.0
    var wrapLines: Bool = false
    let cursorStyle: String
    let cursorBlink: Bool
    let pinchZoomEnabled: Bool
    let directInputEnabled: Bool
    let focusTrigger: Int
    var fitWidthTrigger: Int = 0
    let isSnapshotMirror: Bool
    let onGridSizeChanged: ((Int, Int, Int, Int) -> Void)?
    let onTextInput: ((String) -> Void)?
    let onKeyInput: ((Int32, Int32, String, UInt32) -> Void)?
    let onScrollLines: ((Int, Int, Int) -> Void)?
    let onScrollOffset: ((Int) -> Void)?
    var onHistoryPage: ((Int64?) -> Void)? = nil
    let onFontSizeChanged: ((CGFloat) -> Void)?
    var onSnapshotZoomChanged: ((CGFloat) -> Void)? = nil
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
        view.onHistoryPage = onHistoryPage
        view.onFontSizeChanged = onFontSizeChanged
        view.onSnapshotZoomChanged = onSnapshotZoomChanged
        view.onZoomGestureActive = onZoomGestureActive
        view.onCopyText = onCopyText
        view.updateWrapLines(wrapLines)
        view.updateFont(family: fontFamily, size: fontSize, snapshotZoom: snapshotZoom)
        view.updateFrame(frame)
        if fitWidthTrigger != view.lastFitWidthTrigger {
            view.lastFitWidthTrigger = fitWidthTrigger
            view.fitWidthToViewport()
        }
        if focusTrigger != view.lastFocusTrigger {
            view.lastFocusTrigger = focusTrigger
            if directInputEnabled {
                view.revealCursorForInput()
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
    var lastFitWidthTrigger = 0

    var onGridSizeChanged: ((Int, Int, Int, Int) -> Void)?
    var onTextInput: ((String) -> Void)?
    var onKeyInput: ((Int32, Int32, String, UInt32) -> Void)?
    var onScrollLines: ((Int, Int, Int) -> Void)?
    var onScrollOffset: ((Int) -> Void)?
    var onHistoryPage: ((Int64?) -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onSnapshotZoomChanged: ((CGFloat) -> Void)?
    var onZoomGestureActive: ((Bool, CGFloat) -> Void)?
    var onCopyText: ((String) -> Void)?

    private var rawFrame: TerminalFrame?
    private var frameModel: TerminalFrame?
    private var projectedColumns = 0
    private var wrapLinesPref = false
    private var selection: TerminalSelectionState?
    private var fontFamily = TerminalPreferenceValues.mapleFont
    private var fontSize: CGFloat = 16
    private var snapshotZoom: CGFloat = 1.0
    private var pinchInProgress = false
    private var regularFont: UIFont = TerminalFontRegistry.uiFont(family: "maple", size: 16)
    private var boldFont: UIFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .bold)
    private var italicFont: UIFont = UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    private var cellWidth: CGFloat = 9.5
    private var cellHeight: CGFloat = 19
    private var baselineOffset: CGFloat = 14
    private var lastCols = 0
    private var lastRows = 0
    private var lastLayoutSize: CGSize = .zero
    private var cursorPhaseVisible = true
    private var blinkTimer: Timer?
    private var scrollResidual: CGFloat = 0
    private var pinchBaseSize: CGFloat = 16
    private var pinchBaseZoom: CGFloat = 1.0
    private var offsetX: CGFloat = 0
    private var offsetY: CGFloat = 0
    private var followOutput = true
    private var followInputCursor = false
    private var requestedHistoryStart: Int64?
    private var historyRequestSent = false
    private var displayLink: CADisplayLink?
    private var momentumVelocity: CGPoint = .zero
    private var lastMomentumTimestamp: CFTimeInterval = 0
    private var draggingScrollbar = false
    private var draggingHandle: Int = 0 // 0=none, 1=start, 2=end

    private var activeFrame: TerminalFrame? {
        selection?.frame ?? frameModel
    }

    private var effectiveFontSize: CGFloat {
        if isSnapshotMirror {
            return (fontSize * snapshotZoom).clamped(to: 3.0...64.0)
        }
        return fontSize.clamped(to: 8...32)
    }

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
        displayLink?.invalidate()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stopMomentum()
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
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

    func updateWrapLines(_ wrap: Bool) {
        guard wrap != wrapLinesPref else { return }
        stopMomentum()
        clearSelection()
        wrapLinesPref = wrap
        reproject(force: true)
        offsetX = 0
        offsetY = 0
        followOutput = true
        if bounds.height > 0 { revealCursor(horizontal: false) }
        constrainOffsets()
        setNeedsDisplay()
    }

    func updateFont(family: String, size: CGFloat, snapshotZoom nextZoom: CGFloat = 1.0) {
        let clampedSize = size.clamped(to: 8...32)
        let clampedZoom = nextZoom.isFinite ? nextZoom.clamped(to: 0.2...5.0) : 1.0
        let zoomChanged = isSnapshotMirror && !pinchInProgress && abs(clampedZoom - snapshotZoom) > 0.002
        guard family != fontFamily || abs(clampedSize - fontSize) > 0.05 || zoomChanged else { return }
        stopMomentum()
        fontFamily = family
        fontSize = clampedSize
        if isSnapshotMirror && !pinchInProgress {
            snapshotZoom = clampedZoom
        }
        recomputeMetrics()
        reproject(force: true)
        constrainOffsets()
        notifyGridSizeIfNeeded()
        setNeedsDisplay()
    }

    func updateFrame(_ nextRaw: TerminalFrame?) {
        guard nextRaw != rawFrame else { return }
        let follow = (rawFrame == nil || followOutput)
        let previousRendered = frameModel
        let previousCols = rawFrame?.columns
        rawFrame = nextRaw

        if selection != nil && nextRaw != nil {
            setNeedsDisplay()
            return
        }

        if nextRaw == nil {
            stopMomentum()
            selection = nil
            frameModel = nil
            projectedColumns = 0
            offsetX = 0
            offsetY = 0
            requestedHistoryStart = nil
            historyRequestSent = false
            followOutput = true
            setNeedsDisplay()
            return
        }

        if let nextRaw {
            backgroundColor = PebrelPalette.uiColorFromARGB(nextRaw.background)
        }
        reproject(force: true)

        if isSnapshotMirror {
            if !follow,
               let prev = previousRendered,
               let oldHist = prev.history,
               let cur = frameModel,
               let curHist = cur.history,
               !oldHist.applicationScroll && !curHist.applicationScroll,
               previousCols == nextRaw?.columns,
               let srcCols = nextRaw?.columns, srcCols > 0 {
                let oldRow = Int(floor(offsetY / max(1, cellHeight))).clamped(to: 0...max(0, prev.rows.count - 1))
                let oldSrcOff = prev.sourceOffsets?[safe: oldRow] ?? (oldRow * srcCols)
                let anchor = oldHist.first * Int64(srcCols) + Int64(oldSrcOff)
                let relative = anchor - curHist.first * Int64(srcCols)
                let mappedRow: Int
                if let offsets = cur.sourceOffsets {
                    mappedRow = offsets.lastIndex(where: { Int64($0) <= relative }) ?? 0
                } else {
                    mappedRow = Int(relative / Int64(srcCols))
                }
                let remY = offsetY.truncatingRemainder(dividingBy: max(1, cellHeight))
                offsetY = CGFloat(max(0, mappedRow)) * cellHeight + remY
            }
            if follow && frameModel?.cursorVisible != true {
                offsetY = maxY()
            }
            if bounds.height > 0 && (follow || followInputCursor) {
                revealCursor(horizontal: followInputCursor)
            }
            constrainOffsets()
        }

        updateBlinkTimer()
        setNeedsDisplay()
    }

    func revealCursorForInput() {
        guard isSnapshotMirror else { return }
        stopMomentum()
        if rawFrame?.history?.applicationScroll == false {
            followOutput = true
            requestHistory(start: nil)
        }
        followInputCursor = true
        revealCursor(horizontal: true)
        constrainOffsets()
        setNeedsDisplay()
    }

    func fitWidthToViewport() {
        guard isSnapshotMirror, bounds.width > 16 else { return }
        let cols = max(1, rawFrame?.columns ?? frameModel?.columns ?? 80)
        let baseFont = TerminalFontRegistry.uiFont(family: fontFamily, size: fontSize.clamped(to: 8...32))
        let baseCellW = max(1, ("M" as NSString).size(withAttributes: [.font: baseFont]).width)
        let fit = ((bounds.width - 4) / (CGFloat(cols) * baseCellW)).clamped(to: 0.2...5.0)
        stopMomentum()
        clearSelection()
        snapshotZoom = fit
        recomputeMetrics()
        reproject(force: true)
        offsetX = 0
        if frameModel?.cursorVisible != true {
            offsetY = maxY()
        } else {
            revealCursor(horizontal: false)
        }
        constrainOffsets()
        setNeedsDisplay()
        onSnapshotZoomChanged?(snapshotZoom)
    }

    private func resetSnapshotZoom() {
        guard isSnapshotMirror else { return }
        stopMomentum()
        clearSelection()
        snapshotZoom = 1.0
        recomputeMetrics()
        reproject(force: true)
        offsetX = 0
        offsetY = 0
        followOutput = true
        if frameModel?.cursorVisible != true {
            offsetY = maxY()
        } else {
            revealCursor(horizontal: false)
        }
        constrainOffsets()
        setNeedsDisplay()
        onSnapshotZoomChanged?(snapshotZoom)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            if isSnapshotMirror {
                stopMomentum()
                reproject(force: false)
                if followOutput && frameModel?.cursorVisible != true {
                    offsetY = maxY()
                }
                if followOutput || followInputCursor {
                    revealCursor(horizontal: followInputCursor)
                }
                constrainOffsets()
                setNeedsDisplay()
            }
        }
        notifyGridSizeIfNeeded()
    }

    private func recomputeMetrics() {
        let size = effectiveFontSize
        regularFont = TerminalFontRegistry.uiFont(family: fontFamily, size: size)
        if let desc = regularFont.fontDescriptor.withSymbolicTraits(.traitBold) {
            boldFont = UIFont(descriptor: desc, size: size)
        } else {
            boldFont = UIFont.monospacedSystemFont(ofSize: size, weight: .bold)
        }
        if let desc = regularFont.fontDescriptor.withSymbolicTraits(.traitItalic) {
            italicFont = UIFont(descriptor: desc, size: size)
        } else {
            italicFont = regularFont
        }
        let mSize = ("M" as NSString).size(withAttributes: [.font: regularFont])
        cellWidth = max(1, mSize.width)
        cellHeight = max(1, floor(size * 1.25))
        let asc = regularFont.ascender
        let desc = regularFont.descender
        baselineOffset = (cellHeight - (asc - desc)) * 0.5 + asc
    }

    private func reproject(force: Bool) {
        guard let source = rawFrame else {
            frameModel = nil
            projectedColumns = 0
            return
        }
        if !isSnapshotMirror {
            frameModel = source
            projectedColumns = 0
            return
        }
        let targetCols = (wrapLinesPref && bounds.width > 16) ? max(2, Int(floor(bounds.width / cellWidth))) : 0
        if !force && projectedColumns == targetCols && frameModel != nil {
            return
        }
        projectedColumns = targetCols
        if targetCols > 0 && targetCols < source.columns {
            frameModel = TerminalReflow.reflow(source, columns: targetCols)
        } else {
            frameModel = source
        }
    }

    private func maxX() -> CGFloat {
        guard isSnapshotMirror, let f = activeFrame else { return 0 }
        return max(0, CGFloat(f.columns) * cellWidth - bounds.width)
    }

    private func maxY() -> CGFloat {
        guard isSnapshotMirror, let f = activeFrame else { return 0 }
        return max(0, CGFloat(f.rows.count) * cellHeight - bounds.height)
    }

    private func constrainOffsets() {
        guard isSnapshotMirror else {
            offsetX = 0
            offsetY = 0
            return
        }
        offsetX = offsetX.clamped(to: 0...maxX())
        offsetY = offsetY.clamped(to: 0...maxY())
    }

    private func revealCursor(horizontal: Bool) {
        guard isSnapshotMirror, bounds.height > 0, let f = frameModel, f.cursorVisible else { return }
        let y = CGFloat(f.cursorY) * cellHeight
        if y < offsetY {
            offsetY = y
        } else if y + cellHeight > offsetY + bounds.height {
            offsetY = y + cellHeight - bounds.height
        }
        if horizontal {
            let x = CGFloat(f.cursorX) * cellWidth
            if x < offsetX {
                offsetX = x
            } else if x + cellWidth * 2 > offsetX + bounds.width {
                offsetX = x + cellWidth * 2 - bounds.width
            }
        }
    }

    private func atHistoryTail() -> Bool {
        guard let source = rawFrame, let hist = source.history else { return true }
        return hist.applicationScroll || (hist.first + Int64(source.rows.count)) >= hist.end
    }

    private func requestHistory(start: Int64?) {
        guard let onHistoryPage else { return }
        if historyRequestSent && requestedHistoryStart == start { return }
        historyRequestSent = true
        requestedHistoryStart = start
        onHistoryPage(start)
    }

    private func requestHistoryNearEdge() {
        guard let source = rawFrame, let hist = source.history, !hist.applicationScroll, onHistoryPage != nil,
              let rendered = frameModel, !rendered.rows.isEmpty, source.columns > 0 else {
            return
        }
        func sourceRow(_ visual: Int) -> Int64 {
            let clamped = visual.clamped(to: 0...(rendered.rows.count - 1))
            if let offsets = rendered.sourceOffsets, clamped < offsets.count {
                return Int64(offsets[clamped] / source.columns)
            }
            return Int64(clamped)
        }
        let firstVisible = sourceRow(Int(floor(offsetY / max(1, cellHeight))))
        let lastVisible = sourceRow(Int(floor((offsetY + bounds.height) / max(1, cellHeight))))
        let visibleSourceRows = max(1, Int(lastVisible - firstVisible + 1))
        let reserve = max(0, source.rows.count - visibleSourceRows)
        let margin = Int64(max(1, min(visibleSourceRows, reserve / 3)))
        if followOutput && atHistoryTail() {
            requestHistory(start: nil)
            return
        }
        let nearTop = firstVisible < margin && hist.first > hist.oldest
        let nearBottom = lastVisible >= Int64(source.rows.count) - margin && !atHistoryTail()
        if nearTop || nearBottom {
            let start = max(hist.oldest, hist.first + firstVisible - Int64(reserve / 2))
            requestHistory(start: start)
        } else if requestedHistoryStart == nil {
            requestHistory(start: hist.first)
        }
    }

    private func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
        momentumVelocity = .zero
    }

    private func startMomentum(velocity: CGPoint) {
        stopMomentum()
        guard isSnapshotMirror, hypot(velocity.x, velocity.y) > 80 else { return }
        momentumVelocity = velocity
        lastMomentumTimestamp = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(stepMomentum(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func stepMomentum(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(min(0.05, max(0.001, now - lastMomentumTimestamp)))
        lastMomentumTimestamp = now

        let prevX = offsetX
        let prevY = offsetY
        offsetX -= momentumVelocity.x * dt
        offsetY -= momentumVelocity.y * dt
        constrainOffsets()
        followOutput = (maxY() - offsetY) < cellHeight * 2 && atHistoryTail()
        if rawFrame?.history?.applicationScroll == false {
            requestHistoryNearEdge()
        }
        setNeedsDisplay()

        let decay = pow(CGFloat(0.04), dt)
        momentumVelocity.x *= decay
        momentumVelocity.y *= decay
        let moved = abs(offsetX - prevX) > 0.1 || abs(offsetY - prevY) > 0.1
        if !moved || hypot(momentumVelocity.x, momentumVelocity.y) < 15 {
            stopMomentum()
        }
    }

    private func notifyGridSizeIfNeeded() {
        guard bounds.width > 16, bounds.height > 16 else { return }
        let cols = Int(floor(bounds.width / cellWidth)).clamped(to: 2...400)
        let rows = Int(floor(bounds.height / cellHeight)).clamped(to: 2...200)
        if cols != lastCols || rows != lastRows {
            lastCols = cols
            lastRows = rows
            if !isSnapshotMirror {
                selection = nil
            }
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
        reproject(force: true)
        constrainOffsets()
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
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))

        addGestureRecognizer(tap)
        addGestureRecognizer(doubleTap)
        addGestureRecognizer(tripleTap)
        addGestureRecognizer(longPress)
        addGestureRecognizer(pan)
        addGestureRecognizer(pinch)
    }

    private func cellPoint(at location: CGPoint, in frame: TerminalFrame) -> TerminalCellPoint {
        let sx = location.x + (isSnapshotMirror ? offsetX : 0)
        let sy = location.y + (isSnapshotMirror ? offsetY : 0)
        let col = Int(floor(sx / cellWidth)).clamped(to: 0...max(0, frame.columns - 1))
        let row = Int(floor(sy / cellHeight)).clamped(to: 0...max(0, frame.rows.count - 1))
        return TerminalCellPoint(column: col, row: row)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        stopMomentum()
        if let sel = selection {
            copyCurrentSelection(sel)
            return
        }
        if directInputEnabled {
            revealCursorForInput()
            becomeFirstResponder()
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        stopMomentum()
        guard let f = frameModel else { return }
        let pt = cellPoint(at: recognizer.location(in: self), in: f)
        if isSnapshotMirror && pt.row < f.rows.count {
            let cellText = f.rows[pt.row].cellText(column: pt.column).trimmingCharacters(in: .whitespacesAndNewlines)
            if cellText.isEmpty {
                // Double-tapping blank space toggles Fit-to-Width vs 100% readable scale.
                if abs(snapshotZoom - 1.0) > 0.08 {
                    resetSnapshotZoom()
                } else {
                    fitWidthToViewport()
                }
                return
            }
        }
        followInputCursor = false
        selection = TerminalSelectionState.wordSelection(in: f, column: pt.column, row: pt.row)
        setNeedsDisplay()
    }

    @objc private func handleTripleTap(_ recognizer: UITapGestureRecognizer) {
        stopMomentum()
        guard let f = frameModel else { return }
        let pt = cellPoint(at: recognizer.location(in: self), in: f)
        followInputCursor = false
        selection = TerminalSelectionState.lineSelection(in: f, row: pt.row)
        setNeedsDisplay()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        stopMomentum()
        guard let f = frameModel else { return }
        let pt = cellPoint(at: recognizer.location(in: self), in: f)
        switch recognizer.state {
        case .began:
            followInputCursor = false
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
            stopMomentum()
            scrollResidual = 0
            let hasVerticalScrollbar = isSnapshotMirror ? (maxY() > 1) : (f.scrollTotal > f.rows.count)
            draggingScrollbar = hasVerticalScrollbar && location.x >= bounds.width - 28
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
            let fraction = (location.y / max(1, bounds.height)).clamped(to: 0...1)
            if isSnapshotMirror {
                followInputCursor = false
                offsetY = maxY() * fraction
                followOutput = fraction >= 0.999 && atHistoryTail()
                requestHistoryNearEdge()
                setNeedsDisplay()
            } else {
                let maxOffset = max(0, f.scrollTotal - f.rows.count)
                onScrollOffset?(Int((fraction * CGFloat(maxOffset)).rounded()))
            }
            if recognizer.state == .ended || recognizer.state == .cancelled {
                draggingScrollbar = false
                setNeedsDisplay()
            }
            return
        }

        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)

        if isSnapshotMirror {
            followInputCursor = false
            let prevY = offsetY
            offsetX -= translation.x
            offsetY -= translation.y
            constrainOffsets()
            followOutput = (maxY() - offsetY) < cellHeight * 2 && atHistoryTail()

            // Forward only vertical overflow beyond local snapshot bounds to remote TUI wheel / history.
            let localConsumedY = prevY - offsetY
            let remainingY = translation.y - localConsumedY
            if let source = rawFrame, source.history?.applicationScroll != false, abs(remainingY) > 0.01 {
                scrollResidual += remainingY
                let lines = Int(trunc(scrollResidual / max(1, cellHeight)))
                if lines != 0 {
                    scrollResidual -= CGFloat(lines) * cellHeight
                    let pt = cellPoint(at: location, in: f)
                    let srcCols = max(1, source.columns)
                    let cellIdx = (f.sourceOffsets?[safe: pt.row] ?? (pt.row * srcCols)) + pt.column
                    let srcCol = (cellIdx % srcCols).clamped(to: 0...(srcCols - 1))
                    let srcRow = (cellIdx / srcCols).clamped(to: 0...max(0, source.rows.count - 1))
                    onScrollLines?(-lines, srcCol, srcRow)
                    followOutput = false
                }
            }
            if rawFrame?.history?.applicationScroll == false {
                requestHistoryNearEdge()
            }
            setNeedsDisplay()

            if recognizer.state == .ended {
                startMomentum(velocity: recognizer.velocity(in: self))
            }
            return
        }

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
        if isSnapshotMirror {
            switch recognizer.state {
            case .began:
                stopMomentum()
                pinchInProgress = true
                pinchBaseZoom = snapshotZoom
                onZoomGestureActive?(true, effectiveFontSize)
            case .changed:
                let oldW = max(1, cellWidth)
                let oldH = max(1, cellHeight)
                let focus = recognizer.location(in: self)
                let nextZoom = (pinchBaseZoom * recognizer.scale).clamped(to: 0.2...5.0)
                if abs(nextZoom - snapshotZoom) > 0.004 {
                    snapshotZoom = nextZoom
                    recomputeMetrics()
                    reproject(force: true)
                    offsetX = (offsetX + focus.x) * (cellWidth / oldW) - focus.x
                    offsetY = (offsetY + focus.y) * (cellHeight / oldH) - focus.y
                    constrainOffsets()
                    setNeedsDisplay()
                }
                onZoomGestureActive?(true, effectiveFontSize)
            case .ended, .cancelled:
                pinchInProgress = false
                onSnapshotZoomChanged?(snapshotZoom)
                onZoomGestureActive?(false, effectiveFontSize)
            default:
                break
            }
            return
        }

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
        CGPoint(
            x: (CGFloat(pt.column) + 0.5) * cellWidth - (isSnapshotMirror ? offsetX : 0),
            y: (CGFloat(pt.row) + 0.5) * cellHeight - (isSnapshotMirror ? offsetY : 0)
        )
    }

    private func presentCopyActionIfNeeded(_ sel: TerminalSelectionState) {
        // Tapping selected text copies immediately; long-press release also keeps handles visible for adjustment.
        setNeedsDisplay()
    }

    // MARK: - CoreGraphics / CoreText Cell Painting

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        guard let f = activeFrame else {
            UIColor.black.setFill()
            ctx.fill(rect)
            return
        }

        let defaultBg = PebrelPalette.uiColorFromARGB(f.background)
        defaultBg.setFill()
        ctx.fill(bounds)

        let rowCount = f.rows.count
        let defaultBgBits = Int32(bitPattern: f.background)
        let ox = isSnapshotMirror ? offsetX : 0
        let oy = isSnapshotMirror ? offsetY : 0
        let firstRow = max(0, Int(floor((rect.minY + oy) / max(1, cellHeight))))
        let lastRow = min(rowCount, Int(ceil((rect.maxY + oy) / max(1, cellHeight))))

        ctx.saveGState()
        ctx.clip(to: bounds)
        if ox != 0 || oy != 0 {
            ctx.translateBy(x: -ox, y: -oy)
        }

        // Pass 1: RLE-merged cell backgrounds
        if firstRow < lastRow {
            for y in firstRow..<lastRow {
                let row = f.rows[y]
                let cols = row.cells.count / 6
                let top = CGFloat(y) * cellHeight

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
        }

        // Pass 2: Selection highlight
        if let sel = selection, rowCount > 0 {
            let selColor = PebrelPalette.uiColorFromARGB(f.cursorColor).withAlphaComponent(0.28)
            selColor.setFill()
            let lo = sel.start
            let hi = sel.end
            let startY = max(firstRow, lo.row)
            let endY = min(lastRow - 1, min(hi.row, rowCount - 1))
            if startY <= endY {
                for y in startY...endY {
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
        }

        // Pass 3: Foreground glyphs (ASCII batching + vector box/block/braille + general glyphs)
        if firstRow < lastRow {
            for y in firstRow..<lastRow {
                let row = f.rows[y]
                let cols = row.cells.count / 6
                let top = CGFloat(y) * cellHeight

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
        }

        // Pass 4: Cursor
        if f.cursorVisible && selection == nil && (isSnapshotMirror || cursorPhaseVisible) {
            drawCursor(f, ctx: ctx)
        }

        ctx.restoreGState()

        // Pass 5: Selection knobs (drawn in viewport coordinates)
        if let sel = selection {
            drawSelectionHandles(sel, color: PebrelPalette.uiColorFromARGB(f.cursorColor), ctx: ctx)
        }

        // Pass 6: Overlay vertical & horizontal scrollbar thumbs
        if isSnapshotMirror {
            if maxY() > 1 {
                drawSnapshotVerticalScrollbar(f, ctx: ctx)
            }
            if maxX() > 1 {
                drawSnapshotHorizontalScrollbar(f, ctx: ctx)
            }
        } else if f.scrollTotal > f.rows.count {
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

        let lineSize = effectiveFontSize
        if (flags & 4) != 0 { // Underline
            color.setFill()
            ctx.fill(CGRect(x: x, y: top + cellHeight - max(1, lineSize * 0.08), width: allocatedWidth, height: max(1, lineSize * 0.07)))
        }
        if (flags & 8) != 0 { // Strikethrough
            color.setFill()
            ctx.fill(CGRect(x: x, y: top + cellHeight * 0.5, width: allocatedWidth, height: max(1, lineSize * 0.07)))
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

    private func drawSnapshotVerticalScrollbar(_ f: TerminalFrame, ctx: CGContext) {
        let contentH = max(bounds.height, CGFloat(f.rows.count) * cellHeight)
        let trackH = max(1, bounds.height - 12)
        let thumbH = max(36, trackH * (bounds.height / contentH))
        let maxOff = max(1, maxY())
        let progress = (offsetY / maxOff).clamped(to: 0...1)
        let thumbY = 6 + progress * max(0, trackH - thumbH)
        let rect = CGRect(x: bounds.width - 6, y: thumbY, width: 4, height: thumbH)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 2)
        PebrelPalette.uiColorFromARGB(f.cursorColor)
            .withAlphaComponent(draggingScrollbar ? 0.82 : 0.42)
            .setFill()
        path.fill()
    }

    private func drawSnapshotHorizontalScrollbar(_ f: TerminalFrame, ctx: CGContext) {
        let contentW = max(bounds.width, CGFloat(f.columns) * cellWidth)
        let trackW = max(1, bounds.width - 16)
        let thumbW = max(36, trackW * (bounds.width / contentW))
        let maxOff = max(1, maxX())
        let progress = (offsetX / maxOff).clamped(to: 0...1)
        let thumbX = 6 + progress * max(0, trackW - thumbW)
        let rect = CGRect(x: thumbX, y: bounds.height - 6, width: thumbW, height: 3.5)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 1.75)
        PebrelPalette.uiColorFromARGB(f.cursorColor)
            .withAlphaComponent(0.38)
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
