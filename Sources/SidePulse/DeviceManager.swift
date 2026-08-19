import SwiftUI
import AppKit
import IOKit.ps

/// A mounted SidePulse device (one volume).
struct Device: Identifiable, Equatable, Sendable {
    let volumeURL: URL
    let name: String
    let ledCount: Int

    var id: String { volumeURL.path }
    /// The LED program the controller is running right now.
    var ledsURL: URL { volumeURL.appendingPathComponent("LEDS.LED") }
    /// The program replayed on power-up. The firmware seeds it with its startup
    /// fill, which is also what LEDS.LED reverts to after a reset.
    var initURL: URL { volumeURL.appendingPathComponent("INIT.LED") }
    /// Firmware readout (version, uptime, temperature, OTA slots).
    var statusURL: URL { volumeURL.appendingPathComponent("STATUS.TXT") }
    /// Touched once a minute so the SD reader doesn't power the card down.
    var keepAliveURL: URL { volumeURL.appendingPathComponent("keepalive") }

    /// The model, inferred from the LED count. Shipping units mount as plain
    /// "SidePulse", so the friendly name comes from the strip length rather than
    /// the volume name. `name` stays the raw mount name — it's what diskutil,
    /// Finder and every log line use, so it is never substituted.
    var displayName: String {
        switch ledCount {
        case 2: return "SidePulse Dot"
        case 8: return "SidePulse Pro"
        default: return name
        }
    }

    /// LED count is part of identity: it's refined from INIT.LED by the verified
    /// background scan, and the UI must notice when it changes.
    static func == (a: Device, b: Device) -> Bool {
        a.volumeURL == b.volumeURL && a.ledCount == b.ledCount
    }
}

/// The firmware's own readout, parsed from `STATUS.TXT`.
///
/// The file is one `key value` per line, NUL-padded to 1024 bytes, so every line
/// is trimmed of NULs as well as whitespace. Values can contain spaces
/// (`firmware_git abe603d0d6e7 dirty`), so the key is everything before the first
/// space and the value is the rest of the line.
struct DeviceStatus: Equatable, Sendable {
    var firmwareVersion: String?
    var firmwareBuild: String?
    var uptimeMs: Int?
    var temperatureC: Double?
    var state: String?

    init(_ text: String) {
        let padding = CharacterSet(charactersIn: "\0").union(.whitespaces)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: padding)
            guard let space = line.firstIndex(of: " ") else { continue }
            let value = line[line.index(after: space)...].trimmingCharacters(in: padding)
            switch line[..<space] {
            case "firmware_version": firmwareVersion = value
            case "firmware_build": firmwareBuild = value
            case "uptime_ms": uptimeMs = Int(value)
            case "temp_c": temperatureC = Double(value)
            case "state": state = value
            default: break
            }
        }
    }

    var isEmpty: Bool { firmwareVersion == nil && uptimeMs == nil }

    /// "3m 12s" / "2h 41m" since the controller last powered up.
    var uptimeDescription: String? {
        guard let uptimeMs else { return nil }
        let seconds = uptimeMs / 1000
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, rest = seconds % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }
}

/// A timestamped entry for the 24h activity log (heart = keepalive, dot = events).
struct ActivityEvent: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let kind: Kind
    let text: String
    enum Kind: Sendable { case keepalive, update, error, warning, repair }
}

enum ActivityFilter: Sendable { case all, keepalive, events }

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

/// Discovers SidePulse volumes, writes LED programs, and keeps every connected
/// device alive by touching its `keepalive` file every minute.
@MainActor
final class DeviceManager: ObservableObject {
    /// How often we touch the heartbeat file. The whole point of the app.
    static let heartbeatInterval: TimeInterval = 60

    /// Normalized volume-name stems we recognize. Shipping units mount as plain
    /// `SidePulse`; the vendor docs promise the suffixed names, so all three are
    /// listed. A `nil` count means "the name doesn't say which model".
    nonisolated static let nameStems: [(stem: String, ledCount: Int?)] = [
        ("sidepulsepro", 8), ("sidepulsedot", 2), ("sidepulse", nil)
    ]
    /// Fallback LED count when nothing better is known — the 8-LED SidePulse Pro
    /// layout, the same fallback the vendor's own tooling uses.
    nonisolated static let defaultLEDCount = 8

    /// Lowercased with every non-alphanumeric character dropped, so "SidePulse Pro",
    /// "SidePulse-Pro" and "SIDEPULSEPRO" all normalize alike.
    nonisolated static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The model a mounted volume's name claims, as a double optional: outer nil
    /// = not one of ours, inner nil = ours but the name doesn't say which model.
    ///
    /// Deliberately an **exact** stem match (plus the 1–2 digit suffix macOS adds
    /// for a duplicate mount, "SidePulse 1"), never an open prefix: `scanVolumes`
    /// runs name-only on the main thread and feeds `deliver()`, which writes
    /// immediately — a prefix rule would adopt "SidePulse Backup", the likeliest
    /// name for a user's backup *of* a SidePulse, and create LEDS.LED on it.
    nonisolated static func nameStem(for name: String) -> Int?? {
        let normalized = normalizedName(name)
        for candidate in nameStems {
            if normalized == candidate.stem { return .some(candidate.ledCount) }
            let tail = normalized.dropFirst(candidate.stem.count)
            if normalized.hasPrefix(candidate.stem), !tail.isEmpty, tail.count <= 2,
               tail.allSatisfy(\.isNumber) {
                return .some(candidate.ledCount)
            }
        }
        return nil
    }

