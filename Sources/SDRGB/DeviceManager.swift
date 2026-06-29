import SwiftUI
import AppKit

/// A mounted sdstatusbar device (one volume).
struct Device: Identifiable, Equatable, Sendable {
    let volumeURL: URL
    let name: String
    let ledCount: Int

    var id: String { volumeURL.path }
    var ledsURL: URL { volumeURL.appendingPathComponent("LEDS.TXT") }
    var statusURL: URL { volumeURL.appendingPathComponent("STATUS.TXT") }

    static func == (a: Device, b: Device) -> Bool { a.volumeURL == b.volumeURL }
}

/// Outcome of an isolated I/O operation.
enum IOResult: Sendable { case ok, failed, stuck }

/// A user-facing status message with severity, for the UI banner.
struct AppStatus: Equatable, Sendable {
    enum Level: Sendable { case success, info, warning, error }
    let level: Level
    let text: String
    let date: Date
}

/// A live system readout that can be shown on the strip (one color per metric).
struct Metric: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let color: Color
    let hex: String
    let read: () -> Double
}

/// Discovers sdstatusbar volumes, writes LED programs, and keeps every connected
/// device alive by touching a dedicated heartbeat file every 2 minutes.
@MainActor
final class DeviceManager: ObservableObject {
    /// How often we touch the heartbeat file. The whole point of the app.
    static let heartbeatInterval: TimeInterval = 120

    /// Known volume name → LED count. Unknown matching volumes default to 2.
    /// `SidePulse` is the 8-LED strip; `PulseDot` is the 2-LED dot.
    nonisolated static let knownLEDCounts: [String: Int] = ["SidePulse": 8, "PulseDot": 2]

    @Published private(set) var devices: [Device] = []
    @Published var selectedID: String?
    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var lastHeartbeatOK = false
    @Published private(set) var nextHeartbeat: Date?
    /// Latest user-facing status (success/info/warning/error) for the UI banner.
    @Published private(set) var status: AppStatus?
    /// The program currently on the selected device's LEDS.TXT (read on demand).
    @Published private(set) var currentProgram: String?

    private func setStatus(_ level: AppStatus.Level, _ text: String) {
        status = AppStatus(level: level, text: text, date: Date())
    }

    private var heartbeatTimer: Timer?
    private var tickTimer: Timer?
    private var metricsTimer: Timer?
    /// Coalesces rapid live edits (slider drags) into at most one write per beat.
    private var pendingWrite: DispatchWorkItem?

    /// Schedules the (brief) work of launching the isolated I/O child process,
    /// off the main thread. The actual device I/O happens inside that child, not
    /// here — so a wedge can never block this queue for more than `ioTimeout`.
    private let ioQueue = DispatchQueue(label: "com.gourneau.SDRGB.io", qos: .utility)
    /// `.leds` = a manual program (shows success); `.info` = an Info-mode frame
    /// (silent on success, so cycling doesn't spam); `.keepalive` = a read.
    private enum WriteKind { case leds, info, keepalive }

    /// True while a write/read to that device is outstanding (UI "Writing…").
    func isWriting(_ device: Device?) -> Bool {
        guard let device else { return false }
        return inFlightVolumes.contains(device.volumeURL.path)
    }

    /// Per-device single-flight: at most one I/O op is ever outstanding per
    /// volume, so a stuck device can't stack up work. A volume whose op exceeds
    /// `ioTimeout` is marked "stuck" and skipped until the device reconnects.
    private var inFlightVolumes: Set<String> = []
    /// Volumes whose I/O is paused because the device stopped responding.
    @Published private(set) var stuckVolumes: Set<String> = []
    var anyDeviceStuck: Bool { !stuckVolumes.isEmpty }
    /// If an isolated I/O child doesn't finish within this long, the device is
    /// treated as wedged: the child is abandoned (contained) and I/O pauses.
    nonisolated static let ioTimeout: TimeInterval = 5
    /// Drives the "next in mm:ss" countdown without re-touching the card.
    @Published private(set) var now = Date()

    // MARK: Info mode (multiplexed metrics)

    /// Default seconds between metric samples / Info-mode cycles.
    static let defaultCycleInterval: TimeInterval = 5
    /// User-set time each metric stays on the strip before cycling (clamped 2…30).
    /// Also the metric sampling cadence. Changing it restarts the metrics timer.
    @Published private(set) var cycleInterval: TimeInterval = DeviceManager.defaultCycleInterval

    func setCycleInterval(_ seconds: Double) {
        let v = min(30, max(2, seconds))
        guard v != cycleInterval else { return }
        cycleInterval = v
        metricsTimer?.invalidate()
        startMetrics()
    }

