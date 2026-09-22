import Foundation

/// Builds screenshot file names from a user-defined pattern with `{placeholder}` tokens.
enum FileNamePattern {
    static let defaultPattern = "OneShot {date} at {time}"

    /// Placeholders shown in Settings, with a short description.
    static let placeholders: [(token: String, description: String)] = [
        ("{date}", "2026-09-22"),
        ("{time}", "23.01.05"),
        ("{year}", "2026"),
        ("{month}", "09"),
        ("{day}", "22"),
        ("{hour}", "23"),
        ("{minute}", "01"),
        ("{second}", "05"),
        ("{timestamp}", "Unix time"),
        ("{random}", "8 random characters"),
        ("{random:N}", "N random characters"),
        ("{uuid}", "Unique ID"),
        ("{app}", "Frontmost app"),
        ("{width}", "Width in pixels"),
        ("{height}", "Height in pixels"),
    ]

    struct Context {
        var date = Date()
        var appName: String?
        var pixelSize: CGSize?
    }

    static func fileName(pattern: String, context: Context) -> String {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var index = pattern.startIndex

        while index < pattern.endIndex {
            if pattern[index] == "{", let close = pattern[index...].firstIndex(of: "}") {
                let token = String(pattern[pattern.index(after: index)..<close])
                if let value = value(for: token, context: context) {
                    result += value
                    index = pattern.index(after: close)
                    continue
                }
            }
            result.append(pattern[index])
            index = pattern.index(after: index)
        }

        let sanitized = sanitize(result)
        return sanitized.isEmpty ? fileName(pattern: defaultPattern, context: context) : sanitized
    }

    private static func value(for token: String, context: Context) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        let argument = parts.count > 1 ? parts[1] : nil

        switch name {
        case "date": return format(context.date, "yyyy-MM-dd")
        case "time": return format(context.date, "HH.mm.ss")
        case "year": return format(context.date, "yyyy")
        case "month": return format(context.date, "MM")
        case "day": return format(context.date, "dd")
        case "hour": return format(context.date, "HH")
        case "minute": return format(context.date, "mm")
        case "second": return format(context.date, "ss")
        case "timestamp": return String(Int(context.date.timeIntervalSince1970))
        case "random":
            let length = argument.flatMap(Int.init) ?? 8
            return randomString(length: min(max(length, 1), 64))
        case "uuid": return UUID().uuidString
        case "app": return context.appName ?? "Unknown"
        case "width": return context.pixelSize.map { String(Int($0.width)) } ?? "0"
        case "height": return context.pixelSize.map { String(Int($0.height)) } ?? "0"
        default: return nil
        }
    }

    private static func format(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func randomString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// Removes characters that are invalid or awkward in macOS file names.
    private static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .components(separatedBy: .controlCharacters).joined()
            .trimmingCharacters(in: .whitespaces)
        // A leading dot would create a hidden file.
        return String(cleaned.drop(while: { $0 == "." }).prefix(200))
    }
}