    /// Most LEDs we will believe a device has. A derived count feeds array sizing
    /// in the UI, so a malformed or hostile INIT.LED must not be able to ask for an
    /// arbitrary number of colour wells.
    nonisolated static let maxLEDCount = 64

    /// LED count derived from the firmware-seeded `INIT.LED`: the highest `N:`
    /// index it addresses, plus one. `nil` when the file addresses no LED by index.
    nonisolated static func ledCountFromInit(_ text: String) -> Int? {
        var highest = -1
        for raw in LEDProgram.normalizeNewlines(text).split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(";") || line.hasPrefix("//") || line.hasPrefix("# ") { continue }
            for segment in line.split(whereSeparator: { $0 == " " || $0 == ";" }) {
                guard let colon = segment.firstIndex(of: ":"),
                      let index = Int(segment[..<colon]) else { continue }
                highest = max(highest, index)
            }
        }
        guard highest >= 0 else { return nil }
        return min(maxLEDCount, max(2, highest + 1))
    }

    // MARK: Remembered per-device facts
    //
    // Keyed by volume name rather than mount path: the path is stable in practice
    // but the name is what we match on, and it is what survives a remount.

    nonisolated static func rememberedLEDCount(_ volumeName: String) -> Int? {
        let stored = UserDefaults.standard.integer(forKey: "ledCount." + volumeName)
        return stored > 0 ? stored : nil
    }

    nonisolated static func rememberLEDCount(_ count: Int, for volumeName: String) {
        UserDefaults.standard.set(count, forKey: "ledCount." + volumeName)
    }

    /// True once we have written this volume's `INIT.LED`. After that the file
    /// holds *our* program, and says nothing about how many LEDs the hardware has.
    nonisolated static func hasWrittenInit(_ volumeName: String) -> Bool {
        UserDefaults.standard.bool(forKey: "initWritten." + volumeName)
    }

    nonisolated static func noteInitWritten(_ volumeName: String) {
        UserDefaults.standard.set(true, forKey: "initWritten." + volumeName)
    }

    @Published private(set) var devices: [Device] = []
    @Published var selectedID: String?
    @Published private(set) var lastHeartbeat: Date?
    @Published private(set) var lastHeartbeatOK = false
    @Published private(set) var nextHeartbeat: Date?
    /// Latest user-facing status (success/info/warning/error) for the UI banner.
    @Published private(set) var status: AppStatus?
    /// The program currently on the selected device's LEDS.LED (read on demand).
    @Published private(set) var currentProgram: String?
    /// The selected device's firmware readout. Refreshed by the same STATUS.TXT
    /// read the restart check already does each beat, so it costs no extra I/O.
    @Published private(set) var deviceStatus: DeviceStatus?

    /// Rolling 24h activity log (heart popup = keepalive, dot popup = events).
    @Published private(set) var events: [ActivityEvent] = []
    /// Which slice the Activity window shows (set when heart/dot is clicked).
    @Published var activityFilter: ActivityFilter = .all
    /// The last LED program actually written, for self-heal after a device reset.
    private var lastWrittenLEDS: String?
    /// Whether the most recent `deliver` actually reached the I/O queue. Info mode
    /// reads this so it never dedups against a frame that was silently dropped.
    private var lastDeliveryAccepted = false
    /// Each volume's last `uptime_ms` from STATUS.TXT. A value that goes *backwards*
    /// means the controller power-cycled — the only reliable restart signal this
    /// device gives us (see `healIfRestarted`).
    private var lastUptimeMs: [String: Int] = [:]
    /// Whether a device has been seen this run (gates auto-repair so a device-less
    /// Mac never fires the privileged repair).
    private var everHadDevice = false

    private func setStatus(_ level: AppStatus.Level, _ text: String) {
        status = AppStatus(level: level, text: text, date: Date())
        let kind: ActivityEvent.Kind = level == .error ? .error
            : (level == .warning ? .warning : .update)
        log(kind, text)
    }

    private func log(_ kind: ActivityEvent.Kind, _ text: String) {
        events.append(ActivityEvent(date: Date(), kind: kind, text: text))
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        events.removeAll { $0.date < cutoff }
        if events.count > 3000 { events.removeFirst(events.count - 3000) }
    }

    private var heartbeatTimer: Timer?
    private var tickTimer: Timer?
    private var metricsTimer: Timer?
    /// Coalesces rapid live edits (slider drags) into at most one write per beat.
    private var pendingWrite: DispatchWorkItem?

    /// Schedules the (brief) work of launching the isolated I/O child process,
    /// off the main thread. The actual device I/O happens inside that child, not
    /// here — so a wedge can never block this queue for more than `ioTimeout`.
    private let ioQueue = DispatchQueue(label: "com.gourneau.SidePulse.io", qos: .utility)
    /// `.leds` = a discrete manual program (flashes the status dot); `.liveLeds`
    /// = a live slider write (quiet, so dragging doesn't strobe); `.info` = an
    /// Info-mode frame (silent); `.initLeds` = the power-on program, written to
    /// INIT.LED instead of LEDS.LED; `.keepalive` = the heartbeat touch.
    private enum WriteKind { case leds, liveLeds, info, initLeds, keepalive }

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
    /// Whether the Mac is currently charging (for the battery breathing effect).
    @Published private(set) var batteryCharging = false
    /// Battery breathes while charging (toggle), and how fast (0…1).
    @Published var batteryBreatheWhenCharging = true {
        didSet { if infoActive { showInfoFrame(advance: false, force: true) } }
    }
    /// 0 = slowest. Defaults low for a calm, slow breath.
    @Published var batteryBreatheSpeed = 0.2 {
        didSet { if infoActive { showInfoFrame(advance: false, force: true) } }
    }
    /// Current charge power in watts (for display in the app only).
    @Published private(set) var batteryWatts: Double?
    /// Output brightness for Info mode (0…255).
    @Published var infoBrightness = 255 {
        didSet { if infoActive { showInfoFrame(advance: false, force: true) } }
    }

    /// When true, switch the LEDs off as the Mac sleeps and restore on wake.
    @Published var ledsOffOnSleep = true
    /// When true, switch the LEDs off as the app quits (no restore — it's gone).
    @Published var ledsOffOnQuit = false
    /// When true the app makes **no** writes to the LED files at all.
    ///
    /// The device is a shared filesystem, so anything on the machine can drive it —
    /// an AI agent, an MCP server, a shell script. This app is itself one of those
    /// writers, and Info mode is a continuous one. Observer mode hands the device
    /// over: nothing is written, so nothing fights. The keepalive keeps running,
    /// because it touches `keepalive` rather than `LEDS.LED` — the firmware never
    /// parses it, no other tool is competing for it, and without it the reader
    /// powers the card down after ~3 minutes, which would break everyone.
    /// Persisted — the app stores no other settings, but this one has to survive a
    /// restart: it is switched on precisely because something else owns the device,
    /// and silently resuming writes on the next launch would be the whole failure
    /// it exists to prevent.
    @Published var observerMode = UserDefaults.standard.bool(forKey: "observerMode") {
        didSet {
            guard observerMode != oldValue else { return }
            UserDefaults.standard.set(observerMode, forKey: "observerMode")
            if observerMode {
                clearContention()   // we've stopped pulling; there is no rope
                setStatus(.info, "Observer mode on — the app won't write to the device.")
            } else {
                setStatus(.info, "Observer mode off — the app can write again.")
                // Repaint immediately so Info mode doesn't wait for the next tick.
                if infoActive { showInfoFrame(advance: false, force: true) }
            }
        }
    }

    /// True when the app is writing on a timer right now — the state other tools
    /// would collide with. Presets and colours are one-shot; Info mode is not.
    var isWritingContinuously: Bool { infoActive && !observerMode }

    /// True when the last read of LEDS.LED didn't match what we last wrote, i.e.
    /// something else is driving this device.
    @Published private(set) var programChangedExternally = false

    /// True when we and something else are both writing LEDS.LED — the LEDs will
    /// flicker between two programs and neither side wins. Needs repeated evidence
    /// (see `noteContention`), because a single mismatch is far more likely to be a
    /// clipped read or a device restart than a rival writer.
    @Published private(set) var contended = false
    /// When we last found the device holding something other than what we wrote.
    private var contentionSeen: [Date] = []
    /// How long a contention observation counts for.
    private static let contentionWindow: TimeInterval = 300
    /// Observations needed inside that window before we say so.
    private static let contentionThreshold = 2

    /// Record that the device was holding someone else's program. Returns whether
    /// that is now enough evidence to call it contention.
    @discardableResult
    private func noteContention() -> Bool {
        let now = Date()
        contentionSeen.append(now)
        contentionSeen.removeAll { now.timeIntervalSince($0) > Self.contentionWindow }
        let isContended = contentionSeen.count >= Self.contentionThreshold
        if isContended && !contended {
            log(.warning, "Another tool is writing to this device too")
        }
        contended = isContended
        return isContended
    }

    /// Called when the device holds exactly what we wrote — the tug-of-war is over.
    private func clearContention() {
        contentionSeen.removeAll()
        if contended { contended = false }
    }

    /// Whether a read that differs from what we wrote is just the known clipped-read
    /// artifact — macOS serving a stale cached directory-entry size after the
    /// firmware rewrote the file, so `cat` returns a truncation of the real content.
    /// A rival writer produces different text; clipping produces a prefix.
    nonisolated static func looksClipped(onDevice: String, ours: String) -> Bool {
        let read = onDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrote = ours.trimmingCharacters(in: .whitespacesAndNewlines)
        return !read.isEmpty && read.count < wrote.count && wrote.hasPrefix(read)
    }

    /// Auto-try the repair once, ~30s after the device looks wedged/disconnected.
    @Published var autoRepair = true
    private var autoRepairTimer: Timer?
    /// True when a `com.apple.fskit.msdos` process is detected pegged at ~100% CPU
    /// (the hung-FAT-driver state) — the UI offers a one-click Repair.
    @Published private(set) var hungDriverDetected = false
    /// True when the SD reader has our card's block-storage device but it never
    /// became a mounted volume — the "ghost card" state seen when the device
    /// resets/crashes without re-presenting a disk.
    @Published private(set) var deviceGhosted = false
    /// The precise (and worst) sub-state: the reader latched the card as
    /// `Ejected = Yes` while it's still physically present. No userspace API can
    /// un-eject it — only a sleep/wake re-probe or a physical re-seat recovers it.
    @Published private(set) var ghostEjected = false

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
        nc.addObserver(self, selector: #selector(willSleep),
                       name: NSWorkspace.willSleepNotification, object: nil)
        // App quit: optionally switch the LEDs off before we exit.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
        startHeartbeat()
        startTick()
        startMetrics()
        setupPowerNotification()
        // Detect connected devices (off-thread); the scan handler beats them.
        rescan()
        // On launch, see if the FAT driver is already wedged (stalls Finder too),
        // or the card is ghosting (present in the reader but never mounted).
        checkHungDriver()
        checkDeviceHealth()
    }

    // MARK: - Power source (charging) — updates immediately on plug/unplug

    private var powerSource: CFRunLoopSource?

    private var chargingTimer: Timer?

    private func setupPowerNotification() {
        powerSourceChanged()   // initial
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let mgr = Unmanaged<DeviceManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in mgr.powerSourceChanged() }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
        // Backstop poll (power notifications can lag): react within ~3s. Cheap —
        // just a power read, no device I/O.
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.powerSourceChanged() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        chargingTimer = t
    }

    private func powerSourceChanged() {
        let info = BatteryReader.current()
        let changed = info.charging != batteryCharging
        batteryCharging = info.charging
        batteryWatts = info.charging ? sysMetrics.chargingWatts() : nil
        if changed && infoActive { showInfoFrame(advance: false, force: true) }
    }

    // MARK: - Detection

    @objc private func volumesChanged() {
        // A mount/unmount means a (possibly wedged) device went away or came
        // back — recover: clear stuck/in-flight tracking and resume.
        stuckVolumes.removeAll()
        inFlightVolumes.removeAll()
        // A different unit may be behind the same mount point now — re-learn it.
        lastUptimeMs.removeAll()
        rescan()
    }

    @objc private func didWake() {
        // Resume cadence promptly after sleep.
        startHeartbeat()
        rescan()
        beat()
        checkHungDriver()
        checkDeviceHealth()
        // Re-apply the last LED program — the device loses power across sleep and
        // comes back playing INIT.LED, so whatever we had set is gone. Give the
        // volume a moment to remount first. `healIfRestarted` would also catch this
        // on the next beat via the uptime_ms regression; this just makes it prompt
        // instead of up to a minute later.
        if let program = lastWrittenLEDS {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                self.lastInfoProgram = nil
                _ = self.deliver(program, kind: .info)
            }
        }
    }

    @objc private func willSleep() {
        // Optionally switch the LEDs off as the Mac sleeps (restored on wake).
        //
        // Only when there is something to restore. `lastWrittenLEDS` is what
        // `didWake` puts back, so with nothing recorded — a fresh launch where the
        // user hasn't picked anything yet — switching off would be a change we
        // could never undo: the app would turn off LEDs it never turned on, and
        // they'd stay off until the user set a program by hand. Whatever the strip
        // is showing then isn't ours to clear.
        guard !observerMode,
              DeviceManager.shouldSwitchOffOnSleep(enabled: ledsOffOnSleep,
                                                   hasRestorableProgram: lastWrittenLEDS != nil),
              let device = selectedDevice else { return }
        let url = device.ledsURL
        enqueueIO(kind: .info, volume: device.volumeURL.path) {
            DeviceManager.performWrite(LEDProgram.wireText(LEDProgram.off()), to: url)
        }
    }

    /// Switching off at sleep is only safe when `didWake` has something to put back.
    /// Split out so the rule is testable on its own — the handler it lives in is
    /// driven by an NSWorkspace notification and reads private state.
    nonisolated static func shouldSwitchOffOnSleep(enabled: Bool, hasRestorableProgram: Bool) -> Bool {
        enabled && hasRestorableProgram
    }

    @objc private func appWillTerminate() {
        // The app is exiting, so the async I/O queue won't run — write off
        // synchronously instead. performWrite is bounded by its own timeout, and
        // every connected device gets switched off (skipping any that's wedged).
        guard ledsOffOnQuit, !observerMode else { return }
        let off = LEDProgram.wireText(LEDProgram.off())
        for device in devices where !stuckVolumes.contains(device.volumeURL.path) {
            _ = DeviceManager.performWrite(off, to: device.ledsURL)
        }
    }

    /// Scan every mounted volume for a SidePulse device. Runs the (potentially
    /// blocking) filesystem work off the main thread, then applies on main.
    func rescan() {
        ioQueue.async { [weak self] in
            // Verify marker files (bounded, isolated) on the background queue, so a
            // user volume that merely shares the SidePulse name isn't mistaken for
            // a device (and scribbled with LEDS.LED).
            let found = DeviceManager.scanVolumes(verify: true)
            Task { @MainActor [weak self] in self?.applyScan(found) }
        }
    }

    /// The blocking part of detection — safe to run on a background thread even
    /// if a stale mount hangs on it. When `verify` is true, each name-matched
    /// volume must actually contain LEDS.LED, and the same bounded isolated child
    /// prints INIT.LED so the LED count can be read off the firmware's own startup
    /// fill (a wedged FAT mount can't hang us). When false it matches by mount name
    /// only (fast, main-thread-safe — used as a last-ditch re-check).
    nonisolated static func scanVolumes(verify: Bool = false) -> [Device] {
        let fm = FileManager.default
        let vols = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []

        // Match by mount name first — never stat INTO the volume directly, which
        // can hang if its (emulated) FAT driver is wedged. Listing /Volumes is safe.
        var found: [Device] = []
        for vol in vols {
            let name = vol.lastPathComponent
            guard let stem = nameStem(for: name) else { continue }
            // A name that states the model is the most trustworthy thing we have,
            // then anything we learned earlier, then the 8-LED Pro layout.
            var count = stem ?? rememberedLEDCount(name) ?? defaultLEDCount
            if verify {
                let leds = vol.appendingPathComponent("LEDS.LED").path
                let seed = vol.appendingPathComponent("INIT.LED").path
                // One child does both jobs: prove LEDS.LED is really there (so a
                // same-named user volume is never written to), then print INIT.LED,
                // whose per-index startup fill tells us how many LEDs this unit has.
                let (result, text) = runIsolatedCapturing(
                    #"test -f "$1" || exit 1; cat "$2" 2>/dev/null; exit 0"#,
                    [leds, seed], timeout: ioTimeout)
                guard result == .ok else { continue }
                // Only a *firmware-seeded* INIT.LED describes the hardware. Once
                // "save as power-on default" has overwritten it, the file is our own
                // program — a Chase preset addresses three LEDs, and believing it
                // would turn an 8-LED Pro into a 3-LED device permanently. And when
                // the name already states the model, the file adds nothing.
                if stem == nil, !hasWrittenInit(name),
                   let text, let fromInit = ledCountFromInit(text) {
                    // Never lower a count already learned: a clipped read — macOS
                    // serving a stale cached directory-entry size — truncates
                    // INIT.LED mid-file and would under-report the strip.
                    count = max(fromInit, rememberedLEDCount(name) ?? 0)
                    rememberLEDCount(count, for: name)
                }
            }
            found.append(Device(volumeURL: vol, name: name, ledCount: count))
        }
        return found.sorted { $0.name < $1.name }
    }

    private func applyScan(_ found: [Device]) {
        let changed = found != devices
        devices = found
        if found.isEmpty { deviceStatus = nil }
        if !found.isEmpty { everHadDevice = true }
        // Keep selection valid, preferring the 8-LED device by default.
        if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
            selectedID = found.max(by: { $0.ledCount < $1.ledCount })?.id
        }
        // Keep newly connected devices alive right away and refresh Info mode.
        if changed { beat() }
        if infoActive { showInfoFrame(advance: false, force: true) }
        if found.isEmpty { checkDeviceHealth() }   // is the card ghosting?
        else if deviceGhosted || ghostEjected { deviceGhosted = false; ghostEjected = false }
        evaluateAutoRepair()
    }

    // MARK: - Writing LED programs

    /// Validate and write a program to the selected device's LEDS.LED.
    @discardableResult
    private func deliver(_ program: String, kind: WriteKind = .leds) -> LEDProgram.Validation {
        let validation = LEDProgram.validate(program)
        guard validation.isValid else {
            setStatus(.error, validation.message ?? "Invalid program.")
            return validation
        }
        guard !observerMode else {
            // Say so for something the user just asked for; stay quiet for the
            // automatic writes, which would otherwise spam the banner every tick.
            if kind == .leds || kind == .initLeds {
                setStatus(.warning, "Observer mode is on — turn it off to write to the device.")
            }
            lastDeliveryAccepted = false
            return validation
        }
        // Don't give up on stale state: re-check /Volumes (just a name match, no
        // device I/O) before declaring "no device" — the volume may have just
        // (re)mounted. Update selection in place only; calling the full applyScan
        // here would re-enter beat()/showInfoFrame() mid-deliver. A background
        // rescan (with marker verification) corrects anything this adopts.
        if selectedDevice == nil {
            let found = DeviceManager.scanVolumes()
            if found != devices {
                devices = found
                if selectedID == nil || !found.contains(where: { $0.id == selectedID }) {
                    selectedID = found.max(by: { $0.ledCount < $1.ledCount })?.id
                }
                rescan()   // async, verifies marker files and fixes side effects
            }
        }
        guard let device = selectedDevice else {
            setStatus(.error, "No device connected.")
            return validation
        }
        // The spec says writing INIT.LED also applies it immediately, so it
        // genuinely becomes the visible state and is what self-heal should restore.
        lastWrittenLEDS = program
        if kind == .initLeds { DeviceManager.noteInitWritten(device.name) }
        let targetURL = kind == .initLeds ? device.initURL : device.ledsURL
        let text = LEDProgram.wireText(program)
        lastDeliveryAccepted = enqueueIO(kind: kind, volume: device.volumeURL.path) {
            DeviceManager.performWrite(text, to: targetURL)
        }
        return validation
    }

    /// After a keepalive: if the controller power-cycled, re-apply the last program
    /// so the LEDs come back without user action.
    ///
    /// Detection is a **`uptime_ms` regression in STATUS.TXT**, not a look at
    /// LEDS.LED. The firmware plays INIT.LED on power-up but never rewrites
    /// LEDS.LED — measured on a real unit, LEDS.LED's mtime stayed a month stale
    /// across power cycles (and across a physical re-seat), while `uptime_ms` reset
    /// to ~1000. The volume also stays mounted throughout, so neither file content
    /// nor mount events can see the restart. STATUS.TXT is cached by the host for
    /// ~5s, which is irrelevant at a 60s beat.
    private func healIfRestarted() {
        guard let device = selectedDevice,
              !stuckVolumes.contains(device.volumeURL.path),
              !inFlightVolumes.contains(device.volumeURL.path) else { return }
        // Read STATUS.TXT even with nothing to restore: the same read feeds the
        // gear-menu firmware readout, and it establishes the uptime baseline that
        // a later restart is measured against.
        let intended = lastWrittenLEDS
        let statusPath = device.statusURL.path
        let ledsPath = device.ledsURL.path
        let vol = device.volumeURL.path
        let previous = lastUptimeMs[vol]
        let watchingForRivals = !observerMode && intended != nil
        inFlightVolumes.insert(vol)
        ioQueue.async { [weak self] in
            // Both files in ONE bounded child: this already runs every beat for the
            // restart check, and LEDS.LED costs nothing extra here while a separate
            // read would double the device I/O and need its own single-flight slot.
            let (result, text) = DeviceManager.runIsolatedCapturing(
                #"cat "$1"; printf '\n@@SIDEPULSE@@\n'; cat "$2" 2>/dev/null"#,
                [statusPath, ledsPath], timeout: DeviceManager.ioTimeout)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlightVolumes.remove(vol)
                guard result == .ok, let text else {
                    if result == .stuck { self.stuckVolumes.insert(vol) }
                    return
                }
                let parts = text.components(separatedBy: "@@SIDEPULSE@@")
                // One read serves the restart check, the firmware readout, and the
                // "is anything else writing to this device?" check.
                let status = DeviceStatus(parts[0])
                if !status.isEmpty { self.deviceStatus = status }
                guard let uptime = status.uptimeMs else { return }
                self.lastUptimeMs[vol] = uptime
                // First reading this run is a baseline, not a restart.
                let restarted = previous.map { uptime < $0 } ?? false

                // A restart replays INIT.LED, which is the firmware overwriting us,
                // not a rival tool — so only judge contention on a settled device.
                if watchingForRivals, !restarted, let intended, parts.count > 1 {
                    let onDevice = parts[1]
                    if LEDProgram.wireText(onDevice) == LEDProgram.wireText(intended) {
                        self.clearContention()
                    } else if !DeviceManager.looksClipped(onDevice: onDevice, ours: intended) {
                        self.noteContention()
                    }
                }

                guard restarted else { return }
                guard let intended else { return }   // restarted, nothing of ours to restore
                self.log(.repair, "Device restarted — re-applying LEDs")
                self.lastInfoProgram = nil          // bypass info dedup
                _ = self.deliver(intended, kind: .info)  // silent re-apply
            }
        }
    }

    /// Write `program` to INIT.LED — the program the controller replays on power-up,
    /// so the strip comes back correct after the SD reader powers the card down.
    /// Per the spec the device also applies it immediately.
    @discardableResult
    func saveAsStartup(_ program: String) -> LEDProgram.Validation {
        deliver(program, kind: .initLeds)
    }

    /// Save whatever is showing now as the power-on default.
    func saveCurrentAsStartup() {
        guard let program = lastWrittenLEDS else {
            setStatus(.error, "Nothing to save yet — pick a color or preset first.")
            return
        }
        saveAsStartup(program)
    }

    /// True once there is something worth saving as the power-on default.
    var canSaveStartup: Bool { lastWrittenLEDS != nil && selectedDevice != nil }

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
            setStatus(.error, "No device connected."); return
        }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in _ = self?.deliver(program, kind: .liveLeds) }
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
            Task { @MainActor [weak self] in
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
        let info = BatteryReader.current()
        batteryCharging = info.charging
        batteryWatts = info.charging ? sysMetrics.chargingWatts() : nil
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
        guard metrics.contains(where: { $0.id == id }) else { return }
        let value = metricValues[id] ?? 0
        let hex = effectiveHex(id)
        var program: String
        if id == "battery" && batteryCharging && batteryBreatheWhenCharging {
            // Gentle breathing while charging, at the chosen speed.
            let dur = LEDProgram.frameMs(batteryBreatheSpeed, slow: 4000, fast: 800)
            program = LEDProgram.pulseBar(hex: hex, value: value, ledCount: device.ledCount, durationMs: dur)
        } else {
            program = LEDProgram.fullBar(hex: hex, value: value, ledCount: device.ledCount)
        }
        program = LEDProgram.withBrightness(program, infoBrightness)
        if !force && program == lastInfoProgram { return }
        deliver(program, kind: .info)
        // Only remember it if it was actually queued. applyScan calls beat() first,
        // which takes the volume's single-flight slot synchronously, so the forced
        // frame right after a (re)connect is otherwise dropped *and* then deduped
        // against on every later tick — leaving the strip on whatever INIT.LED lit.
        lastInfoProgram = lastDeliveryAccepted ? program : nil
    }

    // MARK: - Heartbeat (keepalive)

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.beat() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
        nextHeartbeat = Date().addingTimeInterval(Self.heartbeatInterval)
    }

    private func startTick() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.now = Date() }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    /// Keep every connected device alive by **touching** its `keepalive` file — a
    /// dedicated marker the firmware never parses, so the LED animation isn't
    /// disturbed. The MacBook SD reader powers the card down after ~3 minutes of
    /// inactivity, so this runs every 60s. On success it triggers a self-heal check
    /// (re-apply the LED program if the device reset and reverted LEDS.LED to the
    /// firmware's power-on program).
    func beat() {
        for device in devices {
            let url = device.keepAliveURL
            enqueueIO(kind: .keepalive, volume: device.volumeURL.path) {
                DeviceManager.performTouch(url)
            }
        }
        nextHeartbeat = Date().addingTimeInterval(Self.heartbeatInterval)
        checkHungDriver()      // catch a mid-session FAT-driver wedge (~every 60s)
        checkDeviceHealth()    // catch the "ghost card" state (no-op when mounted)
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
    /// Returns false when the op was **not** accepted — the volume is wedged, or
    /// already has an op in flight. A dropped op never runs and never reports, so a
    /// caller that caches "we already sent this" has to know the difference or it
    /// will dedup against a write that never happened.
    @discardableResult
    private func enqueueIO(kind: WriteKind, volume: String,
                           _ op: @escaping @Sendable () -> IOResult) -> Bool {
        guard !stuckVolumes.contains(volume), !inFlightVolumes.contains(volume) else { return false }
        inFlightVolumes.insert(volume)
        ioQueue.async { [weak self] in
            let result = op()
            Task { @MainActor [weak self] in self?.finishIO(kind: kind, volume: volume, result: result) }
        }
        return true
    }

    private func finishIO(kind: WriteKind, volume: String, result: IOResult) {
        inFlightVolumes.remove(volume)
        switch result {
        case .stuck:
            stuckVolumes.insert(volume)
            setStatus(.warning, "Device stopped responding — use Repair to recover.")
            evaluateAutoRepair()
        case .failed:
            switch kind {
            case .leds, .liveLeds, .info, .initLeds:
                setStatus(.error, "Couldn’t write — the device may be unplugged or full.")
            case .keepalive:
                lastHeartbeatOK = false
            }
        case .ok:
            switch kind {
            case .leds:
                setStatus(.success, "Updated")
            case .initLeds:
                setStatus(.success, "Saved as the power-on default")
            case .liveLeds, .info:
                // Live/cycling writes stay quiet; clear any stale error/warning.
                if let level = status?.level, level == .error || level == .warning { status = nil }
            case .keepalive:
                lastHeartbeat = Date(); lastHeartbeatOK = true
                log(.keepalive, "Kept alive")
                healIfRestarted()   // volume slot is now free
            }
        }
    }

    // MARK: - Customizable metric colors

    /// User overrides for metric colors (defaults live on each `Metric`).
    @Published var metricColors: [String: Color] = [:]

    func effectiveColor(_ id: String) -> Color {
        metricColors[id] ?? metrics.first { $0.id == id }?.color ?? .white
    }

    func effectiveHex(_ id: String) -> String {
        if let c = metricColors[id] { return LEDProgram.hex(c) }
        return metrics.first { $0.id == id }?.hex ?? "#ffffff"
    }

    func setMetricColor(_ id: String, _ color: Color) {
        metricColors[id] = color
        if infoActive { showInfoFrame(advance: false, force: true) }
    }

    // MARK: - Reading the live program

    /// Read the program currently on the selected device's LEDS.LED into
    /// `currentProgram`, via an isolated child (single-flight, respects stuck).
    func loadCurrentProgram() {
        guard let device = selectedDevice else {
            currentProgram = nil
            setStatus(.error, "No device connected.")
            return
        }
        let vol = device.volumeURL.path
        guard !stuckVolumes.contains(vol), !inFlightVolumes.contains(vol) else { return }
        let url = device.ledsURL
        inFlightVolumes.insert(vol)
        ioQueue.async { [weak self] in
            let (result, text) = DeviceManager.readContents(url)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlightVolumes.remove(vol)
                switch result {
                case .ok:
                    let onDevice = text ?? ""
                    self.currentProgram = onDevice
                    // Compare against what we last wrote: anything else means
                    // another tool is driving this device.
                    if let ours = self.lastWrittenLEDS {
                        self.programChangedExternally =
                            LEDProgram.wireText(onDevice) != LEDProgram.wireText(ours)
                    } else {
                        self.programChangedExternally = false
                    }
                case .stuck:
                    self.stuckVolumes.insert(vol)
                    self.setStatus(.warning, "Device stopped responding — I/O paused. Reconnect it to recover.")
                case .failed:
                    self.setStatus(.error, "Couldn’t read the device. Is it still mounted?")
                }
            }
        }
    }

    // MARK: - Reconnect / repair a stuck volume

    /// A device must have been seen this run before we'll auto-repair — so a
    /// device-less Mac never fires the privileged repair (which kills the FAT
    /// driver). Stuck always qualifies.
    private func needsRepair() -> Bool {
        anyDeviceStuck || deviceGhosted || (everHadDevice && devices.isEmpty)
    }

    /// Arm/cancel auto-repair based on device health.
    private func evaluateAutoRepair() {
        if needsRepair() { armAutoRepair(after: 30) }
        else { autoRepairTimer?.invalidate(); autoRepairTimer = nil }
    }

    private func armAutoRepair(after seconds: TimeInterval) {
        guard autoRepair, autoRepairTimer == nil else { return }
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fireAutoRepair() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        autoRepairTimer = t
    }

    private func fireAutoRepair() {
        autoRepairTimer = nil
        guard autoRepair, needsRepair() else { return }
        setStatus(.info, "Auto-repairing the device…")
        WakeGuard.shared.autoRepairIfPossible { [weak self] in self?.afterRepair() }
        // Keep retrying on a cooldown while still wedged (cancelled once healthy).
        armAutoRepair(after: 120)
    }

    /// Called after WakeGuard's privileged repair finishes: re-detect and report.
    func afterRepair() {
        stuckVolumes.removeAll()
        inFlightVolumes.removeAll()
        hungDriverDetected = false
        deviceGhosted = false
        ghostEjected = false
        rescan()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self else { return }
            self.checkHungDriver()   // confirm the driver is no longer pegged
            if self.devices.isEmpty {
                self.setStatus(.warning, "Couldn’t reconnect — try Repair again; reboot as a last resort.")
            } else {
                self.setStatus(.success, "Reconnected")
            }
        }
    }

    /// Detect a hung FAT driver (also what stalls Finder) via a cheap `ps` — never
    /// touches the device, so it's safe even while everything else is wedged.
    func checkHungDriver() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hung = DeviceManager.isFskitHung()
            Task { @MainActor [weak self] in self?.hungDriverDetected = hung }
        }
    }

    /// Watchdog for the "ghost card" state: the SD reader sees our card but it
    /// never mounted as a volume (a device crash/reset that didn't re-enumerate a
    /// disk). Only meaningful when we have no mounted device, so it's skipped
    /// otherwise. Never touches the volume — reads the card reader via
    /// `system_profiler` in a bounded child. Triggers auto-repair when found.
    func checkDeviceHealth() {
        guard devices.isEmpty else {
            if deviceGhosted || ghostEjected { deviceGhosted = false; ghostEjected = false }
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let probe = DeviceManager.probeSDXC()
            Task { @MainActor [weak self] in
                guard let self else { return }
                let ghosted = probe.present && self.devices.isEmpty
                if ghosted != self.deviceGhosted {
                    self.deviceGhosted = ghosted
                    if ghosted {
                        self.log(.warning, probe.ejected
                            ? "Card stuck half-ejected (hardware) — re-seat or sleep/wake needed"
                            : "Card detected but not mounted")
                    }
                }
                self.ghostEjected = ghosted && probe.ejected
                if ghosted { self.everHadDevice = true; self.evaluateAutoRepair() }
            }
        }
    }

    /// Probe the SD reader via `ioreg` (bounded child — never the volume). Returns
    /// whether our card's block-storage device exists at all, and whether it's
    /// stuck `Ejected = Yes` (present but un-publishable, the unrecoverable-by-
    /// software state). `AppleSDXCBlockStorageDevice` only exists when a card is/
    /// was inserted, so its presence + no mounted volume == the ghost-card state.
    nonisolated static func probeSDXC() -> (present: Bool, ejected: Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        p.arguments = ["-r", "-c", "AppleSDXCBlockStorageDevice", "-l", "-w0"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (false, false) }
        if done.wait(timeout: .now() + 6) == .timedOut { p.terminate(); return (false, false) }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard out.contains("AppleSDXCBlockStorageDevice") else { return (false, false) }
        return (true, out.contains("\"Ejected\" = Yes"))
    }

    nonisolated static func isFskitHung() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "%cpu=,command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return false }
        if done.wait(timeout: .now() + 4) == .timedOut { p.terminate(); return false }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let sp = line.firstIndex(of: " ") else { continue }
            let cpu = Double(line[..<sp]) ?? 0
            let cmd = line[line.index(after: sp)...]
            if cmd.contains("com.apple.fskit.msdos") && cpu > 50 { return true }
        }
        return false
    }

    /// Write `text` to `url` via an isolated child: stage on local disk first
    /// (safe/fast), then have the child copy it onto the device, strip the
    /// provenance xattr, and remove any AppleDouble `._` companion.
    nonisolated static func performWrite(_ text: String, to url: URL) -> IOResult {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sidepulse-\(UUID().uuidString).led")
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

    /// Touch `url` via an isolated child — the keepalive. Also clears the
    /// AppleDouble `._` companion macOS leaves beside it on a FAT volume.
    ///
    /// The redirect comes first and deliberately: a bare `touch` on an existing
    /// file can be satisfied from the VFS cache without ever reaching the card,
    /// and `finishIO` turns this exit status into `lastHeartbeatOK`, the heart UI
    /// and the restart check — a keepalive that reports success without touching
    /// the device is the worst lie this app could tell. `: >` is a real
    /// `open(O_TRUNC)` that fails loudly if the volume went away, creates the file
    /// on a unit that lacks it, and still honours the vendor's zero-byte contract.
    nonisolated static func performTouch(_ url: URL) -> IOResult {
        let script = #"""
        : > "$1" || exit 1
        /usr/bin/touch "$1" || exit 1
        xattr -c "$1" 2>/dev/null
        rm -f "$(dirname "$1")/._$(basename "$1")" 2>/dev/null
        exit 0
        """#
        return runIsolated(script, [url.path], timeout: ioTimeout)
    }

    /// Read the full (tiny) contents of `url` via an isolated child, capturing
    /// stdout. Returns `.stuck` if it hangs (the child is abandoned, contained).
    nonisolated static func readContents(_ url: URL) -> (IOResult, String?) {
        runIsolatedCapturing(#"cat "$1""#, [url.path], timeout: ioTimeout)
    }

    /// `runIsolated`, but captures the child's stdout. Same containment: a wedged
    /// device hangs the child, never us.
    nonisolated static func runIsolatedCapturing(_ script: String, _ args: [String],
                                                 timeout: TimeInterval) -> (IOResult, String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "sh"] + args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return (.failed, nil) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return (.stuck, nil)
        }
        guard proc.terminationStatus == 0 else { return (.failed, nil) }
        // Every file we read this way is ~1 KB at most — far under the pipe
        // buffer — so the child has already exited and reading to EOF returns
        // promptly rather than deadlocking on a full pipe.
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
