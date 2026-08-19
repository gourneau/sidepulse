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
    /// Poll LEDS.LED while the DSL tab is open, so edits made by anything else on
    /// the machine show up without pressing Reload.
    @State private var autoReload = false
    /// The text as last loaded from the device. While `rawText` still equals this,
    /// the editor holds no unsaved work and auto-reload may replace it; once the
    /// user types, it stops so their edit is never yanked out from under them.
    @State private var loadedText = ""
    @State private var lastReloadAt: Date?
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var statusFlash = false
    @State private var heartBeating = false
    @State private var colorEditMetric: String?

    enum Tab: String, CaseIterable, Identifiable {
        case color = "Color"
        case perLED = "Per-LED"
        case presets = "Presets"
        case modes = "Modes"
        case advanced = "DSL"
        case awake = "Awake"
        var id: String { rawValue }
    }

    private var ledCount: Int { device.selectedDevice?.ledCount ?? 8 }

    /// `perLEDColors` starts at 8 and only grows through `bindingForLED`, while
    /// `ledCount` is data derived from the device. Every read of the array has to go
    /// through here or a device reporting more than 8 LEDs traps on the grid.
    private func ledColor(_ i: Int) -> Color {
        i < perLEDColors.count ? perLEDColors[i] : .white
    }

    /// Size the colour array to the connected strip. Called when the selection
    /// changes, so the grid and the emitted program always agree.
    private func fitPerLEDColors() {
        if perLEDColors.count < ledCount {
            perLEDColors.append(contentsOf:
                Array(repeating: .white, count: ledCount - perLEDColors.count))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if device.hungDriverDetected { hungDriverBanner }
            else if device.deviceGhosted { ghostedBanner }
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
                case .awake: awakeTab
                }
            }
        }
        .padding(14)
        .frame(width: 460)
        .onChange(of: device.status) { _ in flashStatus() }
        .onChange(of: color) { _ in if tab == .color { liveSend() } }
        .onChange(of: perLEDColors) { _ in if tab == .perLED { liveSend() } }
        .onChange(of: brightness) { _ in liveSend() }
        .onChange(of: device.selectedID) { _ in
            fitPerLEDColors()
            if selectedLED >= ledCount { selectedLED = 0 }
            if tab == .advanced { reloadProgram() }
        }
        .onChange(of: device.currentProgram) { newValue in
            guard let newValue else { return }
            if awaitingReload {
                rawText = newValue
                loadedText = newValue
                awaitingReload = false
                lastReloadAt = Date()
                return
            }
            // An auto-reload landed. Only adopt it if the editor is untouched.
            guard autoReload, newValue != loadedText else { return }
            lastReloadAt = Date()
            if rawText == loadedText { rawText = newValue }
            loadedText = newValue
        }
        // Only fires while the popover is open and this tab is showing, so the
        // polling stops the moment the user looks away.
        .onReceive(Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()) { _ in
            guard autoReload, tab == .advanced, device.selectedDevice != nil else { return }
            device.loadCurrentProgram()
        }
    }

    // MARK: - Status dot helpers

    /// Color of the top-left dot: device connection, tinted by the last result.
    private var dotColor: Color {
        if device.anyDeviceStuck { return .red }
        if let level = device.status?.level {
            if level == .error { return .red }
            if level == .warning { return .orange }
        }
        return device.devices.isEmpty ? .gray : .green
    }

    /// Hover text for the dot: connection + what last happened.
    private var statusTooltip: String {
        var parts: [String] = []
        parts.append(device.devices.isEmpty
            ? "No device connected"
            : "Connected: \(device.selectedDevice?.displayName ?? "device") (\(ledCount) LEDs)")
        if let st = device.status {
            parts.append("\(st.text) \(relative(st.date))")
        }
        return parts.joined(separator: " · ")
    }

    /// Briefly pulse the dot when something happens (an update/error).
    private func flashStatus() {
        statusFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { statusFlash = false }
    }

    private func reloadProgram() {
        awaitingReload = true
        device.loadCurrentProgram()
    }

    /// Passwordless repair via the helper, then re-detect the device.
    private func runRepair() {
        wake.repair { device.afterRepair() }
    }

    private var hungDriverBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("macOS's FAT driver is stuck (this also hangs Finder). Repair it?")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Repair") { runRepair() }.disabled(wake.repairBusy)
        }
        .padding(8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Card is in the reader but never mounted. Two flavours: a normal ghost
    /// (Repair can re-probe) and the half-ejected hardware state (only a sleep/
    /// wake re-probe or a physical re-seat can clear it).
    private var ghostedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sdcard").foregroundStyle(.orange)
            Text(device.ghostEjected
                 ? "Card stuck half-ejected in the reader — macOS won’t mount it. Restart the Mac to recover (no software fix is possible)."
                 : "Device detected but not mounted — macOS didn’t enumerate it.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if !device.ghostEjected {
                Button("Repair") { runRepair() }.disabled(wake.repairBusy)
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Open the spec window and force it in front of the menu-bar popover (an
    /// accessory app otherwise opens it behind, which looks wrong).
    private func openSpec() {
        // Become a regular app so the window can come to the front of the
        // menu-bar popover (SpecView reverts to accessory when it closes).
        NSApp.setActivationPolicy(.regular)
        openWindow(id: SpecWindow.id)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let w = NSApp.windows.first(where: { $0.title == SpecWindow.title }) {
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }

    /// Open the 24h activity window (pre-filtered) and bring it to the front,
    /// same front-bring-up dance as the spec window.
    private func openActivity(_ filter: ActivityFilter) {
        device.activityFilter = filter
        NSApp.setActivationPolicy(.regular)
        openWindow(id: ActivityWindow.id)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let w = NSApp.windows.first(where: { $0.title == ActivityWindow.title }) {
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
            let colors = (0..<ledCount).map { Optional(ledColor($0)) }
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
            HStack(spacing: 8) {
                // Status dot: connection + flashes on each update; hover for detail.
                Circle().fill(dotColor)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.quaternary))
                    .scaleEffect(statusFlash ? 1.8 : 1.0)
                    .animation(.easeOut(duration: 0.45), value: statusFlash)
                    .help(statusTooltip + " · click for activity")
                    .pointingCursor()
                    .onTapGesture { openActivity(.events) }

                deviceLabel

                Spacer()

                sharingBadge

                if device.devices.isEmpty {
                    Button { runRepair() } label: {
                        if wake.repairBusy { ProgressView().controlSize(.mini) }
                        else { Text("Reconnect").font(.caption) }
                    }
                    .disabled(wake.repairBusy)
                }

                settingsMenu

                heartView
            }
            if device.contended && !device.observerMode {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.red)
                    Text("Another tool is writing to this device too — you're overwriting each other.")
                        .font(.caption2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Stand back") { device.observerMode = true }.font(.caption2)
                }
            }
            if device.anyDeviceStuck {
                Label("Device not responding — use Repair (gear menu) to recover.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Tells the user, without being asked, whether the app is currently writing to
    /// the shared device on a timer — the state that collides with anything else
    /// driving it — or deliberately standing back.
    @ViewBuilder
    private var sharingBadge: some View {
        if device.observerMode {
            Label("Observing", systemImage: "eye")
                .font(.caption2).foregroundStyle(.blue)
                .help("The app isn't writing to the device, so other tools can drive it freely. The keepalive still runs — it touches a separate file the firmware never reads.")
                .pointingCursor()
                .onTapGesture { device.observerMode = false }
        } else if device.contended {
            // The loudest state: we keep writing, something else keeps overwriting,
            // and the LEDs flicker between two programs while neither side wins.
            Label("Contested", systemImage: "arrow.left.arrow.right")
                .font(.caption2.bold()).foregroundStyle(.red)
                .help("Something else on this Mac keeps replacing what this app writes to LEDS.LED, and this app keeps replacing it back. The LEDs will flicker between the two. Click to stand back (Observer mode).")
                .pointingCursor()
                .onTapGesture { device.observerMode = true }
        } else if device.isWritingContinuously {
            Label("Writing", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2).foregroundStyle(.orange)
                .help("Info mode rewrites LEDS.LED every \(Int(device.cycleInterval))s. If an AI agent, MCP server or script is also driving this device, you'll fight over it. Click to stop writing (Observer mode).")
                .pointingCursor()
                .onTapGesture { device.observerMode = true }
        }
    }

    @ViewBuilder
    private var deviceLabel: some View {
        if device.devices.isEmpty {
            Text("No device").foregroundStyle(.secondary)
        } else if device.devices.count == 1, let d = device.selectedDevice {
            Text("\(d.displayName) · \(d.ledCount) LEDs").help("Mounted as \(d.name)")
        } else {
            Picker(selection: Binding(
                get: { device.selectedID ?? device.selectedDevice?.id ?? "" },
                set: { device.selectedID = $0 }
            )) {
                ForEach(device.devices) { d in
                    // Raw mount name kept alongside, so the Finder correspondence
                    // stays visible when more than one unit is attached.
                    Text("\(d.displayName) · \(d.name) · \(d.ledCount) LEDs").tag(d.id)
                }
            } label: { EmptyView() }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
    }

    /// Beating heart in the header (keepalive). Hover for last/next details.
    private var heartView: some View {
        let connected = !device.devices.isEmpty
        return Image(systemName: connected ? "heart.fill" : "heart.slash.fill")
            .foregroundStyle(connected ? Color.pink : Color.red)
            .scaleEffect(connected ? (heartBeating ? 1.15 : 0.9) : 1.0)
            .animation(connected
                       ? .easeInOut(duration: 0.85).repeatForever(autoreverses: true)
                       : .default,
                       value: heartBeating)
            .onAppear { heartBeating = true }
            .onChange(of: connected) { nowConnected in
                // Restart the beat animation when a device (re)connects after the
                // view already appeared — otherwise it stays frozen at rest.
                if nowConnected { heartBeating = false
                    DispatchQueue.main.async { heartBeating = true } }
            }
            .help(heartbeatDetail)
            .pointingCursor()
            .onTapGesture { openActivity(.keepalive) }
    }

    /// Header gear menu for app-level settings (no longer at the bottom of tabs).
    private var settingsMenu: some View {
        Menu {
            Text("SidePulse \(appVersion)")
            // The firmware's own readout, from the STATUS.TXT the keepalive
            // already reads each beat — no extra device I/O to show it.
            if let status = device.deviceStatus {
                if let version = status.firmwareVersion { Text("Firmware \(version)") }
                if let detail = firmwareDetail(status) { Text(detail) }
            }
            Divider()
            // INIT.LED is replayed on power-up, which is what actually survives the
            // SD reader powering the card down after a few idle minutes.
            Button("Save current LEDs as power-on default") {
                device.saveCurrentAsStartup()
            }
            .disabled(!device.canSaveStartup)
            Divider()
            Toggle("Observer mode — don't write to the device", isOn: $device.observerMode)
            Divider()
            Button("Reconnect / repair device") { runRepair() }
                .disabled(wake.repairBusy)
            Toggle("Auto-repair when wedged", isOn: $device.autoRepair)
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { loginEnabled },
                set: { loginEnabled = LoginItem.setEnabled($0) }
            ))
            // Quitting writes off to LEDS.LED only; INIT.LED is deliberately left
            // alone, so a saved power-on default still comes back on next power-up.
            Toggle("Turn off LEDs when quitting", isOn: $device.ledsOffOnQuit)
            Divider()
            Button("Quit SidePulse") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Uptime / temperature / state line for the gear menu, when the device
    /// reported any of them.
    private func firmwareDetail(_ status: DeviceStatus) -> String? {
        var parts: [String] = []
        if let uptime = status.uptimeDescription { parts.append("up \(uptime)") }
        if let temp = status.temperatureC { parts.append(String(format: "%.1f°C", temp)) }
        if let state = status.state { parts.append(state) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The app's own version, from the bundle's Info.plist (stamped at build time
    /// by package_app.sh from the release tag; "dev" for an unsigned `swift run`).
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (s?, _): return s
        default: return "dev"
        }
    }

    private var heartbeatDetail: String {
        guard !device.devices.isEmpty else { return "No device mounted" }
        var parts = ["Device kept alive (every 1 min)"]
        if let last = device.lastHeartbeat { parts.append("last \(relative(last))") }
        if let next = device.nextHeartbeat {
            let secs = max(0, Int(next.timeIntervalSince(device.now)))
            parts.append(String(format: "next %d:%02d", secs / 60, secs % 60))
        }
        parts.append("click for keepalive log")
        return parts.joined(separator: " · ")
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
                            .fill(ledColor(i))
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

    private var chargingText: String {
        guard device.batteryCharging else { return "On battery" }
        if let w = device.batteryWatts, w > 0.1 { return String(format: "Charging · %.1f W", w) }
        return "Charging"
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        // Clickable color swatch → inline picker for this mode.
                        Button {
                            colorEditMetric = (colorEditMetric == metric.id) ? nil : metric.id
                        } label: {
                            Circle().fill(device.effectiveColor(metric.id))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.quaternary))
                        }
                        .buttonStyle(.plain)
                        .help("Click to choose this mode's color")

                        Toggle(isOn: Binding(
                            get: { device.enabledMetrics.contains(metric.id) },
                            set: { _ in activePreset = nil; device.toggleMetric(metric.id) }
                        )) {
                            HStack(spacing: 6) {
                                Label(metric.name, systemImage: metric.symbol)
                                if showing {
                                    Text("● on strip").font(.caption2).foregroundStyle(.green)
                                }
                                Spacer()
                                Text("\(Int((device.metricValues[metric.id] ?? 0) * 100))%")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    if colorEditMetric == metric.id {
                        ColorEditor(color: Binding(
                            get: { device.effectiveColor(metric.id) },
                            set: { device.setMetricColor(metric.id, $0) }
                        ))
                        .padding(.leading, 22)
                    }
                    if metric.id == "battery" && device.enabledMetrics.contains("battery") {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: device.batteryCharging ? "bolt.fill" : "bolt.slash")
                                    .font(.caption2)
                                    .foregroundStyle(device.batteryCharging ? .green : .secondary)
                                Text(chargingText).font(.caption2).foregroundStyle(.secondary)
                            }
                            Toggle("Breathe while charging", isOn: $device.batteryBreatheWhenCharging)
                                .toggleStyle(.checkbox).font(.caption2)
                            if device.batteryBreatheWhenCharging {
                                HStack(spacing: 8) {
                                    Image(systemName: "tortoise").font(.caption2).foregroundStyle(.secondary)
                                    Slider(value: $device.batteryBreatheSpeed, in: 0...1)
                                    Image(systemName: "hare").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.leading, 22)
                    }
                }
            }

            if device.infoActive {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Brightness").font(.caption)
                        Spacer()
                        Text("\(device.infoBrightness)").font(.caption).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(device.infoBrightness) },
                        set: { device.infoBrightness = Int($0) }
                    ), in: 0...255, step: 1)
                }
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
                if !device.observerMode {
                    Label("This rewrites LEDS.LED continuously. If another tool is driving the device, turn on Observer mode.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if device.observerMode {
                Label("Observer mode is on — modes won't reach the device.",
                      systemImage: "eye")
                    .font(.caption2).foregroundStyle(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Advanced tab

    private var advancedTab: some View {
        let validation = LEDProgram.validate(rawText)
        // One shared count, so the label can never disagree with `validate`.
        let (bytes, lines) = LEDProgram.stats(rawText)
        let busy = device.isWriting(device.selectedDevice)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(device.selectedDevice.map { "Live \($0.ledsURL.lastPathComponent) on \($0.name)" }
                     ?? "LEDS.LED")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { reloadProgram() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(device.selectedDevice == nil || busy)
                Toggle("Auto", isOn: $autoReload)
                    .toggleStyle(.checkbox).font(.caption)
                    .disabled(device.selectedDevice == nil)
                    .help("Re-read LEDS.LED every couple of seconds while this tab is open, so changes made by anything else on this Mac show up here. Your edits are never overwritten — it pauses as soon as you type.")
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
                // The counter can only express the byte/line limits; a bad duration
                // would otherwise just grey out Send with no reason given.
                Text(validation.message
                     ?? "\(bytes)/\(LEDProgram.maxBytes) bytes · \(lines)/\(LEDProgram.maxLines) lines")
                    .font(.caption2)
                    .foregroundStyle(validation.isValid ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if busy { Text("Writing…").font(.caption2).foregroundStyle(.secondary) }
                else if let detail = autoReloadDetail {
                    Text(detail).font(.caption2).foregroundStyle(
                        device.programChangedExternally ? Color.orange : Color.secondary)
                }
                Button("Set as power-on") { device.saveAsStartup(rawText) }
                    .disabled(!validation.isValid || busy || device.selectedDevice == nil)
                    .help("Write this to INIT.LED, the program the device replays every time it powers up.")
                Button("Send") { activePreset = nil; device.send(rawText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validation.isValid || busy)
            }
        }
        .onAppear {
            if !didInitialLoad { didInitialLoad = true; reloadProgram() }
        }
    }

    /// What auto-reload is currently seeing: whether the file on the device still
    /// matches what we wrote, and whether the editor is holding unsaved edits.
    private var autoReloadDetail: String? {
        guard autoReload else { return nil }
        if rawText != loadedText { return "Paused — you have unsaved edits" }
        if device.programChangedExternally { return "Changed by another tool" }
        return lastReloadAt == nil ? "Watching…" : "In sync"
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

    // MARK: - Awake tab

    private var awakeTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Big, glanceable status of the real sleep behavior.
            HStack(spacing: 9) {
                Circle().fill(awakeColor).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.quaternary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(awakeTitle).font(.callout.bold())
                    Text(awakeSubtitle).font(.caption2).foregroundStyle(.secondary)
                    // Always present (just changes text) so turning keep-awake on
                    // doesn't insert a line and reflow the tab. Monospaced digits
                    // keep the counter from jiggling as the numbers change.
                    Text(awakeDurationLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(wake.awakeSince == nil ? Color.secondary : Color.green)
                }
            }
            .help(awakeTitle + " — " + awakeSubtitle)

            Divider()

            Toggle(isOn: $wake.keepAwake) {
                Label("Keep Mac awake", systemImage: "cup.and.saucer")
            }
            .toggleStyle(.checkbox).font(.caption)
            .help("Stops the Mac sleeping while idle (lid open). No permission needed.")

            Toggle(isOn: Binding(
                get: { wake.lidClosed },
                set: { wake.setLidClosed($0) }
            )) {
                HStack(spacing: 4) {
                    Label("Keep awake with lid closed", systemImage: "laptopcomputer")
                    if wake.lidClosedBusy { ProgressView().controlSize(.mini) }
                }
            }
            .toggleStyle(.checkbox).font(.caption)
            .disabled(wake.lidClosedBusy)
            .help("Prevents sleep even when the lid is shut. First time asks you to approve the helper in System Settings → Login Items; then it's instant.")

            if wake.lidClosed {
                Text("Mac won't sleep even with the lid closed — keep it on power; can run warm.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = wake.lidClosedError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Toggle("Turn LEDs off when the Mac sleeps", isOn: $device.ledsOffOnSleep)
                .toggleStyle(.checkbox).font(.caption)
                .help("Switch the LEDs off as the Mac sleeps and restore them on wake.")
            Text("Otherwise the LED device keeps its last colors until USB power cuts, a few moments after the Mac sleeps.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var awakeTitle: String {
        if wake.lidClosed { return "Awake — even with lid closed" }
        if wake.keepAwake { return "Awake — while lid is open" }
        return "Normal sleep"
    }

    private var awakeSubtitle: String {
        if wake.lidClosed { return "The Mac will not sleep at all" }
        if wake.keepAwake { return "Closing the lid will still sleep" }
        return "The Mac sleeps normally"
    }

    private var awakeColor: Color {
        if wake.lidClosed { return .orange }
        if wake.keepAwake { return .green }
        return .gray
    }

    /// The always-present third status line: a live counter when keeping awake,
    /// a neutral label otherwise (so the layout never reflows on toggle).
    private var awakeDurationLine: String {
        if let since = wake.awakeSince { return "Keeping awake for \(awakeDuration(since))" }
        return "Not keeping awake"
    }

    /// Human "1h 23m" / "4m 12s" since keep-awake turned on. Driven by device.now.
    private func awakeDuration(_ since: Date) -> String {
        let secs = max(0, Int(device.now.timeIntervalSince(since)))
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
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

extension View {
    /// Show the pointing-hand cursor on hover so users know the view is clickable.
    func pointingCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
