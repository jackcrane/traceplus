import XCTest
@testable import TelemetryKit

@MainActor final class TelemetryFountainTests: XCTestCase {
    func testWorkloadShapeAndBatches() async throws {
        let emitter = TelemetryEmitter()
        let payload = await emitter.realisticTracePayload(spanCount: 2_500)
        let resource = try XCTUnwrap((payload["resourceSpans"] as? [[String: Any]])?.first)
        let scope = try XCTUnwrap((resource["scopeSpans"] as? [[String: Any]])?.first)
        let spans = try XCTUnwrap(scope["spans"] as? [[String: Any]])
        XCTAssertEqual(spans.count, 2_500)
        XCTAssertEqual(Set(spans.compactMap { $0["traceId"] as? String }).count, 100)
        for trace in Dictionary(grouping: spans, by: { $0["traceId"] as! String }).values {
            let ids = Dictionary(uniqueKeysWithValues: trace.map { ($0["spanId"] as! String, $0) })
            XCTAssertEqual(trace.filter { $0["parentSpanId"] == nil }.count, 1)
            for span in trace {
                guard let parentID = span["parentSpanId"] as? String, let parent = ids[parentID] else { continue }
                let childStart = try XCTUnwrap(UInt64(span["startTimeUnixNano"] as! String))
                let childEnd = try XCTUnwrap(UInt64(span["endTimeUnixNano"] as! String))
                let parentStart = try XCTUnwrap(UInt64(parent["startTimeUnixNano"] as! String))
                let parentEnd = try XCTUnwrap(UInt64(parent["endTimeUnixNano"] as! String))
                XCTAssertGreaterThanOrEqual(childStart, parentStart, "A child cannot start before its parent.")
                XCTAssertLessThanOrEqual(childEnd, parentEnd, "A child cannot outlive its parent.")
            }
        }
        let batches = emitter.splitWorkload(payload, spansPerBatch: 100)
        XCTAssertEqual(batches.count, 25)
    }
}
