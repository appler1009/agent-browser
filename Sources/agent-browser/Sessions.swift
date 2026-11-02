import Foundation

// Finding and talking to helpers that are already running. Unlike sendToHelper this never starts one.

private func setTimeouts(_ fd: Int32, seconds: Double) {
    var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

/// One request to an already running session. Returns nil when no helper answers.
func sendToRunning(session: String, request: [String: Any], timeout: Double = 5) -> [String: Any]? {
    guard let fd = connectSocket(socketPath(session: session)) else { return nil }
    defer { close(fd) }
    setTimeouts(fd, seconds: timeout)
    writeAllToSocket(fd, jsonString(request) + "\n")
    guard let line = readLineFromSocket(fd) else { return nil }
    return parseJSON(line)
}

/// Status of every live session, sorted by name, plus the number of stale socket files.
func listSessions(timeout: Double = 0.8) -> (sessions: [[String: Any]], stale: Int) {
    let dir = NSHomeDirectory() + "/.agent-browser"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(5)) }.sorted()
    let lock = NSLock()
    var live: [[String: Any]] = []
    var stale = 0
    DispatchQueue.concurrentPerform(iterations: names.count) { i in
        let name = names[i]
        let r = sendToRunning(session: name, request: ["cmd": "status", "args": [:]], timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        if let r, r["ok"] as? Bool == true, var s = r["result"] as? [String: Any] {
            s["session"] = name
            live.append(s)
        } else {
            stale += 1
        }
    }
    return (live.sorted { ($0["session"] as? String ?? "") < ($1["session"] as? String ?? "") }, stale)
}
