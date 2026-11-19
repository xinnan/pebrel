import Foundation

struct DesktopCapabilities: Equatable {
    var snapshot = false
    var readTail = false
    var stateSubscription = false
    var input = false
    var terminalGridStream = false
    var screenDelta = false
    var terminalGrid = false
    var terminalScroll = false
    var terminalHistory = false
}

private struct JsonDictBox: @unchecked Sendable {
    let value: [String: Any]
}

/// Manages Desktop Runtime RPC framing, pipelining (max 16 in-flight, 35s timeout),
/// live `mobile.policy` updates, and `runtime.snapshot` / `pane.screen.*` routing.
final class DesktopRuntimeClient {
    let transport: DesktopTransport
    let requestedAllowInput: Bool

    private let lock = NSLock()
    private var nextRequestId: Int64 = 1
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var readyContinuation: CheckedContinuation<[String: Any], Error>?
    private var firstSnapshotContinuation: CheckedContinuation<DesktopSnapshot, Error>?

    private(set) var capabilities = DesktopCapabilities()
    private(set) var negotiatedInput = false
    private(set) var hostOs: String?
    private var liveInputOverride: Bool?
    private var latestSnapshot: DesktopSnapshot?
    private var snapshotDeliveryEnabled = false
    private var lastReceivedAt: TimeInterval = 0
    private(set) var isClosed = false

    var onApproval: ((DesktopPairingApproval) -> Void)?
    var onSnapshot: ((DesktopSnapshot) -> Void)?
    var onScreenEvent: (([String: Any]) -> Void)?
    var onDisconnect: ((DesktopFailureKind) -> Void)?

    init(transport: DesktopTransport, allowInput: Bool = true) {
        self.transport = transport
        self.requestedAllowInput = allowInput
    }

    var recentlyActive: Bool {
        lock.lock()
        let active = !isClosed && lastReceivedAt > 0 && (ProcessInfo.processInfo.systemUptime - lastReceivedAt) < 10.0
        lock.unlock()
        return active
    }

    func connect() async throws {
        transport.onFrame = { [weak self] frame in
            self?.handleIncoming(frame)
        }
        transport.onFailure = { [weak self] kind in
            self?.disconnect(kind: kind)
        }

        try await transport.open()

        // 1. Await mobile.ready (or mobile.approval followed by mobile.ready)
        let readyMsg = try await awaitReady(timeoutSeconds: 30)
        guard let proto = readyMsg["protocol"] as? String,
              (proto == "pebrel.mobile.ssh" || proto == "pebrel.mobile.relay"),
              (readyMsg["version"] as? Int) == 1 else {
            disconnect(kind: .protocol)
            throw DesktopFailure(.protocol)
        }

        if let caps = readyMsg["capabilities"] as? [String: Any] {
            capabilities = DesktopCapabilities(
                snapshot: caps["snapshot"] as? Bool ?? false,
                readTail: caps["read_tail"] as? Bool ?? false,
                stateSubscription: caps["state_subscription"] as? Bool ?? false,
                input: caps["input"] as? Bool ?? false,
                terminalGridStream: caps["terminal_grid_stream"] as? Bool ?? false,
                screenDelta: caps["screen_delta"] as? Bool ?? false,
                terminalGrid: caps["terminal_grid"] as? Bool ?? false,
                terminalScroll: caps["terminal_scroll"] as? Bool ?? false,
                terminalHistory: caps["terminal_history"] as? Bool ?? false
            )
        }
        negotiatedInput = requestedAllowInput && capabilities.input
        if let hostDict = readyMsg["host"] as? [String: Any] {
            hostOs = hostDict["os"] as? String
        }

        // 2. Subscribe to runtime events
        do {
            _ = try await request(method: "events.subscribe", params: [:])
        } catch {
            disconnect(kind: .runtimeUnavailable)
            throw DesktopFailure(.runtimeUnavailable)
        }

        // 3. Await initial runtime.snapshot (30s timeout)
        let first = try await awaitFirstSnapshot(timeoutSeconds: 30)
        lock.lock()
        snapshotDeliveryEnabled = true
        lock.unlock()
        onSnapshot?(first)
    }

