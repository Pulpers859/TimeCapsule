import AVFoundation

/// Owns the audio session while a memory's video is on screen.
///
/// The app previously never configured one, so it ran on the default
/// `.soloAmbient` category. That has two consequences, and they pull in
/// opposite directions:
///
/// 1. `.soloAmbient` obeys the ring/silent switch, so every user browsing with
///    the switch flicked to silent — which is most of them — heard nothing and
///    would reasonably report that video memories have no sound.
/// 2. `.soloAmbient` is still *exclusive*, so it stopped whatever the user was
///    listening to anyway. The worst of both: their podcast stopped and the
///    video was silent.
///
/// `.playback` fixes (1) and is the category Photos itself uses for the same
/// job, so the behaviour matches what people already expect from a memory
/// viewer: opening a video takes over audio.
///
/// (2) is handled by *when* the session is activated rather than by the
/// category. Nothing is activated until a video actually starts playing, and
/// the session stands down with `.notifyOthersOnDeactivation` when the viewer
/// closes, which is the flag that lets the user's music resume instead of
/// staying stopped.
///
/// Note this still means auto-play on swipe interrupts background audio. The
/// alternative — auto-play muted with a tap to unmute — is a product decision,
/// not a technical one, and is deliberately not made here.
nonisolated enum VideoAudioSession {
    /// Both calls run here, in the order they were made.
    ///
    /// They used to be two independent `Task.detached`s at different
    /// priorities, which gives no ordering at all — and the file's own note
    /// below says these calls hop to `mediaserverd` and can block, so the
    /// window is wide. Swiping onto a video and closing the viewer a moment
    /// later could run the deactivation *first*: the sequence ended with the
    /// session active and `.playback` held, with no viewer on screen, and
    /// the `.notifyOthersOnDeactivation` that was meant to restart the
    /// user's music had already been spent. Their music stayed dead until
    /// the app was suspended.
    ///
    /// A serial `DispatchQueue` rather than an actor: `async` blocks run in
    /// submission order, and both callers submit from the main actor, so the
    /// order they are called in is the order they take effect in. Awaiting
    /// an actor only serialises *execution*, not arrival, so two tasks
    /// racing to it can still arrive reversed.
    private static let queue = DispatchQueue(
        label: "Attic.VideoAudioSession",
        qos: .userInitiated
    )

    /// Called immediately before a player starts. Safe to call repeatedly;
    /// re-activating an already-active session is a no-op inside AVFoundation.
    static func begin() {
        // Off the main actor on purpose: both calls take a cross-process hop to
        // mediaserverd and can block for long enough to drop a frame, and this
        // fires on every swipe onto a video.
        queue.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }

    /// Called when the viewer closes and no video can be playing any more.
    static func end() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }
}
