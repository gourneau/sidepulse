import SwiftUI

/// A fast, web-style hover tooltip. Unlike `.help()` (which waits ~1.5s for the
/// system tooltip), this fades in almost immediately and looks like a small
/// floating card. Shown below the element so it doesn't clip at the window top.
private struct InstantTip: ViewModifier {
    let text: String
    let trailing: Bool
    @State private var hovering = false
    @State private var show = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                hovering = isHovering
                if isHovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if hovering { withAnimation(.easeOut(duration: 0.1)) { show = true } }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) { show = false }
                }
            }
            .overlay(alignment: trailing ? .bottomTrailing : .bottomLeading) {
                if show {
                    Text(text)
                        .font(.caption2)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: 240, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.black.opacity(0.12)))
                        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                        .offset(y: 24)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(999)
                }
            }
    }
}

extension View {
    /// Fast floating tooltip on hover. `trailing` anchors it to the right (use for
    /// elements near the right edge so the card extends leftward).
    func instantTip(_ text: String, trailing: Bool = false) -> some View {
        modifier(InstantTip(text: text, trailing: trailing))
    }
}
