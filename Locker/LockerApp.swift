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
                Button("New Workspace…") { model.showNewWorkspace = true }.keyboardShortcut("n")
                Button("New Terminal") { model.addTerminal() }.keyboardShortcut("t")
                    .disabled(model.selected == nil)
                Button("Settings…") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("Workspace") {
                ForEach(0..<9, id: \.self) { i in
                    Button("Workspace \(i + 1)") { model.selectIndex(i) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
            }
        }
    }
}
