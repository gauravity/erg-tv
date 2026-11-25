import AppKit
import Combine
import RideBluetooth
import RideCore
import SwiftUI

@MainActor
@main
struct RideScreenApp: App {
    @NSApplicationDelegateAdaptor(RideAppDelegate.self) private var delegate
    @StateObject private var model = RideAppModel(demo: CommandLine.arguments.contains("--demo"))

    init() { RideTypography.register() }

    var body: some Scene {
        Window("Ride Screen", id: "ride") {
            RideWindow(model: model)
                .frame(minWidth: 740, minHeight: 440)
                .onAppear {
                    delegate.model = model
                    model.playback.restoreOnLaunch()
                }
        }
        .defaultSize(width: 1120, height: 680)
        .commands {
            CommandMenu("Ride") {
                Button("Workout setup") { model.show(.workout) }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                Button("Devices") { model.show(.devices) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("Pause or resume ride") { model.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("End ride…") { model.show(.end) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class RideAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RideAppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.hasSession else { return .terminateNow }
        Task {
            await model.workout.end()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum RideSheet: String, Identifiable {
    case workout, devices, video, end
    var id: Self { self }
}

@MainActor
final class RideAppModel: ObservableObject {
    let demo: Bool
    let devices: BluetoothDevices
    let workout: WorkoutController
    let playback: Playback
    let defaults: UserDefaults
    private let demoTrainer: DemoTrainer?
    private lazy var overlay = SafariHUD(model: self)
    private var observations: Set<AnyCancellable> = []
    private var awake: NSObjectProtocol?
    weak var window: NSWindow? {
        didSet { overlay.update() }
    }

    @Published var sheet: RideSheet?

    init(demo: Bool) {
        self.demo = demo
        defaults = demo ? (UserDefaults(suiteName: "com.local.ridescreen.demo") ?? .standard) : .standard
        let devices = BluetoothDevices(automaticallyConnect: !demo)
        let simulation = demo ? DemoTrainer() : nil
        self.devices = devices
        demoTrainer = simulation
        workout = WorkoutController(trainer: simulation.map { $0 as any TrainerControl } ?? devices)
        playback = Playback(preferences: defaults, demo: demo)

        devices.onTrainerSample = { [weak workout] in workout?.updateTrainer($0) }
        devices.onHeartRate = { [weak workout] in workout?.updateHeartRate($0) }
        devices.onTrainerDisconnect = { [weak workout] in workout?.trainerDisconnected() }

        Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }
            .store(in: &observations)
        workout.$state.removeDuplicates()
            .sink { [weak self] state in self?.keepAwake(state == .riding) }
            .store(in: &observations)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification).receive(on: RunLoop.main)
            .sink { [weak workout] _ in workout?.sleepImminent() }
            .store(in: &observations)
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.overlay.update() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.overlay.update() }
            .store(in: &observations)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] event in
                guard let self, (event.object as? NSWindow) === self.window else { return }
                self.overlay.close()
                if self.hasSession { Task { await self.workout.end() } }
            }
            .store(in: &observations)
        Publishers.CombineLatest(playback.$route, playback.$issue)
            .sink { [weak self] _, _ in
                DispatchQueue.main.async { [weak self] in self?.overlay.update() }
            }
            .store(in: &observations)
    }

    var hasSession: Bool { workout.state != .idle && workout.state != .ended }
    var range: PowerRange? { demo ? PowerRange(min: 25, max: 1_800, increment: 1) : devices.powerRange }

    func show(_ sheet: RideSheet) {
        if sheet == .end && !hasSession { return }
        self.sheet = sheet
        showWindow()
    }

    func openVideo(_ service: VideoService, route: PlaybackRoute? = nil) {
        playback.open(service, route: route)
        if playback.route == .inApp { showWindow() }
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func showSafari() {
        guard !demo else { return }
        if let safari = NSRunningApplication.runningApplications(withBundleIdentifier: Playback.safariIdentifier).first {
            safari.activate()
        } else if let provider = playback.service {
            playback.open(provider, route: .safari)
        }
    }

    func start(_ plan: WorkoutPlan, minutes: Int, fixed: Int?) {
        guard !hasSession else { return }
        defaults.set(minutes, forKey: "workout.minutes")
        defaults.set(plan.ftp, forKey: "workout.ftp")
        defaults.set(fixed, forKey: "workout.fixed")
        sheet = nil
        Task { await workout.start(plan) }
    }

    func togglePause() {
        Task {
            switch workout.state {
            case .riding: await workout.pause()
            case .paused, .interrupted: await workout.resume()
            case .idle, .starting, .ended: break
            }
        }
    }

    private func tick() {
        if let demoTrainer {
            workout.updateTrainer(TrainerSample(power: demoTrainer.watts, cadence: 88, speed: 24.5))
            workout.updateHeartRate(132)
        }
        workout.tick()
    }

    private func keepAwake(_ active: Bool) {
        if active && awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled], reason: "Indoor cycling workout"
            )
        } else if !active, let awake {
            ProcessInfo.processInfo.endActivity(awake)
            self.awake = nil
        }
    }
}

@MainActor
final class DemoTrainer: TrainerControl {
    private(set) var watts = 110
    func activate(target: Int) async throws { watts = target }
    func setTarget(_ watts: Int) async throws { self.watts = watts }
    func stop() async throws { watts = 0 }
}

struct WindowAnchor: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow) -> Void

    final class View: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: View, context: Context) { view.onWindow = onWindow }
}
