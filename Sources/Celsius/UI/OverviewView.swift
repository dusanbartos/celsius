import CelsiusCore
import SwiftUI

/// Every air conditioner on the account, each with a power button. Clicking a unit opens its detail.
struct OverviewView: View {
    var store: ACStore
    var onOpen: (ThinQDevice) -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            VStack(spacing: 2) {
                ForEach(store.devices) { device in
                    UnitRow(
                        name: device.displayName,
                        status: store.status(of: device.id),
                        isOffline: store.isOffline(device.id),
                        onToggle: {
                            guard let isOn = store.status(of: device.id)?.isOn else { return }
                            store.perform(.power(!isOn), on: device.id)
                        },
                        onOpen: { onOpen(device) }
                    )
                }
            }
            Divider()
            MenuRow(title: "Air conditioner settings…", showsBadge: store.availableUpdate != nil, action: onSettings)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Air conditioners")
                .font(.system(size: 13, weight: .semibold))
            if store.transientMessage != nil || store.isReconnecting || store.connection == .loading
                || store.connection == .unauthorized {
                FooterStatus(store: store)
            } else if let summary = store.powerSummary {
                Text("\(summary.on) of \(summary.total) on")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// A Control Center–style row: a round power button, then the unit's name and state, which opens its detail.
private struct UnitRow: View {
    var name: String
    var status: ACStatus?
    var isOffline: Bool
    var onToggle: () -> Void
    var onOpen: () -> Void

    @State private var isHovered = false

    private var isOn: Bool { status?.isOn == true && !isOffline }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12))))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(status == nil || isOffline)
            .opacity(status == nil || isOffline ? Theme.disabledOpacity : 1)
            .help(isOn ? "Turn off" : "Turn on")
            .accessibilityLabel("\(name) power")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityAddTraits(isOn ? [.isSelected] : [])

            Button(action: onOpen) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(isOffline ? Theme.warning : Theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityValue(subtitle)
            .accessibilityHint("Shows all controls")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(isHovered ? 0.1 : 0))
        )
        .padding(.horizontal, -6)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    /// e.g. "Cooling to 23 °C · Room 26 °C", "Off · Room 26 °C" or "Offline".
    private var subtitle: String {
        if isOffline { return "Offline" }
        guard let status else { return "Loading…" }
        let activity = Labels.activity(status, target: status.targetTemperature)
        guard let room = status.currentTemperature else { return activity }
        return "\(activity) · Room \(Labels.temperature(room)) °C"
    }
}
