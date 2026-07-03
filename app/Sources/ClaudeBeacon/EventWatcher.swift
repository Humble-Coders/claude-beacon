import Foundation

/// Watches ~/.claude-beacon/events/ with a kqueue-backed DispatchSource and
/// feeds each event file into the SessionStore. Millisecond latency, no polling.
///
/// On start it replays everything already spooled in the directory (crash /
/// offline recovery) before arming the watch.
final class EventWatcher {
    private let store: SessionStore
    private let dir = BeaconPaths.events
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private let queue = DispatchQueue.main   // keep store single-threaded on main

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        BeaconPaths.ensure()
        // 1. Replay whatever is already spooled.
        drain()
        // 2. Arm the directory watch.
        arm()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func arm() {
        dirFD = open(dir.path, O_EVTONLY)
        guard dirFD >= 0 else {
            Log.write("EventWatcher: failed to open \(dir.path) (errno \(errno)); retrying in 2s")
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write, .extend], queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }
        source = src
        src.resume()
        Log.write("EventWatcher armed on \(dir.path)")
    }

    /// Read, apply, and delete every event file, in timestamp (filename) order.
    private func drain() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let files = names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()   // filenames are "<epoch_ms>-<pid>.json" => chronological

        for name in files {
            let url = dir.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }   // always consume, even on decode failure
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let event = try JSONDecoder().decode(BeaconEvent.self, from: data)
                store.apply(event)   // store fires onNewAlert for fresh red alerts
            } catch {
                Log.write("EventWatcher: bad event file \(name): \(error)")
            }
        }
    }
}
