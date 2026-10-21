import Foundation
import Combine

/// USB tether for a Sony A7R II (or any camera gPhoto2 can drive) through the `gphoto2`
/// command line tool from Homebrew (`brew install gphoto2`), on Apple Silicon.
///
/// One long-running process does the work:
///
///     gphoto2 --port usb:… --capture-tethered --keep --hook-script <hook> --filename <staging>/%Y%m%d-%H%M%S-%03n.%C
///
/// • Every shot taken on the camera (or with SHOOT, which sends gphoto2 SIGUSR1) is downloaded
///   into a hidden staging folder, `<camera folder>/.gphoto2-incoming/`. When gphoto2 has finished
///   writing a file it runs the hook script, which prints `JBHOOK download <path>`. Only then is
///   the file moved (a rename on the same disk, so it is atomic) into the camera folder. The rest
///   of the app never sees a half-written JPG.
/// • File names come from the camera clock: `20261021-101530-000.jpg`. Sony reports every shot
///   as `capt0000.jpg` and restarts that count each session, so the camera's name cannot be used.
/// • RAW files (RAW+JPEG on the camera) go to `<camera folder>/RAW/`, so only JPGs reach the app.
/// • Nothing is deleted from the camera's memory card (`--keep`).
/// • macOS's `ptpcamerad` grabs every PTP camera the moment it is plugged in, which makes
///   gphoto2 fail with "Could not claim the USB device". Until gphoto2 has the camera it is killed
///   every second, and gphoto2 is retried every 3 seconds.
@MainActor
final class CameraTether: ObservableObject {
    enum Status: Equatable {
        case off
        case notInstalled
        case waiting(String)        // no camera yet, or retrying — with the reason
        case connecting
        case connected
    }

    @Published private(set) var status: Status = .off
    /// The user wants the tether on (CAMERA checkbox). Remembered in settings.json.
    @Published private(set) var isOn = false
    @Published private(set) var model: String?
    @Published private(set) var received = 0
    @Published private(set) var lastFile: String?
    @Published private(set) var gphotoPath: String?
    @Published private(set) var version: String?

    /// Folder the photos go to; asked again at every (re)connect.
    var folder: @MainActor () -> URL = { FileManager.default.temporaryDirectory }
    /// Saves ON/OFF so the tether resumes at the next launch.
    var remember: @MainActor (Bool) -> Void = { _ in }

    private let hookScript: URL
    private var process: Process?
    private var generation = 0
    private var staging: URL?
    private var stderrTail: [String] = []
    private var lastProblem: String?
    private var retryTimer: Timer?
    private var killTimer: Timer?
    private var restarting = false

    static let stagingName = ".gphoto2-incoming"
    static let rawFolderName = "RAW"
    private static let hookMarker = "JBHOOK download "

    init(appName: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        hookScript = caches
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("gphoto2-hook.sh")
    }

    var connected: Bool { status == .connected }

    var busy: Bool {
        switch status {
        case .connecting: return true
        case .waiting: return isOn
        default: return false
        }
    }

    var statusText: String {
        switch status {
        case .off: return gphotoPath == nil ? "gphoto2 not installed" : "Camera tether off"
        case .notInstalled: return "gphoto2 not installed — brew install gphoto2"
        case .waiting(let reason): return reason
        case .connecting: return "Connecting to \(model ?? "camera")…"
        case .connected: return "\(model ?? "Camera") connected"
        }
    }

    var toolText: String {
        guard let gphotoPath else { return "Not found — Terminal: brew install gphoto2" }
        let name = version.map { "gphoto2 " + $0 } ?? "gphoto2"
        return "\(name) — \(gphotoPath)"
    }

    // MARK: - Lifecycle

