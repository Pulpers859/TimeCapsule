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
    /// Called immediately before a player starts. Safe to call repeatedly;
    /// re-activating an already-active session is a no-op inside AVFoundation.
    static func begin() {
        // Off the main actor on purpose: both calls take a cross-process hop to
        // mediaserverd and can block for long enough to drop a frame, and this
        // fires on every swipe onto a video.
        Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback)
            try? session.setActive(true)
        }
    }

    /// Called when the viewer closes and no video can be playing any more.
    static func end() {
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }
}
