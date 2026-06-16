import SwiftUI

/// Builds and validates `LEDS.TXT` DSL programs for the sdstatusbar controller.
///
/// The controller accepts at most 512 bytes and at most 10 physical lines.
/// A parse error makes the device blink red 6×, so every program we emit is
/// validated against those limits before it ever reaches the card.
enum LEDProgram {
    static let maxBytes = 512
    static let maxLines = 10

    // MARK: - Builders

    /// All LEDs one solid color, with optional brightness scaling.
    static func solid(color: Color, brightness: Int) -> String {
        var lines: [String] = []
        if brightness < 255 { lines.append("brightness \(clampBrightness(brightness))") }
        lines.append(hex(color))
        return lines.joined(separator: "\n")
    }

    /// Turn every LED off.
    static func off() -> String { "off" }

    /// Per-LED colors. `nil` entries are left unassigned so the controller holds
    /// their current state. An all-`nil` array falls back to `off`.
    static func perLED(_ colors: [Color?], brightness: Int) -> String {
        let segments = colors.enumerated().compactMap { idx, c -> String? in
            guard let c else { return nil }
            return "\(idx):\(hex(c))"
        }
        guard !segments.isEmpty else { return off() }
        var lines: [String] = []
        if brightness < 255 { lines.append("brightness \(clampBrightness(brightness))") }
        lines.append(segments.joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    // MARK: - Presets

    struct Preset: Identifiable, Sendable {
        let id: String
        let name: String
        let symbol: String
        /// Builds the program for a device's LED count, brightness, whether it's
        /// animated, and a 0…1 speed (only meaningful for animatable presets).
        let make: @Sendable (_ ledCount: Int, _ brightness: Int, _ animated: Bool, _ speed: Double) -> String
        /// True if this preset has distinct animated and static forms (so the UI
        /// can show the Animated/Speed controls as meaningful for it).
        let animatable: Bool
        init(_ id: String, _ name: String, _ symbol: String, animatable: Bool = false,
             _ make: @escaping @Sendable (Int, Int, Bool, Double) -> String) {
            self.id = id; self.name = name; self.symbol = symbol
            self.animatable = animatable; self.make = make
        }
    }

    static let presets: [Preset] = [
        Preset("rainbow", "Rainbow", "rainbow", animatable: true) { n, b, anim, speed in
            rainbow(ledCount: n, brightness: b, animated: anim, speed: speed)
        },
        Preset("breathe", "Breathe", "wind", animatable: true) { _, b, anim, speed in
            guard anim else { return withBrightness("#404040", b) }
            let pulse = frameMs(speed, slow: 2600, fast: 500)
            let rest = frameMs(speed, slow: 800, fast: 150)
            return withBrightness("#404040 \(pulse)ms pulse\noff \(rest)ms none\nrepeat", b)
        },
        Preset("sparkle", "Sparkle", "sparkles", animatable: true) { n, b, anim, speed in
            sparkle(ledCount: n, brightness: b, animated: anim, speed: speed)
        },
        Preset("white", "White", "sun.max") { _, b, _, _ in withBrightness("#ffffff", b) },
        Preset("off", "Off", "power") { _, _, _, _ in off() }
    ]

    /// Map a 0…1 speed to a millisecond duration (faster speed → shorter).
    static func frameMs(_ speed: Double, slow: Int, fast: Int) -> Int {
        let s = min(1, max(0, speed))
        return Int((Double(slow) + (Double(fast) - Double(slow)) * s).rounded())
    }

    /// Prepend a `brightness` line unless it's full (255 = controller default).
    static func withBrightness(_ program: String, _ brightness: Int) -> String {
        brightness < 255 ? "brightness \(clampBrightness(brightness))\n\(program)" : program
    }

    /// Rainbow as an evenly spaced hue gradient across the LEDs. When `animated`,
    /// it rotates a full turn over 3 frames so it loops seamlessly and appears to
    /// flow; otherwise it's a single held gradient. Uses the doc's proven per-LED
    /// segment syntax.
    private static func rainbow(ledCount: Int, brightness: Int, animated: Bool, speed: Double) -> String {
        let n = max(1, ledCount)
        let dur = frameMs(speed, slow: 1200, fast: 120)
        func frame(_ offset: Double, timed: Bool) -> String {
            (0..<n).map { i -> String in
                let hue = (Double(i) / Double(n) + offset).truncatingRemainder(dividingBy: 1)
                return "\(i):\(hsvHex(h: hue, s: 1, v: 1))" + (timed ? " \(dur)ms" : "")
            }.joined(separator: timed ? "; " : " ")
        }
        guard animated else { return withBrightness(frame(0, timed: false), brightness) }
        var lines: [String] = []
        if brightness < 255 { lines.append("brightness \(clampBrightness(brightness))") }
        for f in 0..<3 { lines.append(frame(Double(f) / 3, timed: true)) }
        lines.append("repeat")
        return lines.joined(separator: "\n")
    }

    /// Quick indexed sparkle, clamped to the device's LEDs. Animated loops; the
    /// static form holds a single sparkle frame.
    private static func sparkle(ledCount: Int, brightness: Int, animated: Bool, speed: Double) -> String {
        let palette = ["#ffffff", "#ff00ee", "#00ccff", "#ffaa00",
                       "#00ff88", "#ff0040", "#8800ff", "#ffffff"]
        let count = max(1, min(ledCount, palette.count))
        let lit = stride(from: 0, to: count, by: 2)
        guard animated else {
            let segs = lit.map { "\($0):\(palette[$0])" }
            return withBrightness(segs.joined(separator: " "), brightness)
        }
        let step = frameMs(speed, slow: 220, fast: 50)
        let rest = frameMs(speed, slow: 260, fast: 70)
        var lines: [String] = []
        if brightness < 255 { lines.append("brightness \(clampBrightness(brightness))") }
        for i in lit { lines.append("\(i):\(palette[i]) \(step)ms none") }
        lines.append("off \(rest)ms ease-out")
        lines.append("repeat")
        return lines.joined(separator: "\n")
    }

    // MARK: - Info modes (one metric across the whole strip)

    /// Show a single metric across the full strip: the first `lit` LEDs in `hex`
    /// (proportional to its 0...1 value), the rest off. At 100% the whole strip
    /// lights in the metric's color. Emitted as a positional list (proven syntax).
    static func fullBar(hex: String, value: Double, ledCount: Int) -> String {
        let n = max(1, ledCount)
        let v = min(1, max(0, value))
        var lit = Int((v * Double(n)).rounded())
        if v > 0 { lit = max(1, lit) }              // show at least one LED if non-zero
        lit = min(lit, n)
        guard lit > 0 else { return off() }
        var cells = Array(repeating: "#000000", count: n)
        for i in 0..<lit { cells[i] = hex }
        return cells.joined(separator: " ")
    }

    /// Like `fullBar`, but the lit LEDs gently breathe (off → color → off) — used
    /// for the battery metric while charging. Loops on-device.
    static func pulseBar(hex: String, value: Double, ledCount: Int, durationMs: Int = 1600) -> String {
        let n = max(1, ledCount)
        let v = min(1, max(0, value))
        var lit = Int((v * Double(n)).rounded())
        if v > 0 { lit = max(1, lit) }
        lit = min(lit, n)
        guard lit > 0 else { return off() }
        let segs = (0..<lit).map { "\($0):\(hex) \(durationMs)ms pulse" }
        return "off\n" + segs.joined(separator: "; ") + "\nrepeat"
    }

    /// `#rrggbb` for an HSV color (hue/saturation/value in 0...1).
    static func hsvHex(h: Double, s: Double, v: Double) -> String {
        let ns = NSColor(hue: CGFloat(h.truncatingRemainder(dividingBy: 1)),
                         saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1)
            .usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }

    // MARK: - Validation

    enum Validation: Equatable {
        case ok
        case tooManyBytes(Int)
        case tooManyLines(Int)

        var isValid: Bool { self == .ok }
        var message: String? {
            switch self {
            case .ok: return nil
            case .tooManyBytes(let n): return "Too large: \(n) bytes (max \(maxBytes))."
            case .tooManyLines(let n): return "Too many lines: \(n) (max \(maxLines))."
            }
        }
    }

    static func validate(_ program: String) -> Validation {
        let bytes = program.utf8.count
        if bytes > maxBytes { return .tooManyBytes(bytes) }
        // "physical lines" = literal lines in the file.
        let lineCount = program.split(separator: "\n", omittingEmptySubsequences: false).count
        if lineCount > maxLines { return .tooManyLines(lineCount) }
        return .ok
    }

    // MARK: - Color helpers

    static func clampBrightness(_ v: Int) -> Int { min(255, max(0, v)) }

    /// Lowercase `#rrggbb` from a SwiftUI Color via sRGB components.
    static func hex(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}