    /// Finds gphoto2, stops a tether left running by a crashed session, and resumes if it was on.
    func startup(resume: Bool) {
        gphotoPath = GPhoto2.find()
        guard let path = gphotoPath else {
            status = .notInstalled
            Log.warn("gphoto2 not found — camera tether (CAMERA tab) unavailable. Install in Terminal: brew install gphoto2")
            return
        }
        let hook = hookScript.path
        gphotoQueue.async { [weak self] in
            let orphans = GPhoto2.stopOrphans(hook: hook)
            let version = GPhoto2.version(path)
            Task { @MainActor in
                guard let self else { return }
                self.version = version.gphoto2
                Log.ok("gphoto2 \(version.gphoto2 ?? "?") (libgphoto2 \(version.lib ?? "?")) — \(path)")
                if orphans > 0 { Log.warn("Stopped \(orphans) gphoto2 tether(s) left running by the last session") }
                if resume {
                    Log.info("Camera tether was ON last time — starting it again")
                    self.start()
                }
            }
        }
    }

    func toggle() {
        isOn ? stop() : start()
    }

    func start() {
        guard !isOn else { return }
        guard gphotoPath != nil else {
            status = .notInstalled
            Log.error("gphoto2 not installed — in Terminal run: brew install gphoto2")
            return
        }
        isOn = true
        remember(true)
        received = 0
        lastFile = nil
        lastProblem = nil
        status = .waiting("Looking for the camera…")
        Log.info("Camera tether ON — photos go to \(folder().path)")
        startKiller()
        if process != nil {
            // Turned back on while the last session is still stopping: reconnect when it has quit.
            restarting = true
        } else {
            connect()
        }
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        remember(false)
        restarting = false
        retryTimer?.invalidate()
        retryTimer = nil
        stopKiller()
        guard let p = process, p.isRunning else {
            process = nil
            status = .off
            Log.info("Camera tether OFF")
            return
        }
        status = .waiting("Stopping…")
        // SIGINT: gphoto2 finishes the current download, releases the camera and quits.
        p.interrupt()
        let pid = p.processIdentifier
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if p.isRunning { p.terminate() }        // a second signal makes gphoto2 abort
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// The camera folder changed: reconnect so new photos go to the new folder.
    func folderChanged() {
        guard isOn else { return }
        if let p = process, p.isRunning {
            Log.info("Camera folder changed — reconnecting the tether")
            restarting = true
            p.interrupt()
        }
        // Not running: the next retry already uses the new folder.
    }

    /// App is quitting: release the camera now. The ON setting is kept for the next launch.
    func shutdown() {
        retryTimer?.invalidate()
        retryTimer = nil
        stopKiller()
        guard let p = process, p.isRunning else { return }
        isOn = false
        p.interrupt()
        let deadline = Date().addingTimeInterval(3)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        if let staging { sweep(staging, removeTemp: false) }
    }

    /// Takes a photo from the Mac: gphoto2 triggers the shutter on SIGUSR1 while tethered.
    func shoot() {
        guard status == .connected, let p = process, p.isRunning else {
            Log.warn("SHOOT: the camera is not connected")
            return
        }
        kill(p.processIdentifier, SIGUSR1)
        Log.info("SHOOT → \(model ?? "camera")")
    }

    // MARK: - Connect / retry

    private func connect() {
        guard isOn, process == nil, let gphotoPath else { return }
        retryTimer?.invalidate()
        retryTimer = nil
        let dest = folder()
        let staging = dest.appendingPathComponent(Self.stagingName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try writeHookScript()
        } catch {
            problem("Cannot prepare \(staging.path): \(error.localizedDescription)")
            scheduleRetry()
            return
        }
        self.staging = staging
        // Photos downloaded just before a crash or a disconnect.
        sweep(staging, removeTemp: true)

        generation += 1
        let gen = generation
        gphotoQueue.async { [weak self] in
            GPhoto2.killPTPCamera()
            let found = GPhoto2.detect(gphotoPath)
            Task { @MainActor in self?.detected(found, gen: gen, staging: staging) }
        }
    }

    private func detected(_ found: GPhoto2.Camera?, gen: Int, staging: URL) {
        guard gen == generation, isOn, process == nil else { return }
        guard let found else {
            problem("No camera found — USB cable in, camera ON, MENU › Setup › USB Connection › PC Remote")
            scheduleRetry()
            return
        }
        if model != found.model {
            model = found.model
            Log.info("Camera found: \(found.model) (\(found.port))")
            if found.model.hasPrefix("Sony"), !found.model.contains("Control") {
                Log.warn("\(found.model) is not in remote mode — on the camera set MENU › Setup › USB Connection › PC Remote")
            }
        }
        launch(port: found.port, staging: staging, gen: gen)
    }

    private func launch(port: String, staging: URL, gen: Int) {
        guard let gphotoPath else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gphotoPath)
        // % is gphoto2's format character, so a % in the folder path is doubled.
        let pattern = staging.path.replacingOccurrences(of: "%", with: "%%") + "/%Y%m%d-%H%M%S-%03n.%C"
        p.arguments = [
            "--port", port,
            "--hook-script", hookScript.path,
            "--capture-tethered",
            "--keep",               // never delete anything on the camera's card
            "--force-overwrite",    // never stop to ask a question on stdin
            "--filename", pattern,
        ]
        // gphoto2 writes its temporary download file in the current directory.
        p.currentDirectoryURL = staging
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"           // English messages, so errors can be recognised
        env["LC_ALL"] = "C"
        p.environment = env
        p.standardInput = FileHandle.nullDevice

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let outLines = LineSplitter { [weak self] line in
            Task { @MainActor in self?.stdoutLine(line, gen: gen) }
        }
        let errLines = LineSplitter { [weak self] line in
            Task { @MainActor in self?.stderrLine(line, gen: gen) }
        }
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                outLines.flush()
            } else {
                outLines.feed(data)
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                errLines.flush()
            } else {
                errLines.feed(data)
            }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in
                // Let the last output lines (a final download) arrive first.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.exited(gen: gen, code: code)
            }
        }

        stderrTail = []
        do {
            try p.run()
        } catch {
            problem("Cannot start gphoto2: \(error.localizedDescription)")
            scheduleRetry()
            return
        }
        process = p
        status = .connecting
        // gphoto2 quits within a second or two when it cannot open the camera,
        // so still running after 3 s means it has the camera.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.confirm(gen: gen)
        }
    }

    private func confirm(gen: Int) {
        guard gen == generation, isOn, let p = process, p.isRunning, status != .connected else { return }
        status = .connected
        lastProblem = nil
        stopKiller()    // gphoto2 owns the camera now
        Log.ok("Camera connected: \(model ?? "camera") — shoot, photos arrive in \(folder().lastPathComponent)")
    }

    private func exited(gen: Int, code: Int32) {
        guard gen == generation else { return }
        let wasConnected = status == .connected
        let hadProcess = process != nil
        process = nil
        if let staging { sweep(staging, removeTemp: true) }
        let tail = stderrTail
        stderrTail = []
        guard isOn else {
            // stop() already reported OFF if it found gphoto2 had quit.
            if hadProcess {
                status = .off
                Log.info("Camera tether OFF")
            }
            return
        }
        if restarting {
            restarting = false
            status = .waiting("Reconnecting…")
            connect()
            return
        }
        let reason = GPhoto2.explain(tail, code: code)
        if wasConnected {
            Log.warn("Camera disconnected: \(reason)")
            lastProblem = reason
            status = .waiting(reason)
        } else {
            problem(reason)
        }
        startKiller()
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard isOn else { return }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.connect() }
        }
    }

    /// Shows the reason; logs it only when it changes (retries run every 3 s).
    private func problem(_ reason: String) {
        status = .waiting(reason)
        if reason != lastProblem {
            lastProblem = reason
            Log.warn("Camera: \(reason) — retrying every 3 s")
        }
    }

    private func startKiller() {
        guard killTimer == nil else { return }
        killTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            // Never queue up kills if one is still running.
            guard killGate.enter() else { return }
            killQueue.async {
                GPhoto2.killPTPCamera()
                killGate.leave()
            }
        }
    }

    private func stopKiller() {
        killTimer?.invalidate()
        killTimer = nil
    }

    // MARK: - Output

    private func stdoutLine(_ line: String, gen: Int) {
        if let range = line.range(of: Self.hookMarker) {
            // Always import, even from an older process: the file is finished and waiting.
            importFile(String(line[range.upperBound...]))
        } else if line.hasPrefix("Waiting for events from camera") {
            confirm(gen: gen)
        }
    }

    private func stderrLine(_ line: String, gen: Int) {
        guard gen == generation, !GPhoto2.isNoise(line) else { return }
        stderrTail.append(line)
        if stderrTail.count > 30 { stderrTail.removeFirst(stderrTail.count - 30) }
        // While connected the process keeps running, so show its problems right away
        // (for example SHOOT when the camera cannot focus).
        if status == .connected { Log.warn("gphoto2: \(line)") }
    }

    /// Moves a finished download from the staging folder into the camera folder (RAW into RAW/).
    private func importFile(_ path: String) {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: path)
        let stagingDir = src.deletingLastPathComponent()
        guard stagingDir.lastPathComponent == Self.stagingName, fm.fileExists(atPath: src.path) else { return }
        let dest = stagingDir.deletingLastPathComponent()
        let ext = src.pathExtension.lowercased()
        let isJPG = ext == "jpg" || ext == "jpeg"
        let target = isJPG ? dest : dest.appendingPathComponent(Self.rawFolderName, isDirectory: true)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let saved = GPhoto2.freeURL(for: src.lastPathComponent, in: target)
            try fm.moveItem(at: src, to: saved)
            if isJPG {
                received += 1
                lastFile = saved.lastPathComponent
                Log.ok("Camera → \(saved.lastPathComponent)")
            } else {
                Log.info("Camera RAW → \(Self.rawFolderName)/\(saved.lastPathComponent)")
            }
        } catch {
            Log.error("Cannot move \(src.lastPathComponent) out of \(Self.stagingName): \(error.localizedDescription)")
        }
    }

    /// Moves finished files left in the staging folder. Unfinished downloads (`tmpfile…`)
    /// are deleted only when gphoto2 is not running.
    private func sweep(_ staging: URL, removeTemp: Bool) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for url in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if url.lastPathComponent.hasPrefix("tmpfile") {
                if removeTemp { try? fm.removeItem(at: url) }
                continue
            }
            Log.info("Camera: recovering \(url.lastPathComponent) from \(Self.stagingName)")
            importFile(url.path)
        }
    }

    private func writeHookScript() throws {
        let script = """
        #!/bin/sh
        # Written by the app for gphoto2 --hook-script: report each finished download.
        if [ "$ACTION" = "download" ]; then
          printf '\(Self.hookMarker)%s\\n' "$ARGUMENT"
        fi
        exit 0

        """
        let fm = FileManager.default
        try fm.createDirectory(at: hookScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: hookScript, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)
    }
}

