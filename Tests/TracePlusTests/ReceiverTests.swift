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

    func testWaterfallOrdersParentsBeforeChildrenDespiteClockSkew() {
        let traceStart = Date(timeIntervalSinceReferenceDate: 0)
        func span(_ id: String, parent: String?, startMilliseconds: Double) -> CollectorState.TraceItem {
            CollectorState.TraceItem(
                time: traceStart.addingTimeInterval(startMilliseconds / 1_000),
                name: id,
                traceID: "trace",
                spanID: id,
                parentSpanID: parent,
                service: "service",
                attributes: [:],
                events: [],
                durationMilliseconds: 1,
                statusCode: 0
            )
        }

        let parent = span("parent", parent: nil, startMilliseconds: 20)
        let earlyChild = span("early-child", parent: "parent", startMilliseconds: 5)
        let grandchild = span("grandchild", parent: "early-child", startMilliseconds: 1)
        let laterChild = span("later-child", parent: "parent", startMilliseconds: 10)

        let ordered = TraceSpanOrdering.parentFirst([grandchild, laterChild, earlyChild, parent])

        XCTAssertEqual(ordered.map(\.spanID), ["parent", "early-child", "grandchild", "later-child"])
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

    func testClearStoredSignalsRemovesAllTelemetryAndCounters() {
        let collector = CollectorState(httpPort: 52124)
        let trace: [String: Any] = ["traceId": "0123456789abcdef0123456789abcdef", "spanId": "0123456789abcdef", "name": "checkout", "startTimeUnixNano": "1760000000000000000", "endTimeUnixNano": "1760000000010000000"]
        let traceBody: [String: Any] = ["resourceSpans": [["scopeSpans": [["spans": [trace]]]]]]
        let logBody: [String: Any] = ["resourceLogs": [["scopeLogs": [["logRecords": [["body": ["stringValue": "checkout completed"]]]]]]]]
        let metricBody: [String: Any] = ["resourceMetrics": [["scopeMetrics": [["metrics": [["name": "checkout.duration", "gauge": ["dataPoints": [["asDouble": 72.0]]]]]]]]]]
        XCTAssertTrue(collector.processOTLPRequest(path: "/v1/traces", body: traceBody))
        XCTAssertTrue(collector.processOTLPRequest(path: "/v1/logs", body: logBody))
        XCTAssertTrue(collector.processOTLPRequest(path: "/v1/metrics", body: metricBody))

        collector.clearStoredSignals()

        XCTAssertTrue(collector.traces.isEmpty)
        XCTAssertTrue(collector.logs.isEmpty)
        XCTAssertTrue(collector.metrics.isEmpty)
        XCTAssertEqual(collector.traceCount, 0)
        XCTAssertEqual(collector.spanCount, 0)
        XCTAssertEqual(collector.logCount, 0)
        XCTAssertEqual(collector.metricCount, 0)
        XCTAssertNil(collector.lastReceivedAt)
    }

    func testReceiverReadsNumericAttributesLogContextAndAllMetricKinds() throws {
        let collector = CollectorState(httpPort: 52125)
        let span: [String: Any] = ["traceId": "0123456789abcdef0123456789abcdef", "spanId": "0123456789abcdef", "name": "POST /orders", "startTimeUnixNano": "1760000000000000000", "endTimeUnixNano": "1760000000010000000",
            "attributes": [["key": "http.response.status_code", "value": ["intValue": 201]], ["key": "app.score", "value": ["doubleValue": 0.125]], ["key": "app.hit", "value": ["boolValue": false]], ["key": "big", "value": ["intValue": "42"]], ["key": "big", "value": ["intValue": "43"]]]]
        XCTAssertTrue(collector.processOTLPRequest(path: "/v1/traces", body: ["resourceSpans": [["scopeSpans": [["spans": [span]]]]]]))
        let attributes = try XCTUnwrap(collector.traces.first).attributes
        XCTAssertEqual(attributes["http.response.status_code"], "201")
        XCTAssertEqual(attributes["app.score"], "0.125")
        XCTAssertEqual(attributes["app.hit"], "false")
        XCTAssertEqual(attributes["big"], "43")

        let record: [String: Any] = ["timeUnixNano": "1760000000000000000", "severityText": "WARN", "body": ["stringValue": "retrying"], "traceId": "0123456789abcdef0123456789abcdef", "spanId": "0123456789abcdef", "attributes": [["key": "retry.attempt", "value": ["intValue": 2]]]]
        collector.processOTLPRequest(path: "/v1/logs", body: ["resourceLogs": [["scopeLogs": [["logRecords": [record]]]]]])
        let log = try XCTUnwrap(collector.logs.first)
        XCTAssertEqual(log.attributes["retry.attempt"], "2")
        XCTAssertEqual(log.traceID, "0123456789abcdef0123456789abcdef")

        let metrics: [[String: Any]] = [
            ["name": "orders", "unit": "{order}", "sum": ["dataPoints": [["asInt": "7", "attributes": [["key": "outcome", "value": ["stringValue": "ok"]]]]]]],
            ["name": "latency", "unit": "s", "histogram": ["dataPoints": [["count": "4", "sum": 2.0]]]],
            ["name": "empty", "histogram": ["dataPoints": [["count": "0", "sum": 0]]]],
        ]
        collector.processOTLPRequest(path: "/v1/metrics", body: ["resourceMetrics": [["scopeMetrics": [["metrics": metrics]]]]])
        XCTAssertEqual(collector.metrics.count, 2)
        XCTAssertEqual(collector.metrics.first { $0.name == "orders" }?.value, 7)
        XCTAssertEqual(collector.metrics.first { $0.name == "orders" }?.attributes["outcome"], "ok")
        XCTAssertEqual(try XCTUnwrap(collector.metrics.first { $0.name == "latency" }).value, 0.5, accuracy: 0.0001)
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
