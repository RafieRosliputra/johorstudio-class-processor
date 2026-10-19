import Foundation

/// Opens a photo in Quick Look (same as Space in Finder).
@MainActor
enum QuickLook {
    private static var process: Process?

    static func show(_ url: URL) {
        process?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p.arguments = ["-p", url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            process = p
        } catch {
            Log.error("Quick Look: \(error.localizedDescription)")
        }
    }
}
