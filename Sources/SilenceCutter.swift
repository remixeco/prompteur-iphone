import AVFoundation
import Foundation

/// Détecte les blancs d'une prise et produit une version montée sans les silences.
enum SilenceCutter {

    enum CutterError: LocalizedError {
        case noAudioTrack
        case cannotRead
        case cannotExport

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                "Cette prise n'a pas de piste audio à analyser."
            case .cannotRead:
                "La piste audio de la prise n'a pas pu être lue."
            case .cannotExport:
                "La version montée n'a pas pu être produite."
            }
        }
    }

    struct Outcome: Sendable {
        /// Le fichier à lire ensuite : la version montée, ou la prise brute.
        var url: URL
        /// La prise brute, conservée à côté de la version montée.
        var rawURL: URL?
        /// Le temps retiré, en secondes.
        var removedDuration: Double
        /// La durée de la prise avant montage.
        var originalDuration: Double

        var wasCut: Bool { removedDuration > 0 }
    }

    /// Nombre d'échantillons par fenêtre d'analyse : environ 23 ms à 44 100 Hz.
    ///
    /// Une fenêtre courte repère les bords d'un blanc au plus juste. Le lecteur
    /// livre des morceaux d'environ 186 ms, trop grossiers pour un montage net.
    private static let analysisWindowFrames = 1024

    /// Coupe les blancs de la prise quand le réglage est actif.
    ///
    /// Sans blanc à couper, la prise brute est renvoyée telle quelle : aucune
    /// ré-encodage n'est lancé, la prise reste intacte.
    static func cutSilences(in url: URL, settings: SilenceRanges.Settings) async throws -> Outcome {
        let asset = AVURLAsset(url: url)
        let originalDuration = try await asset.load(.duration).seconds
        guard originalDuration > 0 else {
            return Outcome(url: url, rawURL: nil, removedDuration: 0, originalDuration: originalDuration)
        }

        let windows = try await analyze(url: url, thresholdDB: settings.thresholdDB)
        let silences = SilenceRanges.silences(in: windows, settings: settings)
        let plan = SilenceRanges.plan(duration: originalDuration, silences: silences, padding: settings.padding)

        guard plan.removesAnything, !plan.kept.isEmpty else {
            return Outcome(url: url, rawURL: nil, removedDuration: 0, originalDuration: originalDuration)
        }

        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let rawURL = folder.appendingPathComponent("\(base)-brute.mov")
        let destination = folder.appendingPathComponent("\(base)-montée.mov")

        try await export(keeping: plan.kept, from: url, to: destination)

        try? FileManager.default.removeItem(at: rawURL)
        try? FileManager.default.moveItem(at: url, to: rawURL)

        return Outcome(
            url: destination,
            rawURL: rawURL,
            removedDuration: plan.removedDuration,
            originalDuration: originalDuration
        )
    }

    /// Analyse la piste audio et renvoie une fenêtre de niveau par portion lue.
    static func analyze(url: URL, thresholdDB: Double) async throws -> [SilenceRanges.Window] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CutterError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])

        guard reader.canAdd(output) else { throw CutterError.cannotRead }
        reader.add(output)
        guard reader.startReading() else { throw CutterError.cannotRead }

        var windows: [SilenceRanges.Window] = []
        while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
            let start = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            guard let chunk = chunk(of: buffer) else { continue }

            var offset = 0
            while offset < chunk.samples.count {
                let end = min(offset + analysisWindowFrames, chunk.samples.count)
                let level = Self.level(of: chunk.samples[offset..<end])
                windows.append(SilenceRanges.Window(
                    start: start + Double(offset) / chunk.sampleRate,
                    end: start + Double(end) / chunk.sampleRate,
                    decibels: level,
                    isLoud: level >= thresholdDB
                ))
                offset = end
            }
        }

        if reader.status == .failed {
            if let error = reader.error { throw error }
            throw CutterError.cannotRead
        }

        return windows
    }

    // MARK: - Montage

    private static func export(keeping ranges: [SilenceRanges.Range],
                               from source: URL,
                               to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CutterError.cannotExport
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let composedVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw CutterError.cannotExport
        }
        var composedAudio: AVMutableCompositionTrack?
        if audioTrack != nil {
            composedAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        }

        let videoEnd = try await videoTrack.load(.timeRange).duration.seconds
        var audioEnd: Double?
        if let audioTrack {
            audioEnd = try await audioTrack.load(.timeRange).duration.seconds
        }
        let limit = min(videoEnd, audioEnd ?? videoEnd)

        var cursor = CMTime.zero
        for range in ranges {
            let start = max(0, range.start)
            let end = min(range.end, limit)
            guard end - start > 0.02 else { continue }

            let timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600)
            )

            do {
                try composedVideo.insertTimeRange(timeRange, of: videoTrack, at: cursor)
                if let composedAudio, let audioTrack {
                    try composedAudio.insertTimeRange(timeRange, of: audioTrack, at: cursor)
                }
            } catch {
                continue
            }

            cursor = CMTimeAdd(cursor, timeRange.duration)
        }

        guard cursor > CMTime.zero else { throw CutterError.cannotExport }

        try? FileManager.default.removeItem(at: destination)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CutterError.cannotExport
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: destination, as: .mov)
    }

    // MARK: - Niveau

    private struct AudioChunk {
        var samples: [Float]
        var sampleRate: Double
    }

    /// Lit un morceau de piste et le renvoie en échantillons normalisés entre -1 et 1.
    private static func chunk(of buffer: CMSampleBuffer) -> AudioChunk? {
        let frameCount = CMSampleBufferGetNumSamples(buffer)
        guard frameCount > 0,
              let description = CMSampleBufferGetFormatDescription(buffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        pcm.frameLength = AVAudioFrameCount(frameCount)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        ) == noErr else { return nil }

        let channelCount = max(1, Int(format.channelCount))
        var samples: [Float] = []
        samples.reserveCapacity(Int(frameCount))

        if let channels = pcm.int16ChannelData {
            for frame in 0..<Int(frameCount) {
                var total: Int32 = 0
                for channel in 0..<channelCount {
                    total += Int32(channels[channel][frame])
                }
                samples.append(Float(total / Int32(channelCount)) / 32_768)
            }
        } else if let channels = pcm.floatChannelData {
            for frame in 0..<Int(frameCount) {
                var total: Float = 0
                for channel in 0..<channelCount {
                    total += channels[channel][frame]
                }
                samples.append(total / Float(channelCount))
            }
        } else {
            return nil
        }

        return AudioChunk(samples: samples, sampleRate: format.sampleRate)
    }

    /// Niveau en décibels d'une portion d'échantillons déjà normalisés.
    private static func level(of samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return -.infinity }
        var sum = 0.0
        for value in samples {
            sum += Double(value) * Double(value)
        }
        let rms = (sum / Double(samples.count)).squareRoot()
        guard rms > 0 else { return -.infinity }
        return 20 * log10(rms)
    }
}

/// Lecture et écriture des réglages de coupe des blancs.
enum SilenceSettings {
    static let enabledKey = "silenceCuttingEnabled"
    static let thresholdKey = "silenceCuttingThresholdDB"
    static let minimumKey = "silenceCuttingMinimumSilence"
    static let paddingKey = "silenceCuttingPadding"

    static var current: SilenceRanges.Settings {
        let defaults = UserDefaults.standard
        var settings = SilenceRanges.Settings()
        if defaults.object(forKey: enabledKey) != nil {
            settings.isEnabled = defaults.bool(forKey: enabledKey)
        }
        if defaults.object(forKey: thresholdKey) != nil {
            settings.thresholdDB = defaults.double(forKey: thresholdKey)
        }
        if defaults.object(forKey: minimumKey) != nil {
            settings.minimumSilence = defaults.double(forKey: minimumKey)
        }
        if defaults.object(forKey: paddingKey) != nil {
            settings.padding = defaults.double(forKey: paddingKey)
        }
        return settings
    }
}
