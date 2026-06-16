import SwiftUI

struct ContentView: View {
    @EnvironmentObject var device: DeviceManager
    @EnvironmentObject var wake: WakeGuard
    @Environment(\.openWindow) private var openWindow

    @State private var tab: Tab = .color
    @State private var color: Color = .white
    @State private var brightness: Double = 255
    @State private var perLEDColors: [Color] = Array(repeating: .white, count: 8)
    @State private var selectedLED = 0
    @State private var activePreset: String?
    @State private var animatedPresets = true
    @State private var presetSpeed = 0.5
    @State private var rawText = ""
    @State private var didInitialLoad = false
    @State private var awaitingReload = false
    @State private var loginEnabled = LoginItem.isEnabled

    enum Tab: String, CaseIterable, Identifiable {
        case color = "Color"
        case perLED = "Per-LED"
        case presets = "Presets"
        case modes = "Modes"
        case advanced = "DSL"
        var id: String { rawValue }
    }

    private var ledCount: Int { device.selectedDevice?.ledCount ?? 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .color: colorTab
                case .perLED: perLEDTab
                case .presets: presetsTab
                case .modes: modesTab
                case .advanced: advancedTab
                }
            }

            if let st = device.status {
                Label(st.text, systemImage: statusIcon(st.level))
                    .font(.caption).foregroundStyle(statusColor(st.level))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(relative(st.date))
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onChange(of: color) { _ in if tab == .color { liveSend() } }
        .onChange(of: perLEDColors) { _ in if tab == .perLED { liveSend() } }
        .onChange(of: brightness) { _ in liveSend() }
        .onChange(of: device.selectedID) { _ in
            if selectedLED >= ledCount { selectedLED = 0 }
            if tab == .advanced { reloadProgram() }
        }
        .onChange(of: device.currentProgram) { newValue in
            if awaitingReload, let newValue { rawText = newValue; awaitingReload = false }
        }
    }

    // MARK: - Status helpers

    private func statusIcon(_ level: AppStatus.Level) -> String {
        switch level {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func statusColor(_ level: AppStatus.Level) -> Color {
        switch level {
        case .success: return .green
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func reloadProgram() {
        awaitingReload = true
        device.loadCurrentProgram()
    }

    /// Open the spec window and force it in front of the menu-bar popover (an
    /// accessory app otherwise opens it behind, which looks wrong).
    private func openSpec() {
        // Become a regular app so the window can come to the front of the
        // menu-bar popover (SpecView reverts to accessory when it closes).
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "spec")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let w = NSApp.windows.first(where: { $0.title == "LEDS.TXT Format" }) {
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }

    // MARK: - Live sending

    private func liveSend() {
        switch tab {
        case .color:
            activePreset = nil   // a solid color means no preset is active
            device.sendLive(LEDProgram.solid(color: color, brightness: Int(brightness)))
        case .perLED:
            activePreset = nil
            let colors = (0..<ledCount).map { Optional(perLEDColors[$0]) }
            device.sendLive(LEDProgram.perLED(colors, brightness: Int(brightness)))
        case .presets:
            // Brightness/speed/animated keep the same preset active.
            if let id = activePreset,
               let preset = LEDProgram.presets.first(where: { $0.id == id }) {
                device.sendLive(preset.make(ledCount, Int(brightness), animatedPresets, presetSpeed))
            }
        default:
            break
        }
    }

    // MARK: - Header / status

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if device.devices.isEmpty {
                Label("No device connected", systemImage: "circle.slash")
                    .foregroundStyle(.secondary)
            } else if device.devices.count == 1, let d = device.selectedDevice {
                Label("\(d.name) · \(d.ledCount) LEDs", systemImage: "circle.fill")
                    .foregroundStyle(.green)
            } else {
                Picker(selection: Binding(
                    get: { device.selectedID ?? device.selectedDevice?.id ?? "" },
                    set: { device.selectedID = $0 }
                )) {
                    ForEach(device.devices) { d in
                        Text("\(d.name) · \(d.ledCount) LEDs").tag(d.id)
                    }
                } label: {
                    Label("Device", systemImage: "circle.fill").foregroundStyle(.green)
                }
                .pickerStyle(.menu)
            }
            if device.anyDeviceStuck {
                Label("Device not responding — writes paused. Reconnect it to recover.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Small, unobtrusive keepalive line for the footer — it should just work.
    /// Static text (no ticking numbers); details are on hover.
    private var heartbeatLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "heart")
                .foregroundStyle(device.lastHeartbeatOK ? .secondary : .tertiary)
            Text(device.devices.isEmpty ? "keepalive paused" : "keepalive active")
                .foregroundStyle(.secondary)
            Button("beat") { device.beatNow() }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .help(heartbeatDetail)
    }

    private var heartbeatDetail: String {
        guard !device.devices.isEmpty else { return "No device connected." }
        var parts: [String] = []
        if let last = device.lastHeartbeat { parts.append("last kept alive \(relative(last))") }
        if let next = device.nextHeartbeat {
            let secs = max(0, Int(next.timeIntervalSince(device.now)))
            parts.append(String(format: "next in %d:%02d", secs / 60, secs % 60))
        }
        return parts.isEmpty ? "Keepalive armed." : parts.joined(separator: " · ")
    }

    private func relative(_ date: Date) -> String {
        let secs = Int(device.now.timeIntervalSince(date))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        return "\(secs / 60)m ago"
    }

    // MARK: - Color tab

    private var colorTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            ColorEditor(color: $color)
            brightnessSlider
            HStack {
                Button("Off") { activePreset = nil; device.send(LEDProgram.off()) }
                Spacer()
                Text("Live").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Per-LED tab

    private var perLEDTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 32), spacing: 6)], spacing: 6) {
                ForEach(0..<ledCount, id: \.self) { i in
                    Button { selectedLED = i } label: {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(perLEDColors[i])
                            .frame(height: 28)
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .stroke(selectedLED == i ? Color.accentColor : Color.gray.opacity(0.4),
                                        lineWidth: selectedLED == i ? 2.5 : 1))
                            .overlay(Text("\(i)").font(.caption2.bold())
                                .foregroundStyle(.white).shadow(radius: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Editing LED \(selectedLED)").font(.caption).foregroundStyle(.secondary)
            ColorEditor(color: bindingForLED(selectedLED))
            brightnessSlider
            HStack {
                Button("Off") { activePreset = nil; device.send(LEDProgram.off()) }
                Spacer()
                Text("Live").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Presets tab

    private var presetsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(LEDProgram.presets) { preset in
                    Button {
                        activePreset = preset.id
                        device.send(preset.make(ledCount, Int(brightness), animatedPresets, presetSpeed))
                    } label: {
                        Label(preset.name, systemImage: preset.symbol)
                            .frame(maxWidth: .infinity)
                    }
                    .tint(activePreset == preset.id ? .accentColor : nil)
                }
            }
            Toggle("Animated", isOn: $animatedPresets)
                .toggleStyle(.switch).font(.caption)
                .onChange(of: animatedPresets) { _ in resendActivePreset() }
            if animatedPresets {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speed").font(.caption)
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise").font(.caption2).foregroundStyle(.secondary)
                        Slider(value: $presetSpeed, in: 0...1)
                            .onChange(of: presetSpeed) { _ in resendActivePreset() }
                        Image(systemName: "hare").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            brightnessSlider
        }
    }

    private func resendActivePreset() {
        guard let id = activePreset,
              let preset = LEDProgram.presets.first(where: { $0.id == id }) else { return }
        device.send(preset.make(ledCount, Int(brightness), animatedPresets, presetSpeed))
    }

    // MARK: - Modes tab

    private var modesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show live system info on the whole strip. Enable several and it cycles between them, each filling the strip in its color to its level.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(device.metrics) { metric in
                let showing = device.infoActive && device.displayedMetricID == metric.id
                Toggle(isOn: Binding(
                    get: { device.enabledMetrics.contains(metric.id) },
                    set: { _ in activePreset = nil; device.toggleMetric(metric.id) }
                )) {
                    HStack(spacing: 8) {
                        Circle().fill(metric.color).frame(width: 11, height: 11)
                            .overlay(Circle().stroke(.quaternary))
                        Label(metric.name, systemImage: metric.symbol)
                        if showing {
                            Text("● on strip").font(.caption2)
                                .foregroundStyle(.green)
                        }
                        Spacer()
                        Text("\(Int((device.metricValues[metric.id] ?? 0) * 100))%")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }

            if device.enabledMetrics.count >= 2 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Time between modes").font(.caption)
                        Spacer()
                        Text("\(Int(device.cycleInterval))s").font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { device.cycleInterval },
                        set: { device.setCycleInterval($0) }
                    ), in: 2...30, step: 1)
                }
            }

            if device.infoActive {
                Text("Cycling every \(Int(device.cycleInterval))s. Pick a color or preset to take back manual control.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Advanced tab

    private var advancedTab: some View {
        let validation = LEDProgram.validate(rawText)
        let bytes = rawText.utf8.count
        let lines = rawText.split(separator: "\n", omittingEmptySubsequences: false).count
        let busy = device.isWriting(device.selectedDevice)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(device.selectedDevice.map { "Live LEDS.TXT on \($0.name)" } ?? "LEDS.TXT")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { reloadProgram() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(device.selectedDevice == nil || busy)
                Button { openSpec() } label: {
                    Label("Format help", systemImage: "book")
                }
                .buttonStyle(.borderless).font(.caption)
            }
            TextEditor(text: $rawText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("\(bytes)/\(LEDProgram.maxBytes) bytes · \(lines)/\(LEDProgram.maxLines) lines")
                    .font(.caption2)
                    .foregroundStyle(validation.isValid ? Color.secondary : Color.orange)
                Spacer()
                if busy { Text("Writing…").font(.caption2).foregroundStyle(.secondary) }
                Button("Send") { activePreset = nil; device.send(rawText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.isValid || busy)
            }
        }
        .onAppear {
            if !didInitialLoad { didInitialLoad = true; reloadProgram() }
        }
    }

    private var brightnessSlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Brightness").font(.caption)
                Spacer()
                Text("\(Int(brightness))").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: $brightness, in: 0...255, step: 1)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            keepAwakeControls
            heartbeatLine
            HStack {
                Toggle("Launch at login", isOn: $loginEnabled)
                    .toggleStyle(.checkbox).font(.caption)
                    .onChange(of: loginEnabled) { newValue in
                        loginEnabled = LoginItem.setEnabled(newValue)
                    }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.font(.caption)
            }
        }
    }

    private var keepAwakeControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $wake.keepAwake) {
                Label("Keep Mac awake", systemImage: "cup.and.saucer")
            }
            .toggleStyle(.checkbox).font(.caption)

            if wake.keepAwake {
                Toggle(isOn: Binding(
                    get: { wake.lidClosed },
                    set: { wake.setLidClosed($0) }
                )) {
                    HStack(spacing: 4) {
                        Text("…even with the lid closed")
                        if wake.lidClosedBusy { ProgressView().controlSize(.mini) }
                    }
                }
                .toggleStyle(.checkbox).font(.caption2)
                .padding(.leading, 16)
                .disabled(wake.lidClosedBusy)

                if wake.lidClosed {
                    Text("Mac won't sleep even with the lid closed — keep it on power; can run warm.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.leading, 16)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = wake.lidClosedError {
                    Text(err).font(.caption2).foregroundStyle(.orange)
                        .padding(.leading, 16)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bindingForLED(_ i: Int) -> Binding<Color> {
        Binding(
            get: { i < perLEDColors.count ? perLEDColors[i] : .white },
            set: { newValue in
                if perLEDColors.count < ledCount {
                    perLEDColors.append(contentsOf:
                        Array(repeating: .white, count: ledCount - perLEDColors.count))
                }
                if i < perLEDColors.count { perLEDColors[i] = newValue }
            }
        )
    }
}
