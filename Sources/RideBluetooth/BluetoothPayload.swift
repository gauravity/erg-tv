import Foundation
import RideCore

enum ControlOpcode: UInt8 {
    case requestControl = 0x00
    case setTargetPower = 0x05
    case startOrResume = 0x07
    case stopOrPause = 0x08
    case response = 0x80
}

enum BluetoothPayload {
    static func bikeData(_ data: Data) -> TrainerSample? {
        var reader = PacketReader(data)
        guard let flags = reader.read(2) else { return nil }

        // Bit zero means More Data, so only the primary packet includes speed.
        let speed = flags & 1 == 0 ? reader.read(2).map { Double($0) / 100 } : nil
        reader.skip(2, when: flags & (1 << 1) != 0) // Average speed
        let cadence = flags & (1 << 2) != 0 ? reader.read(2).map { Double($0) / 2 } : nil
        reader.skip(2, when: flags & (1 << 3) != 0) // Average cadence
        let distance = flags & (1 << 4) != 0 ? reader.read(3).map { Double($0) / 1_000 } : nil
        reader.skip(2, when: flags & (1 << 5) != 0) // Resistance level
        let power = flags & (1 << 6) != 0 ? reader.readSigned16() : nil
        reader.skip(2, when: flags & (1 << 7) != 0) // Average power
        reader.skip(5, when: flags & (1 << 8) != 0) // Expended energy
        reader.skip(1, when: flags & (1 << 9) != 0) // Heart rate
        reader.skip(1, when: flags & (1 << 10) != 0) // Metabolic equivalent
        reader.skip(2, when: flags & (1 << 11) != 0) // Elapsed time
        reader.skip(2, when: flags & (1 << 12) != 0) // Remaining time
        guard reader.isValid else { return nil }
        return TrainerSample(power: power, cadence: cadence, speed: speed, distance: distance)
    }

    static func heartRate(_ data: Data) -> Int? {
        var reader = PacketReader(data)
        guard let flags = reader.read(1),
              let rate = reader.read(flags & 1 == 0 ? 1 : 2),
              rate > 0 else { return nil }
        let supportsContact = flags & (1 << 2) != 0
        let hasContact = flags & (1 << 1) != 0
        guard !supportsContact || hasContact else { return nil }

        reader.skip(2, when: flags & (1 << 3) != 0)
        if flags & (1 << 4) != 0 {
            guard reader.remaining >= 2, reader.remaining.isMultiple(of: 2) else { return nil }
        }
        return reader.isValid ? rate : nil
    }

    static func supportsTargetPower(_ data: Data) -> Bool? {
        var reader = PacketReader(data)
        guard reader.read(4) != nil, let targetFeatures = reader.read(4) else { return nil }
        return targetFeatures & (1 << 3) != 0
    }

    static func powerRange(_ data: Data) -> PowerRange? {
        var reader = PacketReader(data)
        guard let minimum = reader.readSigned16(),
              let maximum = reader.readSigned16(),
              let increment = reader.read(2),
              minimum <= maximum, increment > 0 else { return nil }
        return PowerRange(min: minimum, max: maximum, increment: increment)
    }

    static func powerCommand(_ watts: Int) -> Data? {
        guard let signed = Int16(exactly: watts) else { return nil }
        let encoded = UInt16(bitPattern: signed)
        return Data([ControlOpcode.setTargetPower.rawValue, UInt8(truncatingIfNeeded: encoded), UInt8(encoded >> 8)])
    }

    static func response(_ data: Data) -> (opcode: UInt8, result: UInt8)? {
        var reader = PacketReader(data)
        guard reader.read(1) == Int(ControlOpcode.response.rawValue),
              let opcode = reader.read(1), let result = reader.read(1) else { return nil }
        return (UInt8(opcode), UInt8(result))
    }
}

private struct PacketReader {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    var isValid: Bool { index <= bytes.count }
    var remaining: Int { max(0, bytes.count - index) }

    mutating func read(_ count: Int) -> Int? {
        guard count <= remaining else {
            index = bytes.count + 1
            return nil
        }
        let value = (0..<count).reduce(0) { result, offset in
            result | (Int(bytes[index + offset]) << (8 * offset))
        }
        index += count
        return value
    }

    mutating func readSigned16() -> Int? {
        read(2).map { Int(Int16(bitPattern: UInt16($0))) }
    }

    mutating func skip(_ count: Int, when present: Bool) {
        if present {
            index = count <= remaining ? index + count : bytes.count + 1
        }
    }
}
