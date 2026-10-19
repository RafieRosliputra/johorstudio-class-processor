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
                    ZStack(alignment: .topLeading) {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: pr.width * k, height: pr.height * k)
                            .position(x: pr.midX * k, y: pr.midY * k)
                    }
                    .frame(width: dw, height: dh)
                    .mask(
                        Rectangle()
                            .frame(width: area.width * k, height: area.height * k)
                            .position(x: area.midX * k, y: area.midY * k)
                    )
                } else {
                    Color(white: 0.15)
                }
                if let master = app.masters[0] {
                    Image(decorative: master, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: dw, height: dh)
                }
                if let text = app.textImage {
                    let tr = Imaging.textRect(text: CGSize(width: text.width, height: text.height), area: app.settings.textArea.cgRect)
                    Image(decorative: text, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: tr.width * k, height: tr.height * k)
                        .position(x: tr.midX * k, y: tr.midY * k)
                }
                if app.photos.isEmpty {
                    Text(app.loading ? "loading…" : "no photo loaded")
                        .font(.system(size: 34 * s, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .frame(width: dw, height: dh)
                }
                PanZoomCatcher(
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
            .overlay(Rectangle().stroke(Color(white: 0.5), lineWidth: 1))
            .help("Drag to move • scroll to resize (applies to every photo when processed)")
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }
}

/// Mouse drag + scroll wheel on the big preview (top-left view points).
struct PanZoomCatcher: NSViewRepresentable {
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
    }

    final class CatcherView: NSView {
        var onBegin: () -> Void = {}
        var onDrag: (CGSize) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onScroll: (Double, CGPoint) -> Void = { _, _ in }
        private var start: CGPoint?
        private var preciseAccum = 0.0

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            NSCursor.closedHand.push()
            onBegin()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let p = convert(event.locationInWindow, from: nil)
            onDrag(CGSize(width: p.x - start.x, height: p.y - start.y))
        }

        override func mouseUp(with event: NSEvent) {
            start = nil
            NSCursor.pop()
            onEnd()
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
            } else {
                Text("\(index + 1)").font(.system(size: 28 * s, weight: .bold)).foregroundStyle(Color(white: 0.35))
            }
            if isRed {
                Color.red.opacity(0.65)
            }
            RightClickCatcher { app.toggleRed(index) }
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
        .help("Right-click to skip / use this photo")
        .frame(maxWidth: .infinity)
    }
}

struct RightClickCatcher: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> CatchView {
        let v = CatchView()
        v.action = action
        return v
    }

    func updateNSView(_ nsView: CatchView, context: Context) { nsView.action = action }

    final class CatchView: NSView {
        var action: () -> Void = {}
        override func rightMouseDown(with event: NSEvent) { action() }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { action() }
        }
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
            TextField("CLASS NAME", text: Binding(get: { app.settings.className }, set: { app.setClassName($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 18 * s, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.black)
                .padding(.vertical, 6 * s)
                .background(RoundedRectangle(cornerRadius: 8 * s).fill(Color.white))
                .onSubmit { Task { await app.refreshText() } }
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
                Button("RESET PHOTO") { app.resetPhotos() }
                    .buttonStyle(PanelButtonStyle())
                    .disabled(app.processing)
                Button("PURGE PRINTER") { app.confirmPurge = true }
                    .buttonStyle(PanelButtonStyle(destructive: true))
            }
        }
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
