import Foundation
import Combine

/// The ADB part of the old "JohorStudio LiveFolder" app:
/// every new JPG in LIVEFOLDER → full size WebP (quality 50) in LIVEFOLDER/WEBP → pushed to the phone
/// in batches of up to 10, then the gallery is refreshed. Simple Gallery Pro is restarted every 2 minutes.
@MainActor
final class ADBManager: ObservableObject {
    static let galleryPackage = "com.simplemobiletools.gallery.pro"
    static let batchSize = 10

    weak var app: AppState?

    @Published private(set) var devices: [String] = []
    /// Devices adb sees but cannot use yet (serial → state, e.g. "unauthorized", "offline").
    @Published private(set) var notReady: [String: String] = [:]
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var sentCount = 0
    @Published private(set) var adbPath: String?

    private var sent = Set<String>()
    /// Loaded photos to send now as "<class> - n.webp", even when auto-send is off.
    private var priority: [(src: URL, name: String)] = []
    private var statusTimer: Timer?
    private var workTimer: Timer?
    private var galleryTimer: Timer?
    private let monitor = FolderMonitor()
    /// Quick adb commands (devices, swipe, gallery…) never wait behind a batch being sent.
    private let queue = DispatchQueue(label: "classproc.adb.cmd")
    private let sendQueue = DispatchQueue(label: "classproc.adb.send", qos: .utility)
    private var checkingDevices = false

    var serial: String? { app?.settings.adbSerial }

    var connected: Bool {
        guard let serial else { return false }
        return devices.contains(serial)
    }

    var statusText: String {
        guard adbPath != nil else { return "adb not installed" }
        if let serial, devices.contains(serial) { return "adb \(serial) connected" }
        if let first = notReady.first {
            return first.value == "unauthorized" ? "adb \(first.key): press Allow on the phone" : "adb \(first.key) \(first.value)"
        }
        if devices.isEmpty { return "adb no device" }
        return "adb \(serial ?? "-") not connected"
    }

    // MARK: - Startup

