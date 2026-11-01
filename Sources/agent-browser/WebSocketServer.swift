import CryptoKit
import Foundation

// Minimal HTTP + WebSocket (RFC 6455) server on 127.0.0.1 for the CDP shim. It only needs what
// DevTools clients use: GET /json/* endpoints and text-frame WebSocket connections.

final class CDPConnection: @unchecked Sendable {
    let fd: Int32
    let path: String
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    func send(_ text: String) { sendFrame(opcode: 0x1, payload: Data(text.utf8)) }

    func sendFrame(opcode: UInt8, payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        if closed { return }
        var frame = Data([0x80 | opcode])  // FIN + opcode; server frames are never masked
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(n >> 8))
            frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((n >> (8 * i)) & 0xFF)) }
        }
        frame.append(payload)
        frame.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let w = write(fd, raw.baseAddress! + off, raw.count - off)
                if w <= 0 { closed = true; return }
                off += w
            }
        }
    }

    func close() {
        lock.lock()
        let wasClosed = closed
        closed = true
        lock.unlock()
        if !wasClosed { Darwin.close(fd) }
    }
}

final class CDPServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private var listenFd: Int32 = -1

    /// Serves GET/PUT /json/* style requests. Called on a background thread; return (status, body).
    var http: (@Sendable (_ method: String, _ path: String, _ host: String) -> (Int, Data))?
    var onOpen: (@Sendable (CDPConnection) -> Void)?
    var onMessage: (@Sendable (CDPConnection, String) -> Void)?
    var onClose: (@Sendable (CDPConnection) -> Void)?

    var running: Bool { listenFd >= 0 }

    func start(port requested: UInt16) throws -> UInt16 {
        if listenFd >= 0 { return port }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CmdError(code: "CDP_START_FAILED", message: "socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = requested.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")  // loopback only, never the network
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw CmdError(code: "CDP_START_FAILED", message: "cannot listen on 127.0.0.1:\(requested): \(String(cString: strerror(errno)))")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenFd = fd
        port = UInt16(bigEndian: bound.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if self.listenFd < 0 { return }; continue }
                Thread.detachNewThread { self.serve(c) }
            }
        }
        return port
    }

    func stop() {
        let fd = listenFd
        listenFd = -1
        port = 0
        if fd >= 0 { close(fd) }
    }

    // MARK: per connection

    private func readHead(_ fd: Int32) -> String? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 32 * 1024 {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            data.append(buf, count: n)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { return String(decoding: data, as: UTF8.self) }
        }
        return nil
    }

    private func respond(_ fd: Int32, _ status: Int, _ body: Data, type: String = "application/json; charset=UTF-8") {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"][status] ?? "OK"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let w = write(fd, raw.baseAddress! + off, raw.count - off)
                if w <= 0 { return }
                off += w
            }
        }
    }

    private func serve(_ fd: Int32) {
        guard let head = readHead(fd) else { close(fd); return }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count >= 2 else { respond(fd, 400, Data("bad request".utf8), type: "text/plain"); close(fd); return }
        let method = first[0], path = first[1]
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }

        // DNS-rebinding / cross-site protection: only local hosts, and no browser Origin.
        let host = headers["host"] ?? ""
        let hostName = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.split(separator: ":").first ?? "")
        guard ["127.0.0.1", "localhost", "[::1]"].contains(hostName), headers["origin"] == nil else {
            respond(fd, 403, Data("forbidden: DevTools endpoint only accepts local, non-browser clients".utf8), type: "text/plain")
            close(fd)
            return
        }

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            _ = resp.withCString { write(fd, $0, strlen($0)) }
            let conn = CDPConnection(fd: fd, path: path)
            onOpen?(conn)
            frameLoop(conn)
            onClose?(conn)
            conn.close()
            return
        }

        if let http {
            let (status, body) = http(method, path, host)
            respond(fd, status, body)
        } else {
            respond(fd, 404, Data("not found".utf8), type: "text/plain")
        }
        close(fd)
    }

    private func readExactly(_ fd: Int32, _ n: Int) -> Data? {
        var out = Data(capacity: n)
        var buf = [UInt8](repeating: 0, count: min(max(n, 1), 65536))
        while out.count < n {
            let r = read(fd, &buf, min(buf.count, n - out.count))
            if r <= 0 { return nil }
            out.append(buf, count: r)
        }
        return out
    }

    private func frameLoop(_ conn: CDPConnection) {
        var message = Data()
        var messageOpcode: UInt8 = 0
        while true {
            guard let h = readExactly(conn.fd, 2) else { return }
            let fin = h[0] & 0x80 != 0, opcode = h[0] & 0x0F, masked = h[1] & 0x80 != 0
            var len = Int(h[1] & 0x7F)
            if len == 126 {
                guard let e = readExactly(conn.fd, 2) else { return }
                len = Int(e[0]) << 8 | Int(e[1])
            } else if len == 127 {
                guard let e = readExactly(conn.fd, 8) else { return }
                len = e.reduce(0) { $0 << 8 | Int($1) }
            }
            if len > 64 * 1024 * 1024 { return }
            var mask = Data()
            if masked { guard let m = readExactly(conn.fd, 4) else { return }; mask = m }
            guard var payload = len == 0 ? Data() : readExactly(conn.fd, len) else { return }
            if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
            switch opcode {
            case 0x8:  // close
                conn.sendFrame(opcode: 0x8, payload: Data())
                return
            case 0x9: conn.sendFrame(opcode: 0xA, payload: payload)  // ping -> pong
            case 0xA: break
            case 0x0, 0x1, 0x2:
                if opcode != 0 { message = Data(); messageOpcode = opcode }
                message.append(payload)
                if fin {
                    if messageOpcode == 0x1, let text = String(data: message, encoding: .utf8) { onMessage?(conn, text) }
                    message = Data()
                }
            default: break
            }
        }
    }
}
