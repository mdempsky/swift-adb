import UIKit
import ADB

// Runs `while true; do screencap -p; done` on the device and extracts PNG frames
// by watching for the PNG IEND trailer (which is always the same 12 bytes).
@MainActor
class ScreencastSession: ObservableObject {
    @Published var frame: UIImage?
    @Published var isStreaming = false
    @Published var fps: Double = 0
    @Published var error: String?

    private let connection: ADBConnection
    private var task: Task<Void, Never>?
    private var frameCount = 0
    private var fpsWindowStart = Date()

    // PNG IEND chunk is always exactly: length(0) + "IEND" + CRC
    private static let iend = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])

    init(connection: ADBConnection) {
        self.connection = connection
    }

    func start() {
        guard !isStreaming else { return }
        isStreaming = true
        error = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.stream()
            } catch {
                self.error = error.localizedDescription
            }
            self.isStreaming = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isStreaming = false
    }

    private func stream() async throws {
        let adbStream = try await connection.openStream(
            destination: "shell:while true; do screencap -p; done"
        )
        var buffer = Data()
        while !Task.isCancelled {
            let chunk = try await adbStream.read()
            buffer.append(chunk)
            extractFrames(from: &buffer)
        }
    }

    private func extractFrames(from buffer: inout Data) {
        while let range = buffer.range(of: Self.iend) {
            let frameData = Data(buffer[buffer.startIndex..<range.upperBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let img = UIImage(data: frameData) {
                frame = img
                tickFPS()
            }
        }
    }

    private func tickFPS() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(fpsWindowStart)
        if elapsed >= 1.0 {
            fps = Double(frameCount) / elapsed
            frameCount = 0
            fpsWindowStart = now
        }
    }
}
