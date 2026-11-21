import SwiftUI

@main
struct LockerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…") { model.openComposer() }.keyboardShortcut("n")
                Button("New Terminal") { model.addTerminal() }.keyboardShortcut("t")
                    .disabled(model.selected == nil)
                Button("Settings…") { model.openSettings() }.keyboardShortcut(",")
            }
            CommandMenu("Workspace") {
                Button("Toggle Browser Panel") { model.togglePane() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(model.selected == nil || model.page != .workspace)
                Button("Open Address…") { model.focusAddressBar() }
                    .keyboardShortcut("l")
                    .disabled(model.selected == nil || model.page != .workspace)
                Button("Reload Page") { model.reloadBrowser() }
                    .keyboardShortcut("r")
                    .disabled(model.selected == nil || model.page != .workspace || !(model.selected.map { model.pane(of: $0.id).open } ?? false))
                Divider()
                ForEach(0..<9, id: \.self) { i in
                    Button("Workspace \(i + 1)") { model.selectIndex(i) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
        }
    }
}
