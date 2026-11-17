import AppKit
import Carbon.HIToolbox

/// Makes ⌘` hop between Claude profiles, which macOS treats as separate apps and so won't cycle itself.
final class WindowCycler {
    static let shared = WindowCycler()
    static let enabledKey = "cycleHotkey"

    private var hotKeys: [EventHotKeyRef] = []
    private var handlerInstalled = false

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // The shortcut is only held while Claude is frontmost, so every other app keeps its own ⌘`.
    func frontmostChanged(to app: NSRunningApplication?) {
        let runningCount = Store.shared.status.values.filter { $0.desktopPID != nil }.count
        let wanted = Self.isEnabled && app?.bundleIdentifier == Launcher.claudeBundleID && runningCount > 1
        LinkRouter.log("frontmost=\(app?.bundleIdentifier ?? "nil") running=\(runningCount) hotkey=\(wanted)")
        wanted ? register() : unregister()
    }

    private func register() {
        guard hotKeys.isEmpty else { return }
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                WindowCycler.shared.cycle(forward: id.id == 1)
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        // ISO keyboards report the backtick key under a different code than ANSI ones, so bind both.
        for keyCode in [kVK_ANSI_Grave, kVK_ISO_Section] {
            for (id, modifiers) in [(UInt32(1), cmdKey), (UInt32(2), cmdKey | shiftKey)] {
                var ref: EventHotKeyRef?
                let hotKeyID = EventHotKeyID(signature: OSType(0x434C_444B), id: id)
                let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
                LinkRouter.log("hotkey \(id) key=\(keyCode) register status=\(status)")
                if let ref { hotKeys.append(ref) }
            }
        }
    }

    private func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
    }

    private func cycle(forward: Bool) {
        let store = Store.shared
        let running = Launcher.runningDesktops()
        let ordered = store.profiles.compactMap { Launcher.pid(for: $0, in: running) }
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        LinkRouter.log("hotkey pressed forward=\(forward) ordered=\(ordered) current=\(String(describing: current))")
        guard ordered.count > 1 else { return }
        let index = ordered.firstIndex { $0 == current } ?? -1
        let next = ordered[(index + (forward ? 1 : ordered.count - 1) + ordered.count) % ordered.count]
        let ok = Launcher.bringToFront(pid: next)
        LinkRouter.log("activate \(next) -> \(ok)")
    }
}
