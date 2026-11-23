import Foundation
import SwiftUI

@main
struct PrompteurApp: App {
    var body: some Scene {
        WindowGroup {
            ScriptEditor()
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .environment(\.locale, Locale(identifier: "fr-FR"))
        }
    }
}

enum Palette {
    static let background = Color(red: 0.045, green: 0.073, blue: 0.062)
    static let surface = Color(red: 0.09, green: 0.13, blue: 0.11)
    static let accent = Color(red: 0.78, green: 0.98, blue: 0.57)
    static let muted = Color(red: 0.68, green: 0.75, blue: 0.70)

    static var backdrop: some View {
        RadialGradient(
            colors: [Color(red: 0.15, green: 0.23, blue: 0.16), background],
            center: .topTrailing,
            startRadius: 0,
            endRadius: 510
        )
        .ignoresSafeArea()
    }
}

private struct ScriptEditor: View {
    private static let example = """
    Bonjour ! Aujourd’hui, je vais te montrer une idée qui me tient à cœur.

    Je prends le temps de respirer. Quand je fais une pause, le texte m’attend.

    Puis je reprends à mon rythme, simplement.
    """

    @AppStorage("script") private var script = Self.example
    @AppStorage(SilenceSettings.enabledKey) private var cutSilences = false
    @AppStorage(SilenceSettings.thresholdKey) private var thresholdDB = SilenceRanges.Settings.default.thresholdDB
    @AppStorage(SilenceSettings.minimumKey) private var minimumSilence = SilenceRanges.Settings.default.minimumSilence
    @FocusState private var editing: Bool
    @State private var filming = false
    @State private var confirmingClear = false
    @State private var voice: VoiceRecognizer
    @State private var camera: CameraCapture

    init() {
        let voice = VoiceRecognizer()
        _voice = State(initialValue: voice)
        _camera = State(initialValue: CameraCapture(onAudio: { voice.append($0) }))
    }

    private var wordCount: Int {
        script.ranges(of: /[\p{L}\p{M}\p{N}]+/).count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Label {
                    Text("Prompteur").font(.headline)
                } icon: {
                    Image(systemName: "waveform")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 42, height: 42)
                        .background(Palette.accent.opacity(0.12), in: .rect(cornerRadius: 13))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ton script")
                        .font(.system(.largeTitle, design: .default, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Écris ou colle ton texte. Il avance au rythme de ta voix pendant que tu filmes.")
                        .font(.body)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                editor

                settingsCard

            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.backdrop)
        .safeAreaInset(edge: .bottom) {
            Button {
                if editing {
                    editing = false
                } else {
                    filming = true
                }
            } label: {
                Label(editing ? "Terminer" : "Ouvrir la caméra", systemImage: editing ? "checkmark" : "video")
                    .font(.headline)
                    .foregroundStyle(Palette.background)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Palette.accent, in: .rect(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .disabled(!editing && wordCount == 0)
            .opacity(!editing && wordCount == 0 ? 0.45 : 1)
            .frame(maxWidth: 560)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Palette.background)
        }
        .fullScreenCover(isPresented: $filming) {
            FilmingView(script: script, camera: camera, voice: voice)
        }
        .confirmationDialog("Effacer tout le texte ?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Effacer tout", role: .destructive) {
                script = ""
                editing = false
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Ton script sera supprimé définitivement.")
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Ton texte")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)

                Spacer(minLength: 0)

                Button {
                    confirmingClear = true
                } label: {
                    Label("Tout effacer", systemImage: "trash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(script.isEmpty ? Palette.muted : Color(red: 1, green: 0.45, blue: 0.42))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.white.opacity(0.06), in: .capsule)
                }
                .buttonStyle(.plain)
                .disabled(script.isEmpty)
                .opacity(script.isEmpty ? 0.45 : 1)
                .accessibilityHint("Supprime tout le texte du script")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)

            TextEditor(text: $script)
                .font(.system(.body, weight: .medium))
                .lineSpacing(6)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(height: 270)
                .focused($editing)
                .accessibilityLabel("Texte du script")

            Divider().overlay(.white.opacity(0.08))

            ViewThatFits(in: .horizontal) {
                HStack {
                    Label("Français", systemImage: "waveform")
                    Spacer()
                    Text(wordCount == 1 ? "1 mot" : "\(wordCount) mots")
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Français", systemImage: "waveform")
                    Text(wordCount == 1 ? "1 mot" : "\(wordCount) mots")
                }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
        }
        .background(Palette.surface, in: .rect(cornerRadius: 21))
        .overlay {
            RoundedRectangle(cornerRadius: 21)
                .strokeBorder(.white.opacity(0.10))
                .allowsHitTesting(false)
        }
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $cutSilences) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Couper les blancs", systemImage: "scissors")
                        .font(.subheadline.weight(.semibold))
                    Text("Supprime les silences où tu ne parles pas, une fois la prise terminée. La prise brute est toujours conservée à côté.")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(Palette.accent)

            if cutSilences {
                VStack(spacing: 16) {
                    sliderRow(
                        title: "Seuil de voix",
                        value: $thresholdDB,
                        range: -50 ... -20,
                        step: 1,
                        formatted: { "\(Int($0)) dB" },
                        hint: "Plus la valeur est basse, plus seuls les vrais silences sont coupés."
                    )
                    sliderRow(
                        title: "Durée minimale",
                        value: $minimumSilence,
                        range: 0.2 ... 2.0,
                        step: 0.05,
                        formatted: { $0.formatted(.number.precision(.fractionLength(2))) + " s" },
                        hint: "Un silence plus court que cette durée est conservé."
                    )
                }
            }
        }
        .padding(18)
        .background(Palette.surface, in: .rect(cornerRadius: 21))
        .overlay {
            RoundedRectangle(cornerRadius: 21)
                .strokeBorder(.white.opacity(0.10))
                .allowsHitTesting(false)
        }
    }

    private func sliderRow(title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double,
                           formatted: @escaping (Double) -> String,
                           hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text(formatted(value.wrappedValue))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Palette.accent)
            }
            Slider(value: value, in: range, step: step)
                .tint(Palette.accent)
            Text(hint)
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
