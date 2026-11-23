import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CameraCapture {
    enum State: Equatable {
        case idle, starting, ready, startingRecording, recording, paused, finishing, processing
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    /// Résumé de la dernière prise, affiché quelques secondes après l'enregistrement.
    private(set) var lastTakeNote: String?
    /// Nombre de morceaux dans la prise en cours : 1 tant qu'aucune pause n'a eu lieu.
    private(set) var segmentCount = 0

    private let worker: CaptureWorker
    private var wantsCamera = false
    private var startupID = UUID()

    var session: AVCaptureSession { worker.session }

    init(onAudio: @escaping @Sendable (CMSampleBuffer) -> Void) {
        worker = CaptureWorker(onAudio: onAudio)
    }

    func start() async {
        wantsCamera = true
        switch state {
        case .idle, .unavailable: break
        default: return
        }

        let id = UUID()
        startupID = id
        state = .starting
        errorMessage = nil

        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil else {
            state = .unavailable("Caméra avant indisponible. Tu peux répéter avec les flèches.")
            return
        }

        let cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
        guard startupID == id, wantsCamera, !Task.isCancelled else { return }
        guard cameraAllowed else {
            state = .unavailable("Autorise la caméra dans les Réglages pour te filmer.")
            return
        }
        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard startupID == id, wantsCamera, !Task.isCancelled else { return }
        guard micAllowed else {
            state = .unavailable("Autorise le micro dans les Réglages pour filmer avec le son.")
            return
        }

        worker.start { [weak self] success in
            guard let self, startupID == id, wantsCamera else { return }
            state = success ? .ready : .unavailable("La caméra n'a pas démarré. Rouvre cet écran pour réessayer.")
        }
    }

    func stop() {
        wantsCamera = false
        startupID = UUID()
        switch state {
        case .startingRecording, .recording, .finishing:
            state = .finishing
        case .paused:
            state = .finishing
        case .processing:
            break // le montage de la prise se termine, on ne l'interrompt pas
        default:
            state = .idle
        }
        worker.stop()
    }

    func startRecording() {
        guard state == .ready else { return }
        state = .startingRecording
        errorMessage = nil
        lastTakeNote = nil
        segmentCount = 0
        worker.record { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                if state == .startingRecording {
                    state = .recording
                }
            case .paused:
                if state == .recording {
                    state = .paused
                }
            case .resumed:
                if state == .paused {
                    state = .recording
                }
            case .finished(let segments):
                guard let segments, !segments.isEmpty else {
                    errorMessage = "La vidéo n'a pas pu être enregistrée. Vérifie l'espace libre, puis réessaie."
                    settleAfterTake()
                    return
                }
                state = .processing
                Task { await processTake(segments) }
            }
        }
    }

    /// Suspend l'enregistrement : le segment en cours est fermé, la prise reste ouverte.
    func pauseRecording() {
        guard state == .recording else { return }
        state = .paused
        worker.pause()
    }

    /// Reprend l'enregistrement dans la même prise : un nouveau segment s'ouvre.
    func resumeRecording() {
        guard state == .paused else { return }
        state = .recording
        worker.resume()
    }

    func stopRecording() {
        guard state == .recording || state == .paused else { return }
        state = .finishing
        worker.finish()
    }

    /// Assemble les morceaux de la prise, puis coupe les blancs si le réglage est actif.
    private func processTake(_ segments: [URL]) async {
        var file: URL

        do {
            let folder = try CaptureWorker.takesFolder()
            file = try await VideoSegments.merge(segments, into: VideoSegments.mergedURL(folder: folder))
            for segment in segments {
                try? FileManager.default.removeItem(at: segment)
            }
        } catch {
            file = segments[0]
            errorMessage = "La prise n'a pas pu être assemblée. La version sans pause est conservée."
        }

        let settings = SilenceSettings.current
        var final = file
        var removed: Double = 0

        if settings.isEnabled {
            do {
                let outcome = try await SilenceCutter.cutSilences(in: file, settings: settings)
                final = outcome.url
                removed = outcome.removedDuration
            } catch {
                errorMessage = "Les blancs n'ont pas pu être coupés. La prise brute est conservée telle quelle."
            }
        }

        do {
            try await PhotoLibrary.save(final)
            var note = "Ajoutée à Photos"
            if removed > 0 {
                note += " · " + Self.describe(removed: removed)
            }
            lastTakeNote = note
        } catch {
            lastTakeNote = nil
            errorMessage = "La vidéo n'a pas pu être ajoutée à Photos. Elle reste dans Fichiers → Prompteur → Prises."
        }
        settleAfterTake()
    }

    /// Efface le résumé de la prise une fois qu'il a été affiché.
    func clearTakeNote() {
        lastTakeNote = nil
    }

    private static func describe(removed: Double) -> String {
        let seconds = Int(removed.rounded())
        if seconds < 60 { return "\(seconds) s de blancs coupés" }
        let minutes = seconds / 60
        let rest = seconds % 60
        return rest == 0 ? "\(minutes) min de blancs coupés" : "\(minutes) min \(rest) s de blancs coupés"
    }

    private func settleAfterTake() {
        if wantsCamera {
            state = .ready
            if !session.isRunning {
                state = .idle
                Task { if wantsCamera { await start() } }
            }
        } else {
            state = .idle
        }
    }
}

