import Combine
@preconcurrency import CoreBluetooth
import Foundation
import RideCore

public enum DeviceRole: Hashable, Sendable {
    case trainer, heartRate

    fileprivate var preference: String {
        self == .trainer ? "bluetooth.trainer" : "bluetooth.heartRate"
    }

    fileprivate var fallbackName: String {
        self == .trainer ? "Trainer" : "Heart-rate sensor"
    }

    fileprivate var service: CBUUID {
        self == .trainer ? GATT.fitnessMachine : GATT.heartRate
    }
}

public struct DeviceCandidate: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let role: DeviceRole
}

@MainActor
public final class BluetoothDevices: NSObject, ObservableObject, TrainerControl {
    @Published public private(set) var bluetoothStatus = "Ready to scan"
    @Published public private(set) var scanning = false
    @Published public private(set) var candidates: [DeviceCandidate] = []
    @Published public private(set) var trainerName: String?
    @Published public private(set) var heartRateName: String?
    @Published public private(set) var trainerStatus = "Not connected"
    @Published public private(set) var heartRateStatus = "Not connected"
    @Published public private(set) var powerRange: PowerRange?

    public var onTrainerSample: ((TrainerSample) -> Void)?
    public var onHeartRate: ((Int?) -> Void)?
    public var onTrainerDisconnect: (() -> Void)?

    private let automaticallyConnect: Bool
    private let preferences = UserDefaults.standard
    private var manager: CBCentralManager?
    private var found: [UUID: CBPeripheral] = [:]
    private var selected: [DeviceRole: CBPeripheral] = [:]
    private var shouldScan = false
    private var scanTimeout: Task<Void, Never>?

    private var controlPoint: CBCharacteristic?
    private var controlSubscribed = false
    private var indoorDataSubscribed = false
    private var supportsPower = false
    private var advertisedRange: PowerRange?
    private var trainerSetupFailed = false
    private var controlHeld = false
    private var loadMayBeActive = false
    private var operationInFlight = false
    private var pending: Command?
    private var commandTimeout: Task<Void, Never>?

    public init(automaticallyConnect: Bool = true) {
        self.automaticallyConnect = automaticallyConnect
        super.init()
        if automaticallyConnect && [DeviceRole.trainer, .heartRate].contains(where: { savedID(for: $0) != nil }) {
            startManager()
        }
    }

    public func scan() {
        shouldScan = true
        startManager()
        beginScan()
    }

    public func stopScanning() {
        shouldScan = false
        manager?.stopScan()
        scanTimeout?.cancel()
        scanTimeout = nil
        scanning = false
    }

    public func connect(_ candidate: DeviceCandidate) {
        guard let manager, manager.state == .poweredOn,
              candidates.contains(candidate), let peripheral = found[candidate.id] else { return }
        choose(peripheral, name: candidate.name, role: candidate.role)
    }

    public func forget(_ role: DeviceRole) {
        guard canChangeSelection(role) else { return }
        preferences.removeObject(forKey: role.preference)
        if let peripheral = selected.removeValue(forKey: role) {
            manager?.cancelPeripheralConnection(peripheral)
        }
        switch role {
        case .trainer:
            resetTrainer(reason: .trainerUnavailable)
            loadMayBeActive = false
            trainerName = nil
            trainerStatus = "Not connected"
        case .heartRate:
            heartRateName = nil
            heartRateStatus = "Not connected"
            onHeartRate?(nil)
        }
    }

    public func activate(target: Int) async throws {
        try Task.checkCancellation()
        let power = try targetCommand(target)
        try beginOperation()
        defer { operationInFlight = false }
        if !controlHeld {
            try await send(Data([ControlOpcode.requestControl.rawValue]))
        }

        // Apply the new target before starting so the trainer cannot resume at an old target.
        try Task.checkCancellation()
        guard controlHeld else { throw ConnectionIssue.noControl }
        loadMayBeActive = true
        try await send(power)
        try Task.checkCancellation()
        try await send(Data([ControlOpcode.startOrResume.rawValue]))
    }

