import SwiftUI
import AppKit

struct ADBTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var adb: ADBManager
    @StateObject private var confirmClear = Box(false)
    @StateObject private var confirmForget = Box(false)
    @Environment(\.uiScale) private var s

    var body: some View {
        HStack(alignment: .top, spacing: 30 * s) {
            VStack(alignment: .leading, spacing: 16 * s) {
                section("1. ADB server & device") {
                    Button("RESET SERVER (kill-server & start-server)") { adb.restartServer() }
                        .buttonStyle(PanelButtonStyle())
                    HStack(spacing: 10) {
                        Picker("Device", selection: Binding(
                            get: { app.settings.adbSerial ?? "" },
                            set: { app.settings.adbSerial = $0.isEmpty ? nil : $0 }
                        )) {
                            if adb.devices.isEmpty { Text("No device").tag("") }
                            if let serial = app.settings.adbSerial, !adb.devices.contains(serial) {
                                Text("\(serial) (not connected)").tag(serial)
                            }
                            ForEach(adb.devices, id: \.self) { Text($0).tag($0) }
                        }
                        Button {
                            adb.refreshDevices(quiet: false)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    HStack(spacing: 10) {
                        Text("Wireless ADB IP")
                        TextField("192.168.x.x:5555", text: $app.settings.wirelessIP)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                        Button("Connect") { adb.connectWireless() }
                    }
                    HStack(spacing: 8) {
                        StatusDot(color: adb.connected ? Theme.statusGreen : .red)
                        Text(adb.statusText).font(.headline)
                    }
                }

                section("2. Auto send LIVEFOLDER → phone") {
                    Button(adb.running ? "STOP SENDING" : "START SENDING") { adb.toggle() }
                        .buttonStyle(PanelButtonStyle(highlighted: adb.running))
                    Text("Every new JPG → full size WebP (quality 50) in LIVEFOLDER/WEBP → pushed \(ADBManager.batchSize) at a time. Files already sent are skipped (adb-sent.json).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 20) {
                        Text("Waiting: \(adb.pendingCount)")
                        Text("Sent: \(adb.sentCount)")
                        if adb.busy {
                            ProgressView().controlSize(.small)
                            Text("sending…").foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    HStack(spacing: 10) {
                        Text("Phone folder")
                        TextField("/sdcard/Downloads/", text: $app.settings.phoneFolder)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    HStack(spacing: 10) {
                        Text("Restart gallery every")
                        TextField("", value: $app.settings.gallerySeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Text("sec")
                    }
                    .onChange(of: app.settings.gallerySeconds) { _, _ in adb.scheduleGallery() }
                    Toggle("Tether mode (open each sent file in Simple Gallery Pro, no auto restart)", isOn: $app.settings.tether)
                        .onChange(of: app.settings.tether) { _, _ in adb.scheduleGallery() }
                }

                section("3. Phone") {
                    HStack(spacing: 10) {
                        Button("PULL DOWN REFRESH") { adb.swipeRefresh() }
                            .buttonStyle(PanelButtonStyle())
                        Button("RESTART GALLERY") { adb.restartGallery() }
                            .buttonStyle(PanelButtonStyle())
                        Button("SCRCPY") { adb.launchScrcpy() }
                            .buttonStyle(PanelButtonStyle())
                    }
                    .disabled(!adb.connected)
                    HStack(spacing: 10) {
                        Button("FORGET SENT RECORD") { confirmForget.value = true }
                            .buttonStyle(PanelButtonStyle())
                        Button("CLEAR PHONE FOLDER") { confirmClear.value = true }
                            .buttonStyle(PanelButtonStyle(destructive: true))
                            .disabled(!adb.connected)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 620 * s)

            LogBox()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 30 * s)
        .padding(.bottom, 20 * s)
        .alert("Clear phone folder?", isPresented: $confirmClear.value) {
            Button("Cancel", role: .cancel) {}
            Button("DELETE", role: .destructive) { adb.clearPhoneFolder() }
        } message: {
            Text("Everything in \(app.settings.phoneFolder) on the phone will be deleted.")
        }
        .alert("Forget sent record?", isPresented: $confirmForget.value) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { adb.forgetSent() }
        } message: {
            Text("Every JPG still in LIVEFOLDER will be sent to the phone again.")
        }
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
