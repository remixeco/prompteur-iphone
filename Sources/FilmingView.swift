import AVFoundation
import SwiftUI

struct FilmingView: View {
    let camera: CameraCapture
    let voice: VoiceRecognizer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var promptHeight = 174.0
    @State private var follower: ScriptFollower
    @State private var followVoice = true
    @State private var showingTake = false
    @State private var startedAt: Date?

    init(script: String, camera: CameraCapture, voice: VoiceRecognizer) {
        self.camera = camera
        self.voice = voice
        _follower = State(initialValue: ScriptFollower(script))
    }

    private var cameraReady: Bool {
        switch camera.state {
        case .ready, .startingRecording, .recording, .finishing: true
        default: false
        }
    }

    private var busyRecording: Bool {
        switch camera.state {
        case .startingRecording, .recording, .finishing: true
        default: false
        }
    }

    private var shouldListen: Bool {
        followVoice && cameraReady && scenePhase != .background && !showingTake
    }

    var body: some View {
        GeometryReader { space in
            VStack(spacing: 12) {
                header
                prompt(height: min(promptHeight, space.size.height * 0.44))
                Spacer(minLength: 4)
                if let message = camera.errorMessage {
                    notice(message)
                }
                if case .unavailable(let message) = camera.state {
                    VStack(spacing: 8) {
                        notice(message)
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied
                            || AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                            Button("Ouvrir les Réglages") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    openURL(url)
                                }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                    .padding(.bottom, 10)
                } else if followVoice, case .failed(let message) = voice.status {
                    notice(message)
                }
                controls
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
        }
        .background {
            ZStack {
                Palette.backdrop
                if cameraReady {
                    CameraPreview(session: camera.session)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                    LinearGradient(colors: [.clear, .black.opacity(0.72)],
                                   startPoint: .center, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .task(id: scenePhase == .background || showingTake) {
            if scenePhase == .background || showingTake {
                camera.stop()
            } else {
                await camera.start()
            }
        }
        .task(id: shouldListen) {
            if shouldListen {
                await startListening()
            } else {
                voice.stop()
            }
        }
        .onChange(of: camera.state) { _, state in
            if state == .recording {
                startedAt = Date()
            } else if state != .finishing {
                startedAt = nil
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            voice.stop()
            camera.stop()
        }
        .sheet(isPresented: $showingTake) {
            if let url = camera.latestVideo {
                TakeView(url: url)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            iconButton("Fermer la caméra", symbol: "xmark") { dismiss() }
                .disabled(busyRecording)

            Spacer(minLength: 0)

            Group {
                if case .unavailable = camera.state {
                    Label("Répétition", systemImage: "text.alignleft")
                } else if let startedAt {
                    HStack(spacing: 7) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(startedAt, style: .timer).monospacedDigit()
                    }
                    .accessibilityLabel("Enregistrement en cours")
                } else {
                    Label("Caméra avant", systemImage: "camera")
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.82), in: .capsule)

            Spacer(minLength: 0)

            iconButton("Revenir au début", symbol: "arrow.counterclockwise") {
                follower.reset()
            }
        }
    }

    private func prompt(height: Double) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: follower.isFinished ? "checkmark.circle.fill" : "waveform")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text(follower.isFinished ? "Script terminé" : voiceLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Text("\(follower.position) / \(follower.wordCount)")
                    .monospacedDigit()
                    .accessibilityLabel("\(follower.position) mots lus sur \(follower.wordCount)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)

            ProgressView(value: Double(follower.position), total: Double(max(1, follower.wordCount)))
                .tint(Palette.accent)
                .padding(.horizontal, 15)
                .accessibilityHidden(true)

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(follower.lines) { line in
                            scriptLine(line).id(line.id)
                        }
                    }
                    .padding(.horizontal, 15)
                    .padding(.top, 14)
                    .padding(.bottom, max(24, height - 48))
                }
                .frame(height: height)
                .defaultScrollAnchor(.top)
                .onChange(of: follower.activeLine) { _, index in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        scroll.scrollTo(index, anchor: .top)
                    }
                }
            }
        }
        .background(.black.opacity(0.88), in: .rect(cornerRadius: 21))
        .overlay {
            RoundedRectangle(cornerRadius: 21)
                .strokeBorder(.white.opacity(0.15))
                .allowsHitTesting(false)
        }
    }

    private func scriptLine(_ line: ScriptFollower.Line) -> some View {
        let current = line.id == follower.activeLine
        let parts = line.split(at: follower.position)
        var read = AttributedString(parts.read)
        read.foregroundColor = Palette.muted
        var unread = AttributedString(parts.unread)
        unread.foregroundColor = current ? Color.white : Palette.muted

        return Text(read + unread)
            .font(.title2.weight(current ? .semibold : .medium))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(current ? Palette.accent : Color.clear)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
    }

    private var voiceLabel: String {
        guard shouldListen else { return "Défilement manuel" }
        switch voice.status {
        case .preparing: return "Préparation du français…"
        case .listening: return "À l’écoute"
        case .failed: return "Suivi vocal indisponible"
        case .idle: return "Démarrage du suivi…"
        }
    }

    private var controls: some View {
        VStack(spacing: 9) {
            if cameraReady {
                HStack {
                    iconButton("Dernière prise", symbol: "film") { showingTake = true }
                        .disabled(busyRecording || camera.latestVideo == nil)

                    Spacer()

                    VStack(spacing: 7) {
                        recordButton
                        Text(recordLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.72), in: .capsule)
                            .accessibilityHidden(true)
                    }

                    Spacer()

                    iconButton(followVoice ? "Mettre le suivi vocal en pause" : "Activer le suivi vocal",
                               symbol: followVoice ? "waveform" : "mic.slash") {
                        if followVoice, case .failed = voice.status {
                            Task { await startListening() }
                        } else {
                            followVoice.toggle()
                        }
                    }
                    .accessibilityLabel(voiceRetryLabel)
                    .foregroundStyle(followVoice ? Palette.accent : .white)
                }
            } else if camera.state == .starting || camera.state == .idle {
                ProgressView("Ouverture de la caméra…")
                    .font(.footnote)
            }

            HStack(spacing: 10) {
                Button {
                    follower.seek(toLine: follower.activeLine - 1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Passage précédent")
                .disabled(follower.activeLine == 0)

                Button {
                    follower.seek(toLine: follower.activeLine + 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Passage suivant")
                .disabled(follower.isFinished)
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .background(.black.opacity(0.62), in: .rect(cornerRadius: 12))
        }
    }

    private var voiceRetryLabel: String {
        if followVoice, case .failed = voice.status { return "Relancer le suivi vocal" }
        return followVoice ? "Mettre le suivi vocal en pause" : "Activer le suivi vocal"
    }

    private var recordLabel: String {
        switch camera.state {
        case .startingRecording: "Démarrage…"
        case .recording: "Arrêter"
        case .finishing: "Enregistrement…"
        default: "Filmer"
        }
    }

    private var recordButton: some View {
        Button {
            if camera.state == .recording {
                camera.stopRecording()
            } else {
                camera.startRecording()
            }
        } label: {
            ZStack {
                Circle().fill(.black.opacity(0.55))
                Circle().strokeBorder(.white, lineWidth: 3)
                RoundedRectangle(cornerRadius: camera.state == .recording ? 6 : 26)
                    .fill(Color(red: 1, green: 0.28, blue: 0.25))
                    .frame(width: camera.state == .recording ? 25 : 50,
                           height: camera.state == .recording ? 25 : 50)
            }
            .frame(width: 66, height: 66)
        }
        .buttonStyle(.plain)
        .disabled(camera.state != .ready && camera.state != .recording)
        .accessibilityLabel(recordLabel)
    }

    private func iconButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.82), in: .circle)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .accessibilityLabel(label)
    }

    private func notice(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.black.opacity(0.86), in: .rect(cornerRadius: 12))
    }

    private func startListening() async {
        guard shouldListen else { return }
        follower.beginListening()
        await voice.start { text, isFinal in
            follower.update(text, isFinal: isFinal)
        }
    }
}
