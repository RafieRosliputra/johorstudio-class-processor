import Foundation

/// Updates the text layer in textLayer.psb through Photoshop and exports it as a transparent PNG.
/// Only the contents of the (first) text layer change; styles/effects stay as designed.
enum PhotoshopText {
    static let appName = "Adobe Photoshop 2026"

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "on run argv",
            "-e", "tell application \"\(appName)\"",
            "-e", "return do javascript (item 1 of argv) with arguments {item 2 of argv, item 3 of argv, item 4 of argv}",
            "-e", "end tell",
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