    public func setTarget(_ watts: Int) async throws {
        try Task.checkCancellation()
        let command = try targetCommand(watts)
        try beginOperation()
        defer { operationInFlight = false }
        guard controlHeld, loadMayBeActive else { throw ConnectionIssue.noControl }
        try await send(command)
    }

    public func stop() async throws {
        try beginOperation()
        defer { operationInFlight = false }
        guard loadMayBeActive else { return }
        guard controlHeld, powerRange != nil else { throw ConnectionIssue.stopUnconfirmed }
        do {
            try await send(Data([ControlOpcode.stopOrPause.rawValue, 0x01])) // Stop parameter.
        } catch {
            throw ConnectionIssue.stopUnconfirmed
        }
    }

    private func startManager() {
        guard manager == nil else { return }
        bluetoothStatus = "Checking Bluetooth…"
        manager = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    private func beginScan() {
        guard shouldScan, !scanning, let manager, manager.state == .poweredOn else { return }
        candidates = []
        found = [:]
        scanning = true
        // Some KICKR firmware exposes FTMS after connecting without advertising its service UUID.
        manager.scanForPeripherals(withServices: nil, options: nil)
        scanTimeout = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(12))
                self?.stopScanning()
            } catch {}
        }
    }

    private func savedID(for role: DeviceRole) -> UUID? {
        preferences.string(forKey: role.preference).flatMap(UUID.init(uuidString:))
    }

    private func restoreSelections() {
        guard automaticallyConnect, let manager else { return }
        for role in [DeviceRole.trainer, .heartRate] {
            if let peripheral = selected[role] {
                connectPeripheral(peripheral, role: role)
            } else if let id = savedID(for: role),
                      let peripheral = manager.retrievePeripherals(withIdentifiers: [id]).first {
                choose(peripheral, name: peripheral.name ?? role.fallbackName, role: role)
            } else if savedID(for: role) != nil {
                shouldScan = true
            }
        }
    }

    private func canChangeSelection(_ role: DeviceRole) -> Bool {
        if role == .trainer, operationInFlight ||
            (loadMayBeActive && selected[.trainer]?.state == .connected) {
            trainerStatus = "End the ride before changing trainer"
            return false
        }
        return true
    }

    private func choose(_ peripheral: CBPeripheral, name: String, role: DeviceRole) {
        if selected[role] === peripheral {
            connectPeripheral(peripheral, role: role)
            return
        }
        guard canChangeSelection(role) else { return }
        if let previous = selected.updateValue(peripheral, forKey: role) {
            manager?.cancelPeripheralConnection(previous)
        }
        preferences.set(peripheral.identifier.uuidString, forKey: role.preference)
        if role == .trainer {
            resetTrainer(reason: .trainerUnavailable)
            loadMayBeActive = false
            trainerName = name
        } else {
            heartRateName = name
            onHeartRate?(nil)
        }
        connectPeripheral(peripheral, role: role)
    }

    private func connectPeripheral(_ peripheral: CBPeripheral, role: DeviceRole) {
        guard let manager, manager.state == .poweredOn else { return }
        peripheral.delegate = self
        switch peripheral.state {
        case .connected:
            // Restored system connections may be connected before this app has discovered services.
            if role == .trainer, powerRange != nil { return }
            if role == .heartRate, heartRateStatus == "Connected" { return }
            configure(peripheral, role: role)
        case .disconnected:
            updateStatus("Connecting…", for: role)
            manager.connect(peripheral, options: nil)
        default:
            break
        }
    }

    private func configure(_ peripheral: CBPeripheral, role: DeviceRole) {
        if role == .trainer, trainerSetupFailed {
            resetTrainer(reason: .trainerUnavailable)
        }
        updateStatus("Setting up…", for: role)
        peripheral.discoverServices([role.service])
    }

    private func role(of peripheral: CBPeripheral) -> DeviceRole? {
        selected.first(where: { $0.value === peripheral })?.key
    }

    private func updateStatus(_ status: String, for role: DeviceRole) {
        if role == .trainer { trainerStatus = status } else { heartRateStatus = status }
    }

    private func resetTrainer(reason: ConnectionIssue) {
        let wasReady = powerRange != nil || controlHeld || pending != nil
        powerRange = nil
        advertisedRange = nil
        supportsPower = false
        trainerSetupFailed = false
        indoorDataSubscribed = false
        controlSubscribed = false
        controlPoint = nil
        controlHeld = false
        finishCommand(.failure(reason))
        if wasReady { onTrainerDisconnect?() }
    }

    private func updateReadiness() {
        guard !trainerSetupFailed, supportsPower, indoorDataSubscribed, controlSubscribed,
              let advertisedRange else { return }
        powerRange = advertisedRange
        trainerStatus = "Ready"
    }

    private func failSetup(_ reason: String, role: DeviceRole) {
        if role == .trainer {
            if controlHeld || pending != nil {
                abortLink(reason: .trainerUnavailable)
                return
            }
            resetTrainer(reason: .trainerUnavailable)
            trainerSetupFailed = true
        } else {
            onHeartRate?(nil)
        }
        updateStatus(reason, for: role)
    }

    private func beginOperation() throws {
        guard !operationInFlight else { throw ConnectionIssue.commandInProgress }
        operationInFlight = true
    }

    private func targetCommand(_ watts: Int) throws -> Data {
        guard let powerRange else { throw ConnectionIssue.trainerUnavailable }
        guard (powerRange.min...powerRange.max).contains(watts),
              (watts - powerRange.min).isMultiple(of: powerRange.increment),
              let command = BluetoothPayload.powerCommand(watts) else { throw ConnectionIssue.invalidTarget }
        return command
    }

    private func send(_ data: Data) async throws {
        guard let opcode = data.first, let peripheral = selected[.trainer], peripheral.state == .connected,
              let controlPoint, controlSubscribed, powerRange != nil else {
            throw ConnectionIssue.trainerUnavailable
        }
        guard opcode == ControlOpcode.requestControl.rawValue || controlHeld else { throw ConnectionIssue.noControl }
        guard pending == nil else { throw ConnectionIssue.commandInProgress }
        try await withCheckedThrowingContinuation { continuation in
            let command = Command(opcode: opcode, continuation: continuation)
            pending = command
            commandTimeout = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(5))
                    guard let self, self.pending?.id == command.id else { return }
                    self.abortLink(reason: .commandTimedOut)
                } catch {}
            }
            peripheral.writeValue(data, for: controlPoint, type: .withResponse)
        }
    }

    private func abortLink(reason: ConnectionIssue) {
        // A late indication for a timed-out procedure must not be matched to a new command.
        trainerStatus = reason.localizedDescription
        resetTrainer(reason: reason)
        if let peripheral = selected[.trainer] { manager?.cancelPeripheralConnection(peripheral) }
    }

    private func completeCommandIfReady() {
        guard let pending, pending.writeAcknowledged, let result = pending.result else { return }
        if result == 0x05 { controlHeld = false }
        if result == 0x01 {
            if pending.opcode == ControlOpcode.requestControl.rawValue { controlHeld = true }
            if pending.opcode == ControlOpcode.stopOrPause.rawValue { loadMayBeActive = false }
        }
        finishCommand(result == 0x01 ? .success(()) : .failure(ConnectionIssue.rejected(result)))
    }

    private func finishCommand(_ result: Result<Void, Error>) {
        commandTimeout?.cancel()
        commandTimeout = nil
        guard let continuation = pending?.continuation else { return }
        pending = nil
        continuation.resume(with: result)
    }
}

