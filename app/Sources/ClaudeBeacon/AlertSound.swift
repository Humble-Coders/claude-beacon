import AppKit

/// Two distinct sounds:
///  • `playOnce` — the attention chime (a low sonar "Submarine"), played up to
///    3× per sticky alert (permission / question) that waits for you.
///  • `playDone` — a brighter one-shot "completion" ding for a finished turn,
///    which is a self-clearing notification, not a nag.
enum AlertSound {
    private static let alertCandidates = ["Submarine", "Ping", "Tink", "Glass"]
    private static let doneCandidates  = ["Glass", "Hero", "Blow", "Ping"]

    private static func sound(_ names: [String]) -> NSSound? {
        for name in names {
            if let s = NSSound(named: NSSound.Name(name)) { return s }
        }
        return nil
    }

    /// One attention chime (respects the sound setting). Restarts if still ringing.
    static func playOnce() {
        guard Settings.shared.alertSound else { return }
        guard let s = sound(alertCandidates) else {
            Log.write("alert chime: no system sound available"); return
        }
        if s.isPlaying { s.stop() }
        s.play()
        Log.write("alert chime")
    }

    /// The distinct one-shot "turn finished" ding (respects the sound setting).
    static func playDone() {
        guard Settings.shared.alertSound else { return }
        guard let s = sound(doneCandidates) else { return }
        if s.isPlaying { s.stop() }
        s.play()
        Log.write("done chime")
    }

    /// Unconditional one-off play (used when toggling the setting on).
    static func preview() {
        sound(alertCandidates)?.play()
    }
}
