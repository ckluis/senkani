import Foundation

public enum ANSIStripper {
    /// Remove ANSI escape sequences from text.
    /// Handles CSI sequences (ESC [ ... letter), OSC sequences (ESC ] ... BEL/ST),
    /// and simple two-byte sequences (ESC letter).
    public static func strip(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var chars = input.makeIterator()

        while let ch = chars.next() {
            if ch == "\u{1B}" {
                // Start of escape sequence
                guard let next = chars.next() else { break }
                switch next {
                case "[":
                    // CSI sequence: consume until a letter (@ through ~)
                    while let c = chars.next() {
                        if c >= "@" && c <= "~" { break }
                    }
                case "]":
                    // OSC sequence: consume until BEL (\u{07}) or ST (ESC \)
                    while let c = chars.next() {
                        if c == "\u{07}" { break }
                        if c == "\u{1B}" {
                            // Check for ST (ESC \)
                            let _ = chars.next()
                            break
                        }
                    }
                default:
                    // Two-byte escape (ESC + single char), just skip
                    break
                }
            } else {
                result.append(ch)
            }
        }

        return result
    }
}
