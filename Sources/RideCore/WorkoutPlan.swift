import Foundation

public struct TrainerSample: Sendable {
    public var power: Int?
    public var cadence: Double?
    public var speed: Double?
    public var distance: Double?

    public init(power: Int? = nil, cadence: Double? = nil, speed: Double? = nil, distance: Double? = nil) {
        self.power = power
        self.cadence = cadence
        self.speed = speed
        self.distance = distance
    }
}

@MainActor
public protocol TrainerControl: AnyObject {
    func activate(target: Int) async throws
    func setTarget(_ watts: Int) async throws
    func stop() async throws
}

public struct PowerRange: Equatable, Sendable {
    public let min: Int
    public let max: Int
    public let increment: Int

    public init(min: Int, max: Int, increment: Int) {
        self.min = min
        self.max = max
        self.increment = increment
    }

    fileprivate var isValid: Bool {
        (Int(Int16.min)...Int(Int16.max)).contains(min) && max >= min && max <= Int(Int16.max)
            && (1...Int(UInt16.max)).contains(increment)
    }

    func nearestTarget(to watts: Double) -> Int {
        let steps = (watts - Double(min)) / Double(increment)
        let lastStep = (max - min) / increment
        return min + Swift.min(lastStep, Int(steps.rounded())) * increment
    }
}

public enum PowerZone: Int, CaseIterable, Hashable, Sendable {
    case zone1 = 1, zone2, zone3, zone4, zone5, zone6

    public var name: String { "Zone \(rawValue)" }

    static func classify(power: Int, ftp: Int?) -> Self? {
        guard let ftp, ftp > 0, power > 0 else { return nil }
        switch Double(power) / Double(ftp) {
        case ..<0.60: return .zone1
        case ..<0.76: return .zone2
        case ..<0.90: return .zone3
        case ..<1.05: return .zone4
        case ..<1.19: return .zone5
        default: return .zone6
        }
    }
}

public struct WorkoutPlan: Equatable, Sendable {
    private struct Segment: Equatable, Sendable {
        let end: Double
        let watts: Int
    }

    public let duration: Double
    public let steadyWatts: Int
    public let ftp: Int?
    private let range: PowerRange
    private let segments: [Segment]

    public init(steadyMinutes: Int, ftp: Int?, fixedWatts: Int?, range: PowerRange) throws {
        guard steadyMinutes > 0 else { throw PlanError.invalidDuration }
        guard range.isValid else { throw PlanError.invalidRange }
        guard let source = fixedWatts ?? ftp, source > 0 else { throw PlanError.invalidPower }
        let ratios = fixedWatts == nil ? [0.50, 0.55, 0.60, 0.67, 0.50] : [0.75, 0.82, 0.90, 1, 0.75]
        let requests = ratios.map { Double(source) * $0 }
        guard requests.allSatisfy({ (Double(range.min)...Double(range.max)).contains($0) }) else {
            throw PlanError.powerOutsideRange(range.min, range.max)
        }

        let targets = requests.map { range.nearestTarget(to: $0) }
        guard targets.allSatisfy({ $0 > 0 }) else { throw PlanError.invalidPower }
        let ends = [180, 360, 480, 480 + Double(steadyMinutes) * 60, 780 + Double(steadyMinutes) * 60]
        duration = ends[4]
        steadyWatts = targets[3]
        self.ftp = ftp.flatMap { $0 > 0 ? $0 : nil }
        self.range = range
        segments = zip(ends, targets).map { Segment(end: $0.0, watts: $0.1) }
    }

    func target(at elapsed: Double) -> Int {
        segments.first(where: { elapsed < $0.end })?.watts ?? segments[4].watts
    }

    func rampedTarget(at elapsed: Double, resumedAt: Double) -> Int {
        let scheduled = target(at: elapsed)
        let easy = min(scheduled, target(at: 0))
        let fraction = min(1, ((elapsed - resumedAt) / 2).rounded(.down) / 5)
        return range.nearestTarget(to: Double(easy) + Double(scheduled - easy) * max(0, fraction))
    }

    private enum PlanError: LocalizedError {
        case invalidDuration, invalidRange, invalidPower, powerOutsideRange(Int, Int)

        var errorDescription: String? {
            switch self {
            case .invalidDuration: "Enter at least one minute for the steady block."
            case .invalidRange: "The trainer reported an invalid power range."
            case .invalidPower: "Enter a positive FTP or fixed power target."
            case let .powerOutsideRange(minimum, maximum):
                "Every workout step must fit the trainer’s supported range of \(minimum)–\(maximum) W."
            }
        }
    }
}
