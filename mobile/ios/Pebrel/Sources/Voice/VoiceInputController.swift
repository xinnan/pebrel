import AVFoundation
import Combine
import Foundation

enum VoicePhase: Equatable {
    case checking
    case missing
    case ready
    case downloading
    case recording
    case transcribing
}

enum VoiceErrorKind: Equatable {
    case permission
    case failed
    case empty
    case short
    case model
    case engine
}

struct VoiceState: Equatable {
    var phase: VoicePhase = .checking
    var error: VoiceErrorKind?
    var progress: Float = 0
    var level: Float = 0
    var seconds: Int = 0
    var cancelArmed: Bool = false
}

@MainActor
final class VoiceInputController: ObservableObject {
    @Published private(set) var state = VoiceState()

    private let recorder = PcmRecorder()
    private var activeTask: Task<Void, Never>?
    private var generation: Int = 0

    func checkModel() {
        generation += 1
        let gen = generation
        state.phase = .checking
        Task {
            let installed = await VoiceModelStore.shared.isInstalled()
            guard gen == self.generation else { return }
            self.state.phase = installed ? .ready : .missing
        }
    }

    func downloadModel() {
        guard state.phase == .missing || state.error != nil else { return }
        activeTask?.cancel()
        generation += 1
        let gen = generation
        state = VoiceState(phase: .downloading, progress: 0)
        activeTask = Task {
            do {
                try await VoiceModelStore.shared.download { [weak self] p in
                    guard let self, gen == self.generation else { return }
                    self.state.progress = p
                }
                guard gen == self.generation else { return }
                self.state = VoiceState(phase: .ready, progress: 1.0)
            } catch is CancellationError {
                guard gen == self.generation else { return }
                self.state = VoiceState(phase: .missing)
            } catch {
                guard gen == self.generation else { return }
                self.state = VoiceState(phase: .missing, error: .model)
            }
        }
    }

    func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        checkModel()
    }

    func removeModel() {
        activeTask?.cancel()
        Task {
            await VoiceModelStore.shared.removeModel()
            self.state = VoiceState(phase: .missing)
        }
    }

    func startRecording() {
        guard state.phase == .ready else { return }
        let permission = AVAudioSession.sharedInstance().recordPermission
        switch permission {
        case .undetermined:
            AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    if !granted { self?.state.error = .permission }
                }
            }
            return
        case .denied:
            state.error = .permission
            return
        case .granted:
            break
        @unknown default:
            return
        }

        generation += 1
        let gen = generation
        do {
            try recorder.start { [weak self] level, seconds in
                guard let self, gen == self.generation, self.state.phase == .recording else { return }
                self.state.level = level
                self.state.seconds = seconds
            }
            state = VoiceState(phase: .recording, level: 0, seconds: 0, cancelArmed: false)
        } catch {
            state = VoiceState(phase: .ready, error: .failed)
        }
    }

    func setCancelArmed(_ armed: Bool) {
        guard state.phase == .recording else { return }
        state.cancelArmed = armed
    }

    func cancelRecordingOrTranscription() {
        generation += 1
        activeTask?.cancel()
        activeTask = nil
        recorder.cancel()
        checkModel()
    }

    func finishRecording(onTranscript: @escaping @MainActor (String) -> Void) {
        guard state.phase == .recording else { return }
        if state.cancelArmed {
            cancelRecordingOrTranscription()
            return
        }

        var pcm = recorder.stop()
        if pcm.count < PcmRecorder.minSamples {
            for i in pcm.indices { pcm[i] = 0 }
            state = VoiceState(phase: .ready, error: .short)
            return
        }
        let hasSignal = pcm.contains { abs($0) > 0.008 }
        if !hasSignal {
            for i in pcm.indices { pcm[i] = 0 }
            state = VoiceState(phase: .ready, error: .empty)
            return
        }

        let samples = pcm
        for i in pcm.indices { pcm[i] = 0 }

        generation += 1
        let gen = generation
        state = VoiceState(phase: .transcribing)
        activeTask = Task {
            do {
                let text = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        try await VoiceModelStore.shared.transcribe(samples: samples)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 120_000_000_000)
                        throw LocalWhisperError.failed("timeout")
                    }
                    guard let value = try await group.next() else { return "" }
                    group.cancelAll()
                    return value
                }
                guard gen == self.generation else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.state = VoiceState(phase: .ready, error: trimmed.isEmpty ? .empty : nil)
                if !trimmed.isEmpty {
                    onTranscript(trimmed)
                }
            } catch is CancellationError {
                guard gen == self.generation else { return }
                self.state = VoiceState(phase: .ready)
            } catch {
                guard gen == self.generation else { return }
                self.state = VoiceState(phase: .ready, error: .engine)
            }
        }
    }

    nonisolated static func appendVoiceDraft(_ draft: String, spoken: String, limit: Int = 8192) -> String? {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return draft }
        let combined = draft.isEmpty ? trimmed : (draft.hasSuffix(" ") || draft.hasSuffix("\n") ? draft + trimmed : draft + " " + trimmed)
        guard combined.count <= limit else { return nil }
        return combined
    }
}