    private let sysMetrics = SystemMetrics()
    /// Enabled metric ids, in display order. Non-empty == Info mode is active.
    @Published var enabledMetrics: [String] = []
    /// Latest sampled value per metric id (0...1), for the UI readout.
    @Published private(set) var metricValues: [String: Double] = [:]
    /// Last program pushed by Info mode, so we only write when it changes.
    private var lastInfoProgram: String?
    /// Which enabled metric is currently shown (advances each sample tick).
    private var cycleIndex = 0
    @Published private(set) var displayedMetricID: String?

    /// Available metrics. Battery = white, CPU = blue, Memory = green.
    private(set) lazy var metrics: [Metric] = [
        Metric(id: "battery", name: "Battery", symbol: "battery.100",
               color: .white, hex: "#ffffff") { [weak self] in self?.sysMetrics.batteryLevel() ?? 0 },
        Metric(id: "cpu", name: "CPU", symbol: "cpu",
               color: .blue, hex: "#0040ff") { [weak self] in self?.sysMetrics.cpuLoad() ?? 0 },
        Metric(id: "memory", name: "Memory", symbol: "memorychip",
               color: .green, hex: "#00ff00") { [weak self] in self?.sysMetrics.memoryUsed() ?? 0 }
    ]

    var infoActive: Bool { !enabledMetrics.isEmpty }

    var selectedDevice: Device? {
        devices.first { $0.id == selectedID } ?? devices.first
    }

    init() {
        rescan()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        nc.addObserver(self, selector: #selector(didWake),
                       name: NSWorkspace.didWakeNotification, object: nil)
        startHeartbeat()
        startTick()
        startMetrics()
        // Detect connected devices (off-thread); the scan handler beats them.
        rescan()
    }

    // MARK: - Detection

    @objc private func volumesChanged() {
        // A mount/unmount means a (possibly wedged) device went away or came
        // back — recover: clear stuck/in-flight tracking and resume.
        stuckVolumes.removeAll()
        inFlightVolumes.removeAll()
        rescan()
    }

    @objc private func didWake() {
        // Resume cadence promptly after sleep.
        startHeartbeat()
        rescan()
    }

    /// Scan every mounted volume for an sdstatusbar device. Runs the (potentially
    /// blocking) filesystem work off the main thread, then applies on main.
    func rescan() {
        ioQueue.async { [weak self] in
            let found = DeviceManager.scanVolumes()
            Task { @MainActor in self?.applyScan(found) }
        }
    }

    /// The blocking part of detection — safe to run on a background thread even
    /// if a stale mount hangs on it.
    nonisolated static func scanVolumes() -> [Device] {
        let fm = FileManager.default
        let vols = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        var found: [Device] = []
        for vol in vols {
            let leds = vol.appendingPathComponent("LEDS.TXT")
            let status = vol.appendingPathComponent("STATUS.TXT")
            // A device exposes LEDS.TXT alongside the firmware's STATUS.TXT.
            guard fm.fileExists(atPath: leds.path),
                  fm.fileExists(atPath: status.path) else { continue }
            let name = vol.lastPathComponent
            let count = knownLEDCounts[name] ?? 2
            found.append(Device(volumeURL: vol, name: name, ledCount: count))
        }
        return found.sorted { $0.name < $1.name }
    }

