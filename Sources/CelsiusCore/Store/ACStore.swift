import Foundation
import Observation

public enum ConnectionState: Equatable, Sendable {
    case needsSetup
    case loading
    case connected
    case offline(String)
    case unauthorized
    case deviceError
}

/// Source of truth for the UI: the last state read from LG's cloud, overlaid with optimistic changes.
///
/// The cloud can take a few seconds to reflect a command, so each change is kept as an override until
/// the server confirms it or it expires. Commands are sent one at a time; a newer command for the same
/// field of the same device replaces one that hasn't been sent yet.
///
/// The selected device gets the full treatment (capabilities, frequent reads, connection state). The other
/// air conditioners on the account are read on the polling schedule, for the overview and the on/total count.
@MainActor
@Observable
public final class ACStore {
    /// The last state read from the cloud for each device, by ID.
    private var serverStatuses: [String: ACStatus] = [:]
    /// What the device's profile says it supports.
    public private(set) var deviceCapabilities: ACCapabilities = .fallback
    public private(set) var connection: ConnectionState = .loading
    public private(set) var device: ThinQDevice?
    /// Every air conditioner on the account, for switching between them.
    public private(set) var devices: [ThinQDevice] = []
    /// Devices other than the selected one that the cloud reported as offline on their last read.
    private var offlineDevices: Set<String> = []
    public private(set) var isSending = false
    /// A short-lived error to show in the footer, e.g. a rejected command.
    public private(set) var transientMessage: String?
    /// True while a few requests in a row have failed but the last known state is still being shown.
    public private(set) var isReconnecting = false
    /// A newer release than the running app, if the last check found one.
    public private(set) var availableUpdate: AppUpdate?
    private var overrides: [Key: Override] = [:]

    /// The user's temperature range, saved as soon as it changes.
    public var temperatureLimits: TemperatureLimits {
        didSet { settings.temperatureLimits = temperatureLimits }
    }

    /// Whether the menu bar shows a unit's room temperature next to the icon, saved as soon as it changes.
    public var showsMenuBarTemperature: Bool {
        didSet { settings.showsMenuBarTemperature = showsMenuBarTemperature }
    }

    /// The unit the menu bar reports on; nil follows the selected one. Saved as soon as it changes.
    public var menuBarDeviceID: String? {
        didSet { settings.menuBarDeviceID = menuBarDeviceID }
    }

    /// Polls faster while the popover is open.
    public var isPopoverVisible = false {
        didSet {
            guard oldValue != isPopoverVisible, isActive else { return }
            startPolling(immediately: isPopoverVisible)
        }
    }

    public static let overrideLifetime: TimeInterval = 8
    public static let visibleInterval: Duration = .seconds(20)
    public static let backgroundInterval: Duration = .seconds(300)
    /// How long the −/+ buttons wait for the value to settle before sending it.
    static let stepDebounce: Duration = .milliseconds(700)
    /// When to read the state back after a command, to confirm it (or recover from a failure).
    static let refreshAfterSend: Duration = .seconds(3)
    static let refreshAfterFailure: Duration = .seconds(1)
    /// Eco changes the unit's target temperature on its own, and the cloud is slow to report it, so the
    /// state is read a few more times, stopping as soon as the target moves.
    static let ecoFollowUpDelays: [Duration] = [.seconds(3), .seconds(3), .seconds(4)]
    static let messageDuration: Duration = .seconds(4)
    /// Waits before each retry of a read that failed in a way that may pass on its own.
    static let readRetryDelays: [Duration] = [.milliseconds(500), .milliseconds(1500)]
    /// Consecutive failed refreshes before the UI says the connection is lost.
    static let failuresBeforeOffline = 3
    /// Wait before sending a failed command once more, and the longer wait after a rate limit.
    static let commandRetryDelay: Duration = .seconds(1)
    static let rateLimitRetryDelay: Duration = .seconds(2)
    /// Pause between two commands in a burst, so LG's rate limit isn't hit.
    static let minimumSendGap: Duration = .milliseconds(400)
    /// How long to wait before asking GitHub for a new release again.
    static let updateCheckInterval: TimeInterval = 24 * 60 * 60

