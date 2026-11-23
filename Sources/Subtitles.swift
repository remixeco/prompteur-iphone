import AVFoundation
import CoreMedia
import Foundation
import Speech

#if canImport(UIKit)
import UIKit
/// Couleur et police des sous-titres, selon la plateforme.
typealias SubtitleColor = UIColor
typealias SubtitleFont = UIFont
/// Hauteur d'une ligne de texte.
func lineHeight(of font: SubtitleFont) -> CGFloat { font.lineHeight }
#else
import AppKit
typealias SubtitleColor = NSColor
typealias SubtitleFont = NSFont
func lineHeight(of font: SubtitleFont) -> CGFloat { font.boundingRectForFont.height }
#endif

/// Sous-titres « prompteur » : les mots s'illuminent au fur et à mesure de la parole.
///
/// La prise est retranscrite avec la nouvelle API Speech, qui donne le moment exact
/// de chaque mot. Ces sous-titres peuvent être gravés dans la vidéo ou exportés à
/// part au format .srt.
enum Subtitles {

    /// Un mot et son moment de lecture.
    struct Word: Sendable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Un groupe de mots affiché ensemble.
    struct Cue: Sendable {
        let words: [Word]

        var start: TimeInterval { words.first?.start ?? 0 }
        var end: TimeInterval { words.last?.end ?? 0 }
        var text: String { words.map(\.text).joined(separator: " ") }
    }

