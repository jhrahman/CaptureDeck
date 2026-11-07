import CoreGraphics

/// The arithmetic behind the Resize dialog. Pure, so it is unit-tested.
public enum ResizeMath {
    public static let maxDimension = 30_000

    /// Size after scaling by `percent` (100 = unchanged), at least 1 px.
    public static func size(from original: (width: Int, height: Int), percent: Double) -> (width: Int, height: Int) {
        (max(1, Int((Double(original.width) * percent / 100).rounded())),
         max(1, Int((Double(original.height) * percent / 100).rounded())))
    }

    /// The height that keeps the original proportions for a new width.
    public static func height(forWidth width: Int, keepingProportionsOf original: (width: Int, height: Int)) -> Int {
        guard original.width > 0 else { return original.height }
        return max(1, Int((Double(width) * Double(original.height) / Double(original.width)).rounded()))
    }

    public static func width(forHeight height: Int, keepingProportionsOf original: (width: Int, height: Int)) -> Int {
        guard original.height > 0 else { return original.width }
        return max(1, Int((Double(height) * Double(original.width) / Double(original.height)).rounded()))
    }

    public static func isValid(width: Int, height: Int) -> Bool {
        (1...maxDimension).contains(width) && (1...maxDimension).contains(height)
    }
}
