import Foundation
import Network
import Observation

/// The future OTLP receiver will own its lifecycle through this object.
@MainActor @Observable
final class CollectorState {
    struct TraceItem: Identifiable {
        let id = UUID()
        let time: Date
        let name: String
        let traceID: String
        let spanID: String
        let parentSpanID: String?
        let service: String
        let attributes: [String: String]
        let events: [String]
        let durationMilliseconds: Double
        let statusCode: Int
    }
    struct LogItem: Identifiable {
        let id = UUID()
        let time: Date
        let severity: String
        let message: String
        let service: String
        var attributes: [String: String] = [:]
        var traceID: String?
        var spanID: String?
    }
    struct MetricItem: Identifiable {
        let id = UUID()
        let time: Date
        let name: String
        let value: Double
        let unit: String
        let service: String
        /// gauge, sum, histogram or exponentialHistogram. Histograms report their mean.
        var kind: String = "gauge"
        var attributes: [String: String] = [:]
    }
    enum Status: String {
        case stopped = "Not running"
        case starting = "Starting"
        case running = "Listening locally"
        case failed = "Receiver unavailable"

        var color: String {
            switch self {
            case .stopped: "secondary"
            case .starting: "orange"
            case .running: "green"
            case .failed: "red"
            }
        }
    }

