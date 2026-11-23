import AVKit
import Photos
import SwiftUI

/// Écran de montage d'une prise : sous-titres, musique et visuels.
///
/// La prise arrive montée. On peut y graver des sous-titres façon prompteur —
/// le mot en cours s'illumine au fur et à mesure — puis enregistrer le résultat
/// dans Photos.
struct TakeEditorView: View {
    let url: URL
    var note: String?

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var cues: [Subtitles.Cue] = []
    @State private var isTranscribing = false
    @State private var isBurning = false
    @State private var isSaving = false
    @State private var status: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 16))
                    .onTapGesture { togglePlayback() }

                if let note {
                    Label(note, systemImage: "scissors")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                }

                tools

                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                }

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await saveToPhotos() }
                } label: {
                    Label(isSaving ? "Enregistrement…" : "Enregistrer dans Photos",
                          systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .foregroundStyle(Palette.background)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Palette.accent, in: .rect(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(isSaving || isBurning || isTranscribing)
                .opacity(isSaving || isBurning || isTranscribing ? 0.5 : 1)
            }
            .padding(20)
            .background(Palette.background)
            .navigationTitle("Montage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .onAppear { player = AVPlayer(url: url) }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    // MARK: - Outils

    private var tools: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                toolButton("Sous-titres", symbol: "captions.bubble", enabled: true) {
                    Task { await toggleSubtitles() }
                }
                toolButton("Musique", symbol: "music.note", enabled: false) {
                    status = "La musique avec coupure automatique arrive bientôt."
                }
                toolButton("Visuels", symbol: "photo.on.rectangle", enabled: false) {
                    status = "Les images de référence arrivent bientôt."
                }
            }

            if isTranscribing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Écoute de la prise…").font(.footnote).foregroundStyle(Palette.muted)
                }
            } else if cues.isEmpty {
                Text("Les sous-titres reprennent tes mots exacts et allument le mot en cours, comme un prompteur.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(cues.prefix(3), id: \.start) { cue in
                        Text(cue.text)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if cues.count > 3 {
                        Text("… \(cues.count - 3) autres phrases")
                            .font(.caption)
                            .foregroundStyle(Palette.muted)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.surface, in: .rect(cornerRadius: 14))

                Button {
                    Task { await burn() }
                } label: {
                    Label(isBurning ? "Gravure…" : "Graver les sous-titres dans la vidéo",
                          systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
                .disabled(isBurning || isSaving)
            }
        }
    }

    private func toolButton(_ title: String,
                            symbol: String,
                            enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? Palette.accent : Palette.muted)
            .frame(maxWidth: .infinity, minHeight: 62)
            .background(Palette.surface, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(0.10))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Prépare les sous-titres, ou les grave s'ils sont déjà prêts.
    private func toggleSubtitles() async {
        if cues.isEmpty {
            await transcribe()
        } else {
            await burn()
        }
    }

    private func transcribe() async {
        isTranscribing = true
        error = nil
        status = "Écoute de la prise…"
        defer { isTranscribing = false }

        do {
            cues = try await Subtitles.transcribe(url: url)
            status = "\(cues.count) phrases reconnues."
        } catch {
            self.error = (error as? Subtitles.SubtitleError)?.errorDescription
                ?? "Les sous-titres n'ont pas pu être préparés."
            status = nil
        }
    }

    /// Grave les sous-titres dans la vidéo et écrit le fichier .srt à côté.
    private func burn() async {
        guard !cues.isEmpty else { return }
        isBurning = true
        error = nil
        status = "Gravure des sous-titres…"
        defer { isBurning = false }

        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let output = folder.appendingPathComponent("\(base)-sous-titres.mov")

        do {
            let burned = try await Subtitles.burn(cues, into: url, output: output)
            try Subtitles.writeSRT(cues, to: folder.appendingPathComponent("\(base).srt"))
            player?.pause()
            player = AVPlayer(url: burned)
            status = "Sous-titres gravés. Le fichier .srt est à côté de la vidéo."
        } catch {
            self.error = (error as? Subtitles.SubtitleError)?.errorDescription
                ?? "Les sous-titres n'ont pas pu être gravés."
            status = nil
        }
    }

    /// Enregistre la version courante dans Photos.
    private func saveToPhotos() async {
        isSaving = true
        error = nil
        defer { isSaving = false }

        do {
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                error = "Autorise l'ajout dans Photos depuis les Réglages."
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            status = "Enregistrée dans Photos."
        } catch {
            self.error = "L'ajout à Photos a échoué."
            status = nil
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }
}