/// gphoto2 helpers that block; run them on `gphotoQueue`, never on the main thread.
private let gphotoQueue = DispatchQueue(label: "camera.gphoto2", qos: .userInitiated)
/// The once-a-second ptpcamerad kill runs on its own queue, so it keeps going during auto-detect.
private let killQueue = DispatchQueue(label: "camera.ptpcamerad", qos: .utility)
private let killGate = Gate()

/// Lets one job through at a time; others are skipped, not queued.
private final class Gate: @unchecked Sendable {
    private var busy = false
    private let lock = NSLock()

    func enter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if busy { return false }
        busy = true
        return true
    }

    func leave() {
        lock.lock()
        busy = false
        lock.unlock()
    }
}

enum GPhoto2 {
    struct Camera: Sendable {
        let model: String
        let port: String
    }

    static func find() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gphoto2",    // Homebrew, Apple Silicon
            "/usr/local/bin/gphoto2",       // Homebrew, Intel
            "/opt/local/bin/gphoto2",       // MacPorts
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func version(_ gphoto: String) -> (gphoto2: String?, lib: String?) {
        var tool: String?
        var lib: String?
        for line in run(gphoto, ["--version"]).text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            if parts[0] == "gphoto2", tool == nil { tool = String(parts[1]) }
            if parts[0] == "libgphoto2", lib == nil { lib = String(parts[1]) }
        }
        return (tool, lib)
    }

    /// First camera in `gphoto2 --auto-detect`, e.g. "Sony Alpha-A7r II (Control)" on "usb:020,028".
    static func detect(_ gphoto: String) -> Camera? {
        for line in run(gphoto, ["--auto-detect"]).text.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let range = text.range(of: #"\s+(usb:\S*|ptpip:\S*)$"#, options: .regularExpression) else { continue }
            let port = text[range].trimmingCharacters(in: .whitespaces)
            let model = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !model.isEmpty { return Camera(model: model, port: port) }
        }
        return nil
    }

    /// macOS's camera daemon: it claims PTP cameras as they are plugged in. It belongs to the
    /// logged-in user, so no admin rights are needed; launchd starts it again when needed.
    static func killPTPCamera() {
        _ = run("/usr/bin/killall", ["-9", "ptpcamerad"], timeout: 5)
    }

    /// Interrupts gphoto2 processes started with our hook script (left by a crash). Returns how many.
    static func stopOrphans(hook: String) -> Int {
        let pids = run("/bin/ps", ["-axo", "pid=,command="]).text
            .split(separator: "\n")
            .filter { $0.contains("--capture-tethered") && $0.contains(hook) }
            .compactMap { line -> Int32? in
                Int32(line.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
            }
        guard !pids.isEmpty else { return 0 }
        for pid in pids { kill(pid, SIGINT) }
        Thread.sleep(forTimeInterval: 2)
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return pids.count
    }

    /// A short reason for the screen and the log, from gphoto2's last error lines.
    static func explain(_ lines: [String], code: Int32) -> String {
        let text = lines.joined(separator: "\n")
        if text.contains("Could not claim the USB device") {
            return "macOS is holding the camera — quit Photos, Image Capture and Imaging Edge, then unplug and replug the USB cable"
        }
        if text.contains("No camera found") || text.contains("Could not detect any camera")
            || text.contains("Could not find the requested device") || text.contains("Unknown port") {
            return "Camera not found — USB cable in, camera ON, USB Connection set to PC Remote"
        }
        if text.contains("Device Busy") || text.contains("I/O in progress") {
            return "Camera busy — wait a moment, or turn the camera off and on"
        }
        if text.contains("I/O problem") || text.contains("I/O Error") || text.contains("Timeout") {
            return "USB connection problem — use a short cable straight into the Mac (no hub)"
        }
        if let line = lines.last(where: { $0.contains("*** Error (") }) ?? lines.last {
            return "gphoto2: \(line)"
        }
        return "gphoto2 stopped (exit code \(code))"
    }

    /// Decoration around gphoto2's error messages.
    static func isNoise(_ line: String) -> Bool {
        line.isEmpty
            || line.hasPrefix("*** Error ***")
            || line.hasPrefix("For debugging messages")
            || line.hasPrefix("Please make sure there is sufficient quoting")
            || line.hasPrefix("env LANG=C gphoto2")
            || line.hasPrefix("and the --debug-logfile")
    }

    /// `name.ext`, or `name (2).ext`, `name (3).ext`… when taken.
    static func freeURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    /// Runs a command and returns its exit status and output. Gives up after `timeout` seconds.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "C"
        env["LC_ALL"] = "C"
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Splits a pipe's output into lines (called from the pipe's background queue).
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(_ onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { onLine(line.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func flush() {
        lock.lock()
        let rest = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        lock.unlock()
        let line = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { onLine(line) }
    }
}
