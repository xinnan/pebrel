import Foundation

private final class WebSocketOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var settled = false
    private var earlyResult: Result<Void, Error>?

    func setContinuation(_ cont: CheckedContinuation<Void, Error>) {
        lock.lock()
        if settled, let earlyResult {
            self.earlyResult = nil
            lock.unlock()
            cont.resume(with: earlyResult)
            return
        }
        continuation = cont
        lock.unlock()
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        let cont = continuation
        continuation = nil
        if cont == nil {
            earlyResult = result
        }
        lock.unlock()
        cont?.resume(with: result)
    }
}

/// WebSocket transport supporting both v1 JSON relay and v2 E2EE Noise relay/LAN endpoints.
final class RelayTransport: NSObject, DesktopTransport {
    let initialProfile: RelayProfile
    private(set) var activeProfile: RelayProfile

    private let maxFrameBytes = 2 * 1024 * 1024 + 1024
    private var urlSession: URLSession?
    private var wsTask: URLSessionWebSocketTask?
    private var tlsDelegate: PinnedTlsSessionDelegate?
    private var secureSession: SecureRelaySession?
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var linkEpoch: String?
    private var relayReached = false
    private var closed = false
    private let lock = NSLock()

    var onFrame: (([String: Any]) -> Void)?
    var onFailure: ((DesktopFailureKind) -> Void)?
    var onEnrolled: ((RelayProfile) -> Void)?

    init(profile: RelayProfile) {
        self.initialProfile = profile
        self.activeProfile = profile
    }

    var transportLabel: String {
        activeProfile.isLan ? "LAN" : "Relay"
    }

    func readyTimeoutFailure() -> DesktopFailureKind {
        relayReached ? .peerOffline : .timeout
    }

    func open() async throws {
        guard let encodedDevice = activeProfile.device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(activeProfile.url)/v\(activeProfile.version)/link?device=\(encodedDevice)&role=mobile"),
              let host = url.host else {
            throw DesktopFailure(.protocol)
        }

        let delegate = PinnedTlsSessionDelegate(expectedPin: activeProfile.tlsPin, expectedHost: host)
        self.tlsDelegate = delegate

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 0
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        self.urlSession = session

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(activeProfile.token)", forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "Origin")

        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = maxFrameBytes
        self.wsTask = ws

        if activeProfile.version == 2 {
            self.secureSession = SecureRelaySession(
                profile: activeProfile,
                sendBinary: { [weak self] bytes in
                    guard let self, let task = self.wsTask else { throw DesktopFailure(.disconnected) }
                    try await task.send(.data(bytes))
                },
                deliverFrame: { [weak self] frame in
                    self?.onFrame?(frame)
                },
                onEnrolled: { [weak self] updated in
                    self?.activeProfile = updated
                    self?.onEnrolled?(updated)
                }
            )
        }

        // Wait for actual WebSocket HTTP 101 upgrade completion via URLSessionWebSocketDelegate
        // instead of sending a premature Ping frame before the server finishes authentication setup.
        let openGate = WebSocketOpenGate()
        delegate.onWebSocketOpen = { [weak self] in
            self?.relayReached = true
            openGate.resolve(.success(()))
        }
        delegate.onTaskComplete = { [weak self] error, httpResponse in
            if let pinErr = self?.tlsDelegate?.pinFailure {
                openGate.resolve(.failure(DesktopFailure(pinErr)))
            } else if let status = httpResponse?.statusCode, status != 101 {
                openGate.resolve(.failure(DesktopFailure(DesktopFailureClassifier.fromHttpStatus(status))))
            } else if let error {
                openGate.resolve(.failure(DesktopFailure(DesktopFailureClassifier.classify(error, relayReached: false))))
            } else {
                openGate.resolve(.failure(DesktopFailure(.disconnected)))
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                openGate.setContinuation(continuation)
                ws.resume()
            }
        } onCancel: { [weak self] in
            openGate.resolve(.failure(DesktopFailure(.disconnected)))
            self?.close()
        }

        delegate.onWebSocketOpen = nil
        delegate.onTaskComplete = nil

        startHeartbeat()
        startReceiving()
    }

