import Foundation

/// CSI escape-sequence primitives. Hand-rolled — no library dependency.
/// Every helper emits one or more CSI sequences only; no platform-
/// specific termios calls in V.15a-1 (those land in V.15a-2).
public enum ANSI {
    public static let esc = "\u{1B}"
    public static let csi = "\u{1B}["

    /// `ESC[2J` — clear entire display.
    public static func clear() -> String {
        return "\(csi)2J"
    }

    /// `ESC[H` — move cursor to home position (row 1, column 1).
    public static func home() -> String {
        return "\(csi)H"
    }

    /// `ESC[<row>;<col>H` — move cursor to row, column (1-indexed).
    public static func moveTo(row: Int, col: Int) -> String {
        return "\(csi)\(row);\(col)H"
    }

    /// `ESC[<value>m` — set graphics attribute (color, intensity).
    /// 30..37 = foreground, 40..47 = background, 1 = bold.
    public static func color(_ value: Int) -> String {
        return "\(csi)\(value)m"
    }

    /// `ESC[1m` — bold.
    public static func bold() -> String {
        return "\(csi)1m"
    }

    /// `ESC[0m` — reset all attributes.
    public static func reset() -> String {
        return "\(csi)0m"
    }
}
