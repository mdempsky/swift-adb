import SwiftUI

@main
struct ScreenshotApp: App {
    @StateObject private var deviceStore = DeviceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(deviceStore)
                .frame(minWidth: 640, minHeight: 480)
        }
        .defaultSize(width: 900, height: 600)
    }
}
