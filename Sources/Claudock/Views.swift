import SwiftUI

enum EditorTarget: Identifiable {
    case new
    case existing(Profile)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let profile): return profile.id.uuidString
        }
    }
}

struct ProfileEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var name = ""
    @State private var colorHex = Palette.all[1]
    @State private var desktop = true
    @State private var code = true
    @State private var shareSettings = true
    @State private var desktopPath = ""
    @State private var codePath = ""

    private var existing: Profile? {
        if case .existing(let profile) = target { return profile }
        return nil
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var validationError: String? {
        if trimmedName.isEmpty { return nil }
        if store.nameTaken(trimmedName, excluding: existing?.id) { return "A profile with this name already exists." }
        if existing == nil && Paths.slug(trimmedName) == "default" { return "“Default” is reserved." }
        if desktop && existing?.isDefault != true && store.desktopDirTaken(resolvedDesktopDir, excluding: existing?.id) {
            return "Another profile already uses this Desktop data folder."
        }
        return nil
    }

    // An empty field means the folder derived from the profile name.
    private var resolvedDesktopDir: String {
        desktopPath.trimmingCharacters(in: .whitespaces).isEmpty ? Paths.desktopDir(for: trimmedName) : Paths.expand(desktopPath)
    }

    private var resolvedCodeDir: String {
        codePath.trimmingCharacters(in: .whitespaces).isEmpty ? Paths.codeDir(for: trimmedName) : Paths.expand(codePath)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && validationError == nil && (desktop || code)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Profile" : "Edit Profile").font(.title3.weight(.semibold))

            TextField("Name (e.g. Work)", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                ForEach(Palette.all, id: \.self) { hex in
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Color.primary, lineWidth: colorHex == hex ? 2 : 0).padding(-3))
                        .onTapGesture { colorHex = hex }
                }
            }
            .padding(.vertical, 2)

            if existing?.isDefault != true {
                Toggle("Claude Desktop", isOn: $desktop)
                if desktop {
                    folderField("Data folder", text: $desktopPath, placeholder: Paths.desktopDir(for: trimmedName))
                }
                Toggle("Claude Code", isOn: $code)
                if code {
                    folderField("CLAUDE_CONFIG_DIR", text: $codePath, placeholder: Paths.codeDir(for: trimmedName))
                }
                if existing == nil {
                    Toggle("Share skills, settings, plugins and CLAUDE.md with ~/.claude", isOn: $shareSettings)
                        .disabled(!code)
                }
            }

            if let validationError {
                Text(validationError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let existing {
                name = existing.name
                colorHex = existing.colorHex
                desktop = existing.desktopDir != nil
                code = existing.codeDir != nil
                desktopPath = existing.desktopDir.map(Paths.abbreviate) ?? ""
                codePath = existing.codeDir.map(Paths.abbreviate) ?? ""
            } else {
                colorHex = Palette.all[store.profiles.count % Palette.all.count]
            }
        }
    }

    private func save() {
        if var profile = existing {
            profile.name = trimmedName
            profile.colorHex = colorHex
            if !profile.isDefault {
                // Turning a side off only unlinks it; the folder stays on disk.
                profile.desktopDir = desktop ? resolvedDesktopDir : nil
                profile.codeDir = code ? resolvedCodeDir : nil
            }
            store.update(profile)
        } else {
            store.add(
                name: trimmedName, colorHex: colorHex,
                desktopDir: desktop ? resolvedDesktopDir : nil,
                codeDir: code ? resolvedCodeDir : nil,
                shareSettings: shareSettings
            )
        }
        dismiss()
    }

    private func folderField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 6) {
            TextField(label, text: text, prompt: Text(Paths.abbreviate(placeholder)))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.showsHiddenFiles = true
                panel.directoryURL = URL(fileURLWithPath: Paths.expand(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue))
                    .deletingLastPathComponent()
                if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = Paths.abbreviate(url.path) }
            }
        }
        .padding(.leading, 20)
    }
}

