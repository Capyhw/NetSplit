import SwiftUI

@main
struct NetSplitApp: App {
    @StateObject private var model = SplitModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuSymbol)
                .symbolRenderingMode(.hierarchical)
                .help(model.modeSubtitle)
        }
        .menuBarExtraStyle(.window)
    }
}
