import XCTest

final class URLNormalizerTests: XCTestCase {
    private func n(_ s: String) -> String? { URLNormalizer.normalize(s)?.absoluteString }

    func testBarePortMeansLocalhost() {
        XCTAssertEqual(n("3000"), "http://localhost:3000")
        XCTAssertEqual(n(":5173"), "http://localhost:5173")
        XCTAssertEqual(n("  8080 "), "http://localhost:8080")
    }

    func testPortOutOfRangeIsNotAnAddress() {
        XCTAssertNil(n("0"))
        XCTAssertNil(n("65536"))
        XCTAssertNil(n(":99999"))
    }

    func testLocalHostsGetHttp() {
        XCTAssertEqual(n("localhost"), "http://localhost")
        XCTAssertEqual(n("localhost:3000/checkout?a=1"), "http://localhost:3000/checkout?a=1")
        XCTAssertEqual(n("127.0.0.1:8000"), "http://127.0.0.1:8000")
        XCTAssertEqual(n("myapp.local"), "http://myapp.local")
        XCTAssertEqual(n("app.localhost:3000"), "http://app.localhost:3000")
        XCTAssertEqual(n("[::1]:3000"), "http://[::1]:3000")
    }

    func testPublicHostsGetHttps() {
        XCTAssertEqual(n("example.com"), "https://example.com")
        XCTAssertEqual(n("example.com/docs"), "https://example.com/docs")
    }

    func testHostWithPortGetsHttp() {
        XCTAssertEqual(n("app.test:3000"), "http://app.test:3000")
    }

    func testExplicitSchemeIsKept() {
        XCTAssertEqual(n("http://example.com"), "http://example.com")
        XCTAssertEqual(n("HTTPS://example.com/x"), "https://example.com/x")
        XCTAssertEqual(n("http://localhost:3000"), "http://localhost:3000")
    }

    func testOtherSchemesAndGarbageAreRejected() {
        XCTAssertNil(n("file:///etc/passwd"))
        XCTAssertNil(n("javascript://alert(1)"))
        XCTAssertNil(n("mailto:a@b.c"))
        XCTAssertNil(n("ftp://example.com"))
        XCTAssertNil(n(""))
        XCTAssertNil(n("   "))
        XCTAssertNil(n("hello world"))
        XCTAssertNil(n("hello"))
        XCTAssertNil(n("http://"))
    }

    func testIsLocalHost() {
        XCTAssertTrue(URLNormalizer.isLocalHost("LOCALHOST"))
        XCTAssertTrue(URLNormalizer.isLocalHost("192.168.1.5"))
        XCTAssertFalse(URLNormalizer.isLocalHost("999.1.1.1"))
        XCTAssertFalse(URLNormalizer.isLocalHost("example.com"))
    }

    // MARK: error text

    func testConnectionRefusedMessage() {
        let m = BrowserErrorText.message(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, target: "localhost:3000", fallback: "x")
        XCTAssertEqual(m.title, "Can't connect to localhost:3000")
        XCTAssertFalse(m.detail.isEmpty)
    }

    func testUnknownErrorUsesFallback() {
        let m = BrowserErrorText.message(domain: "SomethingElse", code: 1, target: "a.b", fallback: "It broke")
        XCTAssertEqual(m.title, "Can't open a.b")
        XCTAssertEqual(m.detail, "It broke")
    }

    func testIgnorableErrors() {
        XCTAssertTrue(BrowserErrorText.isIgnorable(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertTrue(BrowserErrorText.isIgnorable(domain: "WebKitErrorDomain", code: 102))
        XCTAssertFalse(BrowserErrorText.isIgnorable(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
    }
}
