import SwiftUI

/// Grab's design tokens for the sheets and tool windows: spacing and corner radii they share.
/// Use these instead of numbers in views.
enum Design {
    enum Spacing {
        /// Around a sheet's or tool window's content.
        static let sheet: CGFloat = 24
        /// Between the parts of a sheet (header, form, notes, buttons).
        static let section: CGFloat = 16
    }

    /// One scale of corner radii.
    enum Radius {
        /// Small thumbnails in lists, colour swatches.
        static let small: CGFloat = 6
        /// Thumbnails and previews.
        static let thumbnail: CGFloat = 10
        /// Grouped panels inside a window.
        static let box: CGFloat = 12
    }
}
