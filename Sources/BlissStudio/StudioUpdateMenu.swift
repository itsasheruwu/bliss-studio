import Combine
import Sparkle
import SwiftUI

struct StudioUpdateMenu: View {
    let controller: SPUStandardUpdaterController
    @State private var canCheck = false
    @State private var automaticChecks = false
    @State private var automaticDownloads = false

    var body: some View {
        Button("Check for Updates…") { controller.checkForUpdates(nil) }
            .disabled(!canCheck)
            .onReceive(controller.updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }

        Toggle("Check for Updates Automatically", isOn: Binding(
            get: { automaticChecks },
            set: { controller.updater.automaticallyChecksForUpdates = $0 }
        ))
        .onReceive(controller.updater.publisher(for: \.automaticallyChecksForUpdates)) { automaticChecks = $0 }

        Toggle("Install Updates Automatically", isOn: Binding(
            get: { automaticDownloads },
            set: { controller.updater.automaticallyDownloadsUpdates = $0 }
        ))
        .disabled(!automaticChecks)
        .onReceive(controller.updater.publisher(for: \.automaticallyDownloadsUpdates)) { automaticDownloads = $0 }
    }
}
