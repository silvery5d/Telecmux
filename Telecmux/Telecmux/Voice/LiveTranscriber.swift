import AVFoundation
import Speech

/// Records audio from the device microphone and streams it through Apple's
/// on-device speech recognizer (`SFSpeechRecognizer`). Updates `transcript`
/// live as partial results arrive. Stop by calling `stop()`; the final
/// transcript stays in `transcript` until the next `start()`.
@MainActor
@Observable
final class LiveTranscriber {

    enum Status: Equatable {
        case idle
        case requestingPermission
        case recording
        case denied(String)
        case error(String)
    }

    private(set) var status: Status = .idle
    private(set) var transcript: String = ""

    private let engine = AVAudioEngine()
    private var bufferRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer: SFSpeechRecognizer

    init(locale: Locale = .current) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    }

    // MARK: - public

    /// Request permission, configure the audio session + recognition task,
    /// and start streaming. Idempotent: calling while already recording is
    /// a no-op.
    func start() async {
        if case .recording = status { return }
        transcript = ""
        status = .requestingPermission

        guard await requestMicPermission() else {
            status = .denied("Microphone permission denied"); return
        }
        guard await requestSpeechAuth() else {
            status = .denied("Speech recognition permission denied"); return
        }
        guard recognizer.isAvailable else {
            status = .error("Speech recognizer is offline or unavailable"); return
        }

        do {
            try configureAudioSession()
            try beginRecognition()
        } catch {
            status = .error(error.localizedDescription)
            cleanup()
        }
    }

    /// Stop the engine, end the recognition request, and tear down state.
    /// Final transcript stays in `transcript`.
    func stop() {
        guard case .recording = status else { return }
        cleanup()
        status = .idle
    }

    // MARK: - permission

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func requestSpeechAuth() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { auth in
                cont.resume(returning: auth == .authorized)
            }
        }
    }

    // MARK: - audio + recognition setup

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    private func beginRecognition() throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        bufferRequest = request

        // Recognition callback: feed every partial transcript into our
        // @Observable property so the modal updates live.
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    if case .recording = self.status { self.cleanup(); self.status = .idle }
                }
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.bufferRequest?.append(buf)
        }
        engine.prepare()
        try engine.start()
        status = .recording
    }

    // MARK: - cleanup

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        bufferRequest?.endAudio()
        task?.cancel()
        bufferRequest = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
