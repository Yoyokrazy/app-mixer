import SwiftUI

@main
struct AppMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("App Mixer", systemImage: "slider.vertical.3") {
            MixerView(mixer: appDelegate.mixer)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mixer = Mixer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        mixer.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.shutdown()
    }
}
