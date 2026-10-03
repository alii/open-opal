import SwiftUI

@main
struct OpenOpalApp: App {
    @State private var camera = CameraModel()

    var body: some Scene {
        // A primary Window quits on close; WindowGroup keeps the camera alive
        // when the controls are dismissed during a call.
        WindowGroup("Open Opal", id: "main") {
            ContentView()
                .environment(camera)
                .frame(minWidth: 940, minHeight: 620)
                .task { await camera.start() }
                // Closing the controls must not interrupt a video call. Quit
                // OpenOpal to release the camera; hiding its window is safe.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    camera.autoLaunch.refresh()
                }
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

                Button(camera.previewFrozen ? "Unfreeze Preview" : "Freeze Preview") {
                    camera.previewFrozen.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}