    var status: Status = .stopped
    var traceCount = 0
    var spanCount = 0
    var logCount = 0
    var metricCount = 0
    var lastReceivedAt: Date?
    var receiverError: String?
    var traces: [TraceItem] = []
    var logs: [LogItem] = []
    var metrics: [MetricItem] = []
    private var receivedTraceIDs = Set<String>()

    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "dev.traceplus.otlp-receiver")

    /// HTTP bodies arrive in arbitrary-sized network chunks. Keep reading until
    /// the advertised Content-Length has been received before replying.
    private final class HTTPRequestBuffer: @unchecked Sendable {
        var data = Data()

        func completeRequest() -> Data? {
            let marker = Data("\r\n\r\n".utf8)
            guard let headerEnd = data.range(of: marker) else { return nil }
            let header = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
            if header.lowercased().contains("transfer-encoding: chunked") {
                let rawBody = Data(data[headerEnd.upperBound...])
                guard let decoded = decodeChunks(rawBody) else { return nil }
                var request = Data(data[..<headerEnd.upperBound])
                request.append(decoded)
                return request
            }
            let contentLength = header.split(separator: "\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard let contentLength else {
                // Some local URLSession clients stream a body without either
                // framing header. Once it is valid JSON, it is safe to process.
                let body = Data(data[headerEnd.upperBound...])
                guard (try? JSONSerialization.jsonObject(with: body)) != nil else { return nil }
                return data
            }
            let expectedCount = headerEnd.upperBound + contentLength
            return data.count >= expectedCount ? Data(data.prefix(expectedCount)) : nil
        }

        private func decodeChunks(_ raw: Data) -> Data? {
            var offset = 0; var result = Data(); let crlf = Data("\r\n".utf8)
            while true {
                guard offset < raw.count, let line = raw[offset...].range(of: crlf),
                      let size = Int(String(decoding: raw[offset..<line.lowerBound], as: UTF8.self), radix: 16) else { return nil }
                offset = line.upperBound
                guard raw.count >= offset + size + 2 else { return nil }
                if size == 0 { return result }
                result.append(raw[offset..<(offset + size)])
                offset += size + 2
            }
        }
    }

    let host = "127.0.0.1"
    let httpPort: Int

    init(httpPort: Int = 4318) { self.httpPort = httpPort }

    var httpEndpoint: String { "http://\(host):\(httpPort)" }

    var environment: String {
        """
        export OTEL_EXPORTER_OTLP_ENDPOINT=\(httpEndpoint)
        # TracePlus currently accepts OTLP JSON over HTTP
        export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
        export OTEL_SERVICE_NAME=my-service
        """
    }

    func start() {
        guard listener == nil else { return }
        receiverError = nil
        status = .starting
        do {
            let port = NWEndpoint.Port(rawValue: UInt16(httpPort))!
            let listener = try NWListener(using: .tcp, on: port)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.status = .running
                    case .failed(let error):
                        self.status = .failed
                        self.receiverError = error == .posix(.EADDRINUSE)
                            ? "Port \(self.httpPort) is already in use. Quit other TracePlus runs, then retry."
                            : "Could not start the receiver: \(error.localizedDescription)"
                        self.listener?.cancel()
                        self.listener = nil
                        print("TracePlus receiver failed: \(error)")
                    case .cancelled:
                        self.status = .stopped
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: listenerQueue)
        } catch {
            status = .failed
            receiverError = error.localizedDescription
            print("TracePlus couldn't start receiver: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        status = .stopped
    }

    /// Removes every signal retained by this receiver without interrupting the
    /// active listener, so senders can continue publishing immediately.
    func clearStoredSignals() {
        traces.removeAll()
        logs.removeAll()
        metrics.removeAll()
        receivedTraceIDs.removeAll()
        traceCount = 0
        spanCount = 0
        logCount = 0
        metricCount = 0
        lastReceivedAt = nil
    }

    private nonisolated func accept(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        receiveNextChunk(from: connection, buffer: HTTPRequestBuffer())
    }

    private nonisolated func receiveNextChunk(from connection: NWConnection, buffer: HTTPRequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, _ in
            guard let connection else { return }
            if let data { buffer.data.append(data) }
            if let request = buffer.completeRequest() {
                Task { @MainActor in
                    self?.receive(request, from: connection)
                }
            } else if !isComplete {
                self?.receiveNextChunk(from: connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func receive(_ data: Data, from connection: NWConnection) {
        let request = String(decoding: data, as: UTF8.self)
        let path = request.split(separator: "\n", maxSplits: 1).first?
            .split(separator: " ", omittingEmptySubsequences: true).dropFirst().first

        let body = body(in: data)
        let accepted = processOTLPRequest(path: String(path ?? ""), body: body)
        if !accepted {
            send("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", through: connection)
            return
        }
        lastReceivedAt = .now
        send("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", through: connection)
    }

    @discardableResult
    func processOTLPRequest(path: String, body: [String: Any]) -> Bool {
        switch path {
        case "/v1/traces":
            return recordTraces(body)
        case "/v1/logs":
            recordLogs(body)
        case "/v1/metrics":
            recordMetrics(body)
        default:
            return false
        }
        return true
    }

    private func body(in data: Data) -> [String: Any] {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let object = try? JSONSerialization.jsonObject(with: Data(data[separator.upperBound...])) as? [String: Any] else { return [:] }
        return object
    }

    private func recordTraces(_ body: [String: Any]) -> Bool {
        let resources = dictionaries(body["resourceSpans"])
        var received: [TraceItem] = []
        for resource in resources {
            let service = serviceName(in: resource)
            for scope in dictionaries(resource["scopeSpans"]) {
                for span in dictionaries(scope["spans"]) {
                    let start = numeric(span["startTimeUnixNano"])
                    let end = numeric(span["endTimeUnixNano"])
                    let statusCode = (span["status"] as? [String: Any])?["code"] as? Int ?? 0
                    guard let traceID = span["traceId"] as? String, let spanID = span["spanId"] as? String else { continue }
                    let attributes = attributeValues(span["attributes"])
                    let events = dictionaries(span["events"]).compactMap { $0["name"] as? String }
                    received.append(TraceItem(time: date(fromNanoseconds: start), name: span["name"] as? String ?? "Unnamed span", traceID: traceID, spanID: spanID, parentSpanID: span["parentSpanId"] as? String, service: attributes["service.name"] ?? service, attributes: attributes, events: events, durationMilliseconds: Double(max(end - start, 0)) / 1_000_000, statusCode: statusCode))
                }
            }
        }
        guard !received.isEmpty else { return false }
        traces.insert(contentsOf: received, at: 0)
        // Evict whole oldest traces, never individual spans, preserving a
        // complete waterfall for every retained trace.
        while receivedTraceIDs.count > 1_000 {
            guard let oldestID = traces.min(by: { $0.time < $1.time })?.traceID else { break }
            traces.removeAll { $0.traceID == oldestID }
            receivedTraceIDs.remove(oldestID)
        }
        receivedTraceIDs.formUnion(received.map(\.traceID))
        traceCount = receivedTraceIDs.count
        spanCount += received.count
        return true
    }

    private func recordLogs(_ body: [String: Any]) {
        let resources = dictionaries(body["resourceLogs"])
        var received: [LogItem] = []
        for resource in resources {
            let service = serviceName(in: resource)
            for scope in dictionaries(resource["scopeLogs"]) {
                for record in dictionaries(scope["logRecords"]) {
                    let text = (record["body"] as? [String: Any]).map(render) ?? "Log record"
                    let traceID = (record["traceId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let spanID = (record["spanId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    let time = numeric(record["timeUnixNano"]) != 0 ? numeric(record["timeUnixNano"]) : numeric(record["observedTimeUnixNano"])
                    received.append(LogItem(time: date(fromNanoseconds: time), severity: record["severityText"] as? String ?? "UNSPECIFIED", message: text, service: service, attributes: attributeValues(record["attributes"]), traceID: traceID, spanID: spanID))
                }
            }
        }
        if received.isEmpty { received = [LogItem(time: .now, severity: "INFO", message: "Received log record", service: "unknown")] }
        logs.insert(contentsOf: received, at: 0); logs = Array(logs.prefix(500)); logCount += received.count
    }

    private func recordMetrics(_ body: [String: Any]) {
        let resources = dictionaries(body["resourceMetrics"])
        var received: [MetricItem] = []
        for resource in resources {
            let service = serviceName(in: resource)
            for scope in dictionaries(resource["scopeMetrics"]) {
                for metric in dictionaries(scope["metrics"]) {
                    let name = metric["name"] as? String ?? "metric"
                    let unit = metric["unit"] as? String ?? ""
                    for kind in ["gauge", "sum", "histogram", "exponentialHistogram"] {
                        guard let data = metric[kind] as? [String: Any] else { continue }
                        for point in dictionaries(data["dataPoints"]) {
                            guard let value = metricValue(point, kind: kind) else { continue }
                            received.append(MetricItem(time: date(fromNanoseconds: numeric(point["timeUnixNano"])), name: name, value: value, unit: unit, service: service, kind: kind, attributes: attributeValues(point["attributes"])))
                        }
                    }
                }
            }
        }
        if received.isEmpty { received = [MetricItem(time: .now, name: "received.metric", value: 0, unit: "", service: "unknown")] }
        metrics.insert(contentsOf: received, at: 0); metrics = Array(metrics.prefix(500)); metricCount += received.count
    }

    private func serviceName(in resource: [String: Any]) -> String {
        let attributes = dictionaries((resource["resource"] as? [String: Any])?["attributes"])
        return attributes.first { $0["key"] as? String == "service.name" }.flatMap { ($0["value"] as? [String: Any])?["stringValue"] as? String } ?? "unknown"
    }

    private func numeric(_ value: Any?) -> UInt64 {
        if let string = value as? String { return UInt64(string) ?? 0 }
        if let number = value as? NSNumber { return number.uint64Value }
        return 0
    }

    private func dictionaries(_ value: Any?) -> [[String: Any]] {
        if let values = value as? [Any] {
            return values.compactMap { $0 as? [String: Any] }
        }
        return value as? [[String: Any]] ?? []
    }

    private func attributeValues(_ value: Any?) -> [String: String] {
        Dictionary(dictionaries(value).compactMap { attribute -> (String, String)? in
            guard let key = attribute["key"] as? String, let value = attribute["value"] as? [String: Any] else { return nil }
            return (key, render(value))
        }, uniquingKeysWith: { _, last in last })
    }

    /// Renders an OTLP AnyValue. JSON exporters send int64 as either a string
    /// or a bare number, so every numeric form is accepted.
    private func render(_ value: [String: Any]) -> String {
        if let string = value["stringValue"] as? String { return string }
        if let bool = value["boolValue"] as? Bool { return String(bool) }
        if let int = value["intValue"] {
            if let string = int as? String { return string }
            if let number = int as? NSNumber { return String(number.int64Value) }
        }
        if let double = (value["doubleValue"] as? NSNumber)?.doubleValue ?? (value["doubleValue"] as? String).flatMap(Double.init) {
            return double.formatted(.number.precision(.fractionLength(0...6)).grouping(.never))
        }
        if let array = (value["arrayValue"] as? [String: Any])?["values"] as? [[String: Any]] {
            return "[" + array.map(render).joined(separator: ", ") + "]"
        }
        if let list = (value["kvlistValue"] as? [String: Any])?["values"] {
            return attributeValues(list).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        if let bytes = value["bytesValue"] as? String { return bytes }
        return ""
    }

    private func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// One representative number per data point. Histograms collapse to their mean.
    private func metricValue(_ point: [String: Any], kind: String) -> Double? {
        if kind == "histogram" || kind == "exponentialHistogram" {
            guard let count = double(point["count"]), count > 0, let sum = double(point["sum"]) else { return nil }
            return sum / count
        }
        return double(point["asDouble"]) ?? double(point["asInt"])
    }

    private func date(fromNanoseconds nanoseconds: UInt64) -> Date {
        nanoseconds == 0 ? .now : Date(timeIntervalSince1970: Double(nanoseconds) / 1_000_000_000)
    }

    private func send(_ response: String, through connection: NWConnection) {
        // Keep the socket alive briefly after the response. `cancel()` on a
        // just-written TCP socket can otherwise surface as -1005 in URLSession.
        connection.send(content: Data(response.utf8), contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                connection.cancel()
            }
        })
    }
}