    @ObservationIgnored private let settings: SettingsStorage
    @ObservationIgnored private let makeClient: (String, String) -> ThinQClient
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let isPreview: Bool
    @ObservationIgnored private let updateChecker: UpdateChecker?
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private var failureStreak = 0
    @ObservationIgnored private var lastUpdateCheck: Date?
    @ObservationIgnored private var capabilitiesLoaded = false
    /// Profiles already read, so switching back to a device doesn't wait for its profile again.
    @ObservationIgnored private var capabilitiesByDevice: [String: ACCapabilities] = [:]
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var isRefreshingOthers = false
    /// Set when the user picks another device, so a read still running for the previous one is dropped.
    @ObservationIgnored private var deviceSwitched = false
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var queue: [Pending] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshSoonTask: Task<Void, Never>?
    @ObservationIgnored private var refreshOthersSoonTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    struct Override {
        var command: ACCommand
        var expires: Date
    }

    /// What overrides and the queue coalesce on: one field of one device.
    struct Key: Hashable {
        var deviceID: String
        var field: ACField
    }

    struct Pending {
        var deviceID: String
        var command: ACCommand
        var key: Key { Key(deviceID: deviceID, field: command.field) }
    }

    public init(
        settings: SettingsStorage,
        makeClient: @escaping (String, String) -> ThinQClient = { ThinQClient(token: $0, clientID: $1) },
        now: @escaping () -> Date = Date.init,
        updateChecker: UpdateChecker? = nil,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.updateChecker = updateChecker
        self.sleep = sleep
        self.settings = settings
        self.makeClient = makeClient
        self.now = now
        self.isPreview = false
        self.temperatureLimits = settings.temperatureLimits
        self.showsMenuBarTemperature = settings.showsMenuBarTemperature
        self.menuBarDeviceID = settings.menuBarDeviceID
        if settings.token?.isEmpty ?? true { connection = .needsSetup }
    }

    /// A store with fixed data that never touches the network, for snapshots.
    public init(
        previewStatus: ACStatus?, capabilities: ACCapabilities, connection: ConnectionState = .connected,
        availableUpdate: AppUpdate? = nil, isReconnecting: Bool = false,
        devices: [ThinQDevice]? = nil, otherStatuses: [String: ACStatus] = [:]
    ) {
        // Limits that keep the given capabilities as they are.
        let limits = TemperatureLimits(
            minimum: capabilities.minTemperature, maximum: capabilities.maxTemperature,
            halfDegrees: capabilities.temperatureStep < 1
        )
        self.settings = InMemorySettings(token: "preview", temperatureLimits: limits)
        self.temperatureLimits = limits
        self.showsMenuBarTemperature = true
        self.menuBarDeviceID = nil
        self.makeClient = { ThinQClient(token: $0, clientID: $1) }
        self.now = Date.init
        self.isPreview = true
        self.updateChecker = nil
        self.sleep = { _ in }
        self.availableUpdate = availableUpdate
        self.isReconnecting = isReconnecting
        self.deviceCapabilities = capabilities
        self.connection = connection
        let devices = devices ?? [ThinQDevice(
            deviceId: "preview",
            deviceInfo: .init(deviceType: "DEVICE_AIR_CONDITIONER", modelName: "RAC_056905_WW", alias: "Ar-condicionado")
        )]
        self.devices = devices
        self.device = devices.first
        self.serverStatuses = otherStatuses
        if let id = devices.first?.id { self.serverStatuses[id] = previewStatus }
    }

    // MARK: State

    /// The selected device's last state read from the cloud.
    public var serverStatus: ACStatus? { device.flatMap { serverStatuses[$0.id] } }

    /// What the UI shows for the selected device: server state plus pending changes.
    public var status: ACStatus? { device.flatMap { status(of: $0.id) } }

    /// What the UI shows for any device: server state plus pending changes. Nil until it has been read.
    public func status(of deviceID: String) -> ACStatus? {
        guard var status = serverStatuses[deviceID] else { return nil }
        let date = now()
        for field in ACField.allCases {
            if let override = overrides[Key(deviceID: deviceID, field: field)], override.expires > date {
                status = status.applying(override.command)
            }
        }
        return status
    }

    /// Whether the cloud last reported the device as unreachable.
    public func isOffline(_ deviceID: String) -> Bool {
        guard deviceID == device?.id else { return offlineDevices.contains(deviceID) }
        if case .offline = connection { return true }
        return false
    }

    /// The unit the menu bar reports on: the one picked in Settings, or the selected one when none is picked
    /// or the picked one is no longer on the account.
    public var menuBarDevice: ThinQDevice? {
        devices.first { $0.id == menuBarDeviceID } ?? device
    }

