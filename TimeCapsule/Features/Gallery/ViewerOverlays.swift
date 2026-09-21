import Foundation

/// Everything that can cover the full-screen viewer, as one value.
///
/// This exists because one specific mistake has now shipped twice: the rule
/// "a video must not play while something is presented over it" was written
/// as a hand-maintained `||` chain of separate booleans, and twice a new
/// modal was added without being added to the chain. The second time, the
/// video played audibly underneath a "Couldn't Share" alert.
///
/// A comment asserting the list is complete does not help — the last one
/// said exactly that, and was wrong. So completeness is checked three
/// different ways instead, each catching a different mistake:
///
/// 1. **Adding a field is a compile error** until every construction site
///    supplies it. That is why none of these have default values: the
///    memberwise initialiser is the enforcement.
/// 2. **A field missing from `all`** fails `ViewerOverlaysTests`, which
///    compares `all.count` against a reflection of the real stored fields.
/// 3. **A new presentation modifier in the viewer with no field here** fails
///    `ViewerPresentationTripwireTests`, which counts the modifiers in the
///    source file itself.
///
/// Two of these are not presentations at all — `preparingShare` and
/// `deleting` put nothing on screen. They still belong, because they block
/// playback, and because the chain they replace missed that distinction too.
struct ViewerOverlays: Equatable {
    /// `.confirmationDialog` — "Delete this item?"
    var deleteConfirmation: Bool
    /// `.sheet(item: $shareItem)` — the system share sheet.
    var shareSheet: Bool
    /// `.alert` — "Couldn't Delete".
    var deleteFailureAlert: Bool
    /// `.alert` — "Couldn't Share".
    var shareFailureAlert: Bool
    /// `.sheet(item: $infoAsset)` — the memory information panel.
    var infoSheet: Bool
    /// No UI of its own: an export is running and the chrome is disabled.
    var preparingShare: Bool
    /// No UI of its own: a delete is in flight.
    var deleting: Bool

    /// Every stored field, so the rule below cannot quietly skip one.
    ///
    /// A `Mirror` would find the fields without this list, but not in a form
    /// that can be written to. The list is instead checked *against* a
    /// `Mirror` by the tests, which catches it going stale.
    static let all: [WritableKeyPath<ViewerOverlays, Bool>] = [
        \.deleteConfirmation,
        \.shareSheet,
        \.deleteFailureAlert,
        \.shareFailureAlert,
        \.infoSheet,
        \.preparingShare,
        \.deleting,
    ]

    /// How many of the above are real SwiftUI presentation modifiers.
    ///
    /// Read by the source-level tripwire test, which counts the modifiers in
    /// `FullScreenPhotoView.swift` and refuses to let the two drift apart.
    static let presentationCount = 5

    /// The rule. A video may run only when nothing is over the viewer.
    ///
    /// Derived from `all` rather than written as a chain, so a registered
    /// field cannot be left out of the answer.
    var blocksPlayback: Bool {
        ViewerOverlays.all.contains { self[keyPath: $0] }
    }
}
