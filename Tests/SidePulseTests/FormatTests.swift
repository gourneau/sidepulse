import XCTest
@testable import SidePulse

/// Covers the pure, device-independent logic behind the LEDS.LED migration: what
/// counts as one of our volumes, how a program is measured before it is written,
/// and how the firmware's own files are read back.
final class FormatTests: XCTestCase {

    // MARK: Volume matching

    /// Whether `scanVolumes` would claim a volume with this name.
    private func claims(_ name: String) -> Bool { DeviceManager.nameStem(for: name) != nil }

    func testMatchesShippingAndDocumentedVolumeNames() {
        XCTAssertTrue(claims("SidePulse"))
        XCTAssertTrue(claims("SidePulsePro"))
        XCTAssertTrue(claims("SidePulseDot"))
        XCTAssertTrue(claims("SIDEPULSE"))
        XCTAssertTrue(claims("SidePulse Pro"))
        // macOS appends a counter when the same name is mounted twice.
        XCTAssertTrue(claims("SidePulse 1"))
    }

    /// The regression that matters most: the name-only scan runs on the main thread
    /// and feeds `deliver()`, which writes. A prefix rule would adopt a user's
    /// backup volume and create LEDS.LED on it.
    func testDoesNotMatchUnrelatedVolumesThatMerelyStartWithTheName() {
        XCTAssertFalse(claims("SidePulse Backup"))
        XCTAssertFalse(claims("SidePulseArchive"))
        XCTAssertFalse(claims("Macintosh HD"))
        XCTAssertFalse(claims("Time Machine"))
        XCTAssertFalse(claims(""))
        XCTAssertFalse(claims("SidePulse Pro Backup"))
    }

    func testModelIsTakenFromTheNameOnlyWhenTheNameSaysSo() {
        XCTAssertEqual(DeviceManager.nameStem(for: "SidePulsePro"), .some(8))
        XCTAssertEqual(DeviceManager.nameStem(for: "SidePulseDot"), .some(2))
        // Plain "SidePulse" carries no model — the count comes from INIT.LED.
        XCTAssertEqual(DeviceManager.nameStem(for: "SidePulse"), .some(nil))
    }

    // MARK: LED count from INIT.LED

    /// The exact factory startup fill read off the attached unit.
    private let factoryInit = """
    // startup fill
    0:#141414 125ms none
    1:#141414 125ms none
    2:#141414 125ms none
    3:#141414 125ms none
    4:#141414 125ms none
    5:#141414 125ms none
    6:#141414 125ms none
    7:#141414 125ms none
    off
    """

    func testLEDCountFromFactoryStartupFill() {
        XCTAssertEqual(DeviceManager.ledCountFromInit(factoryInit), 8)
    }

    func testLEDCountFromTwoLEDStartupFill() {
        XCTAssertEqual(DeviceManager.ledCountFromInit("0:#141414 125ms none\n1:#141414 125ms none\noff"), 2)
    }

    func testLEDCountIgnoresCommentsAndUnindexedPrograms() {
        XCTAssertNil(DeviceManager.ledCountFromInit("// 7:#ffffff is only a comment\noff"))
        XCTAssertNil(DeviceManager.ledCountFromInit("#ff00ff 1.4s pulse\nrepeat"))
        XCTAssertNil(DeviceManager.ledCountFromInit(""))
    }

    func testLEDCountReadsSemicolonSeparatedSegments() {
        XCTAssertEqual(DeviceManager.ledCountFromInit("0:#ff0000 1s; 3:#0000ff 1s"), 4)
    }

    // MARK: STATUS.TXT

    /// STATUS.TXT is one `key value` per line, NUL-padded to 1024 bytes.
    func testStatusIsParsedOutOfNULPaddedFile() {
        let status = """
        firmware_version 27225.3579
        firmware_build 2026-07-16T16:59:40Z
        firmware_git abe603d0d6e7 dirty
        uptime_ms 85003
        temp_c 30.4
        state idle
        """ + String(repeating: "\0", count: 64)
        let parsed = DeviceStatus(status)
        XCTAssertEqual(parsed.firmwareVersion, "27225.3579")
        XCTAssertEqual(parsed.firmwareBuild, "2026-07-16T16:59:40Z")
        XCTAssertEqual(parsed.uptimeMs, 85003)
        XCTAssertEqual(parsed.temperatureC, 30.4)
        XCTAssertEqual(parsed.state, "idle")
        XCTAssertFalse(parsed.isEmpty)
    }

    func testStatusIsEmptyWhenTheFileSaysNothingUseful() {
        XCTAssertTrue(DeviceStatus("").isEmpty)
        XCTAssertTrue(DeviceStatus("state idle\n").isEmpty)
        // A key that merely starts the same must not be mistaken for uptime_ms.
        XCTAssertNil(DeviceStatus("uptime_ms_total 5\n").uptimeMs)
    }

    func testUptimeIsFormattedForTheUI() {
        XCTAssertEqual(DeviceStatus("uptime_ms 45000").uptimeDescription, "45s")
        XCTAssertEqual(DeviceStatus("uptime_ms 192000").uptimeDescription, "3m 12s")
        XCTAssertEqual(DeviceStatus("uptime_ms 9660000").uptimeDescription, "2h 41m")
        XCTAssertNil(DeviceStatus("state idle").uptimeDescription)
    }

