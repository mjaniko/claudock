import SwiftUI

@main
struct ClaudockApp: App {
    @NSApplicationDelegateAdaptor(LinkRouter.self) private var linkRouter
    @StateObject private var store = Store.shared

    var body: some Scene {
        Window("Claudock", id: "main") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 640, height: 400)

        Settings {
            SettingsView().environmentObject(store)
        }

        MenuBarExtra("Claudock", systemImage: "person.2.circle") {
            MenuBarContent().environmentObject(store)
        }
    }
}
