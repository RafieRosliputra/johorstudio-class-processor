import SwiftUI
import AppKit

/// CAMERA tab: Sony A7R II over USB with gphoto2. Shots land in LIVEFOLDER by themselves.
struct CameraTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tether: CameraTether
    @Environment(\.uiScale) private var s

    private var statusColor: Color {
        switch tether.status {
        case .off: return .gray
        case .notInstalled: return .red
        case .waiting: return .orange
        case .connecting: return .yellow
        case .connected: return Theme.statusGreen
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 30 * s) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16 * s) {
                    section("1. Camera tether (USB, gphoto2)") {
                        Button(tether.isOn ? "STOP TETHER" : "START TETHER") { tether.toggle() }
                            .buttonStyle(PanelButtonStyle(highlighted: tether.isOn))
                            .disabled(tether.gphotoPath == nil)
                        HStack(spacing: 8) {
                            StatusDot(color: statusColor)
                            Text(tether.statusText).font(.headline)
                            if tether.busy { ProgressView().controlSize(.small) }
                        }
                        HStack(spacing: 10) {
                            Button("SHOOT") { tether.shoot() }
                                .buttonStyle(PanelButtonStyle(prominent: tether.connected))
                                .disabled(!tether.connected)
                                .help("Fire the camera from the Mac")
                            Button("OPEN LIVEFOLDER") { NSWorkspace.shared.open(app.liveFolderURL) }
                                .buttonStyle(PanelButtonStyle())
                        }
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow {
                                Text("Camera").foregroundStyle(.secondary)
                                Text(tether.model ?? "—")
                            }
                            GridRow {
                                Text("Photos go to").foregroundStyle(.secondary)
                                Text(app.liveFolderURL.path)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            GridRow {
                                Text("This session").foregroundStyle(.secondary)
                                Text("\(tether.received) photo(s)").monospacedDigit()
                            }
                            GridRow {
                                Text("Last photo").foregroundStyle(.secondary)
                                Text(tether.lastFile ?? "—")
                            }
                            GridRow {
                                Text("gphoto2").foregroundStyle(.secondary)
                                Text(tether.toolText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        .font(.system(size: 13 * s))
                    }

                    section("2. Sony A7R II settings (once)") {
                        Text("""
                        • MENU › Setup › USB Connection › PC Remote. In any other mode the camera is not found.
                        • Airplane Mode ON (Wi-Fi off), and Power Save Start Time at 30 min so the camera stays awake.
                        • File format JPEG. With RAW+JPEG, the RAW files go to LIVEFOLDER/RAW and only JPGs are loaded.
                        • Set the camera's date and time: file names come from the camera clock.
                        • A short, good USB cable straight into the Mac (no hub).
                        • Close Imaging Edge, Photos and Image Capture. They take the camera away from gphoto2.
                        • Mac, once: install Homebrew, then in Terminal run: brew install gphoto2
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    }

                    section("How it works") {
                        Text("""
                        • Shoot on the camera (or press SHOOT). Each photo downloads into a hidden folder, LIVEFOLDER/.gphoto2-incoming, and is moved into LIVEFOLDER only when it is complete. The file counter, Load Photo and ADB auto-send see it as usual.
                        • Names: 20261021-101530-000.jpg. They sort in shooting order, so "photo 1 and the next 5" still works. Do not mix with photos copied in from a card in the same LIVEFOLDER.
                        • Nothing is deleted from the camera's memory card.
                        • macOS grabs cameras as they are plugged in (ptpcamerad). While the tether is looking for the camera, the app stops that every second, so Photos and Image Capture cannot import from cameras or iPhones then.
                        • Unplugged, or the camera turned off? The app keeps retrying every 3 s and reconnects by itself.
                        • The tether stays ON across restarts until you press STOP TETHER.
                        """)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(width: 620 * s)

            LogBox()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 30 * s)
        .padding(.bottom, 20 * s)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10 * s) {
            Text(title).font(.system(size: 16 * s, weight: .bold))
            content()
        }
        .padding(14 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12 * s).fill(Theme.panel))
    }
}
