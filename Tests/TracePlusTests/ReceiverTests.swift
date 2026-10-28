import Foundation
import XCTest
@testable import TracePlus

@MainActor final class ReceiverTests: XCTestCase {
    func testDescendantWaterfallAcceptanceLayout() {
        let traceStart = Date(timeIntervalSinceReferenceDate: 0)
        func span(_ id: String, startMilliseconds: Double, durationMilliseconds: Double) -> CollectorState.TraceItem {
            CollectorState.TraceItem(
                time: traceStart.addingTimeInterval(startMilliseconds / 1_000),
                name: id,
                traceID: "trace",
                spanID: id,
                parentSpanID: nil,
                service: "service",
                attributes: [:],
                events: [],
                durationMilliseconds: durationMilliseconds,
                statusCode: 0
            )
        }

        let firstChild = span("first", startMilliseconds: 164, durationMilliseconds: 108)
        let nestedDescendant = span("nested", startMilliseconds: 171, durationMilliseconds: 57)
        let lastDescendant = span("last", startMilliseconds: 232, durationMilliseconds: 29)
        let timeline = DescendantTimeline(
            spans: [firstChild, nestedDescendant, lastDescendant],
            traceStart: traceStart
        )

        XCTAssertEqual(timeline.start, firstChild.time)
        XCTAssertEqual(timeline.end, firstChild.time.addingTimeInterval(0.108))
        XCTAssertEqual(timeline.traceRelativeStartMilliseconds, 164, accuracy: 0.001)

        // The compact panel is +164 to +272 ms. The nested span must be seven
        // milliseconds into that range, not 32 ms into it (+196 ms).
        let renderedStart = timeline.traceRelativeStartMilliseconds
            + timeline.position(for: nestedDescendant) * timeline.end.timeIntervalSince(timeline.start) * 1_000
        XCTAssertEqual(renderedStart, 171, accuracy: 0.001)
        XCTAssertEqual(timeline.position(for: nestedDescendant), 7.0 / 108.0, accuracy: 0.000_001)
        XCTAssertEqual(432 * timeline.position(for: nestedDescendant), 28, accuracy: 0.001)
    }

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