    func send(_ frame: [String: Any]) async throws {
        guard !isClosed(), let ws = wsTask else {
            throw DesktopFailure(.disconnected)
        }
        if activeProfile.version == 2 {
            guard let secureSession else { throw DesktopFailure(.protocol) }
            try await secureSession.sendRuntimeFrame(frame)
            return
        }
        guard let epoch = linkEpoch else {
            throw DesktopFailure(.disconnected)
        }
        let envelope: [String: Any] = [
            "type": "relay.data",
            "link": epoch,
            "body": frame,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              data.count <= maxFrameBytes else {
            throw DesktopFailure(.protocol)
        }
        let text = String(decoding: data, as: UTF8.self)
        try await ws.send(.string(text))
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if wasClosed { return }
        pingTask?.cancel()
        pingTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        secureSession?.close()
        secureSession = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func isClosed() -> Bool {
        lock.lock()
        let val = closed
        lock.unlock()
        return val
    }

    private func startHeartbeat() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard let self, !self.isClosed(), let ws = self.wsTask else { return }
                let failed: Bool = await withCheckedContinuation { cont in
                    ws.sendPing { err in cont.resume(returning: err != nil) }
                }
                if failed {
                    self.fail(.network)
                    return
                }
            }
        }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && !self.isClosed() {
                guard let ws = self.wsTask else { return }
                do {
                    let message = try await ws.receive()
                    try await self.handleMessage(message)
                } catch let failure as DesktopFailure {
                    self.fail(failure.kind)
                    return
                } catch {
                    if self.isClosed() { return }
                    if let pinErr = self.tlsDelegate?.pinFailure {
                        self.fail(pinErr)
                    } else if ws.closeCode != .invalid {
                        self.fail(DesktopFailureClassifier.fromWebSocketClose(ws.closeCode))
                    } else {
                        self.fail(DesktopFailureClassifier.classify(error, relayReached: self.relayReached))
                    }
                    return
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .string(let text):
            guard text.utf8.count <= maxFrameBytes,
                  let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else {
                throw DesktopFailure(.protocol)
            }
            if activeProfile.version == 2 {
                guard (obj["version"] as? Int) == 2 else { throw DesktopFailure(.protocol) }
            }
            switch type {
            case "relay.waiting":
                return
            case "relay.paired":
                guard linkEpoch == nil,
                      let epoch = obj["link"] as? String,
                      !epoch.isEmpty, epoch.count <= 80 else {
                    throw DesktopFailure(.protocol)
                }
                if activeProfile.version == 2 && !RelayProfile.isValidIdentifier(epoch) {
                    throw DesktopFailure(.protocol)
                }
                linkEpoch = epoch
                if activeProfile.version == 2 {
                    try await secureSession?.paired(epoch: epoch)
                }
            case "relay.peer_left":
                throw DesktopFailure(.peerOffline)
            case "relay.data":
                guard activeProfile.version == 1,
                      let epoch = obj["link"] as? String,
                      epoch == linkEpoch,
                      let body = obj["body"] as? [String: Any] else {
                    throw DesktopFailure(.protocol)
                }
                onFrame?(body)
            default:
                throw DesktopFailure(.protocol)
            }

        case .data(let bytes):
            guard activeProfile.version == 2,
                  bytes.count >= 1, bytes.count <= 65535,
                  let secureSession else {
                throw DesktopFailure(.protocol)
            }
            try await secureSession.receiveBinary(bytes)

        @unknown default:
            throw DesktopFailure(.protocol)
        }
    }

    private func fail(_ kind: DesktopFailureKind) {
        if isClosed() { return }
        close()
        onFailure?(kind)
    }

    deinit {
        close()
    }
}
