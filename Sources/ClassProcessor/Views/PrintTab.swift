import SwiftUI
import AppKit

struct PrintTab: View {
    @EnvironmentObject var app: AppState
    @Environment(\.uiScale) private var s

    var body: some View {
        HStack(alignment: .top, spacing: 30 * s) {
            VStack(spacing: 18 * s) {
                BigPreview()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                SmallStrip()
                    .frame(height: 150 * s)
            }
            .frame(maxWidth: .infinity)
            RightPanel()
                .frame(width: 440 * s)
        }
        .padding(.horizontal, 30 * s)
        .padding(.bottom, 20 * s)
        .alert("Purge printer queue?", isPresented: $app.confirmPurge) {
            Button("Cancel", role: .cancel) {}
            Button("PURGE", role: .destructive) { app.purgePrinter() }
        } message: {
            Text("Every job in the default printer's queue will be deleted. Files in PRINTS and the hotfolder are not touched.")
        }
    }
}

// MARK: - Big preview (photo 1 + master1 + class name)

struct BigPreview: View {
    @EnvironmentObject var app: AppState
    @StateObject private var dragStart = Box<CGPoint?>(nil)
    @Environment(\.uiScale) private var s

    var body: some View {
        GeometryReader { geo in
            let canvas = Imaging.canvas
            let k = min(geo.size.width / canvas.width, geo.size.height / canvas.height)
            let dw = canvas.width * k, dh = canvas.height * k
            ZStack(alignment: .topLeading) {
                Color.white
                if let main = app.photos.first, let cg = main.preview {
                    let area = app.photoArea
                    let pr = Imaging.photoRect(photo: main.size, area: area, zoom: app.settings.zoom, offset: app.offset)
                    // Drawn inside a Canvas exactly the size of the photo area: a zoomed photo must never
                    // become a view bigger than the preview, or it covers the tabs / buttons
                    // (the "ADB tab / PROCESS can't be pressed" bug).
                    Canvas { ctx, _ in
                        let r = CGRect(x: (pr.minX - area.minX) * k, y: (pr.minY - area.minY) * k,
                                       width: pr.width * k, height: pr.height * k)
                        ctx.draw(Image(decorative: cg, scale: 1).resizable().interpolation(.high), in: r)
                    }
                    .frame(width: area.width * k, height: area.height * k)
                    .position(x: area.midX * k, y: area.midY * k)
                    .allowsHitTesting(false)
                } else {
                    Color(white: 0.15)
                }
                if let master = app.masters[0] {
                    Image(decorative: master, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: dw, height: dh)
                        .allowsHitTesting(false)
                }
                if let text = app.textImage {
                    let tr = Imaging.textRect(text: CGSize(width: text.width, height: text.height),
                                              area: app.settings.textArea.cgRect, scale: app.settings.textScale)
                    Image(decorative: text, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: tr.width * k, height: tr.height * k)
                        .position(x: tr.midX * k, y: tr.midY * k)
                        .allowsHitTesting(false)
                }
                if app.photos.isEmpty {
                    Text(app.loading ? "loading…" : "no photo loaded")
                        .font(.system(size: 34 * s, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .frame(width: dw, height: dh)
                        .allowsHitTesting(false)
                }
                PanZoomCatcher(
                    previewURL: app.photos.first?.url,
                    onBegin: { dragStart.value = app.offset },
                    onDrag: { t in
                        guard let start = dragStart.value else { return }
                        app.setOffset(CGPoint(x: start.x + t.width / k, y: start.y + t.height / k))
                    },
                    onEnd: { dragStart.value = nil },
                    onScroll: { ticks, p in
                        app.zoom(ticks: ticks, anchor: CGPoint(x: p.x / k, y: p.y / k))
                    }
                )
                .frame(width: dw, height: dh)
                .allowsHitTesting(!app.photos.isEmpty && !app.processing)
            }
            .frame(width: dw, height: dh)
            .clipped()
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(Color(white: 0.5), lineWidth: 1).allowsHitTesting(false))
            .help("Click: Quick Look • drag to move • scroll to resize (applies to every photo when processed)")
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// Mouse drag + scroll wheel on the big preview (top-left view points).
struct PanZoomCatcher: NSViewRepresentable {
    var previewURL: URL?
    var onBegin: () -> Void
    var onDrag: (CGSize) -> Void
    var onEnd: () -> Void
    var onScroll: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        update(v)
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) { update(nsView) }

    private func update(_ v: CatcherView) {
        v.onBegin = onBegin
        v.onDrag = onDrag
        v.onEnd = onEnd
        v.onScroll = onScroll
        v.previewURL = previewURL
    }

    final class CatcherView: QuickLookView {
        var onBegin: () -> Void = {}
        var onDrag: (CGSize) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onScroll: (Double, CGPoint) -> Void = { _, _ in }
        private var start: CGPoint?
        private var moved = false
        private var preciseAccum = 0.0

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            moved = false
            NSCursor.closedHand.push()
            onBegin()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let p = convert(event.locationInWindow, from: nil)
            if abs(p.x - start.x) > 3 || abs(p.y - start.y) > 3 { moved = true }
            guard moved else { return }
            onDrag(CGSize(width: p.x - start.x, height: p.y - start.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard let s0 = start else { return }
            let p = convert(event.locationInWindow, from: nil)
            if !moved, abs(p.x - s0.x) > 3 || abs(p.y - s0.y) > 3 {
                // Drag without intermediate events (fast flick): still a move, not a click.
                moved = true
                onDrag(CGSize(width: p.x - s0.x, height: p.y - s0.y))
            }
            start = nil
            NSCursor.pop()
            onEnd()
            // A click without dragging = Quick Look.
            if !moved { toggleQuickLook() }
        }

        override func scrollWheel(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            // Same direction whatever "natural scrolling" is set to: wheel up / away = bigger.
            let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                // Trackpad / Magic Mouse: every 10 points = 1 notch.
                preciseAccum += dy
                let ticks = (preciseAccum / 10).rounded(.towardZero)
                if ticks != 0 {
                    preciseAccum -= ticks * 10
                    onScroll(ticks, p)
                }
            } else if dy != 0 {
                onScroll(dy > 0 ? 1 : -1, p)
            }
        }
    }
}

// MARK: - Small photos 2–6 (right-click = red / skip)

struct SmallStrip: View {
    @EnvironmentObject var app: AppState
    @Environment(\.uiScale) private var s

    var body: some View {
        HStack(spacing: 22 * s) {
            ForEach(1..<AppState.setSize, id: \.self) { i in
                SmallBox(index: i)
            }
        }
    }
}

struct SmallBox: View {
    @EnvironmentObject var app: AppState
    let index: Int
    @Environment(\.uiScale) private var s

    var body: some View {
        let photo = index < app.photos.count ? app.photos[index] : nil
        let isRed = app.red.contains(index)
        ZStack {
            Color(white: 0.18)
            if let cg = photo?.preview {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .allowsHitTesting(false)
            } else {
                Text("\(index + 1)").font(.system(size: 28 * s, weight: .bold)).foregroundStyle(Color(white: 0.35))
            }
            if isRed {
                Color.red.opacity(0.65).allowsHitTesting(false)
            }
            RightClickCatcher(previewURL: photo?.url, action: { app.toggleRed(index) })
        }
        .aspectRatio(3 / 2, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if let photo {
                Text(isRed ? "SKIP" : photo.url.lastPathComponent)
                    .font(.system(size: 10 * s, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .foregroundStyle(.white)
            }
        }
        .help("Click: Quick Look • right-click: red (not used)")
        .frame(maxWidth: .infinity)
    }
}

/// Small box: click = Quick Look, right-click (or ctrl-click) = red.
struct RightClickCatcher: NSViewRepresentable {
    var previewURL: URL?
    var action: () -> Void

    func makeNSView(context: Context) -> CatchView {
        let v = CatchView()
        v.action = action
        v.previewURL = previewURL
        return v
    }

    func updateNSView(_ nsView: CatchView, context: Context) {
        nsView.action = action
        nsView.previewURL = previewURL
    }

    final class CatchView: QuickLookView {
        var action: () -> Void = {}
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with event: NSEvent) { action() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) {
                action()
            } else {
                toggleQuickLook()
            }
        }
    }
}

/// Takes ONLY right-clicks; left clicks fall through to the button underneath.
struct RightClickOnly: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> RView {
        let v = RView()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: RView, context: Context) { nsView.action = action }

    final class RView: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp: return super.hitTest(point)
            default: return nil
            }
        }
        override func rightMouseDown(with event: NSEvent) { action() }
    }
}