    /// What the UI offers: the device's capabilities within the user's temperature limits.
    public var capabilities: ACCapabilities { deviceCapabilities.limited(to: temperatureLimits) }

    public var hasToken: Bool { !(settings.token?.isEmpty ?? true) }

    /// How many of the account's air conditioners are on, with pending changes applied.
    /// Nil with a single unit. A unit not read yet counts as off.
    public var powerSummary: (on: Int, total: Int)? {
        guard devices.count > 1 else { return nil }
        let on = devices.count { status(of: $0.id)?.isOn == true }
        return (on, devices.count)
    }

    // MARK: Lifecycle

    public func start() {
        isActive = true
        startPolling(immediately: true)
        Task { await checkForUpdate() }
    }

    /// Looks for a newer release, at most once a day. A failure is silent: it's not worth bothering the user.
    func checkForUpdate() async {
        guard let updateChecker, !isPreview else { return }
        let date = now()
        if let last = lastUpdateCheck, date.timeIntervalSince(last) < Self.updateCheckInterval { return }
        do {
            availableUpdate = try await updateChecker.availableUpdate()
            lastUpdateCheck = date
        } catch {
            // Leave lastUpdateCheck unset so a network failure is retried on the next start.
        }
    }

    /// Stops polling, e.g. while the Mac sleeps.
    public func suspend() {
        isActive = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling(immediately: Bool) {
        guard !isPreview else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = immediately
            while !Task.isCancelled {
                guard let self else { return }
                if first {
                    await self.refresh()
                    await self.refreshOtherDevices()
                } else {
                    first = true
                }
                let interval = self.isPopoverVisible ? Self.visibleInterval : Self.backgroundInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: Setup

    /// Saves a new token and connects to the first air conditioner on the account.
    public func connect(token: String) async {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.token = token
        guard settings.token == token else {
            connection = .needsSetup
            showMessage("Couldn't save the token in the keychain")
            return
        }
        forgetDevice()
        connection = .loading
        await refresh()
        if isActive { startPolling(immediately: false) }
    }

    public func signOut() {
        settings.token = nil
        forgetDevice()
        queue = []
        connection = .needsSetup
    }

    /// Switches the detail view to another air conditioner on the account. Its last known state shows right
    /// away while it's read again. Changes still waiting for the previous one are sent to it as planned.
    public func selectDevice(id: String) async {
        guard id != device?.id, let chosen = devices.first(where: { $0.id == id }) else { return }
        device = chosen
        settings.deviceID = chosen.id
        refreshSoonTask?.cancel()
        let cached = capabilitiesByDevice[chosen.id]
        deviceCapabilities = cached ?? .fallback
        capabilitiesLoaded = cached != nil
        offlineDevices.remove(chosen.id)
        failureStreak = 0
        isReconnecting = false
        if let status = serverStatuses[chosen.id] {
            connection = status.hasError ? .deviceError : .connected
        } else {
            connection = .loading
        }
        deviceSwitched = true
        await refresh()
    }

    private func forgetDevice() {
        settings.deviceID = nil
        device = nil
        devices = []
        serverStatuses = [:]
        offlineDevices = []
        overrides = [:]
        capabilitiesLoaded = false
        capabilitiesByDevice = [:]
    }

    // MARK: Refresh

    public func refresh() async {
        guard !isPreview, !isRefreshing else { return }
        guard let token = settings.token, !token.isEmpty else {
            connection = .needsSetup
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let client = makeClient(token, settings.clientID)
        // Switching devices mid-read makes that read stale, so read again for the one now selected.
        repeat {
            deviceSwitched = false
            await read(with: client)
        } while deviceSwitched
    }

    private func read(with client: ThinQClient) async {
        if serverStatus == nil { connection = .loading }
        do {
            let (deviceID, status, capabilities) = try await retryingTransient {
                let deviceID = try await resolveDevice(client)
                let capabilities = capabilitiesLoaded ? nil : try await client.capabilities(deviceID: deviceID)
                return (deviceID, try await client.status(deviceID: deviceID), capabilities)
            }
            guard !deviceSwitched else { return }
            if let capabilities {
                deviceCapabilities = capabilities
                capabilitiesByDevice[deviceID] = capabilities
                capabilitiesLoaded = true
            }
            serverStatuses[deviceID] = status
            pruneOverrides(for: deviceID)
            noteSuccess()
            connection = status.hasError ? .deviceError : .connected
        } catch {
            guard !deviceSwitched else { return }
            handle(error)
        }
    }

    /// Reads every unit except the selected one, for the overview and the on/total count. Runs on the polling
    /// schedule and after a command to one of them. A failed read keeps the last known state, except that an
    /// offline unit is marked as such and counts as off.
    func refreshOtherDevices() async {
        guard !isPreview, !isRefreshingOthers, devices.count > 1, let token = settings.token, !token.isEmpty else { return }
        isRefreshingOthers = true
        defer { isRefreshingOthers = false }
        let client = makeClient(token, settings.clientID)
        for other in devices where other.id != device?.id {
            do {
                serverStatuses[other.id] = try await client.status(deviceID: other.id)
                offlineDevices.remove(other.id)
                pruneOverrides(for: other.id)
            } catch ThinQError.deviceOffline {
                serverStatuses[other.id]?.isOn = false
                offlineDevices.insert(other.id)
            } catch {
                // Keep the last known state; the next poll tries again.
            }
        }
    }

    /// Runs a read, trying again after a short wait when it fails in a way that may pass on its own.
    private func retryingTransient<T>(_ operation: () async throws -> T) async throws -> T {
        var delays = Self.readRetryDelays[...]
        while true {
            do {
                return try await operation()
            } catch let error as ThinQError where error.isTransient && !delays.isEmpty {
                await sleep(delays.removeFirst())
                if Task.isCancelled { throw CancellationError() }
            }
        }
    }

    private func noteSuccess() {
        failureStreak = 0
        isReconnecting = false
    }

    private func resolveDevice(_ client: ThinQClient) async throws -> String {
        if let device, device.id == settings.deviceID { return device.id }
        devices = try await client.devices().filter(\.isAirConditioner)
        guard let chosen = devices.first(where: { $0.id == settings.deviceID }) ?? devices.first else {
            throw ThinQError.api(code: "", message: "No air conditioner found on this LG account")
        }
        device = chosen
        settings.deviceID = chosen.id
        capabilitiesLoaded = false
        return chosen.id
    }

    /// Drops the device's overrides that the server has confirmed or that have expired.
    private func pruneOverrides(for deviceID: String) {
        guard let serverStatus = serverStatuses[deviceID] else { return }
        let date = now()
        overrides = overrides.filter { key, override in
            key.deviceID != deviceID
                || override.expires > date && serverStatus.applying(override.command) != serverStatus
        }
    }

    private func scheduleRefreshOfOthers(after delay: Duration) {
        guard !isPreview else { return }
        refreshOthersSoonTask?.cancel()
        refreshOthersSoonTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshOtherDevices()
        }
    }

    private func scheduleRefresh(after delay: Duration) {
        guard !isPreview else { return }
        refreshSoonTask?.cancel()
        refreshSoonTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Reads the state after each delay, stopping early once the target temperature differs from `target`.
    private func scheduleRefreshes(after delays: [Duration], untilTargetChangesFrom target: Double?) {
        guard !isPreview else { return }
        refreshSoonTask?.cancel()
        refreshSoonTask = Task { [weak self] in
            for delay in delays {
                guard let self else { return }
                await self.sleep(delay)
                guard !Task.isCancelled else { return }
                await self.refresh()
                if let target, let now = self.serverStatus?.targetTemperature, now != target { return }
            }
        }
    }

    // MARK: Commands

    /// Changes the selected device.
    public func perform(_ command: ACCommand) {
        guard let id = device?.id else { return }
        perform(command, on: id)
    }

    /// Changes any device on the account, e.g. power from the overview.
    public func perform(_ command: ACCommand, on deviceID: String) {
        guard let current = status(of: deviceID) else { return }
        let pending = Pending(deviceID: deviceID, command: command)
        // Re-sending the current value is wasteful and, for power, rejected by the API.
        if current.applying(command) == current, !queue.contains(where: { $0.key == pending.key }) {
            return
        }
        if command.field == .target, deviceID == device?.id { debounceTask?.cancel() }
        overrides[pending.key] = Override(command: command, expires: now().addingTimeInterval(Self.overrideLifetime))
        enqueue(pending)
    }

    /// Updates the target right away and sends it once the value settles (used by the −/+ buttons).
    public func setTargetTemperature(_ value: Double, debounced: Bool) {
        let command = ACCommand.targetTemperature(capabilities.snap(value))
        guard debounced else {
            perform(command)
            return
        }
        guard let id = device?.id else { return }
        let pending = Pending(deviceID: id, command: command)
        overrides[pending.key] = Override(command: command, expires: now().addingTimeInterval(Self.overrideLifetime + 1))
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.stepDebounce)
            guard !Task.isCancelled, let self else { return }
            self.overrides[pending.key]?.expires = self.now().addingTimeInterval(Self.overrideLifetime)
            self.enqueue(pending)
        }
    }

    private func enqueue(_ pending: Pending) {
        if let index = queue.firstIndex(where: { $0.key == pending.key }) {
            queue[index] = pending
        } else {
            queue.append(pending)
        }
        guard worker == nil else { return }
        isSending = true
        worker = Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.send(next)
                if !self.queue.isEmpty { await self.sleep(Self.minimumSendGap) }
            }
            self?.worker = nil
            self?.isSending = false
        }
    }

