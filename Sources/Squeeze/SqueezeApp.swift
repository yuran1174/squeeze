import SwiftUI

@main
struct SqueezeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: "rectangle.compress.vertical")
        }
        .menuBarExtraStyle(.window)
    }
}
