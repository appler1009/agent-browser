import Foundation

struct ClientError: Error {
    var code: String
    var message: String
}

private func spawnDaemon(session: String, profile: String?) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
    p.arguments = ["--session", session] + (profile.map { ["--profile", $0] } ?? []) + ["daemon"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch {
        throw ClientError(code: "DAEMON_START_FAILED", message: "could not start helper: \(error.localizedDescription)")
    }
}

private func connectOrStart(session: String, profile: String?) throws -> Int32 {
    let path = socketPath(session: session)
    if let fd = connectSocket(path) { return fd }
    try spawnDaemon(session: session, profile: profile)
    for _ in 0..<150 {
        usleep(100_000)
        if let fd = connectSocket(path) { return fd }
    }
    throw ClientError(code: "DAEMON_START_FAILED", message: "helper did not come up within 15s")
}

/// Sends one request to the session's helper (starting it if needed) and returns its JSON reply line.
func sendToHelper(session: String, profile: String? = nil, request: [String: Any]) -> Result<String, ClientError> {
    do {
        let fd = try connectOrStart(session: session, profile: profile)
        defer { close(fd) }
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
