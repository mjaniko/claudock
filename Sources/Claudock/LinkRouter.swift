import AppKit

/// Takes over the `claude://` scheme so browser sign-in redirects reach the profile that asked for them.
final class LinkRouter: NSObject, NSApplicationDelegate {
    static let scheme = "claude"
    static let enabledKey = "routeLinks"

    private var lastActiveClaudePID: pid_t?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard Store.demo == nil else { return }
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == Launcher.claudeBundleID {
            lastActiveClaudePID = front.processIdentifier
        }
        Self.applyHandler(enabled: Self.isEnabled)
        // Every Claude instance re-registers itself for the scheme at startup, so keep taking it back.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            guard Self.isEnabled, let probe = URL(string: "\(Self.scheme)://x"),
                  NSWorkspace.shared.urlForApplication(toOpen: probe)?.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL
            else { return }
            Self.log("reclaiming \(Self.scheme):// handler")
            Self.applyHandler(enabled: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if IconRenderer.currentHex != IconRenderer.defaultHex { IconRenderer.applyToDock() }
        // Started by the login item: stay in the menu bar instead of showing the window.
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard event?.eventID == AEEventID(kAEOpenApplication),
              event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) else { return }
        DispatchQueue.main.async { NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() } }
    }

    static func applyHandler(enabled: Bool) {
        let target = enabled ? Bundle.main.bundleURL : Launcher.claudeAppURL
        guard let target, target.pathExtension == "app" else { return }
        NSWorkspace.shared.setDefaultApplication(at: target, toOpenURLsWithScheme: scheme) { _ in }
    }

    @objc private func appActivated(_ note: Notification) {
        let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        WindowCycler.shared.frontmostChanged(to: activated)
        guard let app = activated, app.bundleIdentifier == Launcher.claudeBundleID else { return }
        lastActiveClaudePID = app.processIdentifier
    }

    static func log(_ message: String) {
        let url = Paths.home.appendingPathComponent("Library/Logs/Claudock.log")
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        let running = Launcher.runningDesktops().map(\.pid)
        // Links carry sign-in codes, so only the part before the query is logged.
        Self.log("link \(url.prefix { $0 != "?" }) running=\(running) lastActive=\(String(describing: lastActiveClaudePID))")

        if let pid = topmostClaudePID(among: running) {
            deliver(url, to: pid)
        } else if let pid = lastActiveClaudePID, running.contains(pid) {
            deliver(url, to: pid)
        } else if running.count == 1 {
            deliver(url, to: running[0])
        } else if running.isEmpty {
            openInFreshClaude(url)
        } else if let pid = askWhichProfile(among: running) {
            deliver(url, to: pid)
        }
    }

    // Window order is front to back, so the first Claude window belongs to the instance used last.
    private func topmostClaudePID(among pids: [pid_t]) -> pid_t? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) { return pid }
        }
        return nil
    }

    private func deliver(_ url: String, to pid: pid_t) {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url), forKeyword: keyDirectObject)
        do {
            _ = try event.sendEvent(options: [.waitForReply], timeout: 3)
            Self.log("delivered to \(pid)")
        } catch let error as NSError where error.code == Int(errAEEventNotPermitted) {
            Self.log("not permitted for \(pid)")
            Store.shared.errorMessage = "Claudock isn't allowed to pass sign-in links to Claude. Allow it under System Settings › Privacy & Security › Automation, then sign in again."
        } catch {
            Self.log("send to \(pid) failed: \(error)")
            // Claude doesn't always reply; a timeout still means the link was delivered.
        }
        Launcher.bringToFront(pid: pid)
    }

    private func openInFreshClaude(_ url: String) {
        guard let app = Launcher.claudeAppURL, let link = URL(string: url) else { return }
        NSWorkspace.shared.open([link], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func askWhichProfile(among pids: [pid_t]) -> pid_t? {
        let store = Store.shared
        let choices = store.profiles.compactMap { profile -> (String, pid_t)? in
            guard let pid = store.status[profile.id]?.desktopPID, pids.contains(pid) else { return nil }
            return (profile.name, pid)
        }
        guard !choices.isEmpty else { return pids.first }
        let alert = NSAlert()
        alert.messageText = "Which Claude window should receive this link?"
        alert.informativeText = "A sign-in or deep link arrived and more than one profile is open."
        choices.forEach { alert.addButton(withTitle: $0.0) }
        alert.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index].1 : nil
    }
}
