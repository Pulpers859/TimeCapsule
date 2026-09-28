import AVFoundation

/// Owns the audio session while a memory's video is on screen.
///
/// `.ambient`: a video autoplays with sound only when the ring/silent switch
/// allows it, and never stops what the user is already listening to.
///
/// It was `.playback`, chosen so that nobody with the switch on silent would
/// think video memories had no sound. On device that was the wrong call:
/// swiping onto a video with the phone silenced played it out loud, which
/// is exactly what silencing a phone is meant to prevent. The note here said
/// muted autoplay was "a product decision, not a technical one"; it has been
/// made, and silent means silent.
///
/// Not `.soloAmbient`, the default, which also obeys the switch but is
/// exclusive: opening a video with the phone silenced would stop the user's
/// podcast to play a video they cannot hear. `.ambient` mixes instead, so
/// with the ringer on a video's sound plays over whatever else is playing
/// rather than pausing it — the smaller of the two costs.
///
/// Live Photos in the viewer share this session, so they obey the switch
/// too. Under `.playback` a Live Photo held after watching a video played
/// its sound on a silenced phone.
///
/// The mode is `.default` because `.moviePlayback` is only valid with
/// `.playback`. Asked for with `.ambient`, `setCategory` fails, and under
/// `try?` that failure is silent — the category would never have changed.
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
            try? session.setCategory(.ambient, mode: .default)
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
