import Testing
@testable import RideCore

struct WorkoutTests {
    @Test func defaultStepBoundariesAndQuantisedTargets() throws {
        let plan = try WorkoutPlan(steadyMinutes: 47, ftp: 200, fixedWatts: nil, range: .init(min: 0, max: 800, increment: 1))
        #expect(plan.duration == 3_600)
        #expect(plan.steadyWatts == 134)
        let targets = [0, 179, 180, 360, 480, 3_299, 3_300].map { plan.target(at: Double($0)) }
        #expect(targets == [100, 100, 110, 120, 134, 134, 100])

        let fixed = try WorkoutPlan(steadyMinutes: 60, ftp: 220, fixedWatts: 151, range: .init(min: 10, max: 800, increment: 5))
        #expect(fixed.duration == 4_380)
        #expect(fixed.steadyWatts == 150)
        #expect(fixed.target(at: 0) == 115)
        #expect(fixed.ftp == 220)
        #expect(throws: (any Error).self) {
            try WorkoutPlan(steadyMinutes: 1, ftp: nil, fixedWatts: 150, range: .init(min: 125, max: 800, increment: 1))
        }
    }

    @Test @MainActor func unequalZoneDurationsAndActiveRideTotals() async throws {
        let clock = TestClock()
        let trainer = TestTrainer()
        let ride = WorkoutController(trainer: trainer, now: { clock.time })
        ride.updateTrainer(.init(power: 80, cadence: 75, speed: 36))
        try await ride.start(zone2Plan())
        for second in 1...18 {
            clock.time = Double(second)
            ride.updateTrainer(.init(power: 135, cadence: 75, speed: 36))
            if second == 1 { ride.updateTrainer(.init(power: 80)) }
        }
        #expect(ride.summary.zoneSeconds == [.zone1: 2, .zone2: 16])
        #expect(abs(ride.summary.work - 2.32) < 0.0001)
        #expect(abs((ride.summary.distance ?? -1) - 0.18) < 0.0001)
        #expect(ride.summary.averagePower == 129)

        await ride.pause()
        clock.time = 21
        ride.updateTrainer(.init(power: 80, cadence: 90))
        #expect(ride.summary.zoneSeconds == [.zone1: 2, .zone2: 16])
        #expect(ride.elapsed == 18)
    }

    @Test @MainActor func singleZoneStaysBlueAndIdlePowerDoesNotAddGrey() async throws {
        let clock = TestClock()
        let ride = WorkoutController(trainer: TestTrainer(), now: { clock.time })
        ride.updateTrainer(.init(power: 0, cadence: 75))
        #expect(ride.summary.zoneSeconds.isEmpty)
        try await ride.start(zone2Plan())
        clock.time = 1
        ride.updateTrainer(.init(power: 120, cadence: 75))
        clock.time = 3
        ride.tick()
        #expect(ride.summary.zoneSeconds == [.zone2: 2])
        #expect(ride.summary.averagePower == 80)
        #expect(PowerZone.classify(power: 1, ftp: 200) == .zone1)
        #expect(PowerZone.classify(power: 0, ftp: 200) == nil)
        #expect(PowerZone.classify(power: 120, ftp: nil) == nil)
    }

    @Test @MainActor func heartRateTimeoutAndTrainerTimeoutAreIndependent() async throws {
        let clock = TestClock()
        let trainer = TestTrainer()
        let ride = WorkoutController(trainer: trainer, now: { clock.time })
        let sample = TrainerSample(power: 130, cadence: 80)
        ride.updateTrainer(sample)
        ride.updateHeartRate(140)
        try await ride.start(zone2Plan())
        for time in stride(from: 2.0, through: 10, by: 2) {
            clock.time = time
            ride.updateTrainer(sample)
        }
        #expect(ride.summary.heartRate == nil)
        #expect(ride.state == .riding)

        clock.time = 16
        ride.updateTrainer(sample)
        #expect(ride.state == .interrupted)
        #expect(ride.elapsed == 15)
        #expect(ride.summary.zoneSeconds == [.zone2: 15])
        await ride.end()
        #expect(trainer.operations == [.activate(100), .stop])
    }

    @Test @MainActor func resumeRequiresNewPedallingAndRestartsAtWarmupPower() async throws {
        let clock = TestClock()
        let trainer = TestTrainer()
        let ride = WorkoutController(trainer: trainer, now: { clock.time })
        let sample = TrainerSample(power: 130, cadence: 80)
        ride.updateTrainer(sample)
        try await ride.start(zone2Plan())
        for time in stride(from: 4.0, through: 484, by: 4) {
            clock.time = time
            ride.updateTrainer(sample)
            await Task.yield()
        }
        await ride.pause()
        ride.updateTrainer(.init(power: 0, cadence: 0))
        await ride.resume()
        #expect(ride.state == .paused)
        ride.updateTrainer(sample)
        await ride.resume()
        #expect(ride.state == .riding)
        #expect(ride.elapsed == 484)
        #expect(ride.target == 100)
        #expect(trainer.operations.last == .activate(100))
    }

    @Test @MainActor func pauseWhileActivationIsInFlightStopsAfterTheCommand() async throws {
        let trainer = TestTrainer()
        trainer.holdActivation = true
        let ride = WorkoutController(trainer: trainer, now: { 0 })
        let plan = try zone2Plan()
        ride.updateTrainer(.init(power: 130, cadence: 80))
        let start = Task { await ride.start(plan) }
        await trainer.waitForActivation()

        let pause = Task { await ride.pause() }
        for _ in 0..<100 where ride.state != .paused { await Task.yield() }
        #expect(ride.state == .paused)
        #expect(ride.message == "Waiting for the trainer to confirm the stop.")
        #expect(trainer.operations == [.activate(100)])

        trainer.waiting?.resume()
        await start.value
        await pause.value
        #expect(trainer.operations == [.activate(100), .stop])
        #expect(ride.state == .paused)
        #expect(ride.target == nil)
        #expect(ride.message == nil)
    }

    private func zone2Plan() throws -> WorkoutPlan {
        try WorkoutPlan(steadyMinutes: 47, ftp: 200, fixedWatts: nil, range: .init(min: 0, max: 800, increment: 1))
    }
}

@MainActor
private final class TestClock {
    var time: Double = 0
}

@MainActor
private final class TestTrainer: TrainerControl {
    enum Operation: Equatable {
        case activate(Int), target(Int), stop
    }

    var operations: [Operation] = []
    var holdActivation = false
    var waiting: CheckedContinuation<Void, Never>?
    private var activationObserver: CheckedContinuation<Void, Never>?

    func activate(target: Int) async throws {
        operations.append(.activate(target))
        if holdActivation {
            await withCheckedContinuation {
                waiting = $0
                activationObserver?.resume()
                activationObserver = nil
            }
        }
        try Task.checkCancellation()
    }

    func waitForActivation() async {
        if waiting == nil { await withCheckedContinuation { activationObserver = $0 } }
    }

    func setTarget(_ watts: Int) async throws { operations.append(.target(watts)) }

    func stop() async throws { operations.append(.stop) }
}