    // MARK: Program measurement

    /// `deliver()` appends the trailing newline after validation, so what we count
    /// has to be the wire form or the real ceiling is 511 bytes / 19 lines.
    func testStatsMeasureTheBytesActuallyWritten() {
        XCTAssertEqual(LEDProgram.stats("off").bytes, 4)
        XCTAssertEqual(LEDProgram.stats("off").lines, 1)
        XCTAssertEqual(LEDProgram.stats("a\nb").lines, 2)
        // A program that already ends in a newline must not gain a second one.
        XCTAssertEqual(LEDProgram.wireText("off\n"), "off\n")
        XCTAssertEqual(LEDProgram.wireText("off\n\n"), "off\n")
        XCTAssertEqual(LEDProgram.stats("off\n").bytes, LEDProgram.stats("off").bytes)
    }

    func testValidationUsesTheNewTwentyLineLimit() {
        let nineteen = Array(repeating: "off", count: 19).joined(separator: "\n")
        let twenty = Array(repeating: "off", count: 20).joined(separator: "\n")
        let twentyOne = Array(repeating: "off", count: 21).joined(separator: "\n")
        XCTAssertTrue(LEDProgram.validate(nineteen).isValid)
        XCTAssertTrue(LEDProgram.validate(twenty).isValid)
        XCTAssertEqual(LEDProgram.validate(twentyOne), .tooManyLines(21))
    }

    func testValidationRejectsOverlongDurations() {
        XCTAssertTrue(LEDProgram.validate("#ff00ff 65535ms pulse").isValid)
        XCTAssertEqual(LEDProgram.validate("#ff00ff 65536ms pulse"), .durationTooLong(65536))
        XCTAssertEqual(LEDProgram.validate("#ff00ff 120s pulse"), .durationTooLong(120_000))
        // Decimal seconds and comment lines are handled.
        XCTAssertTrue(LEDProgram.validate("#ff00ff 0.33s ease-in").isValid)
        XCTAssertTrue(LEDProgram.validate("// 999s is only a comment\noff").isValid)
    }

    func testDurationParsingIgnoresNonDurationTokens() {
        XCTAssertEqual(LEDProgram.durationMs("330ms"), 330)
        XCTAssertEqual(LEDProgram.durationMs("2s"), 2000)
        XCTAssertEqual(LEDProgram.durationMs("0.33s"), 330)
        for token in ["#ff00ff", "off", "repeat", "brightness", "pulse", "cosine", "0:#ffffff", "ms"] {
            XCTAssertNil(LEDProgram.durationMs(token), "\(token) is not a duration")
        }
    }

    // MARK: Emitted programs

    /// Every preset, on both strip lengths, at both speed extremes, must fit the
    /// controller's budget — a program that doesn't parse blinks the LEDs red.
    func testEveryPresetFitsTheControllerBudget() {
        for preset in LEDProgram.presets {
            for ledCount in [2, 8] {
                for brightness in [255, 128] {
                    for animated in [true, false] {
                        for speed in [0.0, 0.5, 1.0] {
                            let program = preset.make(ledCount, brightness, animated, speed)
                            let (bytes, lines) = LEDProgram.stats(program)
                            XCTAssertTrue(
                                LEDProgram.validate(program).isValid,
                                "\(preset.id) ledCount=\(ledCount) brightness=\(brightness) "
                                + "animated=\(animated) speed=\(speed): \(bytes)B/\(lines)L — "
                                + (LEDProgram.validate(program).message ?? "")
                            )
                        }
                    }
                }
            }
        }
    }