    enum SubtitleError: LocalizedError {
        case unavailable
        case noAudio
        case nothingRecognized
        case cannotExport

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "La reconnaissance du français n'est pas disponible sur cet appareil."
            case .noAudio:
                "Cette prise n'a pas de piste audio à transcrire."
            case .nothingRecognized:
                "Aucun mot n'a été reconnu dans cette prise."
            case .cannotExport:
                "La vidéo avec sous-titres n'a pas pu être produite."
            }
        }
    }

    // MARK: - Transcription

    /// Transcrit la prise et renvoie les sous-titres, mot par mot.
    static func transcribe(url: URL) async throws -> [Cue] {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "fr-FR")) else {
            throw SubtitleError.unavailable
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let words = try await words(in: url, transcriber: transcriber)
        guard !words.isEmpty else { throw SubtitleError.nothingRecognized }
        return group(words)
    }

    /// Envoie l'audio du fichier au transcritteur et récupère le minutage de chaque mot.
    private static func words(in url: URL, transcriber: SpeechTranscriber) async throws -> [Word] {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SubtitleError.unavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)

        let (stream, continuation) = AsyncThrowingStream<AnalyzerInput, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(48)
        )
        try await analyzer.start(inputSequence: stream)

        let collector = Task { () -> [Word] in
            var best: (duration: Double, words: [Word]) = (0, [])
            for try await result in transcriber.results {
                let current = words(in: result)
                let span = result.range.duration.seconds
                if span >= best.duration {
                    best = (span, current)
                }
            }
            return best.words
        }

        try await feed(url: url, format: format, to: continuation)
        continuation.finish()
        try await analyzer.finalize(through: nil)
        return try await collector.value
    }

    /// Lit le fichier et pousse ses échantillons vers l'analyseur.
    private static func feed(url: URL,
                             format: AVAudioFormat,
                             to continuation: AsyncThrowingStream<AnalyzerInput, any Error>.Continuation) async throws {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let converter = AVAudioConverter(from: source, to: format) else {
            throw SubtitleError.unavailable
        }

        let capacity = AVAudioFrameCount(max(source.sampleRate, format.sampleRate))
        var elapsed = CMTime.zero

        while true {
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: capacity) else { break }
            do {
                try file.read(into: input)
            } catch {
                break // fin du fichier
            }
            guard input.frameLength > 0 else { break }

            let ratio = format.sampleRate / source.sampleRate
            let outCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCapacity) else { break }

            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return input
            }
            guard status != .error, output.frameLength > 0 else {
                if let error { throw error }
                break
            }

            continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: elapsed))
            elapsed = CMTimeAdd(elapsed, CMTime(value: CMTimeValue(output.frameLength), timescale: Int32(format.sampleRate)))
        }
    }

    /// Transforme le texte indexé du transcritteur en mots horodatés.
    private static func words(in result: SpeechTranscriber.Result) -> [Word] {
        var words: [Word] = []

        for run in result.text.runs {
            guard let range = run.attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { continue }

            let text = String(result.text[run.range].characters)
            let pieces = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
            guard !pieces.isEmpty else { continue }

            let start = range.start.seconds
            let duration = max(0.04, range.duration.seconds)
            let weights = pieces.map { Double($0.count) }
            let total = weights.reduce(0, +)

            var cursor = start
            for (index, piece) in pieces.enumerated() {
                let share = total > 0 ? duration * weights[index] / total : duration / Double(pieces.count)
                let wordStart = cursor
                let wordEnd = min(start + duration, cursor + max(0.04, share))
                words.append(Word(text: piece, start: wordStart, end: wordEnd))
                cursor = wordEnd
            }
        }

        return words
    }

    /// Regroupe les mots en phrases courtes, comme des sous-titres de réseau social.
    private static func group(_ words: [Word]) -> [Cue] {
        var cues: [Cue] = []
        var current: [Word] = []
        var length = 0

        func flush() {
            guard !current.isEmpty else { return }
            cues.append(Cue(words: current))
            current = []
            length = 0
        }

        for word in words {
            current.append(word)
            length += word.text.count + 1
            let endsSentence = word.text.hasSuffix(".") || word.text.hasSuffix("?") || word.text.hasSuffix("!")
            if length >= 26 || current.count >= 6 || endsSentence {
                flush()
            }
        }
        flush()
        return cues
    }

    // MARK: - Fichier .srt

    /// Écrit les sous-titres au format .srt à côté de la vidéo.
    static func writeSRT(_ cues: [Cue], to url: URL) throws {
        var lines: [String] = []
        for (index, cue) in cues.enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(timestamp(cue.start)) --> \(timestamp(cue.end))")
            lines.append(cue.text)
            lines.append("")
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let rest = total - Double(hours * 3600 + minutes * 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, rest)
            .replacingOccurrences(of: ".", with: ",")
    }

    // MARK: - Gravure dans la vidéo

    /// Style des sous-titres gravés.
    struct Style {
        var fontSizeRatio: CGFloat = 0.052
        var spoken: SubtitleColor = SubtitleColor(red: 0.78, green: 0.98, blue: 0.57, alpha: 1)
        var unspoken: SubtitleColor = .white
        var font: SubtitleFont = .systemFont(ofSize: 96, weight: .bold)
    }

    /// Grave les sous-titres dans la vidéo : le mot en cours s'illumine.
    static func burn(_ cues: [Cue],
                     into video: URL,
                     output: URL,
                     style: Style = Style(),
                     preset: String = AVAssetExportPresetHighestQuality) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SubtitleError.cannotExport
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let composition = AVMutableComposition()
        guard let composedVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw SubtitleError.cannotExport
        }
        let composedAudio = audioTrack.flatMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        try composedVideo.insertTimeRange(try await videoTrack.load(.timeRange), of: videoTrack, at: .zero)
        if let audioTrack, let composedAudio {
            try composedAudio.insertTimeRange(try await audioTrack.load(.timeRange), of: audioTrack, at: .zero)
        }

        // L'orientation de la prise doit survivre au montage.
        let transform = try await videoTrack.load(.preferredTransform)
        composedVideo.preferredTransform = transform

        let naturalSize = try await videoTrack.load(.naturalSize)
        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let renderSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)

        let durationTime = try await asset.load(.duration)
        let duration = durationTime.seconds
        for cue in cues {
            parent.addSublayer(cueLayer(cue, size: renderSize, duration: duration, style: style))
        }

        let toolConfiguration = AVVideoCompositionCoreAnimationTool.Configuration(
            postProcessingAsVideoLayers: [videoLayer],
            containingLayer: parent
        )
        let tool = AVVideoCompositionCoreAnimationTool(configuration: toolConfiguration)
        var configuration = AVVideoComposition.Configuration()
        configuration.renderSize = renderSize
        configuration.frameDuration = CMTime(value: 1, timescale: 30)
        configuration.animationTool = tool

        // Les instructions de composition restent obligatoires pour l'export.
        // Les classes classiques sont dépréciées, mais les nouvelles ne sont pas
        // acceptées par l'export : c'est la seule variante qui grave les calques.
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: durationTime)
        instruction.layerInstructions = [layerInstruction]
        configuration.instructions = [instruction]

        try? FileManager.default.removeItem(at: output)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw SubtitleError.cannotExport
        }
        exporter.videoComposition = AVVideoComposition(configuration: configuration)
        try await exporter.export(to: output, as: .mov)
        return output
    }

    /// Construit le calque d'une phrase : un calque par mot, illuminé à son moment.
    private static func cueLayer(_ cue: Cue,
                                 size: CGSize,
                                 duration: TimeInterval,
                                 style: Style) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: size)

        let font = style.font.withSize(size.height * style.fontSizeRatio)
        let spacing = size.width * 0.012
        let maxWidth = size.width * 0.86

        // Chaque mot est dessiné dans une image : le rendu hors-ligne de
        // Core Animation n'affiche pas les calques de texte.
        struct Rendered {
            let word: Word
            let plain: CGImage
            let spoken: CGImage
            let width: CGFloat
            let height: CGFloat
        }
        var rendered: [Rendered] = []
        for word in cue.words {
            guard let plainImage = image(of: word.text, font: font, color: style.unspoken),
                  let spokenImage = image(of: word.text, font: font, color: style.spoken) else { continue }
            rendered.append(Rendered(word: word, plain: plainImage.image, spoken: spokenImage.image,
                                     width: plainImage.size.width, height: plainImage.size.height))
        }
        guard !rendered.isEmpty else { return container }

        // Les mots sont répartis sur une ou plusieurs lignes.
        var lines: [[Int]] = [[]]
        var lineWidth: CGFloat = 0
        for (index, item) in rendered.enumerated() {
            if lineWidth + item.width > maxWidth, !lines[lines.count - 1].isEmpty {
                lines.append([])
                lineWidth = 0
            }
            lines[lines.count - 1].append(index)
            lineWidth += item.width + spacing
        }

        // L'origine de Core Animation est en bas à gauche : les sous-titres se
        // placent depuis le bas de l'image et les lignes montent l'une après l'autre.
        let lineHeight = rendered.map(\.height).max() ?? 0
        let margin = size.height * 0.06
        var y = margin + lineHeight * CGFloat(max(0, lines.count - 1))

        for line in lines {
            let total = line.reduce(CGFloat(0)) { $0 + rendered[$1].width + spacing } - spacing
            var x = (size.width - total) / 2
            for index in line {
                let item = rendered[index]
                for (image, keyPath) in [(item.plain, "plain"), (item.spoken, "spoken")] {
                    let layer = CALayer()
                    layer.contents = image
                    layer.contentsScale = 1
                    layer.frame = CGRect(x: x, y: y, width: item.width, height: item.height)
                    container.addSublayer(layer)

                    if keyPath == "spoken" {
                        let total = max(0.1, duration)
                        let start = max(0, min(1, item.word.start / total))
                        let end = max(start + 0.001, min(1, item.word.end / total))
                        let animation = CAKeyframeAnimation(keyPath: "opacity")
                        animation.values = [0, 0, 1, 1, 0, 0]
                        animation.keyTimes = [0, NSNumber(value: Double(start)), NSNumber(value: Double(start)),
                                             NSNumber(value: Double(end)), NSNumber(value: Double(end)), 1]
                        animation.duration = total
                        animation.beginTime = AVCoreAnimationBeginTimeAtZero
                        animation.isRemovedOnCompletion = false
                        animation.fillMode = .both
                        layer.add(animation, forKey: "speech")
                    }
                }
                x += item.width + spacing
            }
            y -= lineHeight
        }

        // La phrase n'apparaît que pendant qu'elle est dite.
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        let start = max(0, min(1, cue.start / max(0.1, duration)))
        let end = max(start + 0.001, min(1, cue.end / max(0.1, duration)))
        opacity.values = [0, 0, 1, 1, 0, 0]
        opacity.keyTimes = [0, NSNumber(value: Double(start)), NSNumber(value: Double(start)),
                            NSNumber(value: Double(end)), NSNumber(value: Double(end)), 1]
        opacity.duration = max(0.1, duration)
        opacity.beginTime = AVCoreAnimationBeginTimeAtZero
        opacity.isRemovedOnCompletion = false
        opacity.fillMode = .both
        container.add(opacity, forKey: "visibility")

        return container
    }

    /// Dessine un mot dans une image, avec un contour sombre pour rester lisible.
    private static func image(of text: String,
                              font: SubtitleFont,
                              color: SubtitleColor) -> (image: CGImage, size: CGSize)? {
        let outline: [NSAttributedString.Key: Any] = [
            .font: font,
            .strokeColor: SubtitleColor.black.withAlphaComponent(0.95),
            .strokeWidth: -font.pointSize * 0.18
        ]
        let fill: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]

        let bounds = NSAttributedString(string: text, attributes: fill).size()
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let size = CGSize(width: ceil(bounds.width) + 8, height: ceil(bounds.height) + 8)

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: size)
        let rendered = renderer.image { _ in
            NSAttributedString(string: text, attributes: outline).draw(at: .zero)
            NSAttributedString(string: text, attributes: fill).draw(at: .zero)
        }
        guard let cgImage = rendered.cgImage else { return nil }
        return (cgImage, size)
        #else
        let rendered = NSImage(size: size)
        rendered.lockFocus()
        NSAttributedString(string: text, attributes: outline).draw(at: .zero)
        NSAttributedString(string: text, attributes: fill).draw(at: .zero)
        rendered.unlockFocus()
        guard let tiff = rendered.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage else { return nil }
        return (cgImage, size)
        #endif
    }
}
