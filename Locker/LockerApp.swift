import SwiftUI

@main
struct LockerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(.light)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…") { model.showNewWorkspace = true }.keyboardShortcut("n")
                Button("New Terminal") { model.addTerminal() }.keyboardShortcut("t")
                    .disabled(model.selected == nil)
                Button("Repositories…") { model.showRepos = true }.keyboardShortcut(",", modifiers: [.command, .shift])
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