    private func send(_ pending: Pending) async {
        guard !isPreview else { return }
        guard let token = settings.token else { return }
        let (deviceID, command) = (pending.deviceID, pending.command)
        let client = makeClient(token, settings.clientID)
        var retried = false
        while true {
            do {
                try await client.send(command, deviceID: deviceID)
                noteSuccess()
                keepOverrideAlive(for: pending)
                confirmLater(pending)
                return
            } catch let error as ThinQError where !retried && (error.isTransient || error == .deviceOffline) {
                retried = true
                keepOverrideAlive(for: pending)
                await sleep(error == .rateLimited ? Self.rateLimitRetryDelay : Self.commandRetryDelay)
                // A newer value for the same field is already waiting, so this one is stale.
                if queue.contains(where: { $0.key == pending.key }) { return }
                // A timeout doesn't say whether the unit got the command; don't send it twice.
                if case .network = error,
                   let current = try? await client.status(deviceID: deviceID),
                   current.applying(command) == current {
                    noteSuccess()
                    confirmLater(pending)
                    return
                }
            } catch {
                if overrides[pending.key]?.command == command {
                    overrides[pending.key] = nil
                }
                if deviceID == device?.id {
                    handle(error)
                    scheduleRefresh(after: Self.refreshAfterFailure)
                } else {
                    handleOther(error, deviceID: deviceID)
                }
                return
            }
        }
    }

