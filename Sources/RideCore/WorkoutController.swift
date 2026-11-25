import Combine
import Foundation

public enum RideState: Equatable, Sendable {
    case idle, starting, riding, paused, interrupted, ended
}

public struct RideMetrics: Equatable, Sendable {
    public var power: Int?
    public var cadence: Double?
    public var speed: Double?
    public var distance: Double?
    public var heartRate: Int?
    public var averagePower: Int?
    public var work: Double = 0
    public var zoneSeconds: [PowerZone: Double] = [:]

    public init() {}
}

@MainActor
public final class WorkoutController: ObservableObject {
    @Published public private(set) var state: RideState = .idle
    @Published public private(set) var plan: WorkoutPlan?
    @Published public private(set) var elapsed: Double = 0
    @Published public private(set) var summary = RideMetrics()
    @Published public private(set) var target: Int?
    @Published public private(set) var message: String?
    @Published public private(set) var currentZone: PowerZone?

    private static let trainerTimeout: Double = 5
    private static let heartRateTimeout: Double = 10
    private static let awaitingStop = "Waiting for the trainer to confirm the stop."

    private struct Reading<Value> {
        let value: Value
        let time: Double

        func fresh(at now: Double, timeout: Double) -> Value? {
            now - time < timeout ? value : nil
        }
    }

    private struct DistanceAnchor {
        let reading: Reading<Double>
        let rideDistance: Double
    }

    private let trainer: any TrainerControl
    private let now: () -> Double
    private var power: Reading<Int>?
    private var cadence: Reading<Double>?
    private var speed: Reading<Double>?
    private var heartRate: Reading<Int>?
    private var cadenceStoppedAt: Double?
    private var lastAdvance: Double?
    private var rampStartedAt: Double?
    private var distanceAnchor: DistanceAnchor?
    private var travelled: Double?
    private var wattSeconds: Double = 0
    private var powerSeconds: Double = 0
    private var zoneSeconds: [PowerZone: Double] = [:]

    // Schedule the stop behind any write already in flight. Ignore obsolete results.
    private var controlGeneration = 0
    private var commandTail: Task<Void, Never>?
    private var pendingActivation: Task<Void, Never>?
    private var pendingStop: Task<Void, Never>?
    private var settingTarget = false

