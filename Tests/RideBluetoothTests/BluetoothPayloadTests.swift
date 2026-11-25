import Foundation
import Testing
@testable import RideBluetooth

@Test func indoorBikePacketReadsPackedFieldsWithTheirCorrectUnits() throws {
    let packet = Data([
        0xFE, 0x1F,        // All optional fields; includes instantaneous speed.
        0xD2, 0x04,        // 12.34 km/h
        0, 0,              // Average speed
        0xAF, 0,           // 87.5 rpm
        0, 0,              // Average cadence
        0xE8, 0x03, 0,     // 1 km
        0, 0,              // Resistance
        0xD4, 0xFE,        // -300 W
        0, 0,              // Average power
        0, 0, 0, 0, 0,     // Energy
        0, 0,              // Heart rate and metabolic equivalent
        0, 0, 0, 0,        // Elapsed and remaining time
    ])
    let sample = try #require(BluetoothPayload.bikeData(packet))
    #expect(sample.speed == 12.34)
    #expect(sample.cadence == 87.5)
    #expect(sample.distance == 1)
    #expect(sample.power == -300)
    #expect(BluetoothPayload.bikeData(Data(packet.dropLast())) == nil)
}

@Test func continuationBikePacketMayOmitSpeedWithoutShiftingPower() throws {
    let sample = try #require(BluetoothPayload.bikeData(Data([0x41, 0, 0x96, 0])))
    #expect(sample.speed == nil)
    #expect(sample.cadence == nil)
    #expect(sample.power == 150)
    #expect(BluetoothPayload.bikeData(Data([0x40, 0, 0x96, 0])) == nil)
}

@Test func heartRateHandlesBothWidthsAndSensorContact() {
    #expect(BluetoothPayload.heartRate(Data([0, 145])) == 145)
    #expect(BluetoothPayload.heartRate(Data([1, 0x2C, 1])) == 300)
    #expect(BluetoothPayload.heartRate(Data([0b110, 145])) == 145)
    #expect(BluetoothPayload.heartRate(Data([0b100, 145])) == nil)
    #expect(BluetoothPayload.heartRate(Data([1, 145])) == nil)
    #expect(BluetoothPayload.heartRate(Data([0, 0])) == nil)
    #expect(BluetoothPayload.heartRate(Data([0x18, 145, 0, 0, 0, 0])) == 145)
    #expect(BluetoothPayload.heartRate(Data([0x18, 145, 0, 0, 0])) == nil)
}

@Test func validErgRequiresTargetPowerFeatureAndAnAdvertisedRange() throws {
    #expect(BluetoothPayload.supportsTargetPower(Data([0, 0, 0, 0, 0x08, 0, 0, 0])) == true)
    #expect(BluetoothPayload.supportsTargetPower(Data([8, 0, 0, 0, 0, 0, 0, 0])) == false)
    #expect(BluetoothPayload.supportsTargetPower(Data([0, 0, 0, 0, 8])) == nil)
    let range = try #require(BluetoothPayload.powerRange(Data([0xF6, 0xFF, 0x08, 0x07, 5, 0])))
    #expect(range.min == -10)
    #expect(range.max == 1800)
    #expect(range.increment == 5)
    #expect(BluetoothPayload.powerRange(Data([0, 0, 1, 0, 0, 0])) == nil)
    #expect(BluetoothPayload.powerRange(Data([2, 0, 1, 0, 1, 0])) == nil)
}

@Test func targetPowerAndControlPointResultHaveTheExpectedEncoding() throws {
    #expect(BluetoothPayload.powerCommand(300) == Data([0x05, 0x2C, 0x01]))
    #expect(BluetoothPayload.powerCommand(-300) == Data([0x05, 0xD4, 0xFE]))
    #expect(BluetoothPayload.powerCommand(Int.max) == nil)
    let result = try #require(BluetoothPayload.response(Data([0x80, 0x05, 0x01])))
    #expect(result.opcode == 0x05)
    #expect(result.result == 0x01)
    #expect(BluetoothPayload.response(Data([0x05, 0x01, 0x01])) == nil)
    #expect(BluetoothPayload.response(Data([0x80, 0x05])) == nil)
}

@MainActor
@Test func demoDoesNotInitialiseBluetoothOrClaimAReadyTrainer() {
    let devices = BluetoothDevices(automaticallyConnect: false)
    #expect(devices.bluetoothStatus == "Ready to scan")
    #expect(devices.powerRange == nil)
    #expect(!devices.scanning)
    #expect(devices.candidates.isEmpty)
}