    /// Reads the device again once the cloud has had time to reflect the command.
    private func confirmLater(_ pending: Pending) {
        if pending.deviceID != device?.id {
            scheduleRefreshOfOthers(after: Self.refreshAfterSend)
        } else if pending.command.field == .eco {
            scheduleRefreshes(after: Self.ecoFollowUpDelays, untilTargetChangesFrom: serverStatus?.targetTemperature)
        } else {
            scheduleRefresh(after: Self.refreshAfterSend)
        }
    }

    private func keepOverrideAlive(for pending: Pending) {
        if overrides[pending.key]?.command == pending.command {
            overrides[pending.key]?.expires = now().addingTimeInterval(Self.overrideLifetime)
        }
    }

    /// A command to a unit other than the selected one failed: say so, without touching the selected
    /// unit's connection state (unless the token itself is the problem).
    private func handleOther(_ error: any Error, deviceID: String) {
        if error is CancellationError { return }
        let error = error as? ThinQError ?? .network(error.localizedDescription)
        if error == .unauthorized {
            connection = .unauthorized
            return
        }
        if error == .deviceOffline { offlineDevices.insert(deviceID) }
        let name = devices.first { $0.id == deviceID }?.displayName ?? "Air conditioner"
        showMessage("\(name): \(error.message)")
    }

    private func handle(_ error: any Error) {
        if error is CancellationError { return }
        let error = error as? ThinQError ?? .network(error.localizedDescription)
        switch error {
        case .unauthorized:
            connection = .unauthorized
        case .deviceOffline:
            connection = .offline(error.message)
        case .network, .serverError:
            // One failed request is a hiccup: keep showing the last state until it keeps failing.
            failureStreak += 1
            if serverStatus != nil, failureStreak < Self.failuresBeforeOffline {
                isReconnecting = true
            } else {
                isReconnecting = false
                connection = .offline(error.message)
            }
        case .rateLimited, .rejected, .api, .invalidResponse:
            if serverStatus == nil { connection = .offline(error.message) }
            showMessage(error.message)
        }
    }

    private func showMessage(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: Self.messageDuration)
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}
