import Foundation
import Combine

/// The ADB part of the old "JohorStudio LiveFolder" app.
///
/// AUTO-SEND (START SENDING): every 5 s, each camera JPG in LIVEFOLDER (top level only) whose
/// "<name>.webp" is not on the phone yet → full size WebP (quality 50, temp file only) → pushed at once.
/// The phone's folder listing is the only record, so a restart / crash simply resumes.
/// While auto-send is on, the PRINT tab does not push anything.
///
/// Otherwise (auto-send off) the PRINT tab pushes "<class> - n.webp" (kept in LIVEFOLDER/WEBP).
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
    @Published private(set) var phoneCount = 0
    @Published private(set) var adbPath: String?

    /// Auto-send on/off as seen from the send queue (stops a long round promptly).
    private let autoFlag = LockedFlag()
    /// Loaded photos to send now as "<class> - n.webp", even when auto-send is off.
    private var priority: [(src: URL, name: String)] = []
    private var statusTimer: Timer?
    private var workTimer: Timer?
    private var galleryTimer: Timer?
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
        restartServer()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDevices(quiet: true) }
        }
        workTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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


    // MARK: - Auto send

    func toggle() {
        running ? stop() : start()
    }

    func start() {
        guard let app else { return }
        guard adbPath != nil else { Log.error("adb not installed"); return }
        running = true
        autoFlag.set(true)
        if !priority.isEmpty {
            Log.info("ADB: auto-send on — \(priority.count) PRINT-tab photo(s) dropped from the queue")
            priority.removeAll()
        }
        Log.ok("ADB auto-send started: \(app.liveFolderURL.path) → \(app.settings.phoneFolder) (every 5s, skips what is already on the phone)")
        scheduleGallery()
        kick()
    }

    func stop() {
        running = false
        autoFlag.set(false)
        galleryTimer?.invalidate()
        galleryTimer = nil
        pendingCount = priority.count
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

    func updatePending() {
        if !running { pendingCount = priority.count }
    }

    /// "TINGKATAN 1C - 3.jpg", "TINGKATAN 1C - xx (2).jpg": already renamed by RESET = already handled.
    nonisolated static func isRenamed(_ name: String) -> Bool {
        name.range(of: #"^.+ - (\d+|xx)( \(\d+\))?\.(jpe?g)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private var phonePath: String {
        let f = app?.settings.phoneFolder ?? "/sdcard/Download/"
        return f.hasSuffix("/") ? f : f + "/"
    }

    /// PRINT tab: send these photos as WebP named `name` — only while auto-send is OFF.
    func sendNow(_ items: [(src: URL, name: String)]) {
        guard adbPath != nil else { return }
        if running {
            Log.info("ADB: auto-send is on — PRINT tab does not push (camera files are sent by auto-send)")
            return
        }
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

    private func kick() {
        guard !busy, connected, adbPath != nil, serial != nil else { return }
        if running {
            autoRound()
        } else if !priority.isEmpty {
            priorityBatch()
        }
    }

    /// One auto-send round: list the phone, then send every camera JPG that is not there yet, one by one.
    private func autoRound() {
        guard let app, let adbPath, let serial else { return }
        busy = true
        let live = app.liveFolderURL
        let phone = phonePath
        let tether = app.settings.tether
        let flag = autoFlag
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("classproc-webp", isDirectory: true)

        sendQueue.async {
            func finish(_ pending: Int, _ onPhone: Int) {
                Task { @MainActor in
                    self.pendingCount = pending
                    if onPhone >= 0 { self.phoneCount = onPhone }
                    self.busy = false
                }
            }
            // 1. What is on the phone already (the only record — survives restarts and crashes).
            let ls = Self.run(adbPath, ["-s", serial, "shell", "ls -1 '\(phone)'"])
            guard ls.status == 0 else {
                let msg = ls.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { @MainActor in Log.error("ADB: cannot list \(phone): \(msg)") }
                finish(0, -1)
                return
            }
            var onPhone = Set(ls.text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })

            // 2. Camera JPGs in LIVEFOLDER (top level) not on the phone, not already renamed.
            let todo = JPGList.scan(live).filter {
                !Self.isRenamed($0.lastPathComponent)
                    && !onPhone.contains($0.deletingPathExtension().lastPathComponent + ".webp")
            }
            if todo.isEmpty {
                finish(0, onPhone.count)
                return
            }
            try? FileManager.default.ensureDirectory(tmpDir)
            var pushed = 0
            for (n, jpg) in todo.enumerated() {
                guard flag.get() else { break }
                // Still being written by the camera, or renamed/moved meanwhile: next round.
                guard FileManager.default.fileExists(atPath: jpg.path), FileReady.isComplete(jpg) else { continue }
                let name = jpg.deletingPathExtension().lastPathComponent + ".webp"
                let tmp = tmpDir.appendingPathComponent(name)
                do {
                    let t0 = Date()
                    guard let image = Imaging.full(jpg) else { throw AppError.cannotRead(jpg.lastPathComponent) }
                    let data = try ImageExport.webpData(image, quality: 50)
                    try data.write(to: tmp, options: .atomic)
                    let r = Self.run(adbPath, ["-s", serial, "push", tmp.path, phone])
                    try? FileManager.default.removeItem(at: tmp)
                    guard r.status == 0 else {
                        let msg = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in Log.error("ADB push \(name) failed: \(msg)") }
                        break
                    }
                    pushed += 1
                    onPhone.insert(name)
                    let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
                    let left = todo.count - n - 1
                    let kb = data.count / 1024
                    Task { @MainActor in
                        Log.ok("ADB: \(name) → phone (\(kb) KB, \(secs)s)\(left > 0 ? " — \(left) more" : "")")
                        self.pendingCount = left
                    }
                    if tether {
                        _ = Self.run(adbPath, ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW",
                                               "-d", "file://\(phone)\(name)", "-t", "image/webp",
                                               "-n", "\(Self.galleryPackage)/.activities.PhotoActivity"])
                    }
                } catch {
                    try? FileManager.default.removeItem(at: tmp)
                    Task { @MainActor in Log.error("WebP \(jpg.lastPathComponent): \(error.localizedDescription)") }
                }
            }
            if pushed > 0, !tether {
                _ = Self.run(adbPath, ["-s", serial, "shell", "input", "swipe", "500", "200", "500", "1200", "300"])
            }
            finish(max(0, todo.count - pushed), onPhone.count)
        }
    }

    /// PRINT tab push (auto-send off): "<class> - n.webp", kept in LIVEFOLDER/WEBP.
    private func priorityBatch() {
        guard let app, let adbPath, let serial else { return }
        priority.removeAll { !FileManager.default.fileExists(atPath: $0.src.path) }
        let batch = Array(priority.prefix(Self.batchSize))
        guard !batch.isEmpty else { return }
        priority.removeFirst(batch.count)
        busy = true
        let webpFolder = WorkPaths.webp(in: app.liveFolderURL)
        let phone = phonePath
        let tether = app.settings.tether
        Log.info("ADB: sending \(batch.count) photo(s)")

        sendQueue.async {
            var ready: [URL] = []
            try? FileManager.default.ensureDirectory(webpFolder)
            for item in batch {
                let webp = webpFolder.appendingPathComponent(item.name + ".webp")
                do {
                    let t0 = Date()
                    guard let image = Imaging.full(item.src) else { throw AppError.cannotRead(item.src.lastPathComponent) }
                    let data = try ImageExport.webpData(image, quality: 50)
                    try ImageExport.writeAtomically(data, to: webp)
                    let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
                    let kb = data.count / 1024
                    Task { @MainActor in Log.ok("WebP: \(webp.lastPathComponent) (\(kb) KB, \(secs)s)") }
                    ready.append(webp)
                } catch {
                    Task { @MainActor in Log.error("WebP \(item.src.lastPathComponent): \(error.localizedDescription)") }
                }
            }
            var failed = false
            if !ready.isEmpty {
                let r = Self.run(adbPath, ["-s", serial, "push"] + ready.map(\.path) + [phone])
                if r.status == 0 {
                    let shown = ready.map(\.lastPathComponent).joined(separator: ", ")
                    Task { @MainActor in Log.ok("ADB: on phone: \(shown)") }
                    if tether, let last = ready.last {
                        _ = Self.run(adbPath, ["-s", serial, "shell", "am", "start", "-a", "android.intent.action.VIEW",
                                               "-d", "file://\(phone)\(last.lastPathComponent)", "-t", "image/webp",
                                               "-n", "\(Self.galleryPackage)/.activities.PhotoActivity"])
                    } else {
                        _ = Self.run(adbPath, ["-s", serial, "shell", "input", "swipe", "500", "200", "500", "1200", "300"])
                    }
                } else {
                    failed = true
                    let msg = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in Log.error("ADB push failed: \(msg)") }
                }
            }
            let failedFlag = failed
            Task { @MainActor in
                if failedFlag { self.priority.insert(contentsOf: batch, at: 0) }
                self.busy = false
                self.updatePending()
            }
        }
    }
}

/// A Bool shared with the send queue.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
