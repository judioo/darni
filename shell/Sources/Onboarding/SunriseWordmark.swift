import SidebarModel
import SwiftUI

extension SunrisePainter {
    /// The Darni wordmark as the sunrise draws it: "Dar" in ink and "ni" in the arc's blue,
    /// bold, letter spacing -0.02 em (brand board, option B). It stands alone wherever it
    /// appears, with no line of words beside it. The sky behind it is the morning's, so
    /// these are the wordmark's colours for a light background.
    static func wordmark(height H: CGFloat) -> Text {
        let size = H * 0.05
        return (Text(Brand.wordmarkLead).foregroundColor(MarkPalette.ink.color)
            + Text(Brand.wordmarkTail).foregroundColor(MarkPalette.blue.color))
            .font(.system(size: size, weight: .bold))
            .tracking(-0.02 * size)
    }
}
