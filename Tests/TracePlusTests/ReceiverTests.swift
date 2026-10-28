import Foundation
import XCTest
@testable import TracePlus

@MainActor final class ReceiverTests: XCTestCase {
    func testReceiverProcessesOTLPTracePayload() throws {
        let collector = CollectorState(httpPort: 52123)
        let spans: [[String: Any]] = (0..<100).map { index in
            ["traceId": String(format: "%032x", index / 10), "spanId": String(format: "%016x", index), "name": "db.query", "startTimeUnixNano": "1760000000000000000", "endTimeUnixNano": "1760000000010000000"]
        }
        let body: [String: Any] = ["resourceSpans": [["scopeSpans": [["spans": spans]]]]]
        XCTAssertTrue(collector.processOTLPRequest(path: "/v1/traces", body: body))
        XCTAssertEqual(collector.spanCount, 100)
        XCTAssertEqual(collector.traceCount, 10)
        XCTAssertEqual(collector.traces.count, 100)
    }

    func testListenerAcceptsAnInboundHTTPTraceRequest() async throws {
        let port = Int.random(in: 55_000...59_000)
        let collector = CollectorState(httpPort: port)
        collector.start()
        defer { collector.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(collector.status, .running)
        let body: [String: Any] = ["resourceSpans": [["scopeSpans": [["spans": [["traceId": "0123456789abcdef0123456789abcdef", "spanId": "0123456789abcdef", "name": "inbound.http", "startTimeUnixNano": "1760000000000000000", "endTimeUnixNano": "1760000000010000000"]]]]]]]
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/traces")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data = try JSONSerialization.data(withJSONObject: body)
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(collector.spanCount, 1)
        XCTAssertEqual(collector.traceCount, 1)
    }
}
