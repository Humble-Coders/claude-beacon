import Foundation

/// Periodically removes dead sessions the hook never got to clean up:
///  - the claude process is gone but no `ended` event arrived (crash / kill -9)
///  - any session older than the 12h TTL (stuck state safety net)
final class Eviction {
    private let store: SessionStore
    private var timer: Timer?
    private let interval: TimeInterval = 30
    private let ttl: TimeInterval = 12 * 60 * 60

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sweep() {
        let now = Date()
        for s in store.all {
            // 1. TTL: drop very old records regardless of state.
            let ageTS = Date(timeIntervalSince1970: Double(s.lastEventTS) / 1000.0)
            if now.timeIntervalSince(ageTS) > ttl {
                Log.write("eviction: TTL drop \(s.project) (\(s.sessionID.prefix(8)))")
                store.remove(s.sessionID)
                continue
            }
            // 2. Process liveness: kill(pid, 0) — ESRCH means the process is gone.
            guard let pid = s.claudePID, pid > 0 else { continue }
            let alive = (kill(pid_t(pid), 0) == 0) || errno == EPERM
            if !alive {
                Log.write("eviction: pid \(pid) gone, drop \(s.project) (\(s.sessionID.prefix(8)))")
                store.remove(s.sessionID)
            }
        }
    }
}
