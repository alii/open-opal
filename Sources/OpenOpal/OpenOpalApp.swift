import SwiftUI

@main
struct OpenOpalApp: App {
    @State private var camera = CameraModel()

    var body: some Scene {
        Window("Open Opal", id: "main") {
            ContentView()
                .environment(camera)
                .frame(minWidth: 940, minHeight: 620)
                .task { await camera.start() }
                .onDisappear { camera.stop() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Camera") {
                Button("Reconnect") {
                    Task { await camera.reconnect() }
                }
                .keyboardShortcut("r")

                Button("Trigger Autofocus") { camera.device.triggerAutofocus() }
                    .keyboardShortcut("f")
                    .disabled(!camera.device.state.isLive)

                Divider()

                Button("Reset All Settings") { camera.settings.reset(); camera.push() }

                Button("Toggle Advanced Settings") { camera.settings.showAdvanced.toggle() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }
    }
}
