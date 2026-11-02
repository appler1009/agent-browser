import Foundation

// MARK: - Unix socket helpers shared by the CLI and the daemon

func sanitizeSession(_ s: String) -> String {
    let ok = s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    return ok && !s.isEmpty ? s : "default"
}

func socketPath(session: String) -> String {
    let dir = NSHomeDirectory() + "/.agent-browser"
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return dir + "/\(sanitizeSession(session)).sock"
}

/// Control socket of the host process that runs the sessions. It is keyed by this binary (path and version) and
/// `AGENT_BROWSER_HOST_ID`, so a different build or a test run never talks to another one's host.
func hostControlPath() -> String {
    let dir = NSHomeDirectory() + "/.agent-browser"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let raw = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let exe = URL(fileURLWithPath: raw).resolvingSymlinksInPath().standardizedFileURL.path  // the same for the CLI and the host it starts
    let key = exe + "|" + agentBrowserVersion + "|" + (ProcessInfo.processInfo.environment["AGENT_BROWSER_HOST_ID"] ?? "")
    var h: UInt64 = 1469598103934665603  // FNV-1a
    for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return dir + "/host-" + String(h, radix: 16) + ".ctl"
}

private func makeAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() where i < buf.count - 1 { buf[i] = UInt8(bitPattern: b) }
    }
    return addr
}

func connectSocket(_ path: String) -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var addr = makeAddr(path)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if r != 0 { close(fd); return nil }
    return fd
}

func listenSocket(_ path: String) -> Int32? {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var addr = makeAddr(path)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if r != 0 { close(fd); return nil }
    chmod(path, 0o600)
    if listen(fd, 16) != 0 { close(fd); return nil }
    return fd
}

/// Reads bytes until a newline or EOF. Returns nil if nothing was read.
func readLineFromSocket(_ fd: Int32) -> String? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while data.count < 64 * 1024 * 1024 {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
        if buf[..<n].contains(10) { break }
    }
    if data.isEmpty { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
}

func writeAllToSocket(_ fd: Int32, _ s: String) {
    let bytes = Array(s.utf8)
    var off = 0
    while off < bytes.count {
        let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { return }
        off += n
    }
}

func jsonString(_ obj: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
        let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
        let s = String(data: d, encoding: .utf8)
    else {
        return #"{"ok":false,"error":{"code":"INTERNAL","message":"result was not serialisable","retry_safe":false},"events":[]}"#
    }
    return s
}

func parseJSON(_ s: String) -> [String: Any]? {
    guard let d = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}
