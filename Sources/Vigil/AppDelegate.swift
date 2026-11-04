// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import AppKit
import VigilCore
import VigilUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let sampler = Sampler()
    private lazy var store = MetricsStore(system: sampler.system)
    private lazy var coordinator = DesktopCoordinator(sampler: sampler, store: store)
    private lazy var layout = LayoutController(
        coordinator: coordinator,
        fileStore: options.layoutFile.map { LayoutFileStore(url: URL(fileURLWithPath: $0)) }
            ?? LayoutFileStore.standard())
    /// Test runs on a scratch layout also get scratch settings.
    private lazy var settings = SettingsStore(
        defaults: options.layoutFile == nil ? .standard : UserDefaults(suiteName: "app.vigil.test") ?? .standard)
    private var menuBar: MenuBarController?
    private var editSession: EditSession?
    private var settingsWindow: SettingsWindow?
    private var dashboard: Dashboard?
    private var hotKeys: [HotKey] = []
    private var registeredShortcuts: ShortcutSettings?
    private var isPaused = false
    private var feed: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var displaySwitch: Task<Void, Never>?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if options.listSpaces {
            listSpaces()
            NSApp.terminate(nil)
            return
        }

        if options.measure {
            coordinator.backgroundDemand = []
            if options.measureStatic { coordinator.refreshLimit = 3 }
            coordinator.show(CostHarness.layout(panels: options.measurePanels, material: options.measureMaterial))
            CostHarness.run(options: options)
        } else {
            coordinator.settings = settings.settings
            settings.onChange = { [weak self] in self?.settingsDidChange($0) }
            layout.onChange = { [weak self] in self?.editSession?.layoutDidChange() }
            if let preset = options.preset { layout.addLayout(preset.profile) }
            if let desktop = options.desktop {
                // Developer flag: pins every panel to Desktop N (saved like any edit).
                layout.change("Pin to Desktop \(desktop)") { profile in
                    for index in profile.panels.indices { profile.panels[index].placement.desktop = .index(desktop) }
                }
            }
            layout.autoSwitch(toDisplays: currentDisplays())
            layout.start()
            menuBar = MenuBarController(
                layout: layout,
                actions: .init(
                    isEditing: { [weak self] in self?.editSession != nil },
                    toggleEditMode: { [weak self] in self?.toggleEditMode() },
                    openDashboard: { [weak self] in self?.openDashboard() },
                    openSettings: { [weak self] in self?.openSettings(tab: $0) },
                    isPaused: { [weak self] in self?.isPaused ?? false },
                    togglePause: { [weak self] in _ = self?.togglePause() }))
            LayerPanelView.openProcess = { [weak self] identity in self?.openDashboard(selecting: identity) }
            coordinator.observeTicks(self) { [weak self] in self?.tick() }
            settingsDidChange(settings.settings)
            observeDisplays()
            observePowerAndHeat()
            if options.edit || options.gallery || options.inspect != nil { openEditModeForTesting() }
            if let tab = options.settingsTab { openSettings(tab: tab) }
            if options.dashboard { openDashboard() }
        }
        startFeed()
        observeSleep()
        if !options.measure { Diagnostics.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        feed?.cancel()
        if options.measure == false { layout.saveNow() }
    }

    // MARK: - Data

    private func startFeed() {
        feed = Task { [sampler, store, coordinator] in
            for await snapshot in await sampler.snapshots() {
                store.apply(snapshot)
                coordinator.storeDidUpdate()
            }
        }
    }

    private func tick() {
        menuBar?.tick(store: store, units: settings.settings.units)
    }

    private func settingsDidChange(_ new: VigilSettings) {
        coordinator.settings = new
        // The menu bar readout needs its metrics even when no panel shows them.
        coordinator.backgroundDemand = Demand([.cpu, .memory]).union(new.general.menuBar.demand)
        menuBar?.readout = new.general.menuBar
        menuBar?.update(shortcuts: new.general.shortcuts)
        registerHotKeys(new.general.shortcuts)
        updateSamplingInterval()
        Task { [sampler] in await sampler.setPrivateSensorsEnabled(new.general.privateSensors) }
    }

    // MARK: - Hotkeys

    private func registerHotKeys(_ shortcuts: ShortcutSettings) {
        guard shortcuts != registeredShortcuts else { return }
        registeredShortcuts = shortcuts
        hotKeys = []  // unregisters the previous ones
        let bindings: [(KeyShortcut?, @MainActor @Sendable () -> Void)] = [
            (shortcuts.editLayout, { [weak self] in self?.toggleEditMode() }),
            (shortcuts.dashboard, { [weak self] in self?.openDashboard() }),
            (shortcuts.peek, { [weak self] in self?.togglePeek() }),
        ]
        for (shortcut, action) in bindings {
            guard let shortcut,
                let hotKey = HotKey(keyCode: Int(shortcut.keyCode), modifiers: Int(shortcut.modifiers), action: action)
            else { continue }
            hotKeys.append(hotKey)
        }
    }

    /// While a shortcut is being recorded in Settings, the current ones must not fire.
    func suspendHotKeys(_ suspended: Bool) {
        if suspended {
            hotKeys = []
            registeredShortcuts = nil
        } else {
            registerHotKeys(settings.settings.general.shortcuts)
        }
    }

    /// Peek: raise all panels above windows; press again to put them back.
    private func togglePeek() {
        guard editSession == nil else { return }
        coordinator.isPeeking.toggle()
    }

    // MARK: - System events

    /// Nothing is sampled while the Mac or its displays sleep; on wake the first
    /// delta (which would span the sleep) is discarded by resetting baselines.
    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        let pause: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification]
        let resume: [Notification.Name] = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification]
        for name in pause {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setSystemPaused(true) }
                })
        }
        for name in resume {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setSystemPaused(false) }
                })
        }
    }

    private func setSystemPaused(_ systemPaused: Bool) {
        let paused = systemPaused || isPaused
        Task { [sampler] in await sampler.setPaused(paused) }
        if !systemPaused { coordinator.layout() }  // displays may have changed while asleep
    }

    private func currentDisplays() -> Set<String> { Set(ScreenCatalog.current().map(\.uuid)) }

    /// Switches to the layout bound to the connected displays, 1 s after they
    /// settle (docking flickers through several configurations; SPEC §7).
    private func observeDisplays() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displaySwitch?.cancel()
                    self.displaySwitch = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, let self else { return }
                        self.layout.autoSwitch(toDisplays: self.currentDisplays())
                    }
                }
            })
    }

    /// Low Power Mode or a hot Mac halves the sampling rate (SPEC §4.4).
    private func observePowerAndHeat() {
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateSamplingInterval() }
                })
        }
    }

    private func updateSamplingInterval() {
        let info = ProcessInfo.processInfo
        let interval = SamplingPolicy.interval(
            base: SamplerConfiguration.default.interval, adaptive: settings.settings.general.adaptiveSampling,
            lowPowerMode: info.isLowPowerModeEnabled, thermalState: info.thermalState.rawValue)
        Task { [sampler] in await sampler.setInterval(interval) }
    }

    // MARK: - Edit Mode

    private func toggleEditMode() {
        if let editSession {
            editSession.end()
            return
        }
        coordinator.isPeeking = false
        let session = EditSession(layout: layout, coordinator: coordinator, store: store)
        session.onEnd = { [weak self] in self?.editSession = nil }
        editSession = session
        session.begin()
    }

    private func openEditModeForTesting() {
        toggleEditMode()
        if options.gallery { editSession?.showGallery() }
        if let id = options.inspect {
            // After the overlays have been laid out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let overlay = self.coordinator.controller(id: id)?.overlay else { return }
                self.editSession?.select(id, extending: false)
                self.editSession?.inspect(
                    id, from: overlay, rect: CGRect(x: overlay.bounds.maxX - 24, y: 6, width: 18, height: 18))
            }
        }
    }

    // MARK: - Windows

    func openSettings(tab: SettingsTab? = nil) {
        if let settingsWindow {
            settingsWindow.show(tab: tab)
            return
        }
        let window = SettingsWindow(
            store: settings, coordinator: coordinator, metrics: store, layout: layout,
            currentDisplays: { [weak self] in self?.currentDisplayNames() ?? [] },
            suspendHotKeys: { [weak self] in self?.suspendHotKeys($0) })
        window.onClose = { [weak self] in self?.settingsWindow = nil }
        settingsWindow = window
        window.show(tab: tab)
    }

    /// Connected displays as (uuid, name), main first.
    private func currentDisplayNames() -> [(String, String)] {
        ScreenCatalog.current().map { ($0.uuid, $0.name) }
    }

    /// Toggles pause and returns the new state (Space in the Dashboard).
    private func togglePause() -> Bool {
        isPaused.toggle()
        Task { [sampler, isPaused] in await sampler.setPaused(isPaused) }
        return isPaused
    }

    func openDashboard(selecting identity: ProcessIdentity? = nil) {
        let dashboard =
            self.dashboard
            ?? Dashboard(store: store, coordinator: coordinator, settings: settings) { [weak self] in
                self?.togglePause() ?? false
            }
        dashboard.onClose = { [weak self] in self?.dashboard = nil }
        dashboard.onCycleLayout = { [weak self] offset in self?.layout.activateNeighbor(offset) }
        self.dashboard = dashboard
        dashboard.show(selecting: identity)
    }

    // MARK: - Debug

    private func listSpaces() {
        guard let bridge = SpacesBridge.shared else {
            print("Spaces bridge unavailable on this macOS version")
            return
        }
        let names = Dictionary(uniqueKeysWithValues: ScreenCatalog.current().map { ($0.uuid, $0.name) })
        for display in bridge.displays() {
            print("\(names[display.displayIdentifier] ?? display.displayIdentifier):")
            for (index, space) in display.desktops.enumerated() {
                print("  Desktop \(index + 1)  space \(space)\(space == display.current ? "  ← current" : "")")
            }
        }
    }
}
