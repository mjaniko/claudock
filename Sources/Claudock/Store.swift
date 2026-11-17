import AppKit
import Foundation
import SwiftUI

final class Store: ObservableObject {
    static let shared = Store()

    @Published var profiles: [Profile] = []
    @Published var status: [UUID: ProfileStatus] = [:]
    @Published var errorMessage: String?
    @Published var terminal: TerminalApp {
        didSet { UserDefaults.standard.set(terminal.rawValue, forKey: "terminal") }
    }

    private let file = Paths.ownData.appendingPathComponent("profiles.json")
    private let queue = DispatchQueue(label: "claudock.refresh")
    private var timer: Timer?
    private var tick = 0

    // Set CLAUDOCK_DEMO to show sample profiles for screenshots; nothing is read from or written to disk.
    static let demo = ProcessInfo.processInfo.environment["CLAUDOCK_DEMO"]

    init() {
        let saved = UserDefaults.standard.string(forKey: "terminal").flatMap(TerminalApp.init(rawValue:))
        terminal = saved ?? TerminalApp.installed.first ?? .terminal
        if Self.demo != nil {
            loadDemo()
            return
        }
        load()
        refresh(accounts: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tick += 1
            self.refresh(accounts: self.tick % 5 == 0)
        }
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
        }
        if !profiles.contains(where: \.isDefault) {
            let defaultProfile = Profile(
                name: "Default", colorHex: Palette.all[0],
                desktopDir: Paths.defaultDesktop, codeDir: Paths.defaultCode, isDefault: true
            )
            profiles.insert(defaultProfile, at: 0)
            save()
        }
    }

    private func loadDemo() {
        let samples: [(String, String, String?, String, String?, pid_t?)] = [
            ("Default", "alex@example.com", nil, "Max", nil, 1),
            ("Work", "alex@acme.example", "Acme Inc", "Team", "cc-work", 2),
            ("Client", "alex@studio.example", "Studio North", "Pro", "cc-client", nil),
        ]
        for (index, sample) in samples.enumerated() {
            let (name, email, org, plan, alias, pid) = sample
            let profile = Profile(
                name: name, colorHex: Palette.all[index],
                desktopDir: index == 0 ? Paths.defaultDesktop : Paths.desktopDir(for: name),
                codeDir: index == 0 ? Paths.defaultCode : Paths.codeDir(for: name),
                isDefault: index == 0, alias: alias
            )
            profiles.append(profile)
            status[profile.id] = ProfileStatus(
                desktopPID: pid, desktopAccount: email,
                code: CodeAccount(email: email, org: org, plan: plan)
            )
        }
    }

    private func save() {
        guard Self.demo == nil else { return }
        try? FileManager.default.createDirectory(at: Paths.ownData, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(profiles) {
            try? data.write(to: file, options: .atomic)
        }
        // Keep rc files that already carry the managed block in step with the profiles.
        for shellFile in ShellFile.allCases where ShellAliases.isInstalled(in: shellFile) {
            try? ShellAliases.write(profiles, to: shellFile)
        }
    }

    func setAliases(_ aliases: [UUID: String]) {
        for index in profiles.indices {
            let value = aliases[profiles[index].id]?.trimmingCharacters(in: .whitespaces) ?? ""
            profiles[index].alias = value.isEmpty ? nil : value
        }
        save()
    }

    // MARK: Profile management

    func nameTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        profiles.contains { $0.id != id && Paths.slug($0.name) == Paths.slug(name) }
    }

    func desktopDirTaken(_ dir: String, excluding id: UUID? = nil) -> Bool {
        profiles.contains { $0.id != id && ($0.desktopDir.map { Paths.same($0, dir) } ?? false) }
    }

    func add(name: String, colorHex: String, desktopDir: String?, codeDir: String?, shareSettings: Bool) {
        let profile = Profile(name: name, colorHex: colorHex, desktopDir: desktopDir, codeDir: codeDir)
        if let dir = codeDir, shareSettings, !FileManager.default.fileExists(atPath: dir) {
            linkSharedSettings(into: dir)
        }
        profiles.append(profile)
        save()
        refresh(accounts: true)
    }

    func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
        refresh(accounts: true)
    }

    func move(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func remove(_ profile: Profile, trashData: Bool) {
        guard !profile.isDefault else { return }
        if trashData {
            for dir in [profile.desktopDir, profile.codeDir].compactMap({ $0 }) {
                guard !Paths.same(dir, Paths.defaultDesktop), !Paths.same(dir, Paths.defaultCode) else { continue }
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: dir), resultingItemURL: nil)
            }
        }
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    private func linkSharedSettings(into dir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for item in ["skills", "settings.json", "CLAUDE.md", "plugins"] {
            let source = Paths.defaultCode + "/" + item
            let target = dir + "/" + item
            if fm.fileExists(atPath: source) && !fm.fileExists(atPath: target) {
                try? fm.createSymbolicLink(atPath: target, withDestinationPath: source)
            }
        }
    }

    /// Adopts existing `Claude-*` and `~/.claude-*` folders in place. Returns how many profiles were added.
    @discardableResult
    func importExisting() -> Int {
        let fm = FileManager.default
        var found: [String: (desktop: String?, code: String?)] = [:]

        for entry in (try? fm.contentsOfDirectory(atPath: Paths.appSupport.path)) ?? [] where entry.hasPrefix("Claude-") {
            let path = Paths.appSupport.appendingPathComponent(entry).path
            guard fm.fileExists(atPath: path + "/Local State") || fm.fileExists(atPath: path + "/config.json") else { continue }
            found[String(entry.dropFirst("Claude-".count)).lowercased(), default: (nil, nil)].desktop = path
        }
        for entry in (try? fm.contentsOfDirectory(atPath: Paths.home.path)) ?? [] where entry.hasPrefix(".claude-") {
            let path = Paths.home.appendingPathComponent(entry).path
            guard fm.fileExists(atPath: path + "/.claude.json") else { continue }
            found[String(entry.dropFirst(".claude-".count)).lowercased(), default: (nil, nil)].code = path
        }

        var added = 0
        for (key, dirs) in found.sorted(by: { $0.key < $1.key }) {
            let desktopKnown = dirs.desktop.map { d in profiles.contains { $0.desktopDir.map { Paths.same($0, d) } ?? false } } ?? true
            let codeKnown = dirs.code.map { c in profiles.contains { $0.codeDir.map { Paths.same($0, c) } ?? false } } ?? true
            if desktopKnown && codeKnown { continue }

            if let index = profiles.firstIndex(where: { !$0.isDefault && Paths.slug($0.name) == key }) {
                if profiles[index].desktopDir == nil { profiles[index].desktopDir = dirs.desktop }
                if profiles[index].codeDir == nil { profiles[index].codeDir = dirs.code }
            } else {
                let color = Palette.all[profiles.count % Palette.all.count]
                profiles.append(Profile(
                    name: key.prefix(1).uppercased() + key.dropFirst(), colorHex: color,
                    desktopDir: desktopKnown ? nil : dirs.desktop, codeDir: codeKnown ? nil : dirs.code
                ))
            }
            added += 1
        }
        if added > 0 {
            save()
            refresh(accounts: true)
        }
        return added
    }

    // MARK: Actions

    func openDesktop(_ profile: Profile) {
        Launcher.openDesktop(profile, runningPID: status[profile.id]?.desktopPID) { [weak self] in self?.errorMessage = $0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh(accounts: false) }
    }

    func quitDesktop(_ profile: Profile) {
        if let pid = status[profile.id]?.desktopPID { Launcher.quitDesktop(pid: pid) }
    }

    func openCode(_ profile: Profile, in folder: URL? = nil) {
        Launcher.openCode(profile, in: folder, terminal: terminal) { [weak self] in self?.errorMessage = $0 }
    }

    func openCodeChoosingFolder(_ profile: Profile) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Claude Code Here"
        if panel.runModal() == .OK, let url = panel.url { openCode(profile, in: url) }
    }

    // MARK: Status

    func refresh(accounts: Bool) {
        guard Self.demo == nil else { return }
        let snapshot = profiles
        let previous = status
        queue.async {
            let instances = Launcher.runningDesktops()
            var codeAccounts: [UUID: CodeAccount] = [:]
            var emailByUUID: [String: String] = [:]
            if accounts {
                for profile in snapshot {
                    guard let dir = profile.codeDir,
                          let account = Self.readCodeAccount(dir: dir, isDefault: profile.isDefault) else { continue }
                    codeAccounts[profile.id] = account
                    if let uuid = account.uuid, let email = account.email { emailByUUID[uuid] = email }
                }
            }
            var next: [UUID: ProfileStatus] = [:]
            for profile in snapshot {
                var entry = previous[profile.id] ?? ProfileStatus()
                entry.desktopPID = Launcher.pid(for: profile, in: instances)
                if accounts {
                    entry.code = codeAccounts[profile.id]
                    entry.desktopAccount = profile.desktopDir.flatMap { Self.readDesktopAccount(dir: $0, emails: emailByUUID) }
                }
                next[profile.id] = entry
            }
            DispatchQueue.main.async {
                if self.status != next { self.status = next }
            }
        }
    }

    private static func readJSON(_ path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func readCodeAccount(dir: String, isDefault: Bool) -> CodeAccount? {
        // Without CLAUDE_CONFIG_DIR the state file lives in $HOME, not inside ~/.claude.
        let path = isDefault ? Paths.home.appendingPathComponent(".claude.json").path : dir + "/.claude.json"
        guard let account = readJSON(path)?["oauthAccount"] as? [String: Any] else { return nil }
        let plan = (account["organizationType"] as? String)?
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        return CodeAccount(
            uuid: account["accountUuid"] as? String,
            email: account["emailAddress"] as? String,
            org: account["organizationName"] as? String,
            plan: plan
        )
    }

    private static func readDesktopAccount(dir: String, emails: [String: String]) -> String? {
        guard let config = readJSON(dir + "/config.json") else { return nil }
        let signedIn = config["oauth:tokenCache"] != nil || config["oauth:tokenCacheV2"] != nil
        guard signedIn else { return nil }
        if let uuid = config["lastKnownAccountUuid"] as? String, let email = emails[uuid] { return email }
        return "Signed in"
    }
}