    func request(method: String, params: [String: Any] = [:], timeoutSeconds: Double = 35.0) async throws -> [String: Any] {
        let reqId: String
        lock.lock()
        if isClosed {
            lock.unlock()
            throw DesktopFailure(.disconnected)
        }
        if pending.count >= 16 {
            lock.unlock()
            throw DesktopRpcFailure("too_many_pending")
        }
        reqId = "\(nextRequestId)"
        nextRequestId += 1
        lock.unlock()

        let envelope: [String: Any] = [
            "id": reqId,
            "method": method,
            "params": params,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: envelope),
              encoded.count + 1 <= 40 * 1024 else {
            throw DesktopRpcFailure("request_too_large")
        }

        let box = try await withThrowingTaskGroup(of: JsonDictBox.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw DesktopFailure(.disconnected) }
                let dict: [String: Any] = try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    if self.isClosed {
                        self.lock.unlock()
                        cont.resume(throwing: DesktopFailure(.disconnected))
                        return
                    }
                    self.pending[reqId] = cont
                    self.lock.unlock()

                    Task {
                        do {
                            try await self.transport.send(envelope)
                        } catch {
                            self.disconnect(kind: DesktopFailureClassifier.classify(error, relayReached: true))
                        }
                    }
                }
                return JsonDictBox(value: dict)
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self?.disconnect(kind: .timeout)
                throw DesktopFailure(.timeout)
            }
            guard let result = try await group.next() else {
                throw DesktopFailure(.disconnected)
            }
            group.cancelAll()
            return result
        }
        return box.value
    }

    func probeHealth() async -> Bool {
        do {
            _ = try await request(method: "runtime.describe", params: [:], timeoutSeconds: 5.0)
            return true
        } catch {
            return false
        }
    }

    func close() {
        disconnect(kind: nil)
    }

    private func disconnect(kind: DesktopFailureKind?) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        let pendingCopy = pending
        pending.removeAll()
        let readyCont = readyContinuation
        readyContinuation = nil
        let snapCont = firstSnapshotContinuation
        firstSnapshotContinuation = nil
        lock.unlock()

        transport.close()
        let error = DesktopFailure(kind ?? .disconnected)
        readyCont?.resume(throwing: error)
        snapCont?.resume(throwing: error)
        for cont in pendingCopy.values {
            cont.resume(throwing: error)
        }
        if let kind {
            onDisconnect?(kind)
        }
    }

    private func awaitReady(timeoutSeconds: Double) async throws -> [String: Any] {
        var timeout = timeoutSeconds
        while true {
            let currentTimeout = timeout
            let box: JsonDictBox = try await withThrowingTaskGroup(of: JsonDictBox.self) { group in
                group.addTask { [weak self] in
                    let dict: [String: Any] = try await withCheckedThrowingContinuation { cont in
                        guard let self else { cont.resume(throwing: DesktopFailure(.disconnected)); return }
                        self.lock.lock()
                        if self.isClosed {
                            self.lock.unlock()
                            cont.resume(throwing: DesktopFailure(.disconnected))
                            return
                        }
                        self.readyContinuation = cont
                        self.lock.unlock()
                    }
                    return JsonDictBox(value: dict)
                }
                group.addTask { [weak self] in
                    try await Task.sleep(nanoseconds: UInt64(currentTimeout * 1_000_000_000))
                    let kind = self?.transport.readyTimeoutFailure() ?? .timeout
                    self?.disconnect(kind: kind)
                    throw DesktopFailure(kind)
                }
                guard let value = try await group.next() else { throw DesktopFailure(.timeout) }
                group.cancelAll()
                return value
            }
            let msg = box.value

            if (msg["type"] as? String) == "mobile.approval" {
                let code = msg["code"] as? String ?? ""
                let expiresAt = (msg["expiresAt"] as? NSNumber)?.int64Value ?? (Int64(Date().timeIntervalSince1970) + 120)
                onApproval?(DesktopPairingApproval(code: code, expiresAt: expiresAt))
                let remaining = max(1.0, min(120.0, Double(expiresAt) - Date().timeIntervalSince1970))
                timeout = remaining + 15.0
                continue
            }
            return msg
        }
    }

    private func awaitFirstSnapshot(timeoutSeconds: Double) async throws -> DesktopSnapshot {
        lock.lock()
        if let already = latestSnapshot {
            lock.unlock()
            return already
        }
        lock.unlock()

        return try await withThrowingTaskGroup(of: DesktopSnapshot.self) { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { cont in
                    guard let self else { cont.resume(throwing: DesktopFailure(.runtimeUnavailable)); return }
                    self.lock.lock()
                    if let already = self.latestSnapshot {
                        self.lock.unlock()
                        cont.resume(returning: already)
                        return
                    }
                    if self.isClosed {
                        self.lock.unlock()
                        cont.resume(throwing: DesktopFailure(.runtimeUnavailable))
                        return
                    }
                    self.firstSnapshotContinuation = cont
                    self.lock.unlock()
                }
            }
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self?.disconnect(kind: .runtimeUnavailable)
                throw DesktopFailure(.runtimeUnavailable)
            }
            guard let snap = try await group.next() else { throw DesktopFailure(.runtimeUnavailable) }
            group.cancelAll()
            return snap
        }
    }

    private func handleIncoming(_ msg: [String: Any]) {
        lock.lock()
        lastReceivedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()

        if let type = msg["type"] as? String {
            switch type {
            case "mobile.ready", "mobile.approval":
                lock.lock()
                let cont = readyContinuation
                readyContinuation = nil
                lock.unlock()
                cont?.resume(returning: msg)
                return
            case "mobile.disconnected":
                disconnect(kind: .runtimeUnavailable)
                return
            case "mobile.policy":
                if let allow = msg["allow_input"] as? Bool {
                    applyLiveInputPolicy(allow)
                }
                return
            default:
                break
            }
        }

        if let event = msg["event"] as? String {
            if event == "runtime.snapshot", let data = msg["data"] as? [String: Any] {
                acceptSnapshotDict(data)
            } else if event.hasPrefix("pane.screen") {
                onScreenEvent?(msg)
            }
            return
        }

        if let id = msg["id"] as? String {
            lock.lock()
            let cont = pending.removeValue(forKey: id)
            lock.unlock()
            guard let cont else { return }

            if (msg["ok"] as? Bool) == true {
                let result = msg["result"] as? [String: Any] ?? [:]
                if let snapDict = result["snapshot"] as? [String: Any] {
                    acceptSnapshotDict(snapDict)
                }
                cont.resume(returning: result)
            } else {
                let errDict = msg["error"] as? [String: Any]
                let code = errDict?["code"] as? String ?? "runtime_error"
                let details = errDict?["details"] as? [String: Any]
                let stderr = details?["stderr"] as? String ?? ""
                cont.resume(throwing: DesktopRpcFailure(code, detail: stderr))
            }
        }
    }

    private func applyLiveInputPolicy(_ allow: Bool) {
        lock.lock()
        liveInputOverride = allow
        guard let prev = latestSnapshot else {
            lock.unlock()
            return
        }
        let updated = DesktopSnapshot(
            processId: prev.processId,
            revision: prev.revision,
            allowInput: allow,
            notificationsEnabled: prev.notificationsEnabled,
            tabs: prev.tabs,
            panes: prev.panes
        )
        latestSnapshot = updated
        let deliver = snapshotDeliveryEnabled
        lock.unlock()
        if deliver {
            onSnapshot?(updated)
        }
    }

    private func acceptSnapshotDict(_ dict: [String: Any]) {
        guard var parsed = DesktopSnapshot.parse(dict) else { return }
        lock.lock()
        if let prev = latestSnapshot {
            if prev.processId == parsed.processId && prev.revision > parsed.revision {
                lock.unlock()
                return
            }
            if dict["mobile_policy"] == nil {
                parsed = DesktopSnapshot(
                    processId: parsed.processId,
                    revision: parsed.revision,
                    allowInput: prev.allowInput,
                    notificationsEnabled: prev.notificationsEnabled,
                    tabs: parsed.tabs,
                    panes: parsed.panes
                )
            }
        }
        if let override = liveInputOverride {
            parsed = DesktopSnapshot(
                processId: parsed.processId,
                revision: parsed.revision,
                allowInput: override,
                notificationsEnabled: parsed.notificationsEnabled,
                tabs: parsed.tabs,
                panes: parsed.panes
            )
        }
        latestSnapshot = parsed
        let firstCont = firstSnapshotContinuation
        firstSnapshotContinuation = nil
        let deliver = snapshotDeliveryEnabled
        lock.unlock()

        firstCont?.resume(returning: parsed)
        if deliver {
            onSnapshot?(parsed)
        }
    }
}
