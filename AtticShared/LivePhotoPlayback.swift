import Foundation

/// When the viewer plays a Live Photo, and how.
///
/// The view calls this on every SwiftUI update, which is many times for each
/// thing that actually happens, so the rules have to hold up to being asked
/// again and again with nothing changed. Framework-free, so they are tested
/// on every CI run rather than only ever seen on a phone.
///
/// Only ever on request: a press of the LIVE button, or holding the photo
/// (which the view handles itself). It used to play Photos' short hint on
/// every arrival, and on device that read as the photo moving on its own.
nonisolated enum LivePhotoPlayback {
    nonisolated enum Action: Equatable {
        /// Nothing new to do.
        case nothing
        /// Not allowed to play now: the page is not the current one, or a
        /// sheet or alert is over the viewer.
        case stop
        /// The whole Live Photo, with its sound.
        case full
    }

    nonisolated struct State: Equatable {
        /// The LIVE-button count last seen. `nil` until the first update, so
        /// a press made before this page existed is never replayed on it.
        var lastRequest: Int?
        /// The button was pressed before the motion had loaded.
        var isFullPending = false

        init(lastRequest: Int? = nil, isFullPending: Bool = false) {
            self.lastRequest = lastRequest
            self.isFullPending = isFullPending
        }
    }

    /// - Parameters:
    ///   - request: the LIVE button's press count. Only a change is a press.
    ///   - motionArrived: the motion for this page has just loaded.
    ///   - hasMotion: it is loaded now.
    ///   - canPlay: this is the current page and nothing is over it.
    static func update(
        _ state: inout State,
        request: Int,
        motionArrived: Bool,
        hasMotion: Bool,
        canPlay: Bool
    ) -> Action {
        let isNewRequest = state.lastRequest.map { $0 != request } ?? false
        state.lastRequest = request

        guard canPlay else {
            state.isFullPending = false
            return .stop
        }
        if isNewRequest {
            guard hasMotion else {
                state.isFullPending = true
                return .nothing
            }
            state.isFullPending = false
            return .full
        }
        // Arriving plays nothing by itself — only a press still waiting on
        // the download.
        if motionArrived, state.isFullPending {
            state.isFullPending = false
            return .full
        }
        return .nothing
    }
}
