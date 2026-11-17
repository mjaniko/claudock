import Foundation

enum ShellFile: String, CaseIterable, Identifiable {
    case zshrc = ".zshrc"
    case bashrc = ".bashrc"
    case bashProfile = ".bash_profile"

    var id: String { rawValue }
    var display: String { "~/" + rawValue }

    // Resolved so an rc file that is a symlink into a dotfiles repo stays a symlink.
    var url: URL { Paths.home.appendingPathComponent(rawValue).resolvingSymlinksInPath() }

    static var preferred: ShellFile {
        (ProcessInfo.processInfo.environment["SHELL"] ?? "").hasSuffix("bash") ? .bashrc : .zshrc
    }
}

enum ShellAliases {
    static let begin = "# >>> Claudock profiles >>>"
    static let end = "# <<< Claudock profiles <<<"

    static func suggestion(for profile: Profile) -> String {
        profile.isDefault ? "" : "cc-" + Paths.slug(profile.name)
    }

    static func isValid(_ alias: String) -> Bool {
        alias.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil
    }

    static func lines(for profiles: [Profile]) -> [String] {
        profiles.compactMap { profile in
            guard let alias = profile.alias, isValid(alias), let dir = profile.codeDir else { return nil }
            // The Default profile is the login used when the variable is not set at all.
            let command = profile.isDefault ? "env -u CLAUDE_CONFIG_DIR claude" : "CLAUDE_CONFIG_DIR=\(pathExpression(dir)) claude"
            return "alias \(alias)='\(command.replacingOccurrences(of: "'", with: "'\\''"))'"
        }
    }

    static func block(for profiles: [Profile]) -> String {
        ([begin, "# Managed by Claudock. Edits inside this block are overwritten."] + lines(for: profiles) + [end]).joined(separator: "\n")
    }

    private static func pathExpression(_ path: String) -> String {
        func escape(_ s: String) -> String {
            var out = s
            for ch in ["\\", "\"", "$", "`"] { out = out.replacingOccurrences(of: ch, with: "\\" + ch) }
            return out
        }
        let home = Paths.home.path
        if path.hasPrefix(home + "/") { return "\"$HOME\(escape(String(path.dropFirst(home.count))))\"" }
        return "\"\(escape(path))\""
    }

    static func isInstalled(in file: ShellFile) -> Bool {
        (try? String(contentsOf: file.url, encoding: .utf8))?.contains(begin) ?? false
    }

    static func write(_ profiles: [Profile], to file: ShellFile) throws {
        var content = stripped(try read(file))
        if !content.isEmpty && !content.hasSuffix("\n") { content += "\n" }
        if !content.isEmpty { content += "\n" }
        try save(content + block(for: profiles) + "\n", to: file)
    }

    static func remove(from file: ShellFile) throws {
        let content = try read(file)
        guard content.contains(begin) else { return }
        try save(stripped(content), to: file)
    }

    private static func read(_ file: ShellFile) throws -> String {
        guard FileManager.default.fileExists(atPath: file.url.path) else { return "" }
        return try String(contentsOf: file.url, encoding: .utf8)
    }

    private static func stripped(_ content: String) -> String {
        guard let start = content.range(of: begin),
              let finish = content.range(of: end, range: start.upperBound..<content.endIndex) else { return content }
        var head = String(content[..<start.lowerBound])
        var tail = String(content[finish.upperBound...])
        while head.hasSuffix("\n\n") { head.removeLast() }
        if tail.hasPrefix("\n") { tail.removeFirst() }
        return head + tail
    }

    private static func save(_ content: String, to file: ShellFile) throws {
        let fm = FileManager.default
        let url = file.url
        let existed = fm.fileExists(atPath: url.path)
        let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".claudock-backup")
        if existed && !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: url, to: backup) }
        try content.write(to: url, atomically: true, encoding: .utf8)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }
}
