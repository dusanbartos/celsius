import CelsiusCore
import SwiftUI

struct PopoverView: View {
    /// The popover's screens, from the top level down.
    enum Screen: Int, Comparable {
        case overview, detail, settings

        static func < (lhs: Screen, rhs: Screen) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var store: ACStore
    /// Freezes the animation clock, for snapshots.
    var fixedDate: Date?

    @State private var screen: Screen
    @State private var settingsReturnsTo: Screen = .overview
    @State private var navigatingBack = false
    @State private var draggingTarget: Double?

    /// `screen` only seeds the first screen (snapshots start on the detail); navigation owns it afterwards.
    init(store: ACStore, fixedDate: Date? = nil, screen: Screen = .overview) {
        self.store = store
        self.fixedDate = fixedDate
        _screen = State(initialValue: screen)
    }

    /// Settings until there's a token, and straight to the detail when the account has a single unit.
    private var shownScreen: Screen {
        if store.connection == .needsSetup { return .settings }
        if screen == .overview && store.devices.count < 2 { return .detail }
        return screen
    }

    var body: some View {
        Group {
            switch shownScreen {
            case .overview:
                OverviewView(store: store, onOpen: open, onSettings: { go(to: .settings) })
                    .transition(slide)
            case .detail:
                controls
                    .transition(slide)
            case .settings:
                SettingsView(store: store, canGoBack: store.connection != .needsSetup) {
                    go(to: settingsReturnsTo)
                }
                .transition(slide)
            }
        }
        .padding(14)
        .frame(width: Theme.popoverWidth)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .animation(.snappy(duration: 0.3), value: shownScreen)
        .onChange(of: store.isPopoverVisible) { _, visible in
            // Every click on the menu bar item starts from the overview. Reset on close, so the next open
            // doesn't flash the previous screen.
            guard !visible else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { screen = .overview }
        }
    }

    // MARK: Navigation

