import SwiftUI

/// Header button that opens or closes the workspace's side panel.
struct PaneToggle: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace

    var body: some View {
        let on = model.pane(of: ws.id).open
        Button { model.updatePane(ws.id) { $0.open.toggle() } } label: {
            Label("Browser", systemImage: "sidebar.right").font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Theme.chipBG : .clear))
                .foregroundStyle(on ? Theme.chipFG : Theme.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Hide the browser panel (⌥⌘B)" : "Show the browser panel (⌥⌘B)")
        .accessibilityLabel(on ? "Hide browser panel" : "Show browser panel")
        .accessibilityIdentifier("pane-toggle")
    }
}

/// The terminal with the side panel to its right. `TerminalArea` is always the first child, so opening or closing
/// the panel never re-creates it: only its width changes.
struct SplitArea: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace
    /// Fraction while the divider is being dragged; committed (and saved) when the drag ends.
    @State private var dragFraction: Double?

    var body: some View {
        let pane = model.pane(of: ws.id)
        GeometryReader { geo in
            let total = Double(geo.size.width)
            let width = PaneLayout.paneWidth(fraction: dragFraction ?? pane.widthFraction, total: total)
            HStack(spacing: 0) {
                TerminalArea(ws: ws)
                if pane.open {
                    divider(total: total, width: width, saved: pane.widthFraction)
                    SidePane(ws: ws).frame(width: width)
                }
            }
        }
    }

    private func divider(total: Double, width: Double, saved: Double) -> some View {
        Rectangle().fill(Theme.border).frame(width: PaneLayout.dividerWidth)
            .overlay(Rectangle().fill(Color.clear).frame(width: 12).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } })
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    // Dragging left widens the panel.
                    let w = PaneLayout.paneWidth(fraction: saved, total: total) - Double(g.translation.width)
                    dragFraction = PaneLayout.fraction(forPaneWidth: w, total: total)
                }
                .onEnded { _ in
                    if let f = dragFraction { model.updatePane(ws.id) { $0.widthFraction = f } }
                    dragFraction = nil
                })
            .accessibilityLabel("Resize panel").accessibilityIdentifier("pane-divider")
    }
}

/// The browser panel: a toolbar over the page. The page's `WKWebView` belongs to `BrowserRegistry`.
struct SidePane: View {
    @EnvironmentObject var model: AppModel
    let ws: Workspace

    var body: some View {
        // Reading the browser here creates it on first open, restored to its last page.
        BrowserPane(browser: model.browser(for: ws.id), ws: ws)
    }
}

struct BrowserPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var browser: BrowserModel
    let ws: Workspace
    @State private var draft = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack {
                BrowserContainer(view: browser.webView)
                if let failure = browser.failure {
                    FailureView(failure: failure) { browser.reload() } openExternally: { browser.openInDefaultBrowser() }
                } else if browser.currentURL.isEmpty {
                    EmptyBrowserView()
                }
            }
        }
        .background(Theme.surface)
        .onAppear { draft = browser.currentURL }
        .onChange(of: browser.currentURL) { _, url in if !addressFocused { draft = url } }
        .onChange(of: model.addressFocusTick) { _, _ in addressFocused = true }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                iconButton("chevron.left", "Back", enabled: browser.canGoBack) { browser.goBack() }
                iconButton("chevron.right", "Forward", enabled: browser.canGoForward) { browser.goForward() }
                if browser.isLoading {
                    iconButton("xmark", "Stop loading", enabled: true) { browser.stop() }
                } else {
                    iconButton("arrow.clockwise", "Reload (⌘R)", enabled: !browser.currentURL.isEmpty) { browser.reload() }
                }
                TextField("Address, or a port like 3000", text: $draft)
                    .textFieldStyle(.plain).font(Theme.mono(12)).focused($addressFocused)
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sidebar))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(addressFocused ? Theme.accent.opacity(0.6) : Theme.line))
                    .onSubmit { if browser.load(draft) { addressFocused = false } }
                    .onExitCommand { draft = browser.currentURL; addressFocused = false }
                    .onChange(of: draft) { _, _ in browser.inputError = nil }
                    .accessibilityLabel("Address").accessibilityIdentifier("browser-address")
                iconButton("arrow.up.right.square", "Open in default browser", enabled: !browser.currentURL.isEmpty) { browser.openInDefaultBrowser() }
            }
            if let e = browser.inputError {
                Text(e).font(.system(size: 11)).foregroundStyle(Theme.red).padding(.leading, 4)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.chrome)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func iconButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(enabled ? Theme.text : Theme.idle).disabled(!enabled)
        .help(label).accessibilityLabel(label)
    }
}

struct EmptyBrowserView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "globe").font(.system(size: 28)).foregroundStyle(Theme.muted)
            Text("Open a page").font(.system(size: 13, weight: .semibold))
            Text("Type a port like 3000, localhost:5173 or a full address.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.surface)
    }
}

struct FailureView: View {
    let failure: BrowserFailure
    let retry: () -> Void
    let openExternally: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26)).foregroundStyle(Theme.amber)
            Text(failure.message.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.center)
            Text(failure.message.detail).font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            HStack {
                Button("Try again", action: retry).buttonStyle(PrimaryButton())
                Button("Open in browser", action: openExternally).buttonStyle(OutlineButton())
            }.padding(.top, 4)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.surface)
        .accessibilityIdentifier("browser-failure")
    }
}

/// Hosts the long-lived `WKWebView`. Unlike `TerminalContainer` it never grabs keyboard focus: a click does.
struct BrowserContainer: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView {
        let c = NSView()
        attach(view, to: c)
        return c
    }
    func updateNSView(_ c: NSView, context: Context) {
        if view.superview !== c { c.subviews.forEach { $0.removeFromSuperview() }; attach(view, to: c) }
    }
    private func attach(_ v: NSView, to c: NSView) {
        v.removeFromSuperview()
        v.frame = c.bounds
        v.autoresizingMask = [.width, .height]
        c.addSubview(v)
    }
}
