import Foundation

/// WCAG relative luminance and contrast ratio, over sRGB components in 0…1.
///
/// Here so a check can *measure* what a rendered surface and its text actually are, rather than
/// assert that some constants are the ones somebody intended. A colour pair either clears the
/// threshold or it does not, and that is a number, not an opinion.
public enum Contrast {
    /// Relative luminance, per WCAG 2.1.
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func channel(_ value: Double) -> Double {
            let v = min(max(value, 0), 1)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// 1…21. 4.5 is the floor for normal text; 3 for large text, icons and control edges.
    public static func ratio(_ first: (red: Double, green: Double, blue: Double),
                             _ second: (red: Double, green: Double, blue: Double)) -> Double {
        let a = luminance(red: first.red, green: first.green, blue: first.blue)
        let b = luminance(red: second.red, green: second.green, blue: second.blue)
        let lighter = Swift.max(a, b)
        let darker = Swift.min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// The floors this app holds itself to.
    public static let textFloor = 4.5
    public static let controlFloor = 3.0
}
