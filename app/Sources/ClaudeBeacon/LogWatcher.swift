import Foundation

/// Watches the Claude desktop app's own log (`~/Library/Logs/Claude/main.log`)
/// for the one thing hooks can't see: permission / question prompts, which the
/// desktop app handles internally and never surfaces to the hook system.
///
/// Two log lines carry everything we need (verified against the shipping app):
///   • "Emitted tool permission request <reqID> for <Tool> in session local_<uuid>"
///       → a session is waiting on you (covers tool permission AND AskUserQuestion).
///   • "Received permission response for <reqID>: ..."
///       → you answered; clear that request.
///
/// The `local_<uuid>` is mapped to the CLI session UUID (and human title) via the
/// desktop session store so log-derived state merges with hook-derived state for
/// the same session.
///
/// This path is deliberately fail-safe: it only ever *adds* desktop alerts. If a
/// future desktop build renames these lines, desktop-permission detection simply
/// goes quiet — nothing crashes, and every other signal keeps working.
final class LogWatcher {
    private let store: SessionStore
    private let resolver = DesktopSessionResolver()
    private let queue = DispatchQueue.main

    private let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Claude/main.log")

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var offset: UInt64 = 0
    private var partial = Data()
    private var backstop: Timer?

    // "Emitted tool permission request <reqID> for <Tool> in session local_<uuid>"
    private let emitRE = try! NSRegularExpression(
        pattern: #"Emitted tool permission request ([0-9a-fA-F-]{8,}) for (\S+) in session (local_[0-9a-fA-F-]+)"#)
    // "Received permission response for <reqID>:" — the user answered.
    private let respRE = try! NSRegularExpression(
        pattern: #"Received permission response for ([0-9a-fA-F-]{8,})"#)
    // "Permission request <reqID> for <Tool> aborted" — cancelled / interrupted /
    // superseded. Ends the request just like a response, but the app logs it
    // differently; without this the request would leak and stay red forever.
    private let abortRE = try! NSRegularExpression(
        pattern: #"Permission request ([0-9a-fA-F-]{8,}) for \S+ aborted"#)

    init(store: SessionStore) {
        self.store = store
    }

    func start() {
        openAndSeekToEnd()
        arm()
        // Backstop poll: guarantees we catch appends even if a vnode event is
        // ever coalesced or missed. Reads are offset-guarded, so this never
        // double-processes a line.
        let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.readNew() }
        RunLoop.main.add(t, forMode: .common)
        backstop = t
        Log.write("LogWatcher started on \(logURL.path)")
    }

    func stop() {
        source?.cancel(); source = nil
        backstop?.invalidate(); backstop = nil
    }

    // MARK: File handling

    private func openAndSeekToEnd() {
        closeFD()
        fd = open(logURL.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.write("LogWatcher: cannot open main.log (errno \(errno)); retrying in 3s")
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reopen() }
            return
        }
        // Start at end of file: we only care about prompts from now on. History
        // is stale (already answered) and would raise false alerts.
        if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? UInt64 {
            offset = size
        } else {
            offset = 0
        }
        partial.removeAll(keepingCapacity: true)
    }

    private func arm() {
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .link], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self = self, let src = self.source else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                // Log rotated (main.log → main1.log, fresh main.log created).
                self.reopen()
            } else {
                self.readNew()
            }
        }
        src.setCancelHandler { [weak self] in self?.closeFD() }
        source = src
        src.resume()
    }

    private func reopen() {
        source?.cancel(); source = nil
        // Reopen the (new) file from its start so we don't miss early lines.
        closeFD()
        fd = open(logURL.path, O_EVTONLY)
        guard fd >= 0 else {
            queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reopen() }
            return
        }
        offset = 0
        partial.removeAll(keepingCapacity: true)
        arm()
        readNew()
    }

    private func closeFD() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    /// Read everything appended since `offset` and process complete lines.
    private func readNew() {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }

        // Detect truncation/rotation-in-place: file shrank below our cursor.
        let end = handle.seekToEndOfFile()
        if end < offset {
            offset = 0
            partial.removeAll(keepingCapacity: true)
        }
        guard end > offset else { return }
        handle.seek(toFileOffset: offset)
        let chunk = handle.readData(ofLength: Int(min(end - offset, 4 * 1024 * 1024)))
        offset += UInt64(chunk.count)
        guard !chunk.isEmpty else { return }

        partial.append(chunk)
        // Split on newlines; keep any trailing partial line for next time.
        let nl = UInt8(ascii: "\n")
        var start = partial.startIndex
        while let idx = partial[start...].firstIndex(of: nl) {
            let lineData = partial[start..<idx]
            if let line = String(data: lineData, encoding: .utf8) { process(line) }
            start = partial.index(after: idx)
        }
        partial.removeSubrange(partial.startIndex..<start)
        // Guard against an unbounded partial (a pathological line with no newline).
        if partial.count > 1 * 1024 * 1024 { partial.removeAll(keepingCapacity: true) }
    }

    // MARK: Line processing

    private func process(_ line: String) {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)

        if let m = emitRE.firstMatch(in: line, range: range) {
            let reqID = sub(line, m, 1)
            let tool = sub(line, m, 2)
            let local = sub(line, m, 3)
            guard !reqID.isEmpty, !local.isEmpty else { return }
            let kind = (tool == "AskUserQuestion") ? "question" : "permission"
            let info = resolver.resolve(local)
            let sid = info?.cliSessionID ?? local   // fall back to the local id
            let msg = kind == "question"
                ? "Claude is asking a question"
                : "Claude needs permission to use \(tool)"
            let isNew = store.desktopRequest(cliSessionID: sid, title: info?.title, cwd: info?.cwd,
                                             pid: nil, kind: kind, reqID: reqID, message: msg)
            if isNew {
                Log.write("desktop \(kind) prompt: \(info?.title ?? sid) (\(tool)) req=\(reqID.prefix(8))")
            }
            return
        }

        if let m = respRE.firstMatch(in: line, range: range) {
            let reqID = sub(line, m, 1)
            if !reqID.isEmpty, store.desktopResolve(reqID: reqID) {
                Log.write("desktop prompt resolved: req=\(reqID.prefix(8))")
            }
            return
        }

        if let m = abortRE.firstMatch(in: line, range: range) {
            let reqID = sub(line, m, 1)
            if !reqID.isEmpty, store.desktopResolve(reqID: reqID) {
                Log.write("desktop prompt aborted: req=\(reqID.prefix(8))")
            }
        }
    }

    private func sub(_ s: String, _ m: NSTextCheckingResult, _ i: Int) -> String {
        guard let r = Range(m.range(at: i), in: s) else { return "" }
        return String(s[r])
    }
}

// MARK: - local_<uuid> → CLI session UUID + title

/// Resolves the desktop app's internal `local_<uuid>` session ids to the CLI
/// session UUID and human title, by reading the desktop session store JSONs.
final class DesktopSessionResolver {
    struct Info { let cliSessionID: String; let title: String?; let cwd: String? }

    private let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    /// Cache the on-disk file URL per local id (stable); the title is re-read
    /// from it each call so renames are reflected.
    private var fileCache: [String: URL] = [:]

    func resolve(_ localID: String) -> Info? {
        let url = fileCache[localID] ?? findFile(localID)
        guard let url = url else { return nil }
        fileCache[localID] = url
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let cli = obj["cliSessionId"] as? String, !cli.isEmpty else { return nil }
        return Info(cliSessionID: cli,
                    title: obj["title"] as? String,
                    cwd: obj["cwd"] as? String)
    }

    private func findFile(_ localID: String) -> URL? {
        let target = "\(localID).json"
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles], errorHandler: nil) else { return nil }
        for case let u as URL in en where u.lastPathComponent == target {
            return u
        }
        return nil
    }
}
