import Foundation
import Testing
@testable import AgentAttentionCore

@Suite("The power daemon's line protocol")
struct PowerProtocolTests {

    @Test("Every request round-trips through the wire form", arguments: [
        PowerRequest.hello(version: 1), .acquire, .renew, .release, .status,
    ])
    func requestsRoundTrip(request: PowerRequest) {
        #expect(PowerRequest.parse(request.wire) == request)
    }

    @Test("Every reply round-trips through the wire form", arguments: [
        PowerReply.ok,
        .okVersion(1),
        .held(secondsRemaining: 42, setting: .on),
        .free(setting: .off),
        .error(.busy),
        .error(.foreign),
        .error(.assertionFailed),
    ])
    func repliesRoundTrip(reply: PowerReply) {
        #expect(PowerReply.parse(reply.wire) == reply)
    }

    /// The daemon runs as root and reads this from a socket. Anything it does not
    /// recognise is refused outright — never guessed at, never partially applied.
    @Test("A line we do not recognise is not a request", arguments: [
        "", "   ", "ACQUIRE", "acquire now", "hello", "hello x", "hello 1 2",
        "release; rm -rf /", "\u{0}acquire",
    ])
    func rubbishIsRefused(line: String) {
        #expect(PowerRequest.parse(line) == nil)
    }

    @Test("A request carries no free text at all")
    func requestsHaveNoPayload() {
        // Every verb but `hello` is a bare word, and `hello` takes only an integer.
        #expect(PowerRequest.acquire.wire == "acquire")
        #expect(PowerRequest.hello(version: 1).wire == "hello 1")
        #expect(PowerRequest.parse("hello 99") == .hello(version: 99))
    }

    @Test("The version the app speaks is pinned")
    func versionIsPinned() {
        #expect(PowerProtocolVersion.current == 1)
    }
}
