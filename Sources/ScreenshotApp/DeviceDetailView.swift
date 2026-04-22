import SwiftUI
import AppKit
import UniformTypeIdentifiers


struct DeviceDetailView: View {
    let device: SavedDevice
    @ObservedObject var connection: ConnectionModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                statusSection
                if connection.isConnected {
                    screenshotSection
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        switch connection.state {
        case .disconnected:
            VStack(spacing: 12) {
                if let error = connection.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Button("Connect to \(device.host)") {
                    Task { await connection.connect(to: device) }
                }
                .buttonStyle(.borderedProminent)
            }

        case .connecting:
            progressRow("Connecting…")

        case .authenticating:
            progressRow("Authenticating…")

        case .needsKeyApproval:
            AuthApprovalView(fingerprint: connection.rsaFingerprint ?? "") {
                connection.disconnect()
            }

        case .connected, .takingScreenshot:
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(connection.deviceName ?? device.host)
                    .font(.headline)
            }
        }
    }

    private func progressRow(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(label).foregroundStyle(.secondary)
        }
    }

    // MARK: - Screenshot

    @ViewBuilder
    private var screenshotSection: some View {
        VStack(spacing: 20) {
            Button {
                Task { await connection.takeScreenshot() }
            } label: {
                Label(
                    connection.isBusy ? "Capturing…" : "Take Screenshot",
                    systemImage: "camera.fill"
                )
                .frame(minWidth: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(connection.isBusy)

            if connection.isBusy {
                ProgressView()
            }

            if let error = connection.errorMessage, !connection.isBusy {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let screenshot = connection.screenshot {
                screenshotPreview(screenshot)
            } else if !connection.isBusy {
                Text("Click \"Take Screenshot\" to capture the Android screen.")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
        }
    }

    private func screenshotPreview(_ image: NSImage) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 360)
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .onDrag { makeDragProvider(for: image) }

            HStack(spacing: 12) {
                Button("Save Screenshot…") { saveScreenshot(image) }
                    .buttonStyle(.bordered)
                Text("or drag to share")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func makeDragProvider(for image: NSImage) -> NSItemProvider {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot.png")
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = "screenshot.png"
        return provider
    }

    private func saveScreenshot(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "screenshot.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }
}
