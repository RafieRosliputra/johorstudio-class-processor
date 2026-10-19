import Foundation

/// Folder layout around the app (the "root"):
///
///     <root>/                              e.g. Desktop/2026 SMK Kulai Besar Class Photo/
///       JohorStudio-Class-Processor.app
///       settings.json
///       LIVEFOLDER/                        JPG from the camera
///         DONE/                            originals after PROCESS (renamed by class)
///         WEBP/                            full size WebP sent to the phone
///       PRINTS/                            finished 1800×1200 JPG
///       log/                               YYYY-MM-DD.log
///       cache/classname.png                text layer rendered by Photoshop
struct WorkPaths {
    let root: URL

    static func detect() -> WorkPaths {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return WorkPaths(root: bundle.deletingLastPathComponent())
        }
        // Running from `swift run`: use the current directory.
        return WorkPaths(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
    }

    /// macOS runs quarantined apps from a random read-only location.
    var isTranslocated: Bool { root.path.contains("/AppTranslocation/") }

    var defaultLiveFolder: URL { root.appendingPathComponent("LIVEFOLDER", isDirectory: true) }
    var prints: URL { root.appendingPathComponent("PRINTS", isDirectory: true) }
    var logs: URL { root.appendingPathComponent("log", isDirectory: true) }
    var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    var textPNG: URL { cache.appendingPathComponent("classname.png") }
    var settingsFile: URL { root.appendingPathComponent("settings.json") }

    static func done(in live: URL) -> URL { live.appendingPathComponent("DONE", isDirectory: true) }
    static func webp(in live: URL) -> URL { live.appendingPathComponent("WEBP", isDirectory: true) }
}

extension FileManager {
    func ensureDirectory(_ url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Writes and deletes a probe file to prove the folder is writable.
    func probeWrite(in folder: URL) -> String? {
        let probe = folder.appendingPathComponent(".classproc-probe-\(UUID().uuidString)")
        do {
            try Data("ok".utf8).write(to: probe)
            try removeItem(at: probe)
            return nil
        } catch {
            try? removeItem(at: probe)
            return error.localizedDescription
        }
    }

    /// `name.ext`, or `name (2).ext`, `name (3).ext`… if taken.
    func freeName(_ base: String, ext: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

/// JPG files directly inside a folder, sorted by file name (Finder order).
enum JPGList {
    static func scan(_ folder: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }
        return items
            .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

enum AppError: LocalizedError {
    case cannotRead(String)
    case renderFailed
    case encodeFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let name): return "Cannot read image \(name)"
        case .renderFailed: return "Image render failed"
        case .encodeFailed(let kind): return "\(kind) encoding failed"
        case .message(let text): return text
        }
    }
}
