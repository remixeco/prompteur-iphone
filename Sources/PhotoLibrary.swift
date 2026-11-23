import Foundation
import Photos

/// Ajout des prises à l’app Photos du téléphone.
enum PhotoLibrary {
    enum SaveError: LocalizedError {
        case denied

        var errorDescription: String? {
            "Autorise l’ajout dans Photos depuis les Réglages. La vidéo reste dans Fichiers → Prompteur → Prises."
        }
    }

    /// Demande l’autorisation si besoin, puis ajoute la vidéo à Photos.
    static func save(_ video: URL) async throws {
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else {
            throw SaveError.denied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: video)
        }
    }
}
