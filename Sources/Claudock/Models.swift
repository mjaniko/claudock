import Foundation
import SwiftUI

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorHex: String
    var desktopDir: String?
    var codeDir: String?
    var isDefault = false
    var alias: String?
}

struct CodeAccount: Equatable {
    var uuid: String?
    var email: String?
    var org: String?
    var plan: String?
}

struct ProfileStatus: Equatable {
    var desktopPID: pid_t?
    var desktopAccount: String?
    var code: CodeAccount?
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let appSupport = home.appendingPathComponent("Library/Application Support")
    static let defaultDesktop = appSupport.appendingPathComponent("Claude").path
    static let defaultCode = home.appendingPathComponent(".claude").path
    static let ownData = appSupport.appendingPathComponent("Claudock")

    static func slug(_ name: String) -> String {
        let mapped = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "profile" : collapsed
    }

    static func desktopDir(for name: String) -> String {
        appSupport.appendingPathComponent("Claude-\(slug(name))").path
    }

    static func codeDir(for name: String) -> String {
        home.appendingPathComponent(".claude-\(slug(name))").path
    }

    static func expand(_ path: String) -> String {
        URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    static func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    static func same(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
    }
}

enum Palette {
    static let all = ["#D97757", "#4A90D9", "#5BB974", "#B67BD6", "#E0B341", "#E0607E", "#4FB8B0", "#8E8E93"]
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x8E8E93
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