struct AliasEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var file = ShellFile.preferred
    @State private var aliases: [UUID: String] = [:]
    @State private var installed = false
    @State private var message: String?

    private var codeProfiles: [Profile] { store.profiles.filter { $0.codeDir != nil } }

    private var draft: [Profile] {
        codeProfiles.map { profile in
            var copy = profile
            let value = aliases[profile.id]?.trimmingCharacters(in: .whitespaces) ?? ""
            copy.alias = value.isEmpty ? nil : value
            return copy
        }
    }

    private var problem: String? {
        let names = draft.compactMap(\.alias)
        if let bad = names.first(where: { !ShellAliases.isValid($0) }) { return "“\(bad)” is not a valid alias name." }
        if Set(names).count != names.count { return "Two profiles use the same alias." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shell Aliases").font(.title3.weight(.semibold))
            Text("Type an alias in any terminal to start Claude Code signed in to that profile. Leave a field empty to skip the profile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Shell file", selection: $file) {
                ForEach(ShellFile.allCases) { Text($0.display).tag($0) }
            }
            .pickerStyle(.segmented)

            Grid(alignment: .leading, verticalSpacing: 8) {
                ForEach(codeProfiles) { profile in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: profile.colorHex)).frame(width: 10, height: 10)
                            Text(profile.name)
                        }
                        TextField("alias", text: Binding(
                            get: { aliases[profile.id] ?? "" },
                            set: { aliases[profile.id] = $0 }
                        ), prompt: Text(profile.isDefault ? "none" : ShellAliases.suggestion(for: profile)))
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }
                }
            }

            Text(ShellHighlighter.highlight(ShellAliases.block(for: draft)))
                .font(.caption.monospaced())
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            if let text = problem ?? message {
                Text(text).font(.caption).foregroundStyle(problem != nil ? .red : .secondary)
            }

            HStack {
                if installed {
                    Button("Remove from \(file.display)", role: .destructive) { run { try ShellAliases.remove(from: file) } done: { "Removed the Claudock block from \(file.display)." } }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(installed ? "Update \(file.display)" : "Write to \(file.display)") {
                    store.setAliases(aliases)
                    run { try ShellAliases.write(store.profiles, to: file) } done: { "Saved. Open a new terminal or run: source \(file.display)" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            for profile in codeProfiles {
                aliases[profile.id] = profile.alias ?? ShellAliases.suggestion(for: profile)
            }
            installed = ShellAliases.isInstalled(in: file)
        }
        .onChange(of: file) { _, new in
            installed = ShellAliases.isInstalled(in: new)
            message = nil
        }
    }

    private func run(_ action: () throws -> Void, done: () -> String) {
        do {
            try action()
            message = done()
        } catch {
            message = error.localizedDescription
        }
        installed = ShellAliases.isInstalled(in: file)
    }
}

enum ShellHighlighter {
    static func highlight(_ code: String) -> AttributedString {
        var result = AttributedString()
        for (index, line) in code.components(separatedBy: "\n").enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += highlightLine(line)
        }
        return result
    }

    private static func highlightLine(_ line: String) -> AttributedString {
        if line.hasPrefix("#") { return piece(line, .secondary) }
        guard line.hasPrefix("alias "), let equals = line.firstIndex(of: "=") else { return AttributedString(line) }

        let name = String(line[line.index(line.startIndex, offsetBy: 6)..<equals])
        var value = piece(String(line[line.index(after: equals)...]), .orange)
        recolor(&value, pattern: "[A-Z_]+(?==)", .purple)
        recolor(&value, pattern: "\\$[A-Za-z_]+", .teal)
        recolor(&value, pattern: "\\bclaude\\b", .green)
        return piece("alias", .pink) + AttributedString(" ") + piece(name, .blue) + AttributedString("=") + value
    }

    private static func piece(_ text: String, _ color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.foregroundColor = color
        return attributed
    }

    private static func recolor(_ text: inout AttributedString, pattern: String, _ color: Color) {
        let plain = String(text.characters)
        var search = plain.startIndex..<plain.endIndex
        while let match = plain.range(of: pattern, options: .regularExpression, range: search) {
            if let lower = AttributedString.Index(match.lowerBound, within: text),
               let upper = AttributedString.Index(match.upperBound, within: text) {
                text[lower..<upper].foregroundColor = color
            }
            search = match.upperBound..<plain.endIndex
        }
    }
}
