import SwiftUI
import AppKit

enum Theme {
    static let background = Color(white: 0.23)
    static let panel = Color(white: 0.30)
    static let statusGreen = Color(red: 0.35, green: 0.95, blue: 0.2)
}

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HeaderBar(adb: app.adb, tether: app.tether)
                Group {
                    switch app.tab {
                    case .print: PrintTab()
                    case .adb: ADBTab(adb: app.adb)
                    case .camera: CameraTab(tether: app.tether)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .environment(\.uiScale, UIScale.factor(for: geo.size))
        }
        .background(Theme.background)
        .frame(minWidth: 1000, minHeight: 650)
        .onAppear { app.start() }
        .alert(
            app.alert?.title ?? "",
            isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }),
            presenting: app.alert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }
}

struct HeaderBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var adb: ADBManager
    @ObservedObject var tether: CameraTether
    @Environment(\.uiScale) private var s

    var body: some View {
        ZStack {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("JohorStudio.com").font(.system(size: 22 * s, weight: .bold))
                Text("Class PROCESSOR").font(.system(size: 22 * s)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            HStack(alignment: .top) {
                HStack(spacing: 10 * s) {
                    TabButton(.print)
                    TabButton(.adb)
                    TabButton(.camera)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(adb.statusText)
                        .foregroundStyle(adb.connected ? Theme.statusGreen : .red)
                    Text("\(app.liveCount) file\(app.liveCount == 1 ? "" : "s") in LIVEFOLDER")
                        .foregroundStyle(app.liveCount > 0 ? Theme.statusGreen : .secondary)
                    if tether.isOn {
                        Text(tether.connected ? "camera \(tether.model ?? "") connected" : "camera waiting")
                            .foregroundStyle(tether.connected ? Theme.statusGreen : .orange)
                            .help(tether.statusText)
                    }
                }
                .font(.system(size: 15 * s, weight: .medium))
                .help(app.liveFolderURL.path)
            }
        }
        .padding(.horizontal, 24 * s)
        .padding(.vertical, 12 * s)
    }
}

struct TabButton: View {
    @EnvironmentObject var app: AppState
    @Environment(\.uiScale) private var s
    let tab: MainTab

    init(_ tab: MainTab) { self.tab = tab }

    var body: some View {
        let selected = app.tab == tab
        Button {
            app.tab = tab
        } label: {
            Text(tab.rawValue)
                .font(.system(size: 18 * s, weight: .medium))
                .frame(width: 100 * s, height: 40 * s)
                .background(Rectangle().fill(selected ? Color.accentColor : Color(white: 0.45)))
                .overlay(Rectangle().stroke(Color(white: 0.6), lineWidth: 1))
                .foregroundStyle(Color.white)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Black log box (PRINT and ADB tabs); everything is also in root/log/YYYY-MM-DD.log.
struct LogBox: View {
    @ObservedObject private var store = LogStore.shared
    @Environment(\.uiScale) private var s

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func color(_ level: LogLevel) -> Color {
        switch level {
        case .info: return .white
        case .ok: return Theme.statusGreen
        case .warn: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        let entries = store.entries.suffix(400)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(entries) { e in
                        Text("\(Self.time.string(from: e.date))  \(e.message)")
                            .foregroundStyle(color(e.level))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(e.id)
                    }
                }
                .font(.system(size: 11 * s, design: .monospaced))
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 10 * s).fill(Color.black))
            .clipShape(RoundedRectangle(cornerRadius: 10 * s))
            .onChange(of: store.entries.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = store.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}
