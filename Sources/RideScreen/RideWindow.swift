import AppKit
import RideBluetooth
import RideCore
import SwiftUI

struct RideWindow: View {
    @ObservedObject var model: RideAppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VideoStage(model: model, playback: model.playback)
                EffortHUD(workout: model.workout)
                    .padding(HUDLayout.inset)
                TotalsHUD(workout: model.workout)
                    .padding(.top, HUDLayout.inset)
                    .padding(.leading, HUDLayout.totalsStart(in: geometry.size.width))
                VStack {
                    Spacer()
                    HStack {
                        if model.demo { Text("Demo").foregroundStyle(.white.opacity(0.9)) }
                        Spacer()
                        RideMenu(model: model, playback: model.playback, workout: model.workout, devices: model.devices)
                    }
                }
                .padding(HUDLayout.inset)
            }
            .clipped()
        }
        .preferredColorScheme(.dark)
        .background(WindowAnchor { model.window = $0 })
        .sheet(item: $model.sheet) { Well(model: model, panel: $0) }
    }
}

private struct VideoStage: View {
    let model: RideAppModel
    @ObservedObject var playback: Playback

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.10, blue: 0.14)
            if let service = playback.service, playback.route == .inApp, !model.demo {
                let request = playback.requestID
                EmbeddedVideo(url: service.url) { playback.reportEmbeddedFailure(request) }
                    .id(request)
            } else if model.demo,
                      let url = Bundle.module.url(forResource: "demo-still", withExtension: "jpg", subdirectory: "Resources"),
                      let still = NSImage(contentsOf: url) {
                GeometryReader { proxy in
                    Image(nsImage: still).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .accessibilityHidden(true)
                }
                LinearGradient(colors: [.black.opacity(0.4), .clear, .black.opacity(0.3)],
                               startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
            }
            if let issue = playback.issue {
                VStack(spacing: 12) {
                    Text(issue).font(RideTypography.label(14))
                    if let service = playback.service, playback.route == .inApp {
                        Button("Open in Safari") { model.openVideo(service, route: .safari) }
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .padding(.top, 140)
            } else if playback.route == .safari && !model.demo {
                VStack(spacing: 12) {
                    Text("\(playback.service?.title ?? "Video") is open in Safari.")
                    Button("Show Safari") { model.showSafari() }
                }
                .padding(.top, 120)
            } else if playback.service == nil && !model.demo {
                VStack(spacing: 12) {
                    Button("Set up ride") { model.show(.workout) }
                        .buttonStyle(.borderedProminent)
                    Text("Choose a video service from the ride menu.")
                        .font(RideTypography.label(14)).foregroundStyle(.secondary)
                }
                .padding(.top, 120)
            }
        }
    }
}

struct RideMenu: View {
    let model: RideAppModel
    @ObservedObject var playback: Playback
    @ObservedObject var workout: WorkoutController
    @ObservedObject var devices: BluetoothDevices
    var floating = false
    @StateObject private var disclosure = MenuDisclosure()

    var body: some View {
        Button { disclosure.open.toggle() } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: HUDLayout.menuSize, height: HUDLayout.menuSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            if !floating {
                Circle().fill(.black.opacity(0.45)).glassEffect(.regular, in: Circle())
            }
        }
        .accessibilityLabel("Ride menu")
        .help("Ride menu")
        .popover(isPresented: $disclosure.open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ForEach(VideoService.allCases) { service in
                        Button {
                            disclosure.open = false
                            model.openVideo(service)
                        } label: {
                            ServiceIcon(service: service, selected: playback.service == service)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(service.title)
                        .accessibilityAddTraits(playback.service == service ? .isSelected : [])
                        .help(service.title)
                    }
                }
                .padding(.bottom, 4)
                Divider()
                action("Workout setup", icon: "bicycle", enabled: !model.hasSession) { model.show(.workout) }
                action("Devices", icon: "sensor") { model.show(.devices) }
                action("Video settings", icon: "play.rectangle") { model.show(.video) }
                if playback.route == .inApp, let service = playback.service, !model.demo {
                    action("Open in Safari", icon: "safari") { model.openVideo(service, route: .safari) }
                }
                if model.hasSession {
                    Divider()
                    if workout.state == .riding {
                        action("Pause ride", icon: "pause.fill") { model.togglePause() }
                    } else if workout.state == .paused || workout.state == .interrupted {
                        action("Resume ride", icon: "play.fill") { model.togglePause() }
                    }
                    action("End ride…", icon: "stop.fill") { model.show(.end) }
                }
            }
            .frame(width: 200, alignment: .leading)
            .padding(12)
            .preferredColorScheme(.dark)
        }
    }

    private func action(_ title: String, icon: String, enabled: Bool = true, work: @escaping () -> Void) -> some View {
        Button {
            disclosure.open = false
            work()
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!enabled)
    }
}

