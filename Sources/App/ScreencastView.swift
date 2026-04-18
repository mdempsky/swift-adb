import SwiftUI
import ADB
import Vision

// Read-only UITextView with native selection handles.
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.text = text
    }
}

struct DeviceView: View {
    @ObservedObject var connection: ADBConnection
    @StateObject private var session: ScreencastSession
    @State private var showFilePicker = false
    @State private var installStatus: String?
    @State private var isInstalling = false

    // Zoom / pan
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPan: CGSize = .zero

    // OCR
    @State private var isRecognizing = false
    @State private var showTextSheet = false
    @State private var recognizedText = ""

    init(connection: ADBConnection) {
        self.connection = connection
        _session = StateObject(wrappedValue: ScreencastSession(connection: connection))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = session.frame {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea(edges: .horizontal)
                    .scaleEffect(scale, anchor: .center)
                    .offset(panOffset)
                    .gesture(zoomGesture)
                    .simultaneousGesture(panGesture)
                    .onTapGesture(count: 2) { resetZoom() }
            } else if session.isStreaming {
                ProgressView("Capturing screen…")
                    .foregroundStyle(.white)
            }
        }
        .navigationTitle(connection.deviceName ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Disconnect") {
                    session.stop()
                    connection.disconnect()
                }
                .tint(.red)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isRecognizing {
                    ProgressView().scaleEffect(0.8).tint(.white)
                } else {
                    Button { recognizeText() } label: {
                        Label("Text", systemImage: "text.viewfinder")
                    }
                    .disabled(session.frame == nil)
                }
                Button {
                    Task { try? await APKInstaller(connection: connection.underlying).shell("input keyevent 224") }
                } label: {
                    Label("Wake", systemImage: "sun.max")
                }
                Button { showFilePicker = true } label: {
                    Label("Install APK", systemImage: "square.and.arrow.down")
                }
                .disabled(isInstalling)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if let status = installStatus {
                    Text(status)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.75))
                }
                if session.isStreaming, session.fps > 0 {
                    HStack {
                        Spacer()
                        Label(String(format: "%.1f fps", session.fps), systemImage: "video")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.trailing, 12)
                            .padding(.bottom, 8)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { installAPK(url: url) }
        }
        .sheet(isPresented: $showTextSheet) { textSheet }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    // MARK: - Zoom / Pan

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = max(1, lastScale * value)
                // Scale panOffset proportionally so content under the pan position
                // stays anchored instead of drifting back toward screen center.
                let factor = newScale / lastScale
                panOffset = CGSize(width: lastPan.width * factor,
                                   height: lastPan.height * factor)
                scale = newScale
            }
            .onEnded { _ in
                lastScale = scale
                lastPan = panOffset
                if scale <= 1 { resetZoom() }
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                panOffset = CGSize(width: lastPan.width + value.translation.width,
                                   height: lastPan.height + value.translation.height)
            }
            .onEnded { _ in lastPan = panOffset }
    }

    private func resetZoom() {
        withAnimation(.spring(duration: 0.25)) {
            scale = 1; lastScale = 1; panOffset = .zero; lastPan = .zero
        }
    }

    // MARK: - OCR

    private var textSheet: some View {
        NavigationStack {
            SelectableText(text: recognizedText.isEmpty ? "No text detected." : recognizedText)
                .navigationTitle("Recognized Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") { showTextSheet = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            UIPasteboard.general.string = recognizedText
                        } label: {
                            Label("Copy All", systemImage: "doc.on.doc")
                        }
                        .disabled(recognizedText.isEmpty)
                    }
                }
        }
    }

    private func recognizeText() {
        guard let frame = session.frame else { return }
        isRecognizing = true
        Task {
            recognizedText = await performOCR(on: frame)
            isRecognizing = false
            showTextSheet = true
        }
    }

    private func performOCR(on image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        return await withCheckedContinuation { cont in
            let request = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                cont.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        }
    }

    // MARK: - APK Install

    private func installAPK(url: URL) {
        isInstalling = true
        installStatus = "Preparing…"
        let installer = APKInstaller(connection: connection.underlying)
        Task {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            do {
                try await installer.install(apkURL: url) { msg in
                    Task { @MainActor in installStatus = msg }
                }
                installStatus = "Installed successfully"
            } catch {
                installStatus = "Error: \(error.localizedDescription)"
            }
            isInstalling = false
        }
    }
}
