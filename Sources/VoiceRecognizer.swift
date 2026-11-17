import AVFoundation
import CoreMedia
import Foundation
import Observation
import Speech
import Synchronization

@MainActor
@Observable
final class VoiceRecognizer {
    enum Status: Equatable {
        case idle
        case preparing
        case listening
        case failed(String)
    }

    private(set) var status: Status = .idle
    private var runID = UUID()
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private nonisolated let feeder = Mutex<VoiceAudioFeeder?>(nil)

    func start(onTranscript: @escaping @MainActor (_ text: String, _ isFinal: Bool) -> Void) async {
        stop()
        let id = runID
        status = .preparing

        do {
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
                throw VoiceError.unavailable
            }
            try checkRun(id)

            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try checkRun(id)
                try await installation.downloadAndInstall()
            }
            try checkRun(id)

            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw VoiceError.unavailable
            }
            try checkRun(id)

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            try checkRun(id)

            let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, any Error>.makeStream(
                bufferingPolicy: .bufferingNewest(48)
            )
            try await analyzer.start(inputSequence: stream)
            try checkRun(id)

            feeder.withLock { $0 = VoiceAudioFeeder(format: format, continuation: continuation) }
            status = .listening
            resultsTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard !Task.isCancelled, self?.runID == id else { return }
                        onTranscript(String(result.text.characters), result.isFinal)
                    }
                    self?.fail(VoiceError.interrupted, run: id)
                } catch {
                    self?.fail(error, run: id)
                }
            }
        } catch is CancellationError {
            if runID == id { stop() }
        } catch {
            fail(error, run: id)
        }
    }

    func stop() {
        runID = UUID()
        feeder.withLock {
            $0?.continuation.finish()
            $0 = nil
        }
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        status = .idle
    }

    nonisolated func append(_ sampleBuffer: CMSampleBuffer) {
        feeder.withLock { feeder in
            do {
                try feeder?.append(sampleBuffer)
            } catch {
                feeder?.continuation.finish(throwing: error)
                feeder = nil
            }
        }
    }

    private func checkRun(_ id: UUID) throws {
        try Task.checkCancellation()
        guard runID == id else { throw CancellationError() }
    }

    private func fail(_ error: any Error, run id: UUID) {
        guard runID == id else { return }
        stop()
        status = .failed(
            (error as? VoiceError)?.errorDescription
            ?? "Le suivi vocal est indisponible. Vérifie ta connexion pour télécharger le modèle français, puis réessaie."
        )
    }
}

private nonisolated enum VoiceError: LocalizedError {
    case unavailable
    case audioFormat
    case interrupted

    var errorDescription: String? {
        switch self {
        case .unavailable: "Le suivi vocal en français est indisponible sur cet appareil."
        case .audioFormat: "Le microphone a changé de format. Relance le suivi vocal."
        case .interrupted: "Le suivi vocal a été interrompu. Tu peux le relancer."
        }
    }
}

private nonisolated struct VoiceAudioFeeder {
    let format: AVAudioFormat
    let continuation: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation
    private var converter: AVAudioConverter?
    private var firstTimestamp: CMTime?

    init(format: AVAudioFormat, continuation: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    mutating func append(_ sampleBuffer: CMSampleBuffer) throws {
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let inputFormat = AVAudioFormat(streamDescription: streamDescription),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw VoiceError.audioFormat
        }
        input.frameLength = AVAudioFrameCount(frameCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: input.mutableAudioBufferList
        ) == noErr else {
            throw VoiceError.audioFormat
        }

        let output = try convertIfNeeded(input)
        guard output.frameLength > 0 else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstTimestamp == nil { firstTimestamp = timestamp }
        let relativeTime = firstTimestamp.map { CMTimeSubtract(timestamp, $0) }
        continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: relativeTime))
    }

    private mutating func convertIfNeeded(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard input.format != format else { return input }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.primeMethod = .none
        }
        let capacity = ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 32
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw VoiceError.audioFormat
        }
        var error: NSError?
        var suppliedInput = false
        let result = converter.convert(to: output, error: &error) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return input
        }
        guard result != .error else { throw error ?? VoiceError.audioFormat }
        return output
    }
}
