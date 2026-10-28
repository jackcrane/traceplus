import SwiftUI

public struct EmitterView: View {
    @Environment(TelemetryEmitter.self) private var emitter
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
            Spacer()
            VStack(alignment: .leading, spacing: 6) { Text("\(emitter.totalSent) signals accepted").font(.headline); Text(emitter.lastResult).foregroundStyle(emitter.lastResult.hasPrefix("Couldn’t") ? .red : .secondary).lineLimit(2) }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }.padding(30)
    }
    private func icon(for signal: TelemetryEmitter.Signal) -> String { switch signal { case .trace: "point.3.connected.trianglepath.dotted"; case .log: "text.alignleft"; case .metric: "chart.xyaxis.line" } }
}
