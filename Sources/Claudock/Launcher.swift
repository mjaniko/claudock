import AppKit
import Foundation

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm"
    case ghostty = "Ghostty"
    case warp = "Warp"

    var id: String { rawValue }

    var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        }
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static var installed: [TerminalApp] { allCases.filter { $0.appURL != nil } }
}

struct DesktopInstance {
    var pid: pid_t
    var userDataDir: String?
}

enum Launcher {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    static var claudeAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID)
    }

    static func runningDesktops() -> [DesktopInstance] {
        guard let app = claudeAppURL else { return [] }
        let exe = app.appendingPathComponent("Contents/MacOS/Claude").path
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var result: [DesktopInstance] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { continue }
            let command = String(trimmed[trimmed.index(after: space)...])
            guard command == exe || command.hasPrefix(exe + " ") else { continue }
            result.append(DesktopInstance(pid: pid, userDataDir: userDataDir(in: command)))
        }
        return result
    }

    // ps joins argv with spaces, so the value runs until the next " --" flag.
    private static func userDataDir(in command: String) -> String? {
        guard let flag = command.range(of: "--user-data-dir=") else { return nil }
        let rest = command[flag.upperBound...]
        let end = rest.range(of: " --")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    static func pid(for profile: Profile, in instances: [DesktopInstance]) -> pid_t? {
        guard let dir = profile.desktopDir else { return nil }
        return instances.first { instance in
            if let used = instance.userDataDir { return Paths.same(used, dir) }
            return Paths.same(dir, Paths.defaultDesktop)
        }?.pid
    }

    static func openDesktop(_ profile: Profile, runningPID: pid_t?, onError: @escaping (String) -> Void) {
        guard let dir = profile.desktopDir else { return }
        if let pid = runningPID, NSRunningApplication(processIdentifier: pid) != nil {
            bringToFront(pid: pid)
            return
        }
        guard let appURL = claudeAppURL else {
            onError("Claude Desktop is not installed. Get it from claude.ai/download.")
            return
        }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        if !Paths.same(dir, Paths.defaultDesktop) {
            config.arguments = ["--user-data-dir=\(dir)"]
        }
        // Lets the Desktop Code tab share this profile's Claude Code login.
        if let codeDir = profile.codeDir, !profile.isDefault {
            config.environment = ["CLAUDE_CONFIG_DIR": codeDir]
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error { DispatchQueue.main.async { onError(error.localizedDescription) } }
        }
    }

    private typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    private typealias SetFront = @convention(c) (UnsafeRawPointer, UInt32) -> OSStatus

    // NSRunningApplication.activate() is refused while Claudock is in the background, so go through the process manager.
    @discardableResult
    static func bringToFront(pid: pid_t) -> Bool {
        let handle = dlopen(nil, RTLD_NOW)
        if let get = dlsym(handle, "GetProcessForPID"), let set = dlsym(handle, "SetFrontProcessWithOptions") {
            var psn = [UInt32](repeating: 0, count: 2)
            if unsafeBitCast(get, to: GetPSN.self)(pid, &psn) == noErr,
               unsafeBitCast(set, to: SetFront.self)(&psn, 1) == noErr { return true }
        }
        return NSRunningApplication(processIdentifier: pid)?.activate() ?? false
    }

    static func quitDesktop(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    static func openCode(_ profile: Profile, in folder: URL?, terminal: TerminalApp, onError: @escaping (String) -> Void) {
        guard let codeDir = profile.codeDir else { return }
        guard let terminalURL = terminal.appURL else {
            onError("\(terminal.rawValue) is not installed.")
            return
        }
        let fm = FileManager.default
        let launchers = Paths.ownData.appendingPathComponent("launchers")
        do {
            try fm.createDirectory(atPath: codeDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: launchers, withIntermediateDirectories: true)
            var lines = ["#!/bin/zsh -il"]
            // Setting the variable changes which login is used, even when it points at ~/.claude.
            if !profile.isDefault {
                lines.append("export CLAUDE_CONFIG_DIR=\(shellQuote(codeDir))")
            }
            lines.append("cd \(shellQuote((folder ?? Paths.home).path))")
            lines.append("exec claude")
            let script = launchers.appendingPathComponent("\(Paths.slug(profile.name)).command")
            try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let config = NSWorkspace.OpenConfiguration()
            let done: (NSRunningApplication?, Error?) -> Void = { _, error in
                if let error { DispatchQueue.main.async { onError(error.localizedDescription) } }
            }
            if terminal == .ghostty {
                config.createsNewApplicationInstance = true
                config.arguments = ["-e", script.path]
                NSWorkspace.shared.openApplication(at: terminalURL, configuration: config, completionHandler: done)
            } else {
                NSWorkspace.shared.open([script], withApplicationAt: terminalURL, configuration: config, completionHandler: done)
            }
        } catch {
            onError(error.localizedDescription)
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
