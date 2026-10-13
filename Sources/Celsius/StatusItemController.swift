import AppKit
import CelsiusCore
import SwiftUI

/// Menu bar item showing the room temperature, with the controls in a popover.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: ACStore
    private var observers: [NSObjectProtocol] = []

    init(store: ACStore) {
        self.store = store
        super.init()

        let hosting = NSHostingController(rootView: PopoverView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
        }
        observeStore()
        closePopoverWhenFocusMovesAway()
    }

    /// Like a native menu bar popover, dismiss when the user moves on. A transient popover only closes on a
    /// click it can see, so switching to a full-screen app's Space left it stranded over that app's content.
    private func closePopoverWhenFocusMovesAway() {
        let close: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.popover.close()
            }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main, using: close))
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: close))
    }

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        store.isPopoverVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        store.isPopoverVisible = false
    }

    // MARK: Menu bar label

    private func observeStore() {
        withObservationTracking {
            updateButton()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeStore() }
        }
    }

    /// The icon, temperature and tooltip describe the unit picked in Settings (the selected one by default).
    private func updateButton() {
        guard let button = statusItem.button else { return }
        let unit = store.menuBarDevice
        let status = unit.flatMap { store.status(of: $0.id) }
        let isOn = status?.isOn ?? false
        let symbol = isOn ? "air.conditioner.horizontal.fill" : "air.conditioner.horizontal"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Celsius")
            ?? NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Celsius")
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))

        let summary = store.powerSummary
        // The room temperature unless turned off in Settings, then with several units how many are on,
        // e.g. "24° · 1/3".
        let parts = [
            store.showsMenuBarTemperature ? status?.currentTemperature.map { "\(Labels.temperature($0))°" } : nil,
            summary.map { "\($0.on)/\($0.total)" },
        ].compactMap { $0 }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " · ")
        button.appearsDisabled = !isOn && status != nil
        let detail = status.map { status in
            status.isOn
                ? "On · \(Labels.mode(status.mode)) · set to \(Labels.temperature(status.targetTemperature))°C"
                : "Off"
        }
        let count = summary.map { "\($0.on) of \($0.total) air conditioners on" }
        let tip = [summary == nil ? nil : unit?.displayName, detail, count].compactMap { $0 }
        button.toolTip = tip.isEmpty ? nil : tip.joined(separator: "\n")
    }
}
