import Foundation

/// Turns what the user typed in the address bar into a URL to load, or nil when it is not an address.
/// Built for local dev servers: `3000` and `:3000` mean `http://localhost:3000`.
enum URLNormalizer {
    static func normalize(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(where: \.isWhitespace) else { return nil }

        if let port = barePort(s) { return URL(string: "http://localhost:\(port)") }

        if let r = s.range(of: "://") {
            let scheme = s[..<r.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            guard var c = URLComponents(string: s), let host = c.host, validHost(host), c.user == nil, c.password == nil else { return nil }
            c.scheme = String(scheme)
            return c.url
        }

        // No scheme: decide it from the host. "mailto:x" ends up with a non-numeric port and is rejected.
        guard var c = URLComponents(string: "http://" + s), let host = c.host, validHost(host), c.user == nil, c.password == nil else { return nil }
        let local = isLocalHost(host)
        if !local && c.port == nil && !host.contains(".") { return nil }   // a bare word is not an address
        c.scheme = (local || c.port != nil) ? "http" : "https"
        return c.url
    }

    /// "3000" or ":3000": a port on localhost.
    private static func barePort(_ s: String) -> Int? {
        let digits = s.hasPrefix(":") ? String(s.dropFirst()) : s
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), (1...65535).contains(n) else { return nil }
        return n
    }

    private static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._:[]%".contains($0)) || !$0.isASCII }
    }

    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h.hasSuffix(".local") || h.hasPrefix("[") || h.contains(":") { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}

/// What the panel says when a page fails to load.
enum BrowserErrorText {
    struct Message: Equatable { var title: String; var detail: String }

    /// Cancelled loads and downloads handed to the system are not failures worth showing.
    static func isIgnorable(domain: String, code: Int) -> Bool {
        (domain == NSURLErrorDomain && code == NSURLErrorCancelled) || (domain == "WebKitErrorDomain" && code == 102)
    }

    /// `target` is how the address reads ("localhost:3000"); `fallback` is the system's own description.
    static func message(domain: String, code: Int, target: String, fallback: String) -> Message {
        guard domain == NSURLErrorDomain else { return Message(title: "Can't open \(target)", detail: fallback) }
        switch code {
        case NSURLErrorCannotConnectToHost:
            return Message(title: "Can't connect to \(target)", detail: "The server isn't running, or it listens on another port.")
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return Message(title: "Can't find \(target)", detail: "Check the address for typos.")
        case NSURLErrorTimedOut:
            return Message(title: "\(target) took too long to answer", detail: "The server may be busy or starting up.")
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return Message(title: "No network connection", detail: "Check your connection and try again.")
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return Message(title: "Can't make a secure connection to \(target)", detail: "For a local server, try the http:// address.")
        default:
            return Message(title: "Can't open \(target)", detail: fallback)
        }
    }
}
