import Foundation
import CoreGraphics

/// A rectangle in top-left pixel coordinates on the 1800×1200 master.
struct AreaRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    /// textLayer in masterSort.psd: the 2429×100 PSB scaled to the full 1800 width.
    static let textDefault = AreaRect(x: 0, y: 1024, w: 1800, h: 74)
}

/// Saved as settings.json next to the app.
struct AppSettings: Codable, Equatable {
    var liveFolder: String?
    var hotfolderPath: String?
    var masterPath: String?          // the chosen xxxx1.webp
    var psbPath: String?
    var className = "XXX"
    var renderedName: String?        // class name currently inside cache/classname.png
    var textArea = AreaRect.textDefault
    var textScale = 100.0            // % of the fitted size, around the centre of the text area

    // Photo placement — kept until changed, applied to every new set.
    var zoom = 1.0                   // 1 = fill the photo area
    var offsetX = 0.0                // master pixels, from the centre of the photo area
    var offsetY = 0.0
    var scrollStep = 1.0             // % per scroll notch

    // ADB
    var adbSerial: String?
    var wirelessIP = ""
    var tether = false
    var phoneFolder = "/sdcard/Downloads/"
    var gallerySeconds = 120
    var autoSend = false             // ADB auto-send was on: start it again at launch

    init() {}

    // Missing keys fall back to defaults so older settings files keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        liveFolder = try c.decodeIfPresent(String.self, forKey: .liveFolder)
        hotfolderPath = try c.decodeIfPresent(String.self, forKey: .hotfolderPath)
        masterPath = try c.decodeIfPresent(String.self, forKey: .masterPath)
        psbPath = try c.decodeIfPresent(String.self, forKey: .psbPath)
        className = try c.decodeIfPresent(String.self, forKey: .className) ?? d.className
        renderedName = try c.decodeIfPresent(String.self, forKey: .renderedName)
        textArea = try c.decodeIfPresent(AreaRect.self, forKey: .textArea) ?? d.textArea
        textScale = try c.decodeIfPresent(Double.self, forKey: .textScale) ?? d.textScale
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? d.zoom
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? d.offsetX
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? d.offsetY
        scrollStep = try c.decodeIfPresent(Double.self, forKey: .scrollStep) ?? d.scrollStep
        adbSerial = try c.decodeIfPresent(String.self, forKey: .adbSerial)
        wirelessIP = try c.decodeIfPresent(String.self, forKey: .wirelessIP) ?? d.wirelessIP
        tether = try c.decodeIfPresent(Bool.self, forKey: .tether) ?? d.tether
        phoneFolder = try c.decodeIfPresent(String.self, forKey: .phoneFolder) ?? d.phoneFolder
        gallerySeconds = try c.decodeIfPresent(Int.self, forKey: .gallerySeconds) ?? d.gallerySeconds
        autoSend = try c.decodeIfPresent(Bool.self, forKey: .autoSend) ?? d.autoSend
    }

    static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            Log.warn("settings.json unreadable (\(error.localizedDescription)) — using defaults")
            return AppSettings()
        }
    }

    func save(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: url, options: .atomic)
        } catch {
            Log.error("Cannot save settings.json: \(error.localizedDescription)")
        }
    }
}