private final class CaptureWorker: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
                                   AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    enum RecordingEvent: Sendable {
        case started
        case paused
        case resumed
        case finished([URL]?)
    }

    private enum Mode {
        case idle, recording, paused, finishing
    }

    let session = AVCaptureSession()

    // The serial queue owns capture configuration, file output and delegate state.
    private let queue = DispatchQueue(label: "fr.remihanditech.prompteur.camera")
    private let audioQueue = DispatchQueue(label: "fr.remihanditech.prompteur.audio")
    private let movie = AVCaptureMovieFileOutput()
    private let audio = AVCaptureAudioDataOutput()
    private let onAudio: @Sendable (CMSampleBuffer) -> Void
    private var configured = false
    private var wantsSession = false
    private var recording: (@MainActor @Sendable (RecordingEvent) -> Void)?
    private var mode: Mode = .idle
    private var segments: [URL] = []

    init(onAudio: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.onAudio = onAudio
        super.init()
    }

    func start(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async {
            self.wantsSession = true
            let success: Bool
            do {
                if !self.configured {
                    try self.configure()
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                success = self.session.isRunning
            } catch {
                success = false
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    func stop() {
        queue.async {
            self.wantsSession = false
            if self.movie.isRecording {
                self.mode = .finishing
                self.movie.stopRecording()
            } else if self.recording == nil, self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// Ouvre la prise : un premier segment est écrit.
    func record(completion: @escaping @MainActor @Sendable (RecordingEvent) -> Void) {
        queue.async {
            guard self.session.isRunning,
                  self.recording == nil,
                  self.movie.connection(with: .video)?.isActive == true,
                  self.movie.connection(with: .audio)?.isActive == true,
                  let folder = try? Self.takesFolder() else {
                DispatchQueue.main.async { completion(.finished(nil)) }
                return
            }

            self.segments = []
            self.recording = completion
            self.mode = .recording
            self.startSegment(in: folder)
        }
    }

    /// Ferme le segment en cours sans clore la prise.
    func pause() {
        queue.async {
            guard self.mode == .recording, self.movie.isRecording else { return }
            self.mode = .paused
            self.movie.stopRecording()
        }
    }

    /// Ouvre un nouveau segment : la reprise reste dans la même prise.
    func resume() {
        queue.async {
            guard self.mode == .paused, self.session.isRunning,
                  let folder = try? Self.takesFolder() else { return }
            self.mode = .recording
            self.startSegment(in: folder)
        }
    }

    /// Clôt la prise : le dernier segment est fermé, les morceaux sont rendus.
    func finish() {
        queue.async {
            guard self.mode == .recording || self.mode == .paused else { return }
            self.mode = .finishing
            if self.movie.isRecording {
                self.movie.stopRecording()
            } else {
                self.closeTake()
            }
        }
    }

    private func startSegment(in folder: URL) {
        let file = folder.appendingPathComponent("Morceau-\(UUID().uuidString).mov")
        movie.startRecording(to: file, recordingDelegate: self)
    }

    private func closeTake() {
        let callback = recording
        recording = nil
        let files = segments
        segments = []
        mode = .idle
        if !wantsSession, session.isRunning {
            session.stopRunning()
        }
        DispatchQueue.main.async { callback?(.finished(files)) }
    }

    private func configure() throws {
        guard let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let microphone = AVCaptureDevice.default(for: .audio) else { throw ConfigurationError.unavailable }
        let videoInput = try AVCaptureDeviceInput(device: front)
        let audioInput = try AVCaptureDeviceInput(device: microphone)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        do {
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            }
            guard session.canAddInput(videoInput) else { throw ConfigurationError.unavailable }
            session.addInput(videoInput)
            guard session.canAddInput(audioInput) else { throw ConfigurationError.unavailable }
            session.addInput(audioInput)
            guard session.canAddOutput(movie) else { throw ConfigurationError.unavailable }
            session.addOutput(movie)
            guard session.canAddOutput(audio) else { throw ConfigurationError.unavailable }
            session.addOutput(audio)
            audio.setSampleBufferDelegate(self, queue: audioQueue)

            if let connection = movie.connection(with: .video) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
            }
            configured = true
        } catch {
            session.outputs.forEach { session.removeOutput($0) }
            session.inputs.forEach { session.removeInput($0) }
            throw error
        }
    }

    static func takesFolder() throws -> URL {
        let folder = URL.documentsDirectory.appending(path: "Prises", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onAudio(sampleBuffer)
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        queue.async {
            guard let callback = self.recording else { return }
            let event: RecordingEvent = self.segments.isEmpty ? .started : .resumed
            DispatchQueue.main.async { callback(event) }
            if !self.wantsSession, self.movie.isRecording {
                self.movie.stopRecording()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: (any Error)?) {
        queue.async {
            let validMovie = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            if validMovie {
                self.segments.append(outputFileURL)
            } else {
                try? FileManager.default.removeItem(at: outputFileURL)
            }

            switch self.mode {
            case .paused:
                if let callback = self.recording {
                    DispatchQueue.main.async { callback(.paused) }
                }
            case .finishing:
                self.closeTake()
            default:
                break
            }
        }
    }

    private enum ConfigurationError: Error { case unavailable }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> Preview {
        Preview()
    }

    func updateUIView(_ view: Preview, context: Context) {
        let layer = view.previewLayer
        if layer.session !== session {
            layer.session = session
            layer.videoGravity = .resizeAspectFill
        }
        if let connection = layer.connection {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
