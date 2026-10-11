import SwiftUI

/// Grab's design tokens: the sizes, spacing and shapes controls share, so a text field, a menu
/// and buttons that sit side by side line up exactly. Use these instead of numbers in views.
enum Design {
    enum Size {
        /// Every control in a bar: the link field, the format menu, the round buttons.
        static let control: CGFloat = 44
        /// Symbols inside bar controls.
        static let icon: CGFloat = 17
        /// The main action's symbol, a touch bolder.
        static let primaryIcon: CGFloat = 19
    }

    enum Spacing {
        /// Between controls in a bar.
        static let controls: CGFloat = 10
        /// Inside a capsule control, from its edge to its content.
        static let inset: CGFloat = 16
        /// Around a sheet's or tool window's content.
        static let sheet: CGFloat = 24
        /// Between the parts of a sheet (header, form, notes, buttons).
        static let section: CGFloat = 16
    }

    /// One scale of corner radii, from the smallest badge to the window-wide highlight.
    enum Radius {
        /// Duration badges on thumbnails.
        static let badge: CGFloat = 4
        /// Small thumbnails in lists, colour swatches.
        static let small: CGFloat = 6
        /// Thumbnails and previews.
        static let thumbnail: CGFloat = 10
        /// Grouped panels inside a window.
        static let box: CGFloat = 12
        /// Banners and cards on the main window.
        static let card: CGFloat = 16
        /// The drop highlight around the whole window.
        static let panel: CGFloat = 18
    }

    enum Typography {
        /// Text typed in, or chosen in, a bar control.
        static let control = Font.system(size: 15)
        /// Small counts and badges in a bar control.
        static let badge = Font.callout.weight(.medium)
    }
}

extension View {
    /// A capsule bar control: the shared height, inset and glass, for fields and menus.
    func barControl() -> some View {
        padding(.horizontal, Design.Spacing.inset)
            .frame(height: Design.Size.control)
            .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// A round bar button with the shared size: plain glass, or filled with the accent colour for
/// the main action.
struct BarButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? Design.Size.primaryIcon : Design.Size.icon,
                          weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: Design.Size.control, height: Design.Size.control)
            .background {
                if prominent { Circle().fill(Color.accentColor) }
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .contentShape(.circle)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
