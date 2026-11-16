import Foundation
import Testing
@testable import ArchipelCore

struct DevServerDetectorTests {
    private func urls(_ text: String) -> [String] {
        DevServerDetector.links(in: text).map(\.url.absoluteString)
    }

    @Test(arguments: [
        ("  ➜  Local:   http://localhost:5173/\n  ➜  Network: use --host to expose", "http://localhost:5173/"),
        ("   - Local:        http://localhost:3000", "http://localhost:3000"),
        ("INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)", "http://127.0.0.1:8000"),
        ("Starting development server at http://127.0.0.1:8000/", "http://127.0.0.1:8000/"),
        ("Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...", "http://0.0.0.0:8000/"),
        ("* Listening on http://[::1]:3000", "http://[::1]:3000"),
        ("Open https://LOCALHOST:8443/app/index.html.", "https://LOCALHOST:8443/app/index.html"),
        ("ready at 'http://localhost:4000/graphql'", "http://localhost:4000/graphql"),
    ])
    func findsCommonServerBanners(text: String, expected: String) {
        #expect(urls(text) == [expected])
    }

    @Test(arguments: [
        "see http://localhost/docs for details",
        "http://localhost:0",
        "http://localhost:70000",
        "http://localhost:123456",
        "https://example.com:8080/",
        "Network: http://192.168.1.20:5173/",
        "ftp://localhost:21",
        "localhost:3000 without a scheme",
        "",
    ])
    func ignoresWhatIsNotALocalServer(text: String) {
        #expect(urls(text).isEmpty)
    }

    @Test func keepsOneLinkPerPortOrderedByLastMention() {
        let text = """
        http://localhost:3000
        http://localhost:5173/
        http://127.0.0.1:3000/api
        """
        #expect(urls(text) == ["http://localhost:5173/", "http://127.0.0.1:3000/api"])
    }

    @Test func wildcardAddressesOpenAsLocalhost() throws {
        let v4 = try #require(DevServerDetector.links(in: "http://0.0.0.0:8000/x?y=1").first)
        #expect(v4.openURL.absoluteString == "http://localhost:8000/x?y=1")
        let v6 = try #require(DevServerDetector.links(in: "http://[::]:9000/").first)
        #expect(v6.openURL.absoluteString == "http://localhost:9000/")
        let plain = try #require(DevServerDetector.links(in: "http://127.0.0.1:8000/").first)
        #expect(plain.openURL == plain.url)
    }

    @Test func labelsAndProbeAddresses() throws {
        let link = try #require(DevServerDetector.links(in: "http://localhost:5173/").first)
        #expect(link.label == ":5173")
        #expect(link.probeAddresses == ["127.0.0.1", "::1"])
        #expect(DevServerDetector.links(in: "http://[::1]:1").first?.probeAddresses == ["::1"])
        #expect(DevServerDetector.links(in: "http://0.0.0.0:80").first?.probeAddresses == ["127.0.0.1"])
    }

    @Test func mergeKeepsKnownOrderAndAppendsNewPorts() {
        let a = DevServerDetector.links(in: "http://localhost:3000")
        let b = DevServerDetector.links(in: "http://localhost:5173")
        let aWithPath = DevServerDetector.links(in: "http://localhost:3000/admin")
        let merged = DevServerDetector.merge(known: a + b, detected: aWithPath)
        #expect(merged.map(\.url.absoluteString) == ["http://localhost:3000/admin", "http://localhost:5173"])
        let grown = DevServerDetector.merge(known: a, detected: b + a)
        #expect(grown.map(\.port) == [3000, 5173])
    }
}
