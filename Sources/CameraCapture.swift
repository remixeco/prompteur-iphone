import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class CameraCapture {
    enum State: Equatable {
        case idle, starting, ready, startingRecording, recording, finishing
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private(set) var latestVideo: URL?
    private(set) var errorMessage: String?

    private let worker: CaptureWorker
    private var wantsCamera = false
    private var startupID = UUID()

    var session: AVCaptureSession { worker.session }

    init(onAudio: @escaping @Sendable (CMSampleBuffer) -> Void) {
        worker = CaptureWorker(onAudio: onAudio)
        if let filename = UserDefaults.standard.string(forKey: "latestVideo"),
           let folder = try? CaptureWorker.takesFolder() {
            let url = folder.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) {
                latestVideo = url
            }
        }
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
            state = success ? .ready : .unavailable("La caméra n’a pas démarré. Rouvre cet écran pour réessayer.")
        }
    }

    func stop() {
        wantsCamera = false
        startupID = UUID()
        switch state {
        case .startingRecording, .recording, .finishing:
            state = .finishing
        default:
            state = .idle
        }
        worker.stop()
    }

    func startRecording() {
        guard state == .ready else { return }
        state = .startingRecording
        errorMessage = nil
        worker.record { [weak self] event in
            guard let self else { return }
            switch event {
            case .started:
                if state == .startingRecording {
                    state = .recording
                }
            case .finished(let file):
                if let file {
                    latestVideo = file
                    UserDefaults.standard.set(file.lastPathComponent, forKey: "latestVideo")
                } else {
                    errorMessage = "La vidéo n’a pas pu être enregistrée. Vérifie l’espace libre, puis réessaie."
                }
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
    }

    func stopRecording() {
        guard state == .recording else { return }
        state = .finishing
        worker.stopRecording()
    }
}

private final class CaptureWorker: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate,
                                   AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    enum RecordingEvent: Sendable {
        case started
        case finished(URL?)
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
                self.movie.stopRecording()
            } else if self.recording == nil, self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

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

            let file = folder.appendingPathComponent("Prise-\(UUID().uuidString).mov")
            self.recording = completion
            self.movie.startRecording(to: file, recordingDelegate: self)
        }
    }

    func stopRecording() {
        queue.async {
            if self.movie.isRecording {
                self.movie.stopRecording()
            }
        }
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
            if let callback = self.recording {
                DispatchQueue.main.async { callback(.started) }
            }
            if !self.wantsSession, self.movie.isRecording {
                self.movie.stopRecording()
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: (any Error)?) {
        let validMovie = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        queue.async {
            let callback = self.recording
            self.recording = nil
            if !self.wantsSession, self.session.isRunning {
                self.session.stopRunning()
            }
            if !validMovie {
                try? FileManager.default.removeItem(at: outputFileURL)
            }
            if let callback {
                DispatchQueue.main.async { callback(.finished(validMovie ? outputFileURL : nil)) }
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
