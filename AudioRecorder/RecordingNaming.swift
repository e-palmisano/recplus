import Foundation

/// Turns a user-typed recording name into a safe, collision-free file base name.
enum RecordingNaming {
    static func sanitize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    /// Appends " 2", " 3", … until no `.m4a` exists at the candidate path.
    static func uniqueBaseName(preferred: String, in directory: URL) -> String {
        var candidate = preferred
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(candidate).m4a").path) {
            candidate = "\(preferred) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// `desiredName` wins if non-blank once sanitized; otherwise `fallback` (the
    /// timestamp base name) is used. The result is always collision-free.
    static func resolveFinalBaseName(desiredName: String?, fallback: String, directory: URL) -> String {
        let sanitized = desiredName.map(sanitize) ?? ""
        let preferred = sanitized.isEmpty ? fallback : sanitized
        return uniqueBaseName(preferred: preferred, in: directory)
    }
}