    func startup() {
        adbPath = Self.findADB()
        guard let adbPath else {
            Log.error("adb not found (/opt/homebrew/bin/adb). Install: brew install android-platform-tools")
            return
        }
        Log.ok("adb: \(adbPath)")
        loadSent()
        restartServer()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices(quiet: true) }
        }
        workTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.kick() }
        }
    }

    static func findADB() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Library/Android/sdk/platform-tools/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Commands

    /// Runs adb (blocking) — only from `queue`.
    nonisolated private static func run(_ adb: String, _ args: [String]) -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func adb(_ args: [String], device: Bool = true, completion: (@MainActor @Sendable (Int32, String) -> Void)? = nil) {
        guard let adbPath else { Log.error("adb not installed"); return }
        var full = args
        if device, let serial { full = ["-s", serial] + args }
        queue.async {
            let r = Self.run(adbPath, full)
            if let completion {
                Task { @MainActor in completion(r.status, r.text) }
            }
        }
    }

    func restartServer() {
        guard let adbPath else { Log.error("adb not installed"); return }
        Log.info("ADB: kill-server & start-server…")
        let ip = app?.settings.wirelessIP.trimmingCharacters(in: .whitespaces) ?? ""
        queue.async {
            _ = Self.run(adbPath, ["kill-server"])
            Thread.sleep(forTimeInterval: 1)
            _ = Self.run(adbPath, ["start-server"])
            var connectText: String?
            if !ip.isEmpty {
                connectText = Self.run(adbPath, ["connect", ip]).text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Task { @MainActor in
                Log.ok("ADB server restarted")
                if let connectText { Log.info("ADB connect \(ip): \(connectText)") }
                self.refreshDevices(quiet: false)
            }
        }
    }

    func connectWireless() {
        let ip = app?.settings.wirelessIP.trimmingCharacters(in: .whitespaces) ?? ""
        guard !ip.isEmpty else { Log.warn("ADB: enter the wireless IP first"); return }
        Log.info("ADB: connect \(ip)…")
        adb(["connect", ip], device: false) { [weak self] _, text in
            Log.info("ADB connect: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            self?.refreshDevices(quiet: false)
        }
    }

    func refreshDevices(quiet: Bool) {
        // Never pile up `adb devices` calls if adb is slow (e.g. server starting).
        if checkingDevices && quiet { return }
        checkingDevices = true
        adb(["devices"], device: false) { [weak self] _, text in
            guard let self else { return }
            self.checkingDevices = false
            var list: [String] = []
            var other: [String: String] = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 2 else { continue }
                let serial = String(parts[0]), state = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if state == "device" { list.append(serial) } else { other[serial] = state }
            }
            let wasConnected = self.connected
            if list != self.devices { self.devices = list }
            if other != self.notReady {
                for (s, state) in other where self.notReady[s] != state {
                    Log.warn(state == "unauthorized"
                             ? "ADB \(s) unauthorized — tick \"Allow USB debugging\" on the phone"
                             : "ADB \(s) is \(state)")
                }
                self.notReady = other
            }
            // Pick the first device when none is chosen (or the chosen one is gone and only one is left).
            if let app = self.app, !list.isEmpty, app.settings.adbSerial == nil || (!list.contains(app.settings.adbSerial!) && list.count == 1) {
                app.settings.adbSerial = list[0]
            }
            if !quiet { Log.info("ADB devices: \(list.isEmpty ? "none" : list.joined(separator: ", "))") }
            if wasConnected != self.connected {
                if self.connected { Log.ok(self.statusText) } else { Log.warn("ADB device disconnected") }
            }
        }
    }

    func swipeRefresh() {
        Log.info("ADB: swipe down (refresh gallery)")
        adb(["shell", "input", "swipe", "500", "200", "500", "1200", "300"])
    }

    func restartGallery(reason: String = "") {
        Log.info("ADB: restart Simple Gallery Pro\(reason)")
        adb(["shell", "am", "force-stop", Self.galleryPackage]) { [weak self] _, _ in
            self?.adb(["shell", "am", "start", "-n", "\(Self.galleryPackage)/.activities.MainActivity"])
        }
    }

    func launchScrcpy() {
        let paths = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            Log.error("scrcpy not found. Install: brew install scrcpy")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var args = ["--always-on-top", "--stay-awake"]
        if let serial { args += ["-s", serial] }
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let adbPath { env["ADB"] = adbPath }
        process.environment = env
        do {
            try process.run()
            Log.ok("scrcpy opened")
        } catch {
            Log.error("scrcpy: \(error.localizedDescription)")
        }
    }

    func clearPhoneFolder() {
        guard let folder = app?.settings.phoneFolder else { return }
        let clean = folder.hasSuffix("/") ? folder : folder + "/"
        Log.warn("ADB: deleting everything in \(clean)")
        adb(["shell", "rm -rf '\(clean)'*"]) { _, text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.ok("ADB: \(clean) cleared\(t.isEmpty ? "" : " (\(t))")")
        }
    }

    // MARK: - Sent record

    private func loadSent() {
        guard let url = app?.paths.sentFile,
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        sent = Set(list)
        sentCount = sent.count
        Log.info("ADB: \(sent.count) file(s) already sent (adb-sent.json)")
    }

    private func saveSent() {
        guard let url = app?.paths.sentFile else { return }
        if let data = try? JSONEncoder().encode(sent.sorted()) {
            try? data.write(to: url, options: .atomic)
        }
        sentCount = sent.count
    }

    func forgetSent() {
        sent = []
        saveSent()
        Log.warn("ADB: sent record cleared — every JPG will be sent again")
        updatePending()
    }

    // MARK: - Auto send

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        guard let app else { return }
        guard adbPath != nil else { Log.error("adb not installed"); return }
        running = true
        let live = app.liveFolderURL
        Log.ok("ADB auto-send started: \(live.path) → \(app.settings.phoneFolder)")
        monitor.start(live) { [weak self] in
            Task { @MainActor in self?.kick() }
        }
        scheduleGallery()
        kick()
    }

    func stop() {
        running = false
        monitor.stop()
        galleryTimer?.invalidate()
        galleryTimer = nil
        Log.info("ADB auto-send stopped")
    }

    func scheduleGallery() {
        galleryTimer?.invalidate()
        galleryTimer = nil
        guard running, let app, !app.settings.tether else { return }
        let seconds = TimeInterval(max(30, app.settings.gallerySeconds))
        galleryTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running, self.connected, self.app?.settings.tether == false else { return }
                self.restartGallery(reason: " (every \(Int(seconds))s)")
            }
        }
    }

    private func pending() -> [URL] {
        guard let app else { return [] }
        return JPGList.scan(app.liveFolderURL).filter { !sent.contains($0.lastPathComponent) }
    }

    func updatePending() {
        pendingCount = priority.count + (running ? pending().count : 0)
    }

    /// Send these photos as WebP named `name` (camera files are only read) as soon as the phone is connected.
    func sendNow(_ items: [(src: URL, name: String)]) {
        guard adbPath != nil else { return }
        let names = Set(items.map(\.name))
        priority.removeAll { names.contains($0.name) }
        priority.append(contentsOf: items)
        if connected {
            Log.info("ADB: \(items.count) photo(s) queued for the phone as \(items.first?.name ?? "")…")
        } else {
            Log.warn("ADB: phone not connected — \(items.count) photo(s) will be sent when it is")
        }
        updatePending()
        kick()
    }

    /// Takes the next batch (≤ 10) and sends it.
    private func kick() {
        updatePending()
        guard !busy, connected, let app, let adbPath, let serial else { return }
        // Renamed copies first, then (when auto-send is on) new camera files.
        priority.removeAll { !FileManager.default.fileExists(atPath: $0.src.path) }
        var batch: [(src: URL, name: String)] = Array(priority.prefix(Self.batchSize))
        let fromPriority = batch.count
        if running, batch.count < Self.batchSize {
            batch += pending().prefix(Self.batchSize - batch.count)
                .map { (src: $0, name: $0.deletingPathExtension().lastPathComponent) }
        }
        guard !batch.isEmpty else { return }
        priority.removeFirst(fromPriority)
        busy = true
        let webpFolder = Paths.webpFolder(app.liveFolderURL)
        let phone = app.settings.phoneFolder.hasSuffix("/") ? app.settings.phoneFolder : app.settings.phoneFolder + "/"
        let tether = app.settings.tether
        Log.info("ADB: sending batch of \(batch.count)")

        sendQueue.async {
            var ready: [(jpg: URL, webp: URL)] = []
            try? FileManager.default.ensureDirectory(webpFolder)
            for (k, item) in batch.enumerated() {
                let jpg = item.src
                // The camera may still be writing.
                guard FileReady.isComplete(jpg) else {
                    Task { @MainActor in Log.info("ADB: \(jpg.lastPathComponent) still writing — next round") }
                    continue
                }
                let webp = webpFolder.appendingPathComponent(item.name + ".webp")
                // Class-named WebP are always made fresh (an older set may have used the same name).
                if k < fromPriority || !FileManager.default.fileExists(atPath: webp.path) {
                    do {
                        let t0 = Date()
                        guard let image = Imaging.full(jpg) else { throw AppError.cannotRead(jpg.lastPathComponent) }
                        let data = try ImageExport.webpData(image, quality: 50)
                        try ImageExport.writeAtomically(data, to: webp)
                        Task { @MainActor in Log.ok("WebP: \(webp.lastPathComponent) (\(image.width)×\(image.height), \(data.count / 1024) KB, \(String(format: "%.1f", Date().timeIntervalSince(t0)))s)") }
                    } catch {
                        Task { @MainActor in Log.error("WebP \(jpg.lastPathComponent): \(error.localizedDescription)") }
                        continue
                    }
                }
                ready.append((jpg, webp))
            }

            var pushedNames: [String] = []
            if !ready.isEmpty {
                Task { @MainActor in Log.info("ADB: pushing \(ready.count) WebP…") }
                let r = Self.run(adbPath, ["-s", serial, "push"] + ready.map(\.webp.path) + [phone])
                if r.status == 0 {
                    // The camera file counts as sent (auto-send will not send it again under its own name).
                    pushedNames = ready.map(\.jpg.lastPathComponent)
                    let shown = ready.map(\.webp.lastPathComponent).joined(separator: ", ")
                    Task { @MainActor in Log.ok("ADB: on phone: \(shown)") }
                    if tether, let last = ready.last {
                        let remote = "file://\(phone)\(last.webp.lastPathComponent)"
                        _ = Self.run(adbPath, ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW",
                                               "-d", remote, "-t", "image/webp",
                                               "-n", "\(Self.galleryPackage)/.activities.PhotoActivity"])
                    } else {
                        _ = Self.run(adbPath, ["-s", serial, "shell", "input", "swipe", "500", "200", "500", "1200", "300"])
                    }
                } else {
                    let msg = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let retry = Array(batch.prefix(fromPriority))
                    Task { @MainActor in
                        Log.error("ADB push failed: \(msg)")
                        self.priority.insert(contentsOf: retry, at: 0)
                    }
                }
            }

            let pushed = pushedNames
            Task { @MainActor in
                for name in pushed { self.sent.insert(name) }
                if !pushed.isEmpty {
                    self.saveSent()
                    Log.ok("ADB: pushed \(pushed.count) → \(phone) (\(pushed.joined(separator: ", ")))")
                    if tether { Log.info("ADB: opened on phone (tether)") }
                }
                self.busy = false
                self.updatePending()
            }
        }
    }
}

enum Paths {
    static func webpFolder(_ live: URL) -> URL { WorkPaths.webp(in: live) }
}
