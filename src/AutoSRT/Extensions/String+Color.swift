import Foundation

/// Type alias for RGB tuple to make it easier to extend
typealias Tuple3RGB = (red: Int, green: Int, blue: Int)

extension String {
    /// Convert hex color string to RGB components
    /// - Returns: A tuple containing RGB components (red, green, blue)
    func hexToRGB() -> Tuple3RGB {
        var hexSanitized = self.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        // Remove "0x" or "&H" prefix if present
        if hexSanitized.hasPrefix("0x") {
            hexSanitized = String(hexSanitized.dropFirst(2))
        } else if hexSanitized.hasPrefix("&H") {
            hexSanitized = String(hexSanitized.dropFirst(2))
        }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let red = Int((rgb & 0xFF0000) >> 16)
        let green = Int((rgb & 0x00FF00) >> 8)
        let blue = Int(rgb & 0x0000FF)

        return (red: red, green: green, blue: blue)
    }

    /// Convert hex color to ASS format color string
    /// - Returns: ASS format color string (e.g., "&H00FFFFFF")
    func toASSColor() -> String {
        var hexSanitized = self.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        // If it's already in ASS format, return as is
        if hexSanitized.hasPrefix("&H") {
            return hexSanitized
        }

        // Remove "0x" prefix if present
        if hexSanitized.hasPrefix("0x") {
            hexSanitized = String(hexSanitized.dropFirst(2))
        }

        // Convert to ASS format (AABBGGRR)
        let rgb = hexToRGB()
        return String(format: "&H00%02X%02X%02X", rgb.blue, rgb.green, rgb.red)
    }

    /// Calculate the contrast color (black or white) based on luminance
    /// - Returns: ASS format color string for the contrasting color
    func contrastColor() -> String {
        let rgb: Tuple3RGB = hexToRGB()
        let rr = Double(rgb.red) / 255.0
        let gg = Double(rgb.green) / 255.0
        let bb = Double(rgb.blue) / 255.0
        let luminance = 0.2126 * rr + 0.7152 * gg + 0.0722 * bb
        return luminance > 0.5 ? "&H00000000" : "&H00FFFFFF"
    }
}
