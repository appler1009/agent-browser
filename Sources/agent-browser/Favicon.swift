import AppKit
import Foundation

/// Fetches a page's icon for the tab in the watch window: no cookies, no disk cache, https (or loopback http) only,
/// at most 256 KB, 5 s.
enum FaviconFetcher {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5; c.timeoutIntervalForResource = 8
        c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        return URLSession(configuration: c)
    }()

    static func fetch(_ u: URL) async -> NSImage? {
        guard u.scheme == "https" || (u.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(u.host ?? "")) else { return nil }
        guard let (data, resp) = try? await session.data(from: u), data.count <= 262_144,
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: data), img.size.width > 0 else { return nil }
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}
