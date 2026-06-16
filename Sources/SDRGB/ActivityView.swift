import SwiftUI

/// The 24h activity log window. Opened by clicking the header status dot (events)
/// or the heart (keepalive writes).
struct ActivityView: View {
    @EnvironmentObject var device: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $device.activityFilter) {
                Text("All").tag(ActivityFilter.all)
                Text("Keepalive").tag(ActivityFilter.keepalive)
                Text("Events").tag(ActivityFilter.events)
            }
            .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 12)

            let items = filtered
            if items.isEmpty {
                Spacer()
                Text("No activity in the last 24 hours.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(items) { event in
                    HStack(spacing: 8) {
                        Image(systemName: icon(event.kind))
                            .foregroundStyle(color(event.kind))
                            .frame(width: 16)
                        Text(event.text).font(.callout)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(timeText(event.date))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text("\(items.count) in last 24h").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Keepalive now") { device.beatNow() }.font(.caption)
            }
            .padding([.horizontal, .bottom], 12)
        }
        .frame(width: 440, height: 480)
    }

    private var filtered: [ActivityEvent] {
        let newestFirst = device.events.reversed()
        switch device.activityFilter {
        case .all: return Array(newestFirst)
        case .keepalive: return newestFirst.filter { $0.kind == .keepalive }
        case .events: return newestFirst.filter { $0.kind != .keepalive }
        }
    }

    private func icon(_ k: ActivityEvent.Kind) -> String {
        switch k {
        case .keepalive: return "heart.fill"
        case .update: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .repair: return "wrench.and.screwdriver.fill"
        }
    }

    private func color(_ k: ActivityEvent.Kind) -> Color {
        switch k {
        case .keepalive: return .pink
        case .update: return .green
        case .error: return .red
        case .warning: return .orange
        case .repair: return .blue
        }
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
