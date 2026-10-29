import SwiftUI

public struct EmitterView: View {
    @Environment(TelemetryEmitter.self) private var emitter
    @Environment(ContrailRunner.self) private var ramen
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) { Text("Telemetry Fountain").font(.largeTitle.weight(.bold)); Text("A local OTLP signal generator for TracePlus.").foregroundStyle(.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow { Text("Receiver").foregroundStyle(.secondary); TextField("Receiver URL", text: Bindable(emitter).endpoint).textFieldStyle(.roundedBorder) }
                GridRow { Text("Service name").foregroundStyle(.secondary); TextField("Service name", text: Bindable(emitter).serviceName).textFieldStyle(.roundedBorder) }
            }
            HStack(spacing: 12) { ForEach(TelemetryEmitter.Signal.allCases) { signal in Button { emitter.send(signal) } label: { Label("Send \(signal.rawValue)", systemImage: icon(for: signal)) }.buttonStyle(.borderedProminent).disabled(emitter.isSending) } }
            Button {
                emitter.sendRealisticWorkload()
            } label: {
                Label("Send 2,500-span realistic workload", systemImage: "bolt.fill")
            }
            .buttonStyle(.bordered)
            .disabled(emitter.isSending)
            if let progress = emitter.workloadProgress {
                VStack(alignment: .leading, spacing: 7) {
                    HStack { Text(emitter.workloadPhase); Spacer(); Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit() }
                        .font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                }
            }
            Toggle("Continuously emit one signal every 2 seconds", isOn: Bindable(emitter).autoEmit).toggleStyle(.switch)
            Divider()
            ramenSection
            Spacer()
            VStack(alignment: .leading, spacing: 6) { Text("\(emitter.totalSent) signals accepted").font(.headline); Text(emitter.lastResult).foregroundStyle(emitter.lastResult.hasPrefix("Couldn’t") ? .red : .secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }.padding(30)
    }

    private var ramenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) { Text("Contrail").font(.headline); Text("Flight-planning test app (web UI, five services, Postgres) in Docker.").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { ramen.revealInFinder() } label: { Label("Folder", systemImage: "folder") }.buttonStyle(.bordered)
                Button { ramen.openApp() } label: { Label("Open App", systemImage: "safari") }.buttonStyle(.bordered).disabled(ramen.state != .running)
                if ramen.isActive {
                    Button { ramen.stop() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(.borderedProminent).tint(.red).disabled(ramen.state == .stopping)
                } else {
                    Button { ramen.start(endpoint: emitter.endpoint) } label: { Label("Start", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
                }
            }
            HStack {
                Circle().fill(ramen.state == .running ? .green : ramen.state == .stopped ? .gray : .orange).frame(width: 8, height: 8)
                Text(ramen.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(ramen.output.isEmpty ? "Output appears here once the app starts." : ramen.output.joined(separator: "\n"))
                        .font(.caption.monospaced()).foregroundStyle(ramen.output.isEmpty ? .tertiary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).id("end")
                }
                .frame(height: 150).padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: ramen.output.count) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }
    private func icon(for signal: TelemetryEmitter.Signal) -> String { switch signal { case .trace: "point.3.connected.trianglepath.dotted"; case .log: "text.alignleft"; case .metric: "chart.xyaxis.line" } }
}