    private func applyScan(_ found: [Device]) {
        let changed = found != devices
        devices = found
        // Keep selection valid, preferring the 8-LED device by default.
        if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
            selectedID = found.max(by: { $0.ledCount < $1.ledCount })?.id
        }
        // Keep newly connected devices alive right away and refresh Info mode.
        if changed { beat() }
        if infoActive { showInfoFrame(advance: false, force: true) }
    }

    // MARK: - Writing LED programs

    /// Validate and write a program to the selected device's LEDS.TXT.
    @discardableResult
    private func deliver(_ program: String, kind: WriteKind = .leds) -> LEDProgram.Validation {
        let validation = LEDProgram.validate(program)
        guard validation.isValid else {
            setStatus(.error, validation.message ?? "Invalid program.")
            return validation
        }
        guard let device = selectedDevice else {
            setStatus(.error, "No device connected — plug in SidePulse or PulseDot.")
            return validation
        }
        let ledsURL = device.ledsURL
        let text = program + "\n"
        enqueueIO(kind: kind, volume: device.volumeURL.path) {
            DeviceManager.performWrite(text, to: ledsURL)
        }
        return validation
    }

    /// A manual program (color/preset/raw). Takes over from Info mode and writes
    /// immediately. Returns the validation outcome so the UI can surface errors.
    @discardableResult
    func send(_ program: String) -> LEDProgram.Validation {
        clearInfo()
        pendingWrite?.cancel()
        return deliver(program)
    }

    /// A manual program from a live control (slider drag). Debounced so rapid
    /// edits collapse into roughly one SD write every 200 ms — gentle on the
    /// device's small mass-storage firmware.
    func sendLive(_ program: String) {
        clearInfo()
        let validation = LEDProgram.validate(program)
        guard validation.isValid else { setStatus(.error, validation.message ?? "Invalid program."); return }
        guard selectedDevice != nil else {
            setStatus(.error, "No device connected — plug in SidePulse or PulseDot."); return
        }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in _ = self?.deliver(program) }
        }
        pendingWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - Info mode (multiplexed metrics)

    /// Turn a metric on/off. Enabling any metric activates Info mode; turning the
    /// last one off returns to manual (the LEDs hold their last frame).
    func toggleMetric(_ id: String) {
        if let idx = enabledMetrics.firstIndex(of: id) {
            enabledMetrics.remove(at: idx)
        } else {
            enabledMetrics.append(id)
        }
        cycleIndex = 0
        if infoActive { showInfoFrame(advance: false, force: true) } else { clearInfo() }
    }

    /// Drop all metrics (used when a manual program takes over).
    private func clearInfo() {
        if !enabledMetrics.isEmpty { enabledMetrics.removeAll() }
        lastInfoProgram = nil
        displayedMetricID = nil
        cycleIndex = 0
    }

    private func startMetrics() {
        sampleMetrics()
        let t = Timer(timeInterval: cycleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleMetrics()
                self?.showInfoFrame(advance: true)
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        metricsTimer = t
    }

    /// Sample every metric once (the sole caller of `cpuLoad()`, so its delta
    /// window stays consistent) and publish for the UI.
    private func sampleMetrics() {
        var values: [String: Double] = [:]
        for metric in metrics { values[metric.id] = metric.read() }
        metricValues = values
    }

    /// Show the current metric across the whole strip, cycling to the next one
    /// each tick when more than one metric is enabled. Writes only when the
    /// program changes, to spare the SD card needless writes.
    private func showInfoFrame(advance: Bool, force: Bool = false) {
        guard infoActive, let device = selectedDevice else { return }
        let count = enabledMetrics.count
        guard count > 0 else { return }
        if advance { cycleIndex += 1 }
        let id = enabledMetrics[cycleIndex % count]
        displayedMetricID = id
        guard let metric = metrics.first(where: { $0.id == id }) else { return }
        let program = LEDProgram.fullBar(hex: metric.hex,
                                         value: metricValues[id] ?? 0,
                                         ledCount: device.ledCount)
        if !force && program == lastInfoProgram { return }
        lastInfoProgram = program
        deliver(program, kind: .info)
    }

    // MARK: - Heartbeat (keepalive)

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.beat() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
        nextHeartbeat = Date().addingTimeInterval(Self.heartbeatInterval)
    }

    private func startTick() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    /// Keep every connected device alive with a gentle **read** of STATUS.TXT
    /// (rather than a write). Any host I/O keeps the USB/SD link active, and a
    /// read is far less likely to wedge the device's tiny mass-storage firmware
    /// than a write — and it never disturbs the running LED animation.
    func beat() {
        for device in devices {
            enqueueIO(kind: .keepalive, volume: device.volumeURL.path) {
                DeviceManager.performRead(device.statusURL)
            }
        }
        // lastHeartbeat / lastHeartbeatOK are set when a read actually succeeds.
        nextHeartbeat = Date().addingTimeInterval(Self.heartbeatInterval)
    }

    /// Force an immediate heartbeat (used by the "Beat now" button).
    func beatNow() {
        startHeartbeat()
        beat()
    }

    // MARK: - Isolated I/O (a wedge gets stuck in a child process, never the app)

    /// Run an isolated I/O op for `volume`, single-flight. The `op` closure runs
    /// on a background thread and launches a child process that does the actual
    /// device I/O with a hard timeout, so a wedge is contained in that child —
    /// the app stays responsive and can still quit cleanly.
    private func enqueueIO(kind: WriteKind, volume: String,
                           _ op: @escaping @Sendable () -> IOResult) {
        guard !stuckVolumes.contains(volume), !inFlightVolumes.contains(volume) else { return }
        inFlightVolumes.insert(volume)
        ioQueue.async { [weak self] in
            let result = op()
            Task { @MainActor in self?.finishIO(kind: kind, volume: volume, result: result) }
        }
    }

    private func finishIO(kind: WriteKind, volume: String, result: IOResult) {
        inFlightVolumes.remove(volume)
        let name = deviceName(forVolume: volume)
        switch result {
        case .stuck:
            stuckVolumes.insert(volume)
            setStatus(.warning, "\(name) stopped responding — I/O paused. Unplug and replug to recover.")
        case .failed:
            switch kind {
            case .leds, .info:
                setStatus(.error, "Couldn’t write to \(name) — it may have been unplugged or full. Reconnect and try again.")
            case .keepalive:
                lastHeartbeatOK = false
            }
        case .ok:
            switch kind {
            case .leds:
                setStatus(.success, "Updated \(name).")
            case .info:
                // Cycling shouldn't spam success; clear any stale error/warning.
                if let level = status?.level, level == .error || level == .warning { status = nil }
            case .keepalive:
                lastHeartbeat = Date(); lastHeartbeatOK = true
            }
        }
    }

    private func deviceName(forVolume volume: String) -> String {
        devices.first { $0.volumeURL.path == volume }?.name ?? "the device"
    }

    // MARK: - Reading the live program

    /// Read the program currently on the selected device's LEDS.TXT into
    /// `currentProgram`, via an isolated child (single-flight, respects stuck).
    func loadCurrentProgram() {
        guard let device = selectedDevice else {
            currentProgram = nil
            setStatus(.error, "No device connected — plug in SidePulse or PulseDot.")
            return
        }
        let vol = device.volumeURL.path
        guard !stuckVolumes.contains(vol), !inFlightVolumes.contains(vol) else { return }
        let url = device.ledsURL
        let name = device.name
        inFlightVolumes.insert(vol)
        ioQueue.async { [weak self] in
            let (result, text) = DeviceManager.readContents(url)
            Task { @MainActor in
                guard let self else { return }
                self.inFlightVolumes.remove(vol)
                switch result {
                case .ok:
                    self.currentProgram = text ?? ""
                case .stuck:
                    self.stuckVolumes.insert(vol)
                    self.setStatus(.warning, "\(name) stopped responding — I/O paused. Unplug and replug to recover.")
                case .failed:
                    self.setStatus(.error, "Couldn’t read \(name). Is it still mounted?")
                }
            }
        }
    }

    /// Write `text` to `url` via an isolated child: stage on local disk first
    /// (safe/fast), then have the child copy it onto the device, strip the
    /// provenance xattr, and remove any AppleDouble `._` companion.
    nonisolated static func performWrite(_ text: String, to url: URL) -> IOResult {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sdrgb-\(UUID().uuidString).txt")
        guard let data = text.data(using: .utf8), (try? data.write(to: tmp)) != nil else {
            return .failed
        }
        // `cat > dest` truncates+writes; bail if it fails so the exit status
        // reflects the write, then best-effort clean xattrs and the `._` sibling.
        let script = #"""
        cat "$1" > "$2" || exit 1
        xattr -c "$2" 2>/dev/null
        rm -f "$(dirname "$2")/._$(basename "$2")" 2>/dev/null
        exit 0
        """#
        let result = runIsolated(script, [tmp.path, url.path], timeout: ioTimeout)
        if result != .stuck { try? FileManager.default.removeItem(at: tmp) }
        return result
    }

    /// Read a few bytes of `url` via an isolated child — the gentle keepalive.
    nonisolated static func performRead(_ url: URL) -> IOResult {
        runIsolated(#"head -c 64 "$1" > /dev/null 2>&1"#, [url.path], timeout: ioTimeout)
    }

    /// Read the full (tiny) contents of `url` via an isolated child, capturing
    /// stdout. Returns `.stuck` if it hangs (the child is abandoned, contained).
    nonisolated static func readContents(_ url: URL) -> (IOResult, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", #"cat "$1""#, "sh", url.path]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return (.failed, nil) }
        if done.wait(timeout: .now() + ioTimeout) == .timedOut {
            proc.terminate()
            return (.stuck, nil)
        }
        guard proc.terminationStatus == 0 else { return (.failed, nil) }
        // The file is ≤512 B, well under the pipe buffer, so the child has
        // already exited; reading to EOF returns promptly.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (.ok, String(data: data, encoding: .utf8) ?? "")
    }

    /// Run a short `/bin/sh` script (with positional args $1, $2, …) in a child
    /// process, waiting at most `timeout`. Returns `.stuck` if it doesn't finish
    /// — the child is then abandoned (a D-state child can't be killed, but it's
    /// fully contained and never blocks the app).
    nonisolated static func runIsolated(_ script: String, _ args: [String],
                                        timeout: TimeInterval) -> IOResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "sh"] + args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return .failed }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()   // best-effort; contained even if it can't be killed
            return .stuck
        }
        return proc.terminationStatus == 0 ? .ok : .failed
    }
}