// MARK: - Right panel

struct RightPanel: View {
    @EnvironmentObject var app: AppState
    @StateObject private var showTextArea = Box(false)
    @Environment(\.uiScale) private var s

    var body: some View {
        VStack(spacing: 10 * s) {
            HStack(spacing: 10 * s) {
                VStack(spacing: 2) {
                    Button("Directory") { app.chooseLiveFolder() }
                        .buttonStyle(PanelButtonStyle())
                    small(AppState.shortPath(app.liveFolderURL))
                }
                VStack(spacing: 2) {
                    Button("HOTFOLDER") { app.chooseHotfolder() }
                        .buttonStyle(PanelButtonStyle())
                    small(app.hotfolderURL.map(AppState.shortPath) ?? "not selected")
                }
            }

            Button(app.loading ? "Loading…" : "Load Photo") { app.loadPhotoPanel() }
                .buttonStyle(PanelButtonStyle())
                .disabled(app.loading || app.processing)

            // Master File (overlay) + what was loaded
            VStack(spacing: 4 * s) {
                HStack(spacing: 6) {
                    Button("Master File (overlay)") { app.chooseMaster() }
                        .buttonStyle(PanelButtonStyle())
                    Button {
                        showTextArea.value = true
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 16 * s))
                    }
                    .buttonStyle(.plain)
                    .help("Class name text position (X/Y/W/H on the 1800×1200 master)")
                    .popover(isPresented: $showTextArea.value) {
                        AreaEditor(title: "Class name text area", area: $app.settings.textArea, defaultArea: .textDefault)
                            .padding()
                    }
                }
                VStack(spacing: 1) {
                    ForEach(app.masterLines, id: \.self) { line in
                        Text(line)
                            .foregroundStyle(line.contains("MISSING") || line.contains("missing") ? Color.red : Color.primary)
                    }
                }
                .font(.system(size: 12 * s))
            }
            .padding(8 * s)
            .background(RoundedRectangle(cornerRadius: 10 * s).fill(Theme.panel))

