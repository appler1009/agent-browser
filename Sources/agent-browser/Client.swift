import Foundation

struct ClientError: Error {
    var code: String
    var message: String
}

private func spawnHost() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    p.arguments = ["host"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
        throw ClientError(code: "DAEMON_START_FAILED", message: "could not start helper: \(error.localizedDescription)")
    }
}

/// Asks the host process (started if needed) to run this session; returns once its socket is listening.
private func startSession(session: String, profile: String?) throws {
    let ctl = hostControlPath()
    var spawned = false
    for _ in 0..<150 {
        if let fd = connectSocket(ctl) {
            defer { close(fd) }
            var req: [String: Any] = ["host": "start", "session": session]
            if let profile { req["profile"] = profile }
            writeAllToSocket(fd, jsonString(req) + "\n")
            if let line = readLineFromSocket(fd), parseJSON(line)?["ok"] as? Bool == true { return }
            throw ClientError(code: "DAEMON_START_FAILED", message: "helper refused to start session \"\(session)\"")
        }
        if !spawned { try spawnHost(); spawned = true }
        usleep(100_000)
    }
    throw ClientError(code: "DAEMON_START_FAILED", message: "helper did not come up within 15s")
}

private func connectOrStart(session: String, profile: String?) throws -> Int32 {
    let path = socketPath(session: session)
    if let fd = connectSocket(path) { return fd }
    try startSession(session: session, profile: profile)
    for _ in 0..<50 {
        if let fd = connectSocket(path) { return fd }
        usleep(100_000)
    }
    throw ClientError(code: "DAEMON_START_FAILED", message: "session \"\(session)\" did not come up")
}

/// Sends one request to the session's helper (starting it if needed) and returns its JSON reply line.
func sendToHelper(session: String, profile: String? = nil, request: [String: Any]) -> Result<String, ClientError> {
    do {
        let fd = try connectOrStart(session: session, profile: profile)
        defer { close(fd) }
        var request = request
        let env = ProcessInfo.processInfo.environment.filter { SessionEnv.forwarded.contains($0.key) }
        if !env.isEmpty { request["env"] = env }
        writeAllToSocket(fd, jsonString(request) + "\n")
        guard let line = readLineFromSocket(fd) else {
            return .failure(ClientError(code: "NO_RESPONSE", message: "helper closed the connection without replying"))
        }
        return .success(line)
    } catch let e as ClientError {
        return .failure(e)
    } catch {
        return .failure(ClientError(code: "INTERNAL", message: "\(error)"))
    }
}
