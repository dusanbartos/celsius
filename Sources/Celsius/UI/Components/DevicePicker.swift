import CelsiusCore
import SwiftUI

/// The selected air conditioner's name. When the account has more than one, it opens a menu to switch.
struct DevicePicker: View {
    var store: ACStore

    var body: some View {
        let name = Text(store.device?.displayName ?? "Air conditioner")
            .font(.system(size: 13, weight: .semibold))
        if store.devices.count > 1 {
            Menu {
                ForEach(store.devices) { device in
                    Toggle(device.displayName, isOn: Binding(
                        get: { device.id == store.device?.id },
                        set: { _ in Task { await store.selectDevice(id: device.id) } }
                    ))
                }
            } label: {
                HStack(spacing: 4) {
                    name
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch air conditioner")
            .accessibilityLabel("Air conditioner")
            .accessibilityValue(store.device?.displayName ?? "")
        } else {
            name
        }
    }
}
