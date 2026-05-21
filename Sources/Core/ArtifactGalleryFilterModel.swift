import Foundation

/// V.9b-2 — Chip-state model for `ArtifactGalleryView`'s toolbar
/// filter form. Wraps the four `ArtifactFilter` dimensions (source-
/// pane chips, tag chips, version min/max, since-date) with mutation
/// methods the SwiftUI form binds to, and emits an `ArtifactFilter`
/// for `ArtifactStore.list(filter:)`.
///
/// Kept in Core so the chip → filter mapping is unit-testable from
/// `SenkaniTests` without driving SwiftUI. The view supplies the
/// 250 ms debounce around `filter` reads (spec: `## Filter UI` in
/// `spec/artifact_gallery.md`).
public struct ArtifactGalleryFilterModel: Sendable, Equatable {
    /// Multi-select source-pane chips. Default = every pane selected.
    public var selectedSourcePanes: Set<ArtifactSourcePane>

    /// Tag chips composed OR-within (any chip-tag overlap matches).
    public var tagChips: Set<String>

    /// Version range minimum (inclusive). `nil` = unbounded below.
    public var versionMin: Int?

    /// Version range maximum (inclusive). `nil` = unbounded above.
    public var versionMax: Int?

    /// Created-at lower bound. `nil` = no since constraint.
    public var since: Date?

    public init(
        selectedSourcePanes: Set<ArtifactSourcePane> = Set(ArtifactSourcePane.allCases),
        tagChips: Set<String> = [],
        versionMin: Int? = nil,
        versionMax: Int? = nil,
        since: Date? = nil
    ) {
        self.selectedSourcePanes = selectedSourcePanes
        self.tagChips = tagChips
        self.versionMin = versionMin
        self.versionMax = versionMax
        self.since = since
    }

    /// Default model: every source-pane chip selected, no tag chips,
    /// no version bounds, no since-date.
    public static let unconstrained = ArtifactGalleryFilterModel()

    /// Debounce window the view waits between filter mutation and
    /// the next `ArtifactStore.list(filter:)` call. Captured here so
    /// the contract is queryable from non-SwiftUI tests; the actual
    /// timing lives in `ArtifactGalleryView`.
    public static let debounceMilliseconds: Int = 250

    /// True when no dimension carries a constraint beyond the
    /// default. Drives the "Clear filter" button enabled state.
    public var isUnconstrained: Bool {
        selectedSourcePanes == Set(ArtifactSourcePane.allCases)
            && tagChips.isEmpty
            && versionMin == nil
            && versionMax == nil
            && since == nil
    }

    /// Emit the `ArtifactFilter` that the model represents. The
    /// store's `list(filter:)` treats nil/empty as unconstrained per
    /// dimension; this property collapses defaults to nil so the
    /// emitted filter equals `.unconstrained` exactly when
    /// `isUnconstrained == true`.
    public var filter: ArtifactFilter {
        let panes: Set<ArtifactSourcePane>?
        if selectedSourcePanes == Set(ArtifactSourcePane.allCases) || selectedSourcePanes.isEmpty {
            panes = nil
        } else {
            panes = selectedSourcePanes
        }

        let tags: Set<String>? = tagChips.isEmpty ? nil : tagChips

        let range: ClosedRange<Int>?
        if versionMin != nil || versionMax != nil {
            let lo = versionMin ?? Int.min
            let hi = versionMax ?? Int.max
            range = lo <= hi ? lo...hi : nil
        } else {
            range = nil
        }

        return ArtifactFilter(
            tags: tags,
            sourcePane: panes,
            versionRange: range,
            since: since
        )
    }

    // MARK: - Chip mutation

    /// Toggle a source-pane chip on/off. Does not enforce non-empty
    /// — view layer decides whether to snap-back to all-selected
    /// when the operator deselects every chip (the empty-set case
    /// also emits `.unconstrained` per the `filter` mapping above,
    /// so the user sees every artifact either way).
    public mutating func toggleSourcePane(_ pane: ArtifactSourcePane) {
        if selectedSourcePanes.contains(pane) {
            selectedSourcePanes.remove(pane)
        } else {
            selectedSourcePanes.insert(pane)
        }
    }

    /// Add a tag chip. Idempotent (Set semantics). Empty / whitespace
    /// strings are ignored — the autocomplete UI surfaces real tags
    /// only, and the model refuses to record a meaningless chip.
    public mutating func addTagChip(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tagChips.insert(trimmed)
    }

    /// Remove a tag chip. Idempotent.
    public mutating func removeTagChip(_ tag: String) {
        tagChips.remove(tag)
    }

    /// Reset every dimension to the unconstrained default.
    public mutating func clearAll() {
        self = .unconstrained
    }
}