    /// Pushes deeper screens in from the trailing edge, and slides back the other way.
    private var slide: AnyTransition {
        let forward = AnyTransition.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading))
        let back = AnyTransition.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing))
        return (navigatingBack ? back : forward).combined(with: .opacity)
    }

    private func go(to target: Screen) {
        if target == .settings { settingsReturnsTo = shownScreen }
        // The outgoing screen leaves with the transition it was last drawn with, so set the direction first
        // and change the screen on the next update.
        navigatingBack = target < shownScreen
        Task { screen = target }
    }

    private func open(_ device: ThinQDevice) {
        Task { await store.selectDevice(id: device.id) }
        go(to: .detail)
    }

    // MARK: Main screen

    private var status: ACStatus? { store.status }
    private var isOn: Bool { status?.isOn ?? false }
    private var caps: ACCapabilities { store.capabilities }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        bigTemperature
                        Text(Labels.activity(status, target: draggingTarget ?? status?.targetTemperature))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .contentTransition(.interpolate)
                    }
                    Spacer()
                    miniUnit
                }
                temperatureSlider
            }
            Divider()
            settingsRows
            Divider()
            toggleRows
            Divider()
            MenuRow(title: "Air conditioner settings…", showsBadge: store.availableUpdate != nil) { go(to: .settings) }
        }
        .redacted(reason: status == nil ? .placeholder : [])
    }

    /// Device name and power, with the room temperature below (or what's wrong, when something is). With
    /// several units, a back button returns to the overview.
    private var header: some View {
        HStack(spacing: 8) {
            if store.devices.count > 1 {
                Button { go(to: .overview) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("All air conditioners")
                .accessibilityLabel("All air conditioners")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(store.device?.displayName ?? "Air conditioner")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if store.transientMessage != nil || store.isReconnecting || store.connection != .connected {
                    FooterStatus(store: store)
                } else {
                    Text("Room · \(Labels.temperature(status?.currentTemperature)) °C")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .contentTransition(.numericText())
                }
            }
            Spacer()
            Toggle("Power", isOn: Binding(get: { isOn }, set: { store.perform(.power($0)) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(status == nil)
        }
    }

    private var bigTemperature: some View {
        let value = draggingTarget ?? status?.targetTemperature
        let whole = value.map { String(Int($0.rounded(.down))) } ?? "—"
        let half = value.map { $0.rounded(.down) != $0 } ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(whole)
                .font(.system(size: 44, weight: .medium))
                .contentTransition(.numericText(value: value ?? 0))
            if half {
                Text(".5")
                    .font(.system(size: 22, weight: .medium))
            }
            Text("°C")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.secondaryText)
        }
        .monospacedDigit()
        .animation(.snappy(duration: 0.25), value: value)
        .opacity(isOn && temperatureEditable ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Target temperature \(Labels.temperature(value)) degrees")
    }

    /// The animated unit, drawn at full size and scaled down to sit beside the temperature.
    private var miniUnit: some View {
        ACUnitView(
            isOn: isOn,
            mode: status?.mode,
            fanSpeed: status?.fanSpeed,
            swing: status?.swing ?? false,
            sleeping: status?.sleepMinutesLeft != nil,
            target: draggingTarget ?? status?.targetTemperature,
            isVisible: store.isPopoverVisible || fixedDate != nil,
            fixedDate: fixedDate
        )
        .frame(width: 240)
        .scaleEffect(Self.miniUnitScale, anchor: .topLeading)
        .frame(width: 240 * Self.miniUnitScale, height: ACUnitView.height * Self.miniUnitScale, alignment: .topLeading)
    }

    private static let miniUnitScale: CGFloat = 0.55
    /// Shared by every pop-up button so they line up regardless of the selected value.
    private static let popUpWidth: CGFloat = 96

    private var temperatureEditable: Bool { ACMode.acceptsTargetTemperature(status?.mode) }

    private var temperatureSlider: some View {
        let enabled = isOn && temperatureEditable
        return TemperatureSlider(
            value: status?.targetTemperature ?? caps.minTemperature,
            range: caps.minTemperature...caps.maxTemperature,
            step: caps.temperatureStep,
            accent: Theme.modeColor(status?.mode),
            onChange: { draggingTarget = $0 },
            onCommit: { value in
                draggingTarget = nil
                store.setTargetTemperature(value, debounced: false)
            },
            onStep: { delta in
                let current = status?.targetTemperature ?? caps.minTemperature
                store.setTargetTemperature(current + delta, debounced: true)
            }
        )
        .disabled(!enabled)
        .opacity(enabled ? 1 : Theme.disabledOpacity)
    }

    /// Mode as a segmented control, then fan speed and airflow as native pop-up buttons.
    private var settingsRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mode")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            SegmentedControl(
                options: caps.modes.map { (Labels.mode($0), $0) },
                selection: Binding(get: { status?.mode ?? "" }, set: { store.perform(.mode($0)) })
            )
            .accessibilityLabel("Mode")
            .padding(.bottom, 2)

            pickerRow(
                "Fan speed",
                options: caps.fanSpeeds.map { (Labels.fan($0), $0) },
                selection: Binding(get: { status?.fanSpeed ?? "" }, set: { store.perform(.fanSpeed($0)) })
            )
            if caps.supportsSwing {
                pickerRow(
                    "Airflow",
                    options: [("Fixed", false), ("Swing", true)],
                    selection: Binding(get: { status?.swing ?? false }, set: { store.perform(.swing($0)) })
                )
            }
        }
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }

    private func pickerRow<Value: Hashable>(
        _ title: String, options: [(title: String, value: Value)], selection: Binding<Value>
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
            Spacer()
            PopUpButton(options: options, selection: selection)
                .frame(width: Self.popUpWidth)
                .accessibilityLabel(title)
        }
    }

    private var toggleRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if caps.supportsEco {
                CircleToggleRow(systemImage: "leaf", title: "Eco mode", isOn: status?.eco == true) {
                    store.perform(.eco(status?.eco != true))
                }
            }
        }
        .disabled(!isOn)
        .opacity(isOn ? 1 : Theme.disabledOpacity)
    }
}