    public convenience init(trainer: any TrainerControl) {
        let origin = ContinuousClock.now
        self.init(trainer: trainer) {
            let duration = origin.duration(to: .now).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
    }

    init(trainer: any TrainerControl, now: @escaping () -> Double) {
        self.trainer = trainer
        self.now = now
    }

    public func start(_ plan: WorkoutPlan) async {
        guard state == .idle || state == .ended else { return }
        guard canActivate(at: now(), requiresPedalling: false) else { return }

        self.plan = plan
        elapsed = 0
        travelled = nil
        wattSeconds = 0
        powerSeconds = 0
        zoneSeconds.removeAll()
        publish(at: now())
        await activate(plan.target(at: 0), resuming: false)
    }

    public func pause() async {
        guard state == .riding || state == .starting else { return }
        let time = now()
        advance(to: time)
        publish(at: time)
        guard state == .riding || state == .starting else { return }
        await deactivate(to: .paused).value
    }

    public func resume() async {
        guard let plan, state == .paused || state == .interrupted else { return }
        guard canActivate(at: now(), requiresPedalling: true) else { return }
        await activate(plan.rampedTarget(at: elapsed, resumedAt: elapsed), resuming: true)
    }

    public func end() async {
        guard state != .idle else { return }
        let time = now()
        advance(to: time)
        publish(at: time)
        if state == .ended {
            await pendingStop?.value
        } else if state == .riding || state == .starting {
            await deactivate(to: .ended).value
        } else {
            state = .ended
            await pendingStop?.value
        }
    }

    public func updateTrainer(_ sample: TrainerSample) {
        let time = now()
        advance(to: time)

        if let watts = sample.power, watts >= 0 { power = Reading(value: watts, time: time) }
        if let rpm = sample.cadence, rpm.isFinite, rpm >= 0 {
            cadence = Reading(value: rpm, time: time)
            cadenceStoppedAt = rpm == 0 && state == .riding ? cadenceStoppedAt ?? time : nil
        }
        if let kmh = sample.speed, kmh.isFinite, kmh >= 0 { speed = Reading(value: kmh, time: time) }
        if state == .riding, let km = sample.distance, km.isFinite, km >= 0 {
            if let anchor = distanceAnchor, time - anchor.reading.time < Self.trainerTimeout,
               km >= anchor.reading.value {
                travelled = anchor.rideDistance + km - anchor.reading.value
            }
            travelled = travelled ?? 0
            distanceAnchor = DistanceAnchor(reading: Reading(value: km, time: time), rideDistance: travelled ?? 0)
        }
        publish(at: time)
        scheduleTarget()
    }

    public func updateHeartRate(_ bpm: Int?) {
        let time = now()
        heartRate = bpm.flatMap { $0 > 0 ? Reading(value: $0, time: time) : nil }
        publish(at: time)
    }

    public func trainerDisconnected() {
        let time = now()
        advance(to: time)
        power = nil
        cadence = nil
        speed = nil
        if state == .riding || state == .starting {
            _ = deactivate(to: .interrupted, message: "Trainer disconnected. Resistance could not be confirmed.")
        }
        publish(at: time)
    }

    public func sleepImminent() {
        let time = now()
        advance(to: time)
        power = nil
        cadence = nil
        speed = nil
        heartRate = nil
        if state == .riding || state == .starting {
            _ = deactivate(to: .interrupted, message: "Workout paused because the Mac went to sleep.")
        }
        publish(at: time)
    }

    public func tick() {
        let time = now()
        advance(to: time)
        publish(at: time)
        scheduleTarget()
    }

    private func canActivate(at time: Double, requiresPedalling: Bool) -> Bool {
        guard pendingStop == nil else {
            message = Self.awaitingStop
            return false
        }
        guard power?.fresh(at: time, timeout: Self.trainerTimeout) != nil,
              let rpm = cadence?.fresh(at: time, timeout: Self.trainerTimeout) else {
            message = "Waiting for live power and cadence from the trainer."
            return false
        }
        guard !requiresPedalling || rpm > 0 else {
            message = "Start pedalling, then resume the workout."
            return false
        }
        return true
    }

    private func activate(_ watts: Int, resuming: Bool) async {
        state = .starting
        message = nil
        controlGeneration += 1
        let generation = controlGeneration
        let activation = enqueue { session in
            defer { session.pendingActivation = nil }
            guard session.controlGeneration == generation else { return }
            do {
                try await session.trainer.activate(target: watts)
                guard session.controlGeneration == generation else { return }
                let time = session.now()
                guard session.canActivate(at: time, requiresPedalling: resuming) else {
                    _ = session.deactivate(to: .interrupted, message: session.message)
                    return
                }
                session.target = watts
                session.lastAdvance = time
                session.distanceAnchor = nil
                session.rampStartedAt = resuming ? session.elapsed : nil
                session.cadenceStoppedAt = session.cadence?.value == 0 ? time : nil
                session.state = .riding
                session.publish(at: time)
            } catch {
                guard session.controlGeneration == generation else { return }
                _ = session.deactivate(to: .interrupted, message: error.localizedDescription)
            }
        }
        pendingActivation = activation
        await activation.value
    }

    private func deactivate(to next: RideState, message: String? = nil) -> Task<Void, Never> {
        controlGeneration += 1
        pendingActivation?.cancel()
        state = next
        target = nil
        lastAdvance = nil
        rampStartedAt = nil
        distanceAnchor = nil
        cadenceStoppedAt = nil
        self.message = message ?? Self.awaitingStop
        if let pendingStop { return pendingStop }

        let stop = enqueue { session in
            defer { session.pendingStop = nil }
            do {
                try await session.trainer.stop()
                if session.message == Self.awaitingStop { session.message = message }
            } catch {
                let warning = "Trainer stop could not be confirmed."
                session.message = [message, warning].compactMap { $0 }.joined(separator: " ")
            }
        }
        pendingStop = stop
        return stop
    }

    @discardableResult
    private func enqueue(_ action: @escaping @MainActor (WorkoutController) async -> Void) -> Task<Void, Never> {
        let previous = commandTail
        let task = Task { [weak self] in
            await previous?.value
            if let self { await action(self) }
        }
        commandTail = task
        return task
    }

    private func scheduleTarget() {
        guard let plan, state == .riding, !settingTarget else { return }
        let watts = rampStartedAt.map { plan.rampedTarget(at: elapsed, resumedAt: $0) } ?? plan.target(at: elapsed)
        guard watts != target else { return }

        settingTarget = true
        let generation = controlGeneration
        enqueue { session in
            defer { session.settingTarget = false }
            guard session.controlGeneration == generation else { return }
            do {
                try await session.trainer.setTarget(watts)
                guard session.controlGeneration == generation else { return }
                session.target = watts
            } catch {
                guard session.controlGeneration == generation else { return }
                let time = session.now()
                session.advance(to: time)
                session.publish(at: time)
                guard session.controlGeneration == generation else { return }
                _ = session.deactivate(to: .interrupted, message: error.localizedDescription)
            }
        }
    }

    private func advance(to time: Double) {
        guard state == .riding, let plan, let start = lastAdvance, let power, let cadence else { return }
        let connectionDeadline = min(power.time, cadence.time) + Self.trainerTimeout
        let cadenceDeadline = cadenceStoppedAt.map { $0 + Self.trainerTimeout } ?? .infinity
        let freshUntil = min(connectionDeadline, cadenceDeadline)
        let workoutEnd = start + (plan.duration - elapsed)
        let duration = min(time, freshUntil, workoutEnd) - start

        if duration > 0 {
            elapsed = min(plan.duration, elapsed + duration)
            lastAdvance = start + duration
            wattSeconds += Double(power.value) * duration
            powerSeconds += duration
            if let zone = PowerZone.classify(power: power.value, ftp: plan.ftp) {
                zoneSeconds[zone, default: 0] += duration
            }
            if let speed, let rate = speed.fresh(at: start, timeout: Self.trainerTimeout) {
                let validSeconds = min(duration, speed.time + Self.trainerTimeout - start)
                travelled = (travelled ?? 0) + rate * validSeconds / 3_600
            }
        }

        if time >= workoutEnd, workoutEnd <= freshUntil {
            elapsed = plan.duration
            _ = deactivate(to: .ended)
        } else if time >= freshUntil {
            let reason = cadenceDeadline < connectionDeadline ? "Pedalling stopped."
                : "Trainer power or cadence is no longer updating."
            _ = deactivate(to: .interrupted, message: reason)
        }
    }

    private func publish(at time: Double) {
        var metrics = RideMetrics()
        metrics.power = power?.fresh(at: time, timeout: Self.trainerTimeout)
        metrics.cadence = cadence?.fresh(at: time, timeout: Self.trainerTimeout)
        metrics.speed = speed?.fresh(at: time, timeout: Self.trainerTimeout)
        metrics.heartRate = heartRate?.fresh(at: time, timeout: Self.heartRateTimeout)
        metrics.distance = travelled
        metrics.averagePower = powerSeconds > 0 ? Int((wattSeconds / powerSeconds).rounded()) : nil
        metrics.work = wattSeconds / 1_000
        metrics.zoneSeconds = zoneSeconds
        if metrics != summary { summary = metrics }
        let zone = metrics.power.flatMap { PowerZone.classify(power: $0, ftp: plan?.ftp) }
        if zone != currentZone { currentZone = zone }
    }
}
