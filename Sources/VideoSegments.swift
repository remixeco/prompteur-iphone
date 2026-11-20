import AVFoundation
import Foundation

/// Recolle des segments successifs en un seul fichier.
///
/// Une pause ferme le segment en cours et en ouvre un autre ; à la fin, tous
/// les segments sont réassemblés dans l'ordre, sans trou, en une seule prise.
enum VideoSegments {

    enum MergeError: LocalizedError {
        case empty
        case cannotCompose
        case cannotExport

        var errorDescription: String? {
            switch self {
            case .empty:
                "Aucun segment à recoller."
            case .cannotCompose:
                "Les morceaux de la prise n'ont pas pu être assemblés."
            case .cannotExport:
                "La prise complète n'a pas pu être produite."
            }
        }
    }

    /// Assemble les segments dans l'ordre et renvoie le fichier final.
    static func merge(_ segments: [URL], into destination: URL) async throws -> URL {
        let usable = segments.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !usable.isEmpty else { throw MergeError.empty }

        if usable.count == 1 {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: usable[0], to: destination)
            return destination
        }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MergeError.cannotCompose
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        for segment in usable {
            let asset = AVURLAsset(url: segment)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
                  let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first else { continue }

            let videoRange = try await sourceVideo.load(.timeRange)
            let audioRange = try await sourceAudio.load(.timeRange)
            let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)
            guard duration > CMTime.zero else { continue }

            let range = CMTimeRange(start: videoRange.start, duration: duration)
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            try audioTrack?.insertTimeRange(range, of: sourceAudio, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor > CMTime.zero else { throw MergeError.cannotCompose }

        try? FileManager.default.removeItem(at: destination)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw MergeError.cannotExport
        }
        exporter.shouldOptimizeForNetworkUse = true
        try await exporter.export(to: destination, as: .mov)
        return destination
    }

    /// Emplacement du fichier final d'une prise, à côté des segments.
    static func mergedURL(folder: URL) -> URL {
        folder.appendingPathComponent("Prise-\(UUID().uuidString).mov")
    }
}
