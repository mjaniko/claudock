import ServiceManagement
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var editing: EditorTarget?
    @State private var deleting: Profile?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        List {
            ForEach(store.profiles) { profile in
                ProfileCard(
                    profile: profile,
                    status: store.status[profile.id] ?? ProfileStatus(),
                    onEdit: { editing = .existing(profile) },
                    onDelete: { deleting = profile }
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
            }
            .onMove { store.move(from: $0, to: $1) }
        }
        .listStyle(.plain)
        .frame(minWidth: 560, minHeight: 300)
        .toolbar {
            ToolbarItemGroup {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
                Button {
                    editing = .new
                } label: {
                    Label("New Profile", systemImage: "plus").labelStyle(.titleAndIcon)
                }
            }
        }
        .sheet(item: $editing) { target in
            ProfileEditor(target: target).environmentObject(store)
        }
        .onAppear {
            switch Store.demo {
            case "editor": editing = .existing(store.profiles[1])
            case "settings", "aliases": openSettings()
            default: break
            }
        }
        .confirmationDialog(
            "Remove “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { profile in
            Button("Remove from List") { store.remove(profile, trashData: false) }
            Button("Remove and Move Data to Trash", role: .destructive) { store.remove(profile, trashData: true) }
        } message: { _ in
            Text("Removing from the list keeps the profile's chats and login on disk.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct ProfileCard: View {
    @EnvironmentObject var store: Store
    let profile: Profile
    let status: ProfileStatus
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var color: Color { Color(hex: profile.colorHex) }
    private var isRunning: Bool { status.desktopPID != nil }

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.headline)
                    if let plan = status.code?.plan, !plan.isEmpty { badge(plan, .secondary) }
                    if isRunning { badge("Running", .green) }
                }
                ForEach(accountLines, id: \.self) { line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let alias = profile.alias {
                    Text(verbatim: alias)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if profile.desktopDir != nil {
                actionButton("Desktop", icon: "macwindow", prominent: isRunning) { store.openDesktop(profile) }
                    .help(isRunning ? "Bring this profile's Claude window to the front" : "Open Claude Desktop with this profile")
            }
            if profile.codeDir != nil {
                actionButton("Code", icon: "terminal", prominent: false) { store.openCode(profile) }
                    .help("Open Claude Code in \(store.terminal.rawValue) with this profile")
            }

            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if profile.desktopDir != nil { store.openDesktop(profile) }
        }
        .contextMenu { menuItems }
    }

    private var avatar: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 38, height: 38)
            .overlay(
                Text(profile.name.prefix(1).uppercased())
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
            .overlay(alignment: .bottomTrailing) {
                if isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                }
            }
    }

    // One line when Desktop and Code share an account, otherwise one line per side.
    private var accountLines: [String] {
        let org = status.code?.org.flatMap { $0.isEmpty || $0.contains("@") ? nil : $0 }
        let code = status.code?.email
        let desktop = status.desktopAccount

        if profile.desktopDir != nil, profile.codeDir != nil {
            if let code, desktop == code { return [[code, org].compactMap { $0 }.joined(separator: " · ")] }
            if desktop == nil, code == nil { return ["Not signed in. Open Desktop to sign in."] }
            return ["Desktop: \(desktop ?? "not signed in")", "Code: \(code ?? "not signed in")"]
        }
        if profile.desktopDir != nil { return [desktop ?? "Not signed in. Open Desktop to sign in."] }
        return [code.map { [$0, org].compactMap { $0 }.joined(separator: " · ") } ?? "Not signed in. Open Code and run /login."]
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }

    private func actionButton(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
        }
        .buttonStyle(PillButtonStyle(tint: prominent ? color : nil))
    }

    @ViewBuilder
    private var menuItems: some View {
        if profile.codeDir != nil {
            Button("Open Claude Code in Folder…") { store.openCodeChoosingFolder(profile) }
        }
        if isRunning {
            Button("Quit This Desktop Window") { store.quitDesktop(profile) }
        }
        Divider()
        if let dir = profile.desktopDir {
            Button("Reveal Desktop Data in Finder") { reveal(dir) }
        }
        if let dir = profile.codeDir {
            Button("Reveal Claude Code Config in Finder") { reveal(dir) }
        }
        Divider()
        Button("Edit…", action: onEdit)
        if !profile.isDefault {
            Button("Remove…", role: .destructive, action: onDelete)
        }
    }

    private func reveal(_ dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage(LinkRouter.enabledKey) private var routeLinks = true
    @AppStorage(WindowCycler.enabledKey) private var cycleHotkey = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var showingAliases = false
    @State private var importResult: String?
    @AppStorage(IconRenderer.colorKey) private var iconHex = IconRenderer.defaultHex

    private var iconColor: Binding<Color> {
        Binding(
            get: { Color(hex: iconHex) },
            set: { newValue in
                guard let rgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                iconHex = String(format: "#%02X%02X%02X", Int(round(rgb.redComponent * 255)), Int(round(rgb.greenComponent * 255)), Int(round(rgb.blueComponent * 255)))
                IconRenderer.applyToDock()
            }
        )
    }

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent {
                    HStack {
                        ColorPicker("Icon colour", selection: iconColor, supportsOpacity: false).labelsHidden()
                        Button("Reset") {
                            iconHex = IconRenderer.defaultHex
                            IconRenderer.applyToDock()
                        }
                        .disabled(iconHex == IconRenderer.defaultHex)
                    }
                } label: {
                    Text("Icon colour")
                    Text("Recolours the Dock icon while Claudock is running.")
                }
            }

            Section("General") {
                Toggle("Open Claudock at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLoginItem(enabled) }
                Picker("Terminal for Claude Code", selection: $store.terminal) {
                    ForEach(TerminalApp.installed) { Text($0.rawValue).tag($0) }
                }
            }

            Section("Switching") {
                Toggle(isOn: $cycleHotkey) {
                    Text(verbatim: "⌘ ` switches between open Claude profiles")
                    Text(verbatim: "⇧ ⌘ ` goes the other way. Only active while a Claude window is in front.")
                }
                .onChange(of: cycleHotkey) { _, _ in
                    WindowCycler.shared.frontmostChanged(to: NSWorkspace.shared.frontmostApplication)
                }
                Toggle(isOn: $routeLinks) {
                    Text("Send browser sign-in links to the Claude window used last")
                    Text("Without this, “Open Claude” in the browser can land in the wrong profile.")
                }
                .onChange(of: routeLinks) { _, enabled in LinkRouter.applyHandler(enabled: enabled) }
            }

            Section("Profiles") {
                LabeledContent {
                    Button("Edit Aliases…") { showingAliases = true }
                } label: {
                    Text("Shell aliases")
                    Text("Start a profile's Claude Code from any terminal, e.g. cc-work.")
                }
                LabeledContent {
                    Button("Import") {
                        let count = store.importExisting()
                        importResult = count == 0 ? "No new profile folders found." : "Imported \(count) profile\(count == 1 ? "" : "s")."
                    }
                } label: {
                    Text("Existing profile folders")
                    Text(importResult ?? "Adopt Claude-* and ~/.claude-* folders made by other tools.")
                }
            }

            Section {
                Text("Signing in: Claude logs in through your browser, which remembers its last account. Start the sign-in from the browser profile that holds the right account, or use a private window.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showingAliases) {
            AliasEditor().environmentObject(store)
        }
        .onAppear { if Store.demo == "aliases" { showingAliases = true } }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.errorMessage = "Couldn't change the login item: \(error.localizedDescription)"
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.profiles) { profile in
            let running = store.status[profile.id]?.desktopPID != nil
            Menu {
                if profile.desktopDir != nil {
                    Button(running ? "Show Desktop" : "Open Desktop") { store.openDesktop(profile) }
                }
                if profile.codeDir != nil {
                    Button("Claude Code") { store.openCode(profile) }
                    Button("Claude Code in Folder…") { store.openCodeChoosingFolder(profile) }
                }
                if running {
                    Divider()
                    Button("Quit This Desktop Window") { store.quitDesktop(profile) }
                }
            } label: {
                Image(nsImage: Self.dot(profile.colorHex, filled: running))
                Text(running ? "\(profile.name) (open)" : profile.name)
            }
        }
        Divider()
        Button("Open Claudock") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit Claudock") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // Filled when the profile's Desktop window is open, a ring when it isn't.
    private static func dot(_ hex: String, filled: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let color = NSColor(Color(hex: hex))
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if filled {
                color.setFill()
                path.fill()
            } else {
                color.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Quiet pill button; `tint` marks the active state with the profile colour.
struct PillButtonStyle: ButtonStyle {
    var tint: Color?
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let base = tint ?? Color.primary
        let fill = tint == nil ? (hovering ? 0.13 : 0.07) : (hovering ? 0.32 : 0.22)
        configuration.label
            .labelStyle(PillLabelStyle())
            .font(.callout.weight(.medium))
            .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(base))
            .frame(width: 92, height: 30)
            .background(base.opacity(configuration.isPressed ? fill + 0.08 : fill), in: Capsule())
            .overlay(Capsule().strokeBorder(base.opacity(tint == nil ? 0.1 : 0.45), lineWidth: 1))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct PillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small).opacity(0.75)
            configuration.title
        }
    }
}