@MainActor
private final class MenuDisclosure: ObservableObject {
    @Published var open = false
}

private struct ServiceIcon: View {
    let service: VideoService
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(service == .youtube ? .white : Color(white: 0.12))
            switch service {
            case .youtube:
                RoundedRectangle(cornerRadius: 5).fill(Color(red: 1, green: 0, blue: 0.22))
                    .frame(width: 26, height: 18)
                Image(systemName: "play.fill").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
            case .plex:
                HStack(spacing: 0) {
                    Text("ple").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.18))
                }
            case .iplayer:
                VStack(spacing: 4) {
                    HStack(spacing: 1) {
                        ForEach(Array("BBC".enumerated()), id: \.offset) { _, letter in
                            Text(String(letter)).font(.system(size: 5, weight: .bold)).foregroundStyle(.black)
                                .frame(width: 7, height: 7).background(.white)
                        }
                    }
                    Image(systemName: "play.fill").font(.system(size: 15, weight: .black))
                        .foregroundStyle(Color(red: 1, green: 0.31, blue: 0.66))
                }
            }
        }
        .frame(width: 44, height: 44)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? .blue : .white.opacity(0.20), lineWidth: selected ? 2 : 1))
    }
}

private struct Well: View {
    @ObservedObject var model: RideAppModel
    let panel: RideSheet

    var body: some View {
        switch panel {
        case .workout: WorkoutSetup(model: model, devices: model.devices, workout: model.workout)
        case .devices: DeviceSetup(model: model, devices: model.devices, workout: model.workout)
        case .video: VideoSetup(model: model, playback: model.playback)
        case .end:
            VStack(alignment: .leading, spacing: 16) {
                Text("End this ride?").font(.title2.weight(.semibold))
                HStack {
                    Spacer()
                    Button("Keep riding") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                    Button("End ride", role: .destructive) {
                        model.sheet = nil
                        Task { await model.workout.end() }
                    }
                }
            }
            .padding(24)
            .frame(width: 360)
        }
    }
}

private struct WorkoutSetup: View {
    @ObservedObject var model: RideAppModel
    @ObservedObject var devices: BluetoothDevices
    @ObservedObject var workout: WorkoutController
    @StateObject private var draft: WorkoutDraft

    init(model: RideAppModel, devices: BluetoothDevices, workout: WorkoutController) {
        self.model = model
        self.devices = devices
        self.workout = workout
        let lastFTP = model.defaults.object(forKey: "workout.ftp") as? Int
        let lastWatts = model.defaults.object(forKey: "workout.fixed") as? Int
        _draft = StateObject(wrappedValue: WorkoutDraft(
            ftp: lastFTP ?? (model.demo ? 230 : nil), fixed: lastWatts,
            minutes: model.defaults.object(forKey: "workout.minutes") as? Int ?? 47
        ))
    }

    private var preview: Result<WorkoutPlan, Error>? {
        guard let range = model.range, let duration = Int(draft.minutes),
              draft.useFixed ? Int(draft.fixed) != nil : Int(draft.ftp) != nil else { return nil }
        return Result {
            try WorkoutPlan(steadyMinutes: duration, ftp: Int(draft.ftp),
                            fixedWatts: draft.useFixed ? Int(draft.fixed) : nil, range: range)
        }
    }

