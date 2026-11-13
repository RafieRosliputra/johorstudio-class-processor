import Foundation
import AppKit

/// Updates the text layer in textLayer.psb through Photoshop and exports it as a transparent PNG.
/// Only the contents of the (first) text layer change; styles/effects stay as designed.
enum PhotoshopText {
    /// Any installed Photoshop version: the running one first, then the newest in /Applications.
    static func findApp() -> URL? {
        let ws = NSWorkspace.shared
        for id in ["com.adobe.Photoshop", "com.adobe.Photoshop.beta"] {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.bundleURL { return running }
        }
        if let url = ws.urlForApplication(withBundleIdentifier: "com.adobe.Photoshop") { return url }
        let fm = FileManager.default
        let apps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        var found: [URL] = []
        for dir in (try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil)) ?? [] where dir.lastPathComponent.hasPrefix("Adobe Photoshop") {
            if dir.pathExtension == "app" { found.append(dir) }
            else { found += ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" && $0.lastPathComponent.hasPrefix("Adobe Photoshop") } }
        }
        return found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }.first
    }

    /// Runs inside Photoshop. arguments: [className, psbPath, pngPath]
    static let jsx = """
    var className = arguments[0];
    var psb = new File(arguments[1]);
    var png = new File(arguments[2]);
    app.displayDialogs = DialogModes.NO;
    var doc = null;
    for (var i = 0; i < app.documents.length; i++) {
        try { if (app.documents[i].fullName.fsName == psb.fsName) { doc = app.documents[i]; } } catch (e) {}
    }
    if (doc == null) { doc = app.open(psb); }
    app.activeDocument = doc;
    function findText(layers) {
        for (var i = 0; i < layers.length; i++) {
            var l = layers[i];
            if (l.typename == "LayerSet") { var r = findText(l.layers); if (r != null) { return r; } }
            else if (l.kind == LayerKind.TEXT) { return l; }
        }
        return null;
    }
    var layer = findText(doc.layers);
    if (layer == null) { throw new Error("No text layer in " + psb.name); }
    layer.textItem.contents = className;
    doc.save();
    var opts = new PNGSaveOptions();
    opts.compression = 1;
    opts.interlaced = false;
    doc.saveAs(png, opts, true, Extension.LOWERCASE);
    "OK " + layer.name;
    """

    /// Blocking — call off the main thread. Returns Photoshop's result text.
    static func render(className: String, psb: URL, png: URL) throws -> String {
        try FileManager.default.ensureDirectory(png.deletingLastPathComponent())
        guard let app = findApp() else {
            throw AppError.message("Photoshop not found in /Applications — install or open Photoshop first")
        }
        Log.info("Photoshop app: \(app.path)")
        // Literal path in the script so AppleScript loads that Photoshop's own terminology (do javascript).
        let appPath = app.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            // First run waits for the macOS "allow to control Photoshop" prompt.
            "-e", "with timeout of 600 seconds",
            "-e", "tell application \"\(appPath)\"",
            "-e", "return do javascript (item 1 of argv) with arguments {item 2 of argv, item 3 of argv, item 4 of argv}",
            "-e", "end tell",
            "-e", "end timeout",
            "-e", "end run",
            jsx, className, psb.path, png.path,
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let errText = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw AppError.message("Photoshop: \(errText.isEmpty ? "osascript exited \(process.terminationStatus)" : errText)")
        }
        guard FileManager.default.fileExists(atPath: png.path) else {
            throw AppError.message("Photoshop did not write \(png.lastPathComponent) (\(text))")
        }
        return text
    }
}
