import Combine
import Foundation

protocol TerminalTransportBridge: AnyObject {
    func sendBytes(_ data: Data) async throws
    func resize(columns: Int, rows: Int, width: Int, height: Int) async throws
    func scrollHistory(lines: Int) async
    func returnToLiveInput() async
}

/// Owns a `GhosttyCore` on a dedicated serial queue, coalescing frames at ~60 Hz
/// and honoring DEC 2026 synchronized output + 120ms resize settle debouncing.
final class TerminalSession {
    private let queue = DispatchQueue(label: "io.github.kuddev.pebrel.terminal.core", qos: .userInteractive)
    private var core: GhosttyCore?
    private weak var transport: TerminalTransportBridge?

    private var currentFrame: TerminalFrame?
    private var pendingFrameWork: DispatchWorkItem?
    private var syncOutputStartedAt: Date?
    private var resizeWork: DispatchWorkItem?
    private var lastColumns = 80
    private var lastRows = 24
    private var lastCellWidth = 10
    private var lastCellHeight = 20
    private var closed = false
    private var queuedBytes = 0
    private let maxQueuedBytes = 128 * 1024
    private let inputLock = NSLock()

    var onFrame: ((TerminalFrame) -> Void)?
    var onTitle: ((String) -> Void)?

    init(columns: Int = 80, rows: Int = 24, scrollback: Int = 1000, colors: [UInt32]? = nil) {
        self.lastColumns = columns
        self.lastRows = rows
        queue.sync {
            if let created = try? GhosttyCore(columns: columns, rows: rows, scrollback: scrollback) {
                if let colors, colors.count == 19 {
                    created.applyColors(colors)
                }
                self.core = created
                self.currentFrame = try? created.render()
            }
        }
    }

    func attachTransport(_ transport: TerminalTransportBridge?) {
        queue.async { [weak self] in
            self?.transport = transport
        }
    }

