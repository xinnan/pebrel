import AVFoundation
import Foundation

/// Captures 16 kHz mono Float32 PCM audio (0.3s..60s) via AVAudioEngine with zeroized buffer cleanup.
final class PcmRecorder {
    static let sampleRate: Double = 16000
    static let maxSamples = 16000 * 60
    static let minSamples = 4800

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false
    private var startedAt = Date()

    func start(onMeter: @escaping @MainActor (Float, Int) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw LocalWhisperError.failed("audio_format_unavailable")
        }

        lock.lock()
        samples.removeAll(keepingCapacity: false)
        samples.reserveCapacity(16000 * 10)
        running = true
        startedAt = Date()
        lock.unlock()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = Self.sampleRate / max(1.0, inputFormat.sampleRate)
            let outCap = AVAudioFrameCount(max(64, ceil(Double(buffer.frameLength) * ratio) + 32))
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }

            var consumed = false
            var err: NSError?
            let status = converter.convert(to: converted, error: &err) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let ptr = converted.floatChannelData?[0] else { return }
            let frameCount = Int(converted.frameLength)
            guard frameCount > 0 else { return }

            var sumSq: Float = 0
            for i in 0..<frameCount {
                let s = ptr[i]
                sumSq += s * s
            }
            let rms = min(1.0, sqrt(sumSq / Float(frameCount)) * 4.0)

            self.lock.lock()
            let active = self.running
            let elapsed = Int(Date().timeIntervalSince(self.startedAt))
            if active && self.samples.count < Self.maxSamples {
                let remaining = Self.maxSamples - self.samples.count
                let take = min(frameCount, remaining)
                self.samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: take))
            }
            self.lock.unlock()

            if active {
                Task { @MainActor in onMeter(rms, elapsed) }
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        lock.lock()
        running = false
        let captured = samples
        for i in samples.indices { samples[i] = 0 }
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return captured
    }

    func cancel() {
        var discarded = stop()
        for i in discarded.indices { discarded[i] = 0 }
    }
}
