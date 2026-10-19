import SwiftUI
import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

enum MainTab: String, CaseIterable {
    case print = "PRINT"
    case adb = "ADB"
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// One loaded camera photo (index 0 = main / big preview, 1…5 = the small boxes).
struct LoadedPhoto: Identifiable {
    let id = UUID()
    var url: URL
    var preview: CGImage?
    var size: CGSize            // full size after EXIF rotation
}

@MainActor
final class AppState: ObservableObject {
    static let setSize = 6
    static let masterCount = 5

    let paths: WorkPaths
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { scheduleSave() } }
    }
    @Published var tab: MainTab = .print
    @Published var alert: AlertItem?
    @Published var confirmPurge = false

    // Masters
    @Published private(set) var masters: [CGImage?] = Array(repeating: nil, count: masterCount)
    @Published private(set) var masterLines: [String] = ["No master selected"]
    @Published private(set) var photoArea = CGRect(x: 0, y: 222, width: 1800, height: 785)

    // Class name text (rendered by Photoshop)
    @Published private(set) var textImage: CGImage?
    @Published private(set) var renderingText = false

    // Photos
    @Published private(set) var photos: [LoadedPhoto] = []
    @Published private(set) var red = Set<Int>()
    @Published private(set) var loading = false
    @Published private(set) var processing = false
    @Published private(set) var liveCount = 0
    /// Class name used for this set (set by refresh / PROCESS). On RESET the camera files are renamed
    /// "<class> - 1…5" (red = "xx") and moved to DONE. Until then LIVEFOLDER is not touched.
    @Published private(set) var setClass: String?
    /// Class name whose WebP "<class> - 1…6" were already sent to the phone for this set.
    private var webpSentFor: String?
    var hasCopies: Bool { setClass != nil }

    let adb = ADBManager()

    private var saveTimer: Timer?
    private var countTimer: Timer?
    private let liveMonitor = FolderMonitor()
    private var activity: NSObjectProtocol?
    private var started = false

    init() {
        let paths = WorkPaths.detect()
        LogStore.shared.configure(folder: paths.logs)
        self.paths = paths
        settings = AppSettings.load(from: paths.settingsFile)
        adb.app = self
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Class photo session running"
        )
    }

    func start() {
        guard !started else { return }
        started = true
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.info("===== JohorStudio-Class-Processor \(version) starting =====")
        if paths.isTranslocated {
            Log.error("App is running from a temporary macOS location (App Translocation). Move it into the root folder and run: xattr -dr com.apple.quarantine \"JohorStudio-Class-Processor.app\"")
        }
        Log.info("Root: \(paths.root.path)")
        if let err = FileManager.default.probeWrite(in: paths.root) {
            Log.error("Root folder is not writable: \(err)")
        }
        for folder in [liveFolderURL, WorkPaths.done(in: liveFolderURL), paths.prints, paths.cache] {
            do { try FileManager.default.ensureDirectory(folder) } catch {
                Log.error("Cannot create \(folder.path): \(error.localizedDescription)")
            }
        }
        Log.info("LIVEFOLDER: \(liveFolderURL.path)")
        Log.info("PRINTS: \(paths.prints.path)")
        if let hot = hotfolderURL {
            if FileManager.default.isDirectory(hot) { Log.ok("Hotfolder: \(hot.path)") } else { Log.error("Hotfolder not found: \(hot.path)") }
        } else {
            Log.warn("No hotfolder selected — choose HOTFOLDER before PRINT SAMPLES")
        }
        loadMasters()
        loadText()
        if settings.psbPath == nil { Log.warn("No textLayer.psb selected — press CLASS NAME") }
        watchLiveFolder()
        adb.startup()
        Log.info("Startup finished")
        // Start every session with XXX in the text layer.
        settings.className = "XXX"
        if settings.psbPath != nil, settings.renderedName != "XXX" || textImage == nil {
            Task { await refreshText(makeCopies: false) }
        }
        // Testing: `open App.app --args --load /path/first.jpg`
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--load"), i + 1 < args.count {
            loadSet(startingAt: URL(fileURLWithPath: args[i + 1]))
        }
    }

    // MARK: - Settings

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.settings.save(to: self.paths.settingsFile)
            }
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        settings.save(to: paths.settingsFile)
    }

    // MARK: - Folders

    var liveFolderURL: URL {
        settings.liveFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? paths.defaultLiveFolder
    }

    var hotfolderURL: URL? {
        settings.hotfolderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func shortPath(_ url: URL) -> String {
        "\(url.deletingLastPathComponent().lastPathComponent) / \(url.lastPathComponent)"
    }

    func chooseLiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = liveFolderURL
        panel.prompt = "Use as LIVEFOLDER"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.liveFolder = url.path
        Log.ok("LIVEFOLDER: \(url.path)")
        try? FileManager.default.ensureDirectory(WorkPaths.done(in: url))
        watchLiveFolder()
        if adb.running { adb.stop(); adb.start() }
    }

    func chooseHotfolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = hotfolderURL ?? paths.root
        panel.prompt = "Use as HOTFOLDER"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let err = FileManager.default.probeWrite(in: url) {
            Log.error("Hotfolder not writable: \(url.path) — \(err)")
            alert = AlertItem(title: "Hotfolder not writable", message: err)
            return
        }
        settings.hotfolderPath = url.path
        Log.ok("Hotfolder: \(url.path)")
    }

    private func watchLiveFolder() {
        let live = liveFolderURL
        liveMonitor.start(live) { [weak self] in
            Task { @MainActor in self?.countLive() }
        }
        countTimer?.invalidate()
        countTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.countLive() }
        }
        countLive()
    }

    private func countLive() {
        let n = JPGList.scan(liveFolderURL).count
        if n != liveCount { liveCount = n }
        adb.updatePending()
    }

    // MARK: - Masters

    /// Pick xxxx1.webp; xxxx2…xxxx5.webp are found next to it.
    func chooseMaster() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "webp") ?? .image, .png]
        panel.directoryURL = settings.masterPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? paths.root
        panel.prompt = "Use as master 1"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.masterPath = url.path
        loadMasters()
    }

    /// "master1.webp" → (prefix "master", ext "webp"); nil if the name does not end with 1.
    static func masterPattern(_ url: URL) -> (prefix: String, ext: String)? {
        let base = url.deletingPathExtension().lastPathComponent
        guard base.hasSuffix("1") else { return nil }
        return (String(base.dropLast()), url.pathExtension)
    }

    func masterURL(_ n: Int) -> URL? {
        guard let path = settings.masterPath else { return nil }
        let first = URL(fileURLWithPath: path)
        guard let p = Self.masterPattern(first) else { return n == 1 ? first : nil }
        return first.deletingLastPathComponent().appendingPathComponent("\(p.prefix)\(n).\(p.ext)")
    }

    func loadMasters() {
        guard let path = settings.masterPath else {
            masters = Array(repeating: nil, count: Self.masterCount)
            masterLines = ["No master selected"]
            Log.warn("No master selected — press Master File (overlay)")
            return
        }
        if Self.masterPattern(URL(fileURLWithPath: path)) == nil {
            Log.warn("\(URL(fileURLWithPath: path).lastPathComponent): name does not end with 1 — only this master is used")
        }
        var list: [CGImage?] = []
        var lines: [String] = []
        for n in 1...Self.masterCount {
            guard let url = masterURL(n) else {
                list.append(nil)
                lines.append("master \(n) missing")
                continue
            }
            if let img = Imaging.load(url) {
                list.append(img)
                lines.append("\(url.lastPathComponent) loaded")
                if img.width != Int(Imaging.canvas.width) || img.height != Int(Imaging.canvas.height) {
                    Log.warn("\(url.lastPathComponent) is \(img.width)×\(img.height) — stretched to 1800×1200")
                }
            } else {
                list.append(nil)
                lines.append("\(url.lastPathComponent) MISSING")
                Log.error("Master not found: \(url.path)")
            }
        }
        masters = list
        masterLines = lines
        if let first = list[0], let area = Imaging.transparentArea(first) {
            photoArea = area
            Log.ok("Masters: \(list.compactMap { $0 }.count)/\(Self.masterCount) loaded — photo area x\(Int(area.minX)) y\(Int(area.minY)) w\(Int(area.width)) h\(Int(area.height))")
        } else if list[0] != nil {
            Log.error("Master 1 has no transparent area for the photo")
        }
    }

    // MARK: - Class name / textLayer.psb

    var psbName: String {
        settings.psbPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No textLayer.psb"
    }

    var textOutdated: Bool { settings.renderedName != settings.className || textImage == nil }

    func choosePSB() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "psb") ?? .data, UTType(filenameExtension: "psd") ?? .data]
        panel.directoryURL = settings.psbPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? paths.root
        panel.prompt = "Use for class name"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.psbPath = url.path
        Log.ok("Class name PSB: \(url.path)")
    }

    private func loadText() {
        if let img = Imaging.load(paths.textPNG) {
            textImage = img
            Log.info("Class name text loaded: \"\(settings.renderedName ?? "?")\"")
        }
    }

    func setClassName(_ text: String) {
        let upper = text.uppercased()
        if upper != settings.className { settings.className = upper }
    }

    /// Photoshop: put the class name into the text layer, save the PSB, export PNG.
    @discardableResult
    func refreshText(makeCopies: Bool = true) async -> Bool {
        guard let psb = settings.psbPath else {
            alert = AlertItem(title: "No textLayer.psb", message: "Press CLASS NAME and choose textLayer.psb first.")
            return false
        }
        let name = settings.className.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            alert = AlertItem(title: "No class name", message: "Type the class name first.")
            return false
        }
        guard !renderingText else { return false }
        renderingText = true
        defer { renderingText = false }
        Log.info("Photoshop: \"\(name)\" → \(URL(fileURLWithPath: psb).lastPathComponent)…")
        let tmp = paths.cache.appendingPathComponent("classname-render.png")
        let target = paths.textPNG
        let start = Date()
        do {
            let result: String = try await Task.detached(priority: .userInitiated) {
                try? FileManager.default.removeItem(at: tmp)
                let r = try PhotoshopText.render(className: name, psb: URL(fileURLWithPath: psb), png: tmp)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: tmp, to: target)
                return r
            }.value
            guard let img = Imaging.load(target) else { throw AppError.cannotRead(target.lastPathComponent) }
            textImage = img
            settings.renderedName = name
            Log.ok("Photoshop: class name updated to \"\(name)\" (\(result), \(String(format: "%.1f", Date().timeIntervalSince(start)))s)")
            if makeCopies { sendPhoneWebP() }
            return true
        } catch {
            Log.error("Photoshop: \(error.localizedDescription)")
            alert = AlertItem(title: "Photoshop failed", message: error.localizedDescription)
            return false
        }
    }

    // MARK: - Photos

    func loadPhotoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg]
        panel.directoryURL = liveFolderURL
        panel.prompt = "Load 6 photos"
        panel.message = "Choose the first photo — the next 5 (by file name) are loaded with it"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadSet(startingAt: url)
    }

    func loadSet(startingAt first: URL) {
        let list = JPGList.scan(first.deletingLastPathComponent())
        guard let i = list.firstIndex(where: { $0.lastPathComponent == first.lastPathComponent }) else {
            Log.error("\(first.lastPathComponent) not found")
            return
        }
        let set = Array(list[i...].prefix(Self.setSize))
        guard set.count == Self.setSize else {
            Log.warn("Only \(set.count) photo(s) from \(first.lastPathComponent) — need \(Self.setSize). Not loaded.")
            alert = AlertItem(title: "Not enough photos",
                              message: "Only \(set.count) photo(s) from \(first.lastPathComponent). 6 are needed — nothing loaded.")
            return
        }
        if hasCopies {
            Log.info("New set loaded — finishing RESET & RENAME for the previous set first")
            renameProcessed()
        }
        loading = true
        Log.info("Loading: \(set.map(\.lastPathComponent).joined(separator: ", "))")
        Task {
            let loaded: [LoadedPhoto] = await Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: (Int, LoadedPhoto).self) { group in
                    for (n, url) in set.enumerated() {
                        group.addTask {
                            let preview = Imaging.preview(url)
                            let size = Imaging.orientedSize(url) ?? CGSize(width: preview?.width ?? 3, height: preview?.height ?? 2)
                            return (n, LoadedPhoto(url: url, preview: preview, size: size))
                        }
                    }
                    var out = [(Int, LoadedPhoto)]()
                    for await item in group { out.append(item) }
                    return out.sorted { $0.0 < $1.0 }.map(\.1)
                }
            }.value
            photos = loaded
            red = []
            webpSentFor = nil
            loading = false
            for p in loaded where p.preview == nil { Log.error("Cannot read \(p.url.lastPathComponent)") }
            Log.ok("6 photos loaded (main: \(loaded[0].url.lastPathComponent))")
        }
    }

    func toggleRed(_ index: Int) {
        guard index > 0, index < photos.count, !processing else { return }
        if red.contains(index) {
            red.remove(index)
            Log.info("Photo \(index + 1) (\(photos[index].url.lastPathComponent)) will be processed")
        } else {
            red.insert(index)
            Log.info("Photo \(index + 1) (\(photos[index].url.lastPathComponent)) skipped (red)")
        }
    }

    /// RESET PHOTO: rename (if a class name was applied), unload, class name → XXX in the box AND the text layer.
    func resetPhotos() {
        renameProcessed()
        photos = []
        red = []
        settings.className = "XXX"
        Log.info("Reset: no photo loaded, class name → XXX")
        if settings.psbPath != nil {
            Task { await refreshText(makeCopies: false) }
        }
    }

    /// Suffix per loaded photo: photos that are not red get 1…5 in order, red ones (and a 6th) get "xx".
    func plannedSuffixes() -> [Int: String] {
        var out: [Int: String] = [:]
        var n = 0
        for i in 0..<photos.count {
            if !red.contains(i), n < Self.masterCount {
                n += 1
                out[i] = String(n)
            } else {
                out[i] = "xx"
            }
        }
        return out
    }

    /// WebP "<class> - 1…6" (by position) of the 6 loaded photos → phone. Camera files are not touched.
    func sendPhoneWebP() {
        guard photos.count == Self.setSize,
              let rendered = settings.renderedName, rendered != "XXX",
              !rendered.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let cls = Self.safeFileName(rendered)
        setClass = cls
        guard webpSentFor != cls else { return }
        webpSentFor = cls
        let items = photos.enumerated().map { (i, p) in (src: p.url, name: "\(cls) - \(i + 1)") }
        adb.sendNow(items)
    }

    /// RESET: camera files → "<class> - 1…5" (photos not red, in order) / "<class> - xx" (red),
    /// moved to LIVEFOLDER/DONE. File contents never change.
    func renameProcessed() {
        guard let cls = setClass else { return }
        let fm = FileManager.default
        let done = WorkPaths.done(in: liveFolderURL)
        try? fm.ensureDirectory(done)
        let suffix = plannedSuffixes()
        for (i, photo) in photos.enumerated() {
            let src = photo.url
            guard fm.fileExists(atPath: src.path) else {
                Log.warn("RENAME \(src.lastPathComponent): file not found")
                continue
            }
            let ext = src.pathExtension.lowercased().isEmpty ? "jpg" : src.pathExtension.lowercased()
            let dest = fm.freeName("\(cls) - \(suffix[i] ?? "xx")", ext: ext, in: done)
            do {
                try fm.moveItem(at: src, to: dest)
                Log.ok("RENAME \(src.lastPathComponent) → DONE/\(dest.lastPathComponent)")
            } catch {
                Log.error("RENAME \(src.lastPathComponent): \(error.localizedDescription)")
            }
        }
        setClass = nil
        webpSentFor = nil
        countLive()
    }

    // MARK: - Text layer size & position

    func nudgeText(dx: Double, dy: Double) {
        settings.textArea.x += dx
        settings.textArea.y += dy
    }

    // MARK: - Zoom & position (master pixels, saved in settings)

    var offset: CGPoint { CGPoint(x: settings.offsetX, y: settings.offsetY) }

    func setOffset(_ p: CGPoint) {
        var o = p
        if let main = photos.first {
            let rect = Imaging.photoRect(photo: main.size, area: photoArea, zoom: settings.zoom, offset: .zero)
            o = Imaging.clamp(offset: p, drawn: rect.size, area: photoArea)
        }
        settings.offsetX = o.x
        settings.offsetY = o.y
    }

    /// `ticks` scroll notches (+ = bigger), around `anchor` (canvas pixels).
    func zoom(ticks: Double, anchor: CGPoint?) {
        let step = max(0.1, settings.scrollStep) / 100
        let old = settings.zoom
        let new = min(10, max(1, old + ticks * step))
        guard new != old else { return }
        // Keep the point under the cursor in place.
        let c = anchor.map { CGPoint(x: $0.x - photoArea.midX, y: $0.y - photoArea.midY) } ?? .zero
        let k = new / old
        let o = CGPoint(x: c.x + (settings.offsetX - c.x) * k, y: c.y + (settings.offsetY - c.y) * k)
        settings.zoom = new
        setOffset(o)
    }

    func resetPlacement() {
        settings.zoom = 1
        settings.offsetX = 0
        settings.offsetY = 0
        Log.info("Photo size/position reset to fill")
    }

    // MARK: - PROCESS / PRINT SAMPLES

    static func safeFileName(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func process(printSamples: Bool) async {
        guard !processing else { return }
        guard photos.count == Self.setSize else {
            alert = AlertItem(title: "No photo loaded", message: "Press Load Photo first.")
            return
        }
        let order = (0..<photos.count).filter { !red.contains($0) }
        guard order.count <= Self.masterCount else {
            alert = AlertItem(title: "Mark one photo red",
                              message: "6 photos but only 5 masters. Right-click one of the small photos to skip it.")
            return
        }
        for n in 1...order.count where masters[n - 1] == nil {
            alert = AlertItem(title: "Master \(n) missing", message: "Press Master File (overlay) and choose xxxx1.webp.")
            return
        }
        guard !settings.className.trimmingCharacters(in: .whitespaces).isEmpty, settings.className != "XXX" else {
            alert = AlertItem(title: "No class name", message: "Type the class name, then press refresh.")
            return
        }
        if printSamples {
            guard let hot = hotfolderURL, FileManager.default.isDirectory(hot) else {
                alert = AlertItem(title: "No hotfolder", message: "Press HOTFOLDER and choose the printer hotfolder.")
                return
            }
        }
        processing = true
        defer { processing = false }

        if textOutdated {
            Log.info("Class name text is not \"\(settings.className)\" yet — refreshing first")
            guard await refreshText(makeCopies: false) else { return }
        }
        // File names follow the text layer exactly: "TINGKATAN 1C - 1.jpg".
        let cls = Self.safeFileName(settings.renderedName ?? settings.className)

        struct Job { let index: Int; let number: Int; let url: URL; let size: CGSize; let master: CGImage }
        let jobs = order.enumerated().map { (k, i) in
            Job(index: i, number: k + 1, url: photos[i].url, size: photos[i].size, master: masters[k]!)
        }
        let text = textImage
        let area = photoArea
        let textArea = settings.textArea.cgRect
        let textScale = settings.textScale
        let zoom = settings.zoom
        let offset = self.offset
        let prints = paths.prints
        let hot = printSamples ? hotfolderURL : nil

        Log.info("\(printSamples ? "PRINT SAMPLES" : "PROCESS"): \(cls) — \(jobs.count) photo(s)\(red.isEmpty ? "" : ", skipped: \(red.sorted().map { "#\($0 + 1)" }.joined(separator: ", "))")")

        await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            try? fm.ensureDirectory(prints)
            for job in jobs {
                let name = "\(cls) - \(job.number).jpg"
                let out = prints.appendingPathComponent(name)

                // 1. Export to PRINTS (never overwrite).
                if fm.fileExists(atPath: out.path) {
                    Log.warn("PRINTS/\(name) already exists — not exported again")
                } else {
                    do {
                        let rect = Imaging.photoRect(photo: job.size, area: area, zoom: zoom, offset: offset)
                        let px = Int(ceil(max(rect.width, rect.height)))
                        guard let photo = Imaging.preview(job.url, maxPixels: px) else { throw AppError.cannotRead(job.url.lastPathComponent) }
                        let image = try Imaging.render(photo: photo, master: job.master, text: text, area: area,
                                                       textArea: textArea, textScale: textScale, zoom: zoom, offset: offset)
                        let data = try ImageExport.jpegData(image)
                        try ImageExport.writeAtomically(data, to: out)
                        Log.ok("EXPORT \(job.url.lastPathComponent) + master\(job.number) → PRINTS/\(name)")
                    } catch {
                        Log.error("EXPORT \(name): \(error.localizedDescription)")
                        continue
                    }
                }

                // 2. PRINT SAMPLES: copy the PRINTS file to the hotfolder.
                if let hot {
                    let dest = hot.appendingPathComponent(name)
                    if fm.fileExists(atPath: dest.path) {
                        Log.warn("Hotfolder already has \(name) — not copied again")
                    } else {
                        do {
                            let tmp = hot.appendingPathComponent(".\(name).tmp")
                            try? fm.removeItem(at: tmp)
                            try fm.copyItem(at: out, to: tmp)
                            try fm.moveItem(at: tmp, to: dest)
                            Log.ok("PRINT PRINTS/\(name) → hotfolder")
                        } catch {
                            Log.error("Copy to hotfolder \(name): \(error.localizedDescription)")
                        }
                    }
                }
            }
        }.value

        sendPhoneWebP()
        setClass = cls
        Log.info("Camera files stay in LIVEFOLDER until RESET & RENAME")
        Log.ok("\(printSamples ? "PRINT SAMPLES" : "PROCESS") finished: \(cls)")
    }

    // MARK: - Printer

    /// Right-click on PURGE PRINTER: the macOS print queue (Print Center on macOS 27).
    func openPrinterQueue() {
        let ws = NSWorkspace.shared
        if let app = ws.urlForApplication(withBundleIdentifier: "com.apple.printcenter") {
            ws.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            Log.info("Opened Print Center (printer queue)")
            return
        }
        let printers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Printers")
        if let proxy = (try? FileManager.default.contentsOfDirectory(at: printers, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) {
            ws.open(proxy)
            Log.info("Opened printer queue \(proxy.deletingPathExtension().lastPathComponent)")
            return
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
            ws.open(url)
            Log.info("Opened Printers & Scanners")
        }
    }

    func purgePrinter() {
        Task {
            let result = await Task.detached { PrinterQueue.purgeDefault() }.value
            switch result {
            case .success(let msg): Log.ok("PURGE PRINTER: \(msg)")
            case .failure(let err):
                Log.error("PURGE PRINTER: \(err.message)")
                alert = AlertItem(title: "Purge failed", message: err.message)
            }
        }
    }
}