    func setColors(_ colors19: [UInt32]) {
        guard colors19.count == 19 else { return }
        queue.async { [weak self] in
            guard let self, let core = self.core, !self.closed else { return }
            core.applyColors(colors19)
            self.scheduleRender()
        }
    }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, let core = self.core, !self.closed else { return }
            var offset = 0
            while offset < data.count {
                let end = min(offset + 65536, data.count)
                let slice = data.subdata(in: offset..<end)
                if let replies = try? core.feed(slice), !replies.isEmpty {
                    self.sendRawToTransport(replies)
                }
                offset = end
            }
            if let title = core.pollTitle() {
                DispatchQueue.main.async { [weak self] in
                    self?.onTitle?(title)
                }
            }
            self.scheduleRender()
        }
    }

    func resize(columns: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        let cols = columns.clamped(to: 2...400)
        let r = rows.clamped(to: 2...200)
        let cw = cellWidth.clamped(to: 1...256)
        let ch = cellHeight.clamped(to: 1...256)

        queue.async { [weak self] in
            guard let self, let core = self.core, !self.closed else { return }
            if cols == self.lastColumns && r == self.lastRows && cw == self.lastCellWidth && ch == self.lastCellHeight {
                return
            }
            self.lastColumns = cols
            self.lastRows = r
            self.lastCellWidth = cw
            self.lastCellHeight = ch
            try? core.resize(columns: cols, rows: r, cellWidth: cw, cellHeight: ch)
            self.scheduleRender()

            self.resizeWork?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self, let transport = self.transport, !self.closed else { return }
                let pxW = cols * cw
                let pxH = r * ch
                Task {
                    try? await transport.resize(columns: cols, rows: r, width: pxW, height: pxH)
                }
            }
            self.resizeWork = item
            self.queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: item)
        }
    }

    func sendText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let data = Data(text.utf8)
        return sendRawToTransport(data)
    }

    func paste(_ raw: String) -> Bool {
        guard raw.count <= 32768 else { return false }
        let cleaned = raw
            .replacingOccurrences(of: "\u{001B}", with: "")
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        guard !cleaned.isEmpty else { return true }
        let bracketed: Bool = queue.sync {
            core?.bracketedPaste() ?? false
        }
        let payload = bracketed ? "\u{001B}[200~\(cleaned)\u{001B}[201~" : cleaned
        return sendRawToTransport(Data(payload.utf8))
    }

    func sendKey(code: Int32, modifiers: Int32, action: Int32 = 1, text: String = "", unshifted: UInt32 = 0) -> Bool {
        let encoded: Data = queue.sync {
            guard let core, !closed else { return Data() }
            if !isAtBottomLocked() {
                core.scrollToBottom()
                scheduleRender()
            }
            return core.encodeKey(code: code, modifiers: modifiers, action: action, text: text, unshifted: unshifted)
        }
        guard !encoded.isEmpty else { return true }
        return sendRawToTransport(encoded)
    }

    func sendShortcut(_ shortcut: TerminalShortcut) -> Bool {
        sendKey(
            code: shortcut.code,
            modifiers: shortcut.modifiers,
            action: 1,
            text: shortcut.text,
            unshifted: shortcut.unshifted
        )
    }

    func scrollViewport(delta: Int, column: Int, row: Int) {
        queue.async { [weak self] in
            guard let self, let core = self.core, !self.closed else { return }
            let mode = core.applicationScrollMode()
            if mode == 0 {
                core.scroll(delta: delta)
                self.scheduleRender()
            } else {
                let bytes = core.wheel(lines: delta, column: column, row: row, applicationOnly: false)
                if !bytes.isEmpty {
                    self.sendRawToTransport(bytes)
                } else if let transport = self.transport {
                    Task { await transport.scrollHistory(lines: delta) }
                }
            }
        }
    }

    func scrollTo(offset: Int) {
        queue.async { [weak self] in
            guard let self, let core = self.core, !self.closed else { return }
            core.scrollTo(offset: offset)
            self.scheduleRender()
        }
    }

    func scrollToBottom() {
        queue.async { [weak self] in
            guard let self, let core = self.core, !self.closed else { return }
            core.scrollToBottom()
            self.scheduleRender()
        }
    }

    func latestFrame() -> TerminalFrame? {
        queue.sync { currentFrame }
    }

    func screenText() -> String {
        queue.sync { currentFrame?.screenText() ?? "" }
    }

    func previewText() -> String {
        queue.sync { currentFrame?.previewText(maxLines: 6) ?? "" }
    }

    func currentGeometry() -> (columns: Int, rows: Int, width: Int, height: Int) {
        queue.sync {
            (lastColumns, lastRows, lastColumns * lastCellWidth, lastRows * lastCellHeight)
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self else { return }
            self.closed = true
            self.pendingFrameWork?.cancel()
            self.resizeWork?.cancel()
            self.core?.destroy()
            self.core = nil
        }
    }

    @discardableResult
    private func sendRawToTransport(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        inputLock.lock()
        if queuedBytes + data.count > maxQueuedBytes {
            inputLock.unlock()
            return false
        }
        queuedBytes += data.count
        inputLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let transport = self.transport
            Task {
                defer {
                    self.inputLock.lock()
                    self.queuedBytes = max(0, self.queuedBytes - data.count)
                    self.inputLock.unlock()
                }
                guard let transport else { return }
                await transport.returnToLiveInput()
                try? await transport.sendBytes(data)
            }
        }
        return true
    }

    private func isAtBottomLocked() -> Bool {
        currentFrame?.isAtBottom ?? true
    }

    private func scheduleRender() {
        if pendingFrameWork != nil { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFrameWork = nil
            guard let core = self.core, !self.closed else { return }

            if core.synchronizedOutput() {
                let now = Date()
                if let started = self.syncOutputStartedAt {
                    if now.timeIntervalSince(started) >= 1.0 {
                        core.endSynchronizedOutput()
                        self.syncOutputStartedAt = nil
                    } else {
                        self.scheduleRender()
                        return
                    }
                } else {
                    self.syncOutputStartedAt = now
                    self.scheduleRender()
                    return
                }
            } else {
                self.syncOutputStartedAt = nil
            }

            guard let frame = try? core.render() else { return }
            self.currentFrame = frame
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(frame)
            }
        }
        pendingFrameWork = item
        queue.asyncAfter(deadline: .now() + .milliseconds(16), execute: item)
    }

    deinit {
        core?.destroy()
    }
}