            // Class name
            HStack(spacing: 10 * s) {
                Button("CLASS NAME") { app.choosePSB() }
                    .buttonStyle(PanelButtonStyle())
                    .help(app.settings.psbPath ?? "Choose textLayer.psb")
                Button {
                    Task { await app.refreshText() }
                } label: {
                    ZStack {
                        if app.renderingText {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 20 * s, weight: .bold))
                        }
                    }
                    .frame(width: 48 * s, height: 40 * s)
                    .background(RoundedRectangle(cornerRadius: 10 * s).fill(app.textOutdated ? Color.orange : Color.white))
                    .foregroundStyle(Color.black)
                }
                .buttonStyle(.plain)
                .disabled(app.renderingText)
                .help("Update the class name in Photoshop (textLayer.psb)")
            }
            HStack(spacing: 6 * s) {
                TextField("CLASS NAME", text: Binding(get: { app.settings.className }, set: { app.setClassName($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 18 * s, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.black)
                    .padding(.vertical, 6 * s)
                    .background(RoundedRectangle(cornerRadius: 8 * s).fill(Color.white))
                    .onSubmit { Task { await app.refreshText() } }
                // Text layer size (%) and position
                TextField("", value: $app.settings.textScale, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 48 * s)
                    .help("Class name text size %")
                Text("%").font(.system(size: 13 * s))
                HStack(spacing: 2) {
                    nudge("arrow.left", dx: -1, dy: 0)
                    nudge("arrow.up", dx: 0, dy: -1)
                    nudge("arrow.down", dx: 0, dy: 1)
                    nudge("arrow.right", dx: 1, dy: 0)
                }
            }
            small(app.textOutdated
                  ? "\(app.psbName) — press refresh (now: \(app.settings.renderedName ?? "none"))"
                  : "\(app.psbName) — \(app.settings.renderedName ?? "")")

            // Scroll size
            HStack(spacing: 8 * s) {
                Text("scroll size %").font(.system(size: 16 * s))
                TextField("", value: $app.settings.scrollStep, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 56 * s)
                Spacer()
                Text("size \(Int((app.settings.zoom * 100).rounded()))%")
                    .font(.system(size: 13 * s, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Fill") { app.resetPlacement() }
                    .help("Back to 100% (fill), centred")
            }

            HStack(spacing: 10 * s) {
                Button(app.processing ? "WORKING…" : "PROCESS FILES") {
                    Task { await app.process(printSamples: false) }
                }
                .buttonStyle(PanelButtonStyle(prominent: true))
                Button("PRINT SAMPLES") {
                    Task { await app.process(printSamples: true) }
                }
                .buttonStyle(PanelButtonStyle())
                Button {
                    NSWorkspace.shared.open(app.paths.prints)
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 26 * s))
                        .foregroundStyle(Color.yellow)
                }
                .buttonStyle(.plain)
                .help("Open PRINTS")
            }
            .disabled(app.processing || app.photos.isEmpty)

            LogBox()
                .frame(maxHeight: .infinity)

            HStack(spacing: 10 * s) {
                Button(app.hasCopies ? "RESET & RENAME" : "RESET PHOTO") { app.resetPhotos() }
                    .buttonStyle(PanelButtonStyle(highlighted: app.hasCopies))
                    .help(app.hasCopies
                          ? "Renamed copies are in DONE: camera originals → Trash, unload, class name → XXX"
                          : "Unload the photos, class name → XXX")
                    .disabled(app.processing)
                Button("PURGE PRINTER") { app.confirmPurge = true }
                    .overlay(RightClickOnly { app.openPrinterQueue() })
                    .help("Click: purge the queue • right-click: open the printer queue")
                    .buttonStyle(PanelButtonStyle(destructive: true))
            }
        }
    }

    /// Move the class name text by 5 px (option-click: 1 px, shift-click: 20 px).
    private func nudge(_ icon: String, dx: Double, dy: Double) -> some View {
        Button {
            let flags = NSEvent.modifierFlags
            let step = flags.contains(.option) ? 1.0 : (flags.contains(.shift) ? 20.0 : 5.0)
            app.nudgeText(dx: dx * step, dy: dy * step)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11 * s, weight: .bold))
                .frame(width: 22 * s, height: 26 * s)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlColor)))
        }
        .buttonStyle(.plain)
        .help("Move class name text (x \(Int(app.settings.textArea.x)), y \(Int(app.settings.textArea.y))) — option: 1px, shift: 20px")
    }

    private func small(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * s))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }
}
