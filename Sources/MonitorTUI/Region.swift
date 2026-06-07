import Foundation

/// A single region of the TUI dashboard frame. Lines are pre-styled
/// (any ANSI escape sequences live in the string). Regions are
/// concatenated in declaration order by `RenderFrame.toANSI()`.
public struct Region: Sendable, Equatable {
    public let id: String
    public let lines: [String]

    public init(id: String, lines: [String]) {
        self.id = id
        self.lines = lines
    }
}
