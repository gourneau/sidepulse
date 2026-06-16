import SwiftUI

/// An inline color editor: a live preview, quick swatches, and RGB sliders.
/// Lives entirely inside the popover, so it works reliably in a menu-bar
/// (accessory) app where the native ColorPicker's NSColorPanel does not, and it
/// updates the bound color live as you drag.
struct ColorEditor: View {
    @Binding var color: Color

    private static let swatches: [Color] = [
        Color(.sRGB, red: 1, green: 1, blue: 1),     // white
        Color(.sRGB, red: 1, green: 0, blue: 0),     // red
        Color(.sRGB, red: 1, green: 0.5, blue: 0),   // orange
        Color(.sRGB, red: 1, green: 1, blue: 0),     // yellow
        Color(.sRGB, red: 0, green: 1, blue: 0),     // green
        Color(.sRGB, red: 0, green: 1, blue: 1),     // cyan
        Color(.sRGB, red: 0, green: 0.3, blue: 1),   // blue
        Color(.sRGB, red: 0.6, green: 0, blue: 1),   // purple
        Color(.sRGB, red: 1, green: 0, blue: 0.8),   // pink
        Color(.sRGB, red: 0, green: 0, blue: 0)      // off
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)
                    .frame(width: 46, height: 38)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 24), spacing: 6)], spacing: 6) {
                    ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                        Button { color = swatch } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(swatch)
                                .frame(width: 22, height: 22)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            channelSlider("R", channel(\.r), .red)
            channelSlider("G", channel(\.g), .green)
            channelSlider("B", channel(\.b), .blue)
        }
    }

    private func channelSlider(_ label: String, _ value: Binding<Double>, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption.monospaced()).foregroundStyle(tint).frame(width: 12)
            Slider(value: value, in: 0...1).tint(tint)
            Text("\(Int((value.wrappedValue * 255).rounded()))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: - RGB <-> Color

    private struct RGB { var r: Double; var g: Double; var b: Double }

    private func components() -> RGB {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return RGB(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }

    private func channel(_ keyPath: WritableKeyPath<RGB, Double>) -> Binding<Double> {
        Binding(
            get: { components()[keyPath: keyPath] },
            set: { newValue in
                var c = components()
                c[keyPath: keyPath] = newValue
                color = Color(.sRGB, red: c.r, green: c.g, blue: c.b)
            }
        )
    }
}
