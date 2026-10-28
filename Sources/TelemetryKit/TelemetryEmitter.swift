import Foundation
import Observation

@MainActor @Observable
public final class TelemetryEmitter {
    public enum Signal: String, CaseIterable, Identifiable { case trace = "Trace", log = "Log", metric = "Metric"; public var id: String { rawValue }; var path: String { "/v1/\(rawValue.lowercased())s" } }
    public var endpoint = "http://127.0.0.1:4318"
    public var serviceName = "telemetry-fountain"
    public var autoEmit = false { didSet { updateTimer() } }
    public var totalSent = 0
    public var lastResult = "Ready to send to TracePlus"
    public var isSending = false
    public var workloadProgress: Double?
    public var workloadPhase = ""
    private var timer: Timer?
    public init() {}
    public func send(_ signal: Signal) {
        guard !isSending else { return }; isSending = true; lastResult = "Sending \(signal.rawValue.lowercased())…"
        workloadProgress = nil
        let body = payload(for: signal); let url = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + signal.path
        Task { do {
            guard let requestURL = URL(string: url) else { throw EmitterError.invalidEndpoint }
            var request = URLRequest(url: requestURL); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); let data = try JSONSerialization.data(withJSONObject: body); request.setValue(String(data.count), forHTTPHeaderField: "Content-Length"); request.httpBody = data
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw EmitterError.rejected }
            totalSent += 1; lastResult = "Sent \(signal.rawValue.lowercased()) to \(requestURL.host ?? "receiver")"
        } catch { lastResult = "Couldn’t send: \(error.localizedDescription)" }; isSending = false }
    }
    public func sendRealisticWorkload() {
        guard !isSending else { return }
        isSending = true
        workloadProgress = 0
        workloadPhase = "Preparing workload…"
        lastResult = "Building 2,500 realistic spans…"
        let url = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/traces"
        Task { do {
            let body = await realisticTracePayload(spanCount: 2_500)
            guard let requestURL = URL(string: url) else { throw EmitterError.invalidEndpoint }
            let batches = splitWorkload(body, spansPerBatch: 100)
            for (index, batch) in batches.enumerated() {
                workloadPhase = "Uploading batch \(index + 1) of \(batches.count)…"
                workloadProgress = 0.85 + (Double(index) / Double(batches.count) * 0.15)
                var request = URLRequest(url: requestURL); request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); let data = try JSONSerialization.data(withJSONObject: batch); request.setValue(String(data.count), forHTTPHeaderField: "Content-Length"); request.httpBody = data
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw EmitterError.rejected }
            }
            totalSent += 2_500; workloadProgress = 1; workloadPhase = "Upload complete"; lastResult = "Sent 2,500 realistic spans across 100 traces"
        } catch { workloadPhase = "Upload failed"; lastResult = "Couldn’t send workload: \(error.localizedDescription)" }; isSending = false }
    }
    func splitWorkload(_ body: [String: Any], spansPerBatch: Int) -> [[String: Any]] {
        guard let resourceSpan = (body["resourceSpans"] as? [[String: Any]])?.first,
              let scopeSpan = (resourceSpan["scopeSpans"] as? [[String: Any]])?.first,
              let spans = scopeSpan["spans"] as? [[String: Any]] else { return [body] }
        return stride(from: 0, to: spans.count, by: spansPerBatch).map { start in
            var scope = scopeSpan
            scope["spans"] = Array(spans[start..<min(start + spansPerBatch, spans.count)])
            var resource = resourceSpan
            resource["scopeSpans"] = [scope]
            return ["resourceSpans": [resource]]
        }
    }
    private func updateTimer() { timer?.invalidate(); timer = nil; guard autoEmit else { return }; timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in guard let self else { return }; let signals = Signal.allCases; self.send(signals[self.totalSent % signals.count]) } } }
    private func payload(for signal: Signal) -> [String: Any] {
        let time = String(UInt64(Date().timeIntervalSince1970 * 1_000_000_000)); let resource: [String: Any] = ["attributes": [["key": "service.name", "value": ["stringValue": serviceName]], ["key": "service.version", "value": ["stringValue": "1.0.0"]]]]; let scope: [String: Any] = ["name": "traceplus.telemetry-fountain", "version": "1.0.0"]
        switch signal {
        case .trace:
            let span: [String: Any] = ["traceId": randomHex(length: 32), "spanId": randomHex(length: 16), "name": "GET /checkout", "kind": 2, "startTimeUnixNano": time, "endTimeUnixNano": String(UInt64(time)! + 72_000_000), "attributes": [["key": "http.request.method", "value": ["stringValue": "GET"]], ["key": "http.response.status_code", "value": ["intValue": "200"]]], "status": ["code": 1]]
            return ["resourceSpans": [["resource": resource, "scopeSpans": [["scope": scope, "spans": [span]]]]]]
        case .log:
            let record: [String: Any] = ["timeUnixNano": time, "severityNumber": 9, "severityText": "INFO", "body": ["stringValue": "Checkout completed by Telemetry Fountain"]]
            return ["resourceLogs": [["resource": resource, "scopeLogs": [["scope": scope, "logRecords": [record]]]]]]
        case .metric:
            let metric: [String: Any] = ["name": "demo.checkout.duration", "unit": "ms", "gauge": ["dataPoints": [["timeUnixNano": time, "asDouble": 72.0]]]]
            return ["resourceMetrics": [["resource": resource, "scopeMetrics": [["scope": scope, "metrics": [metric]]]]]]
        }
    }
    func realisticTracePayload(spanCount: Int) async -> [String: Any] {
        precondition(spanCount.isMultiple(of: 25), "The realistic workload uses complete 25-span traces.")
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        var spans: [[String: Any]] = []
        let traces = spanCount / 25
        for traceIndex in 0..<traces {
            if traceIndex.isMultiple(of: 2) {
                workloadProgress = Double(traceIndex) / Double(traces) * 0.85
                workloadPhase = "Generating trace \(traceIndex + 1) of \(traces)…"
                await Task.yield()
            }
            let traceID = randomHex(length: 32)
            let base = now - UInt64(Int.random(in: 0...3_600) * 1_000_000_000)
            spans += realisticCheckoutTrace(traceID: traceID, base: base, isFailure: traceIndex.isMultiple(of: 23))
        }
        assert(spans.count == spanCount)
        let resource: [String: Any] = ["attributes": [["key": "service.name", "value": ["stringValue": serviceName]], ["key": "telemetry.sdk.name", "value": ["stringValue": "telemetry-fountain"]]]]
        return ["resourceSpans": [["resource": resource, "scopeSpans": [["scope": ["name": "traceplus.load-test"], "spans": spans]]]]]
    }
    /// Builds a single causally valid trace. Offsets and durations are milliseconds;
    /// every child interval is intentionally contained by its parent interval.
    private func realisticCheckoutTrace(traceID: String, base: UInt64, isFailure: Bool) -> [[String: Any]] {
        struct Spec { let name: String; let service: String; let kind: Int; let parent: Int?; let offset: Int; let duration: Int; let attributes: [(String, String)] }
        let total = Int.random(in: 460...620)
        let status = isFailure ? "503" : "200"
        let specs: [Spec] = [
            .init(name: "POST /api/checkout", service: "checkout-api", kind: 2, parent: nil, offset: 0, duration: total, attributes: [("http.request.method", "POST"), ("url.path", "/api/checkout"), ("http.response.status_code", status)]),
            .init(name: "auth.validate_token", service: "checkout-api", kind: 3, parent: 0, offset: 8, duration: 42, attributes: [("rpc.system", "grpc")]),
            .init(name: "ValidateToken", service: "auth-service", kind: 1, parent: 1, offset: 11, duration: 34, attributes: [("rpc.system", "grpc")]),
            .init(name: "SELECT session", service: "auth-service", kind: 3, parent: 2, offset: 16, duration: 12, attributes: [("db.system", "postgresql"), ("db.operation.name", "SELECT")]),
            .init(name: "redis GET rate-limit", service: "checkout-api", kind: 3, parent: 0, offset: 54, duration: 7, attributes: [("db.system", "redis"), ("db.operation.name", "GET")]),
            .init(name: "inventory.reserve", service: "checkout-api", kind: 3, parent: 0, offset: 66, duration: 84, attributes: [("rpc.system", "grpc")]),
            .init(name: "ReserveInventory", service: "inventory-service", kind: 1, parent: 5, offset: 70, duration: 76, attributes: [("rpc.system", "grpc")]),
            .init(name: "SELECT stock_level", service: "inventory-service", kind: 3, parent: 6, offset: 76, duration: 22, attributes: [("db.system", "postgresql"), ("db.operation.name", "SELECT")]),
            .init(name: "redis SET reservation", service: "inventory-service", kind: 3, parent: 6, offset: 106, duration: 9, attributes: [("db.system", "redis"), ("db.operation.name", "SET")]),
            .init(name: "payment.authorize", service: "checkout-api", kind: 3, parent: 0, offset: 158, duration: 118, attributes: [("rpc.system", "grpc")]),
            .init(name: "AuthorizePayment", service: "payment-service", kind: 1, parent: 9, offset: 164, duration: 108, attributes: [("rpc.system", "grpc")]),
            .init(name: "fraud.score_transaction", service: "payment-service", kind: 3, parent: 10, offset: 171, duration: 57, attributes: [("rpc.system", "grpc")]),
            .init(name: "ScoreTransaction", service: "fraud-service", kind: 1, parent: 11, offset: 176, duration: 47, attributes: [("rpc.system", "grpc")]),
            .init(name: "SELECT risk_rules", service: "fraud-service", kind: 3, parent: 12, offset: 181, duration: 16, attributes: [("db.system", "postgresql"), ("db.operation.name", "SELECT")]),
            .init(name: "payment-gateway charge", service: "payment-service", kind: 3, parent: 10, offset: 232, duration: 29, attributes: [("server.address", "payments.example.net")]),
            .init(name: "order.persist", service: "checkout-api", kind: 1, parent: 0, offset: 284, duration: 53, attributes: []),
            .init(name: "INSERT orders", service: "checkout-api", kind: 3, parent: 15, offset: 289, duration: 29, attributes: [("db.system", "postgresql"), ("db.operation.name", "INSERT")]),
            .init(name: "INSERT order_items", service: "checkout-api", kind: 3, parent: 15, offset: 320, duration: 11, attributes: [("db.system", "postgresql"), ("db.operation.name", "INSERT")]),
            .init(name: "kafka publish order.created", service: "checkout-api", kind: 4, parent: 0, offset: 345, duration: 14, attributes: [("messaging.system", "kafka"), ("messaging.destination.name", "order.created")]),
            // The consumer begins after the producer has acknowledged Kafka, so it
            // stays under the request's causal envelope rather than the closed producer span.
            .init(name: "process order.created", service: "notification-service", kind: 4, parent: 0, offset: 365, duration: 59, attributes: [("messaging.system", "kafka")]),
            .init(name: "email.enqueue_receipt", service: "notification-service", kind: 3, parent: 19, offset: 373, duration: 31, attributes: [("server.address", "email-provider.internal")]),
            .init(name: "analytics publish checkout", service: "checkout-api", kind: 4, parent: 0, offset: 370, duration: 9, attributes: [("messaging.system", "kafka")]),
            .init(name: "GET feature flags", service: "checkout-api", kind: 3, parent: 0, offset: 386, duration: 12, attributes: [("server.address", "flags.internal")]),
            .init(name: "cache invalidate cart", service: "checkout-api", kind: 3, parent: 0, offset: 405, duration: 6, attributes: [("db.system", "redis"), ("db.operation.name", "DEL")]),
            .init(name: "serialize response", service: "checkout-api", kind: 1, parent: 0, offset: max(425, total - 28), duration: 12, attributes: [])
        ]
        let ids = specs.map { _ in randomHex(length: 16) }
        return specs.enumerated().map { index, spec in
            let start = base + UInt64(spec.offset) * 1_000_000
            let end = start + UInt64(spec.duration) * 1_000_000
            var attributes: [[String: Any]] = [["key": "service.name", "value": ["stringValue": spec.service]], ["key": "deployment.environment", "value": ["stringValue": "production"]], ["key": "cloud.region", "value": ["stringValue": "us-east-1"]], ["key": "traceplus.synthetic", "value": ["boolValue": true]]]
            attributes += spec.attributes.map { ["key": $0.0, "value": ["stringValue": $0.1]] }
            var span: [String: Any] = ["traceId": traceID, "spanId": ids[index], "name": spec.name, "kind": spec.kind, "startTimeUnixNano": String(start), "endTimeUnixNano": String(end), "attributes": attributes, "status": ["code": isFailure && (index == 0 || index == 9) ? 2 : 1]]
            if let parent = spec.parent { span["parentSpanId"] = ids[parent] }
            if isFailure && index == 9 { span["events"] = [["name": "exception", "timeUnixNano": String(end), "attributes": [["key": "exception.type", "value": ["stringValue": "GatewayTimeout"]], ["key": "exception.message", "value": ["stringValue": "Payment gateway timed out"]]]]] }
            return span
        }
    }
    private func randomHex(length: Int) -> String { (0..<(length / 2)).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined() }
    enum EmitterError: LocalizedError { case invalidEndpoint, rejected; var errorDescription: String? { switch self { case .invalidEndpoint: "The receiver URL is invalid."; case .rejected: "The receiver rejected the OTLP payload." } } }
}
