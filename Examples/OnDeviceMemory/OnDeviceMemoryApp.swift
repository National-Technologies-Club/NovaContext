import Foundation
import SwiftUI

@main struct OnDeviceMemoryApp: App {
    private let testing = ProcessInfo.processInfo.environment["NOVACONTEXT_TEST_HOST"] == "1"
    private let modelFree = ProcessInfo.processInfo.arguments.contains("--model-free")

    var body: some Scene {
        WindowGroup {
            if testing {
                Text("NovaContext test host")
            } else {
                MemoryDemoView(model: MemoryDemo(directory: databaseDirectory,
                    responder: modelFree ? PreviewResponder() : AppleResponder()), modelFree: modelFree)
            }
        }
    }

    private var databaseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Preview content never enters the real on-device demonstration store.
        return base.appendingPathComponent(modelFree ? "preview.novacontext" : "memory.novacontext")
    }
}