// Core Bluetooth delivers all central and peripheral callbacks on the configured main queue.
extension BluetoothDevices: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothStatus = "Bluetooth on"
            restoreSelections()
            beginScan()
            return
        case .poweredOff:
            bluetoothStatus = "Bluetooth is off"
        case .unauthorized:
            bluetoothStatus = "Allow Bluetooth in System Settings"
        case .unsupported:
            bluetoothStatus = "Bluetooth unavailable"
        case .resetting:
            bluetoothStatus = "Bluetooth restarting…"
        default:
            bluetoothStatus = "Checking Bluetooth…"
        }
        if [.poweredOff, .unauthorized, .unsupported].contains(central.state) { stopScanning() }
        resetTrainer(reason: .trainerUnavailable)
        if selected[.trainer] != nil { trainerStatus = "Disconnected" }
        if selected[.heartRate] != nil { heartRateStatus = "Disconnected" }
        onHeartRate?(nil)
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let advertised = Set((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []) +
            (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []))
        let role: DeviceRole
        if advertised.contains(GATT.fitnessMachine) || name?.localizedCaseInsensitiveContains("KICKR CORE") == true ||
            savedID(for: .trainer) == peripheral.identifier {
            role = .trainer
        } else if advertised.contains(GATT.heartRate) || savedID(for: .heartRate) == peripheral.identifier {
            role = .heartRate
        } else { return }
        let candidate = DeviceCandidate(id: peripheral.identifier, name: name ?? role.fallbackName, role: role)
        found[candidate.id] = peripheral
        if !candidates.contains(where: { $0.id == candidate.id }) { candidates.append(candidate) }
        if automaticallyConnect, selected[role] == nil, savedID(for: role) == candidate.id {
            choose(peripheral, name: candidate.name, role: role)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let role = role(of: peripheral) else { return }
        configure(peripheral, role: role)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        guard let role = role(of: peripheral) else { return }
        updateStatus("Couldn’t connect. Scan to retry.", for: role)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard let role = role(of: peripheral) else { return }
        if role == .trainer {
            resetTrainer(reason: .trainerUnavailable)
        } else {
            onHeartRate?(nil)
        }
        updateStatus("Disconnected", for: role)
        if automaticallyConnect { connectPeripheral(peripheral, role: role) }
    }
}