    var body: some View {
        let preview = preview
        let plan = preview.flatMap { try? $0.get() }
        VStack(alignment: .leading, spacing: 16) {
            Text("Workout setup").font(.title2.weight(.semibold))
            Form {
                Picker("Workout", selection: $draft.useFixed) {
                    Text("Zone 2").tag(false)
                    Text("Fixed watts").tag(true)
                }
                .pickerStyle(.segmented)
                TextField(draft.useFixed ? "FTP in watts (optional)" : "FTP in watts", text: $draft.ftp)
                if draft.useFixed { TextField("Steady target in watts", text: $draft.fixed) }
                TextField("Steady minutes", text: $draft.minutes)
            }
            if let plan {
                Text("8 min warm-up · \(draft.minutes) min at \(plan.steadyWatts) W · 5 min cool-down")
                    .font(.callout)
            }
            if model.range == nil {
                Text("Connect your trainer to start.").foregroundStyle(.secondary)
            } else if workout.summary.cadence == nil || workout.summary.cadence == 0 {
                Text("Pedal gently to confirm the trainer is sending data.").foregroundStyle(.secondary)
            }
            if case let .failure(error) = preview { Text(error.localizedDescription).foregroundStyle(.orange) }
            HStack {
                Button("Devices") { model.show(.devices) }
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button("Start ride") {
                    if let plan, let duration = Int(draft.minutes) {
                        model.start(plan, minutes: duration, fixed: draft.useFixed ? Int(draft.fixed) : nil)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan == nil || model.hasSession || workout.summary.power == nil || (workout.summary.cadence ?? 0) <= 0)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

@MainActor
private final class WorkoutDraft: ObservableObject {
    @Published var useFixed: Bool
    @Published var ftp: String
    @Published var fixed: String
    @Published var minutes: String

    init(ftp: Int?, fixed: Int?, minutes: Int) {
        useFixed = fixed != nil
        self.ftp = ftp.map(String.init) ?? ""
        self.fixed = fixed.map(String.init) ?? ""
        self.minutes = String(minutes)
    }
}

private struct DeviceSetup: View {
    @ObservedObject var model: RideAppModel
    @ObservedObject var devices: BluetoothDevices
    @ObservedObject var workout: WorkoutController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Devices").font(.title2.weight(.semibold))
            if model.demo {
                Text("Demo trainer and heart-rate readings")
            } else {
                connection(devices.trainerName ?? "Trainer", devices.trainerStatus,
                           workout.summary.power.map { "\($0) W" }, role: .trainer)
                connection(devices.heartRateName ?? "Heart-rate sensor", devices.heartRateStatus,
                           workout.summary.heartRate.map { "\($0) bpm" }, role: .heartRate)
                if !devices.candidates.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(devices.candidates) { candidate in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.name)
                                        Text(candidate.role == .trainer ? "Trainer" : "Heart rate")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Connect") { devices.connect(candidate) }
                                        .disabled(blocked(candidate.role))
                                }
                            }
                        }.padding(1)
                    }
                    .frame(maxHeight: 150)
                }
                Text(devices.bluetoothStatus).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if !model.demo {
                    Button(devices.scanning ? "Stop scan" : "Scan") {
                        if devices.scanning { devices.stopScanning() } else { devices.scan() }
                    }
                }
                Spacer()
                Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onDisappear { if !model.demo { devices.stopScanning() } }
    }

    private func connection(_ name: String, _ status: String, _ reading: String?, role: DeviceRole) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.semibold)
                Text([status, reading].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if role == .trainer ? devices.trainerName != nil : devices.heartRateName != nil {
                Button("Forget") { devices.forget(role) }.disabled(blocked(role))
            }
        }
    }

    private func blocked(_ role: DeviceRole) -> Bool {
        role == .trainer && (.riding == workout.state || .starting == workout.state)
    }
}

private struct VideoSetup: View {
    @ObservedObject var model: RideAppModel
    @ObservedObject var playback: Playback

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Video settings").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(VideoService.allCases) { service in
                    HStack {
                        Text(service.title)
                        Spacer()
                        Picker(service.title, selection: Binding(
                            get: { playback.preference(for: service) },
                            set: { playback.setPreference($0, for: service) }
                        )) {
                            ForEach(PlaybackRoute.allCases) { route in Text(route.rawValue).tag(route) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 144)
                    }
                }
            }
            Text("Use Safari if sign-in, audio or playback gives you trouble in the app.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Done") { model.sheet = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
        .id(playback.requestID)
    }
}