    /// The animated rainbow used to emit three hue-offset keyframes — ~411 bytes on
    /// an 8-LED strip, the largest program the app produced. Seed + roll is a
    /// fraction of that, and continuously interpolated instead of 3-stepped.
    func testAnimatedRainbowSeedsThenRolls() {
        let program = LEDProgram.presets.first { $0.id == "rainbow" }!.make(8, 255, true, 0.5)
        let lines = program.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "seed, roll, repeat")
        XCTAssertEqual(lines[0].split(separator: " ").count, 8, "one colour per LED")
        XCTAssertTrue(lines[0].hasPrefix("#"), "positional colour list, not indexed")
        XCTAssertTrue(lines[1].hasPrefix("roll "), "got \(lines[1])")
        XCTAssertEqual(lines[2], "repeat")
        XCTAssertLessThan(LEDProgram.stats(program).bytes, 130)
    }

    /// `roll` rotates whatever is currently visible, and an indexed assignment
    /// leaves unmentioned LEDs holding their state — so the comet must be seeded
    /// onto a cleared strip or it smears across whatever was showing.
    func testChaseClearsTheStripBeforeSeedingTheComet() {
        for ledCount in [2, 8] {
            let program = LEDProgram.presets.first { $0.id == "chase" }!.make(ledCount, 255, true, 0.5)
            let lines = program.split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.first, "off", "comet must be seeded onto a cleared strip")
            XCTAssertTrue(lines.contains { $0.hasPrefix("roll ") })
            XCTAssertEqual(lines.last, "repeat")
        }
    }

    /// A 2-LED Dot must not be given a tail longer than the device.
    func testChaseTailIsScaledToTheStrip() {
        func cometSegments(_ ledCount: Int) -> Int {
            let program = LEDProgram.presets.first { $0.id == "chase" }!.make(ledCount, 255, false, 0.5)
            return program.split(separator: "\n").map(String.init)[1].split(separator: " ").count
        }
        XCTAssertEqual(cometSegments(2), 1)
        XCTAssertEqual(cometSegments(8), 3)
    }

    func testStaticFormsOfRollPresetsDoNotRoll() {
        for id in ["rainbow", "chase"] {
            let program = LEDProgram.presets.first { $0.id == id }!.make(8, 255, false, 0.5)
            XCTAssertFalse(program.contains("roll"), "\(id) static form should hold, not roll")
            XCTAssertFalse(program.contains("repeat"), "\(id) static form should not loop")
        }
    }

    func testInfoModeBarsFitAndDegradeSensibly() {
        for ledCount in [2, 8] {
            for value in [0.0, 0.01, 0.5, 1.0] {
                XCTAssertTrue(LEDProgram.validate(
                    LEDProgram.fullBar(hex: "#ffffff", value: value, ledCount: ledCount)).isValid)
                XCTAssertTrue(LEDProgram.validate(
                    LEDProgram.pulseBar(hex: "#ffffff", value: value, ledCount: ledCount)).isValid)
            }
        }
        // Zero is off; anything non-zero lights at least one LED.
        XCTAssertEqual(LEDProgram.fullBar(hex: "#ffffff", value: 0, ledCount: 8), "off")
        XCTAssertTrue(LEDProgram.fullBar(hex: "#ffffff", value: 0.01, ledCount: 8).hasPrefix("#ffffff"))
    }

    func testEmittedDurationsAreClamped() {
        XCTAssertEqual(LEDProgram.frameMs(0, slow: 999_999, fast: 100), LEDProgram.maxDurationMs)
        XCTAssertTrue(LEDProgram.validate(
            LEDProgram.pulseBar(hex: "#ffffff", value: 1, ledCount: 8, durationMs: 999_999)).isValid)
    }

    // MARK: Spec rendering

    /// The spec's preamble uses four-space-indented shell examples. Before this,
    /// they were swallowed into the surrounding paragraph.
    func testSpecViewRendersIndentedShellExamplesAsCode() {
        let source = """
        The simplest way to change the color is

            $ echo "#FF00FF" > /Volumes/SidePulsePro/LEDS.LED

        Or to slowly pulse it.
        """
        let blocks = SpecView.parse(source)
        guard blocks.count == 3 else { return XCTFail("expected 3 blocks, got \(blocks.count)") }
        guard case .code(let code) = blocks[1] else { return XCTFail("middle block should be code") }
        XCTAssertEqual(code, ##"$ echo "#FF00FF" > /Volumes/SidePulsePro/LEDS.LED"##)
    }

    func testSpecViewDedentsByTheBlockMinimumAndKeepsBackslashEscapes() {
        let source = "intro\n\n     $ echo \"off\\n#FF00FF 1s pulse\\nrepeat\"\n\nafter"
        let blocks = SpecView.parse(source)
        guard case .code(let code) = blocks[1] else { return XCTFail("expected a code block") }
        XCTAssertEqual(code, #"$ echo "off\n#FF00FF 1s pulse\nrepeat""#)
    }

    /// A `#` heading inside a fence is content, not a heading — the DSL uses `#`
    /// for both colours and comments.
    func testSpecViewKeepsFencedContentIntact() {
        let blocks = SpecView.parse("## Colors\n\n```text\n# all LEDs white\n#ffffff\n```\n")
        guard blocks.count == 2 else { return XCTFail("expected 2 blocks, got \(blocks.count)") }
        guard case .h2(let heading) = blocks[0] else { return XCTFail("expected a heading") }
        XCTAssertEqual(heading, "Colors")
        guard case .code(let code) = blocks[1] else { return XCTFail("expected a code block") }
        XCTAssertEqual(code, "# all LEDs white\n#ffffff")
    }

    /// The shipped spec must survive the renderer without losing its examples.
    func testEmbeddedSpecRendersEveryFencedExample() {
        let blocks = SpecView.parse(SpecText.content)
        let codeBlocks = blocks.filter { if case .code = $0 { return true } else { return false } }
        let fences = SpecText.content.components(separatedBy: "\n").filter { $0.hasPrefix("```") }.count
        XCTAssertEqual(fences % 2, 0, "unbalanced code fences in LEDS_FORMAT.md")
        XCTAssertEqual(codeBlocks.count, fences / 2 + 4,
                       "every fenced block, plus the four indented preamble examples")
        XCTAssertTrue(SpecText.content.contains("LEDS.LED"))
        XCTAssertFalse(SpecText.content.contains("LEDS.TXT"))
    }
}