extension BluetoothDevices: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let role = role(of: peripheral) else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == role.service }) else {
            failSetup(role == .trainer ? "FTMS unavailable. Check trainer firmware." : "Heart-rate service unavailable",
                      role: role)
            return
        }
        let uuids = role == .trainer
            ? [GATT.machineFeatures, GATT.indoorBikeData, GATT.supportedPowerRange, GATT.controlPoint, GATT.machineStatus]
            : [GATT.heartRateMeasurement]
        peripheral.discoverCharacteristics(uuids, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard let role = role(of: peripheral), service.uuid == role.service else { return }
        guard error == nil, let characteristics = service.characteristics else {
            failSetup("Couldn’t read device capabilities", role: role)
            return
        }
        if role == .heartRate {
            guard let measurement = characteristics.first(where: {
                $0.uuid == GATT.heartRateMeasurement && $0.properties.contains(.notify)
            }) else {
                failSetup("Heart-rate readings unavailable", role: role)
                return
            }
            peripheral.setNotifyValue(true, for: measurement)
            return
        }
        guard let feature = characteristics.first(where: { $0.uuid == GATT.machineFeatures && $0.properties.contains(.read) }),
              let range = characteristics.first(where: { $0.uuid == GATT.supportedPowerRange && $0.properties.contains(.read) }),
              let bike = characteristics.first(where: { $0.uuid == GATT.indoorBikeData && $0.properties.contains(.notify) }),
              let control = characteristics.first(where: { $0.uuid == GATT.controlPoint && $0.properties.contains([.indicate, .write]) })
        else {
            failSetup("Trainer lacks FTMS power control or live ride data", role: role)
            return
        }
        controlPoint = control
        peripheral.readValue(for: feature)
        peripheral.readValue(for: range)
        peripheral.setNotifyValue(true, for: bike)
        peripheral.setNotifyValue(true, for: control)
        if let status = characteristics.first(where: { $0.uuid == GATT.machineStatus && $0.properties.contains(.notify) }) {
            peripheral.setNotifyValue(true, for: status)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let role = role(of: peripheral), characteristic.uuid != GATT.machineStatus else { return }
        guard error == nil, characteristic.isNotifying else {
            failSetup("Couldn’t subscribe to device data", role: role)
            return
        }
        if role == .heartRate {
            heartRateStatus = "Connected"
        } else {
            if characteristic.uuid == GATT.controlPoint { controlSubscribed = true }
            if characteristic.uuid == GATT.indoorBikeData { indoorDataSubscribed = true }
            updateReadiness()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard let role = role(of: peripheral) else { return }
        if error != nil {
            if [GATT.machineFeatures, GATT.supportedPowerRange].contains(characteristic.uuid) {
                failSetup("Couldn’t read trainer power capabilities", role: role)
            } else if characteristic.uuid == GATT.controlPoint, pending != nil {
                abortLink(reason: .writeUnconfirmed)
            }
            return
        }
        guard let data = characteristic.value else { return }
        switch (role, characteristic.uuid) {
        case (.heartRate, GATT.heartRateMeasurement):
            onHeartRate?(BluetoothPayload.heartRate(data))
        case (.trainer, GATT.machineFeatures):
            guard BluetoothPayload.supportsTargetPower(data) == true else {
                failSetup("Trainer does not advertise ERG control", role: role)
                return
            }
            supportsPower = true
            updateReadiness()
        case (.trainer, GATT.supportedPowerRange):
            guard let range = BluetoothPayload.powerRange(data) else {
                failSetup("Trainer reported an invalid power range", role: role)
                return
            }
            advertisedRange = range
            updateReadiness()
        case (.trainer, GATT.indoorBikeData):
            if let sample = BluetoothPayload.bikeData(data) { onTrainerSample?(sample) }
        case (.trainer, GATT.controlPoint):
            guard let response = BluetoothPayload.response(data), pending?.opcode == response.opcode else { return }
            pending?.result = response.result
            completeCommandIfReady()
        case (.trainer, GATT.machineStatus):
            if data.first == 0xFF, controlHeld || pending != nil {
                abortLink(reason: .noControl)
            }
        default:
            break
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard role(of: peripheral) == .trainer, characteristic.uuid == GATT.controlPoint, pending != nil else { return }
        if error != nil {
            abortLink(reason: .writeUnconfirmed)
            return
        }
        pending?.writeAcknowledged = true
        completeCommandIfReady()
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard let role = role(of: peripheral), invalidatedServices.contains(where: { $0.uuid == role.service }) else { return }
        if role == .trainer {
            abortLink(reason: .trainerUnavailable)
        } else {
            onHeartRate?(nil)
            configure(peripheral, role: role)
        }
    }
}

private enum GATT {
    static let fitnessMachine = CBUUID(string: "1826")
    static let machineFeatures = CBUUID(string: "2ACC")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let supportedPowerRange = CBUUID(string: "2AD8")
    static let controlPoint = CBUUID(string: "2AD9")
    static let machineStatus = CBUUID(string: "2ADA")
    static let heartRate = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")
}

private struct Command {
    let id = UUID()
    let opcode: UInt8
    let continuation: CheckedContinuation<Void, Error>
    var writeAcknowledged = false
    var result: UInt8?
}

private enum ConnectionIssue: LocalizedError {
    case trainerUnavailable, invalidTarget, noControl, stopUnconfirmed, commandInProgress
    case commandTimedOut, writeUnconfirmed, rejected(UInt8)

    var errorDescription: String? {
        switch self {
        case .trainerUnavailable: "Trainer unavailable"
        case .invalidTarget: "Trainer cannot apply that power target"
        case .noControl: "Trainer control lost. Close other trainer apps and reconnect."
        case .stopUnconfirmed: "Couldn’t confirm the trainer stopped"
        case .commandInProgress: "Trainer command already in progress"
        case .commandTimedOut: "Trainer did not confirm the command"
        case .writeUnconfirmed: "Couldn’t send a confirmed trainer command"
        case .rejected(0x02): "Trainer does not support that command"
        case .rejected(0x03): "Trainer rejected that target"
        case .rejected(0x05): "Trainer control denied. Close other trainer apps."
        case .rejected: "Trainer could not complete the command"
        }
    }
}
