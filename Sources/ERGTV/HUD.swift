import AppKit
import CoreText
import RideCore
import SwiftUI

@MainActor
enum RideTypography {
    static var hasGeist = false
    static var hasInter = false

    static func register() {
        hasGeist = register("GeistMono")
        hasInter = register("Inter")
    }

    private static func register(_ file: String) -> Bool {
        guard let url = Bundle.module.url(forResource: file, withExtension: "ttf", subdirectory: "Resources") else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static func value(_ size: CGFloat) -> Font {
        hasGeist ? .custom("GeistMono-Regular", fixedSize: size)
            : .system(size: size, weight: .regular, design: .monospaced)
    }

    static func label(_ size: CGFloat = 12) -> Font {
        hasInter ? .custom("Inter-Regular", size: size) : .system(size: size)
    }
}

struct MetricValue: View {
    let value: String
    let label: String
    var unit = ""
    var slot = 4
    var size: CGFloat = 24
    var unitSize: CGFloat = 12
    var tint: Color = .white

    var body: some View {
        let number = Text(value).font(RideTypography.value(size)).foregroundColor(tint)
        let suffix = Text(unit.isEmpty ? "" : " \(unit)")
            .font(RideTypography.label(unitSize).weight(.semibold))
            .foregroundColor(.white.opacity(0.88))

        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(repeating: "0", count: slot))
                .font(RideTypography.value(size))
                .frame(width: size * 0.63 * CGFloat(slot), alignment: .leading)
            if !unit.isEmpty {
                Text(unit).font(RideTypography.label(unitSize).weight(.semibold))
                    .fixedSize()
            }
        }
        .hidden()
        .overlay(alignment: .leading) {
            Text("\(number)\(suffix)")
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value == "—" ? "Unavailable" : [value, unit].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

private extension PowerZone {
    var tint: Color {
        switch self {
        case .zone1: Color(red: 0.72, green: 0.75, blue: 0.80)
        case .zone2: Color(red: 0.22, green: 0.68, blue: 0.95)
        case .zone3: Color(red: 0.17, green: 0.78, blue: 0.45)
        case .zone4: Color(red: 1, green: 0.82, blue: 0.32)
        case .zone5: Color(red: 1, green: 0.53, blue: 0.19)
        case .zone6: Color(red: 0.94, green: 0.32, blue: 0.27)
        }
    }
}

struct SessionZoneBar: View {
    let seconds: [PowerZone: Double]

    var body: some View {
        let used = PowerZone.allCases.compactMap { zone -> (PowerZone, Double)? in
            guard let duration = seconds[zone], duration.isFinite, duration > 0 else { return nil }
            return (zone, duration)
        }
        let total = used.reduce(0) { $0 + $1.1 }
        let description = total > 0 ? used.map { zone, duration in
            "\(zone.name) \(Int((duration / total * 100).rounded()))%"
        }.joined(separator: ", ") : "No timed power data"
        GeometryReader { geometry in
            if total > 0 {
                HStack(spacing: 0) {
                    ForEach(used, id: \.0) { zone, duration in
                        zone.tint.frame(width: geometry.size.width * duration / total)
                    }
                }
            } else {
                Color.white.opacity(0.16)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityLabel("Time spent in power zones")
        .accessibilityValue(description)
        .help(description)
    }
}

private struct HUDSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let floating: Bool

    func body(content: Content) -> some View {
        if floating {
            content
        } else if reduceTransparency {
            content.background(Color(red: 0.10, green: 0.14, blue: 0.19), in: .rect(cornerRadius: 16))
        } else {
            content.glassEffect(.regular.tint(.black.opacity(0.47)), in: .rect(cornerRadius: 16))
        }
    }
}

struct EffortHUD: View {
    @ObservedObject var workout: WorkoutController
    var floating = false

    var body: some View {
        let data = workout.summary
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                MetricValue(value: integer(data.power), label: "Live power", unit: "W", size: 50, unitSize: 18)
                HStack(spacing: 8) {
                    Text("ERG target").font(RideTypography.label()).foregroundStyle(.white.opacity(0.88))
                        .accessibilityHidden(true)
                    MetricValue(value: integer(workout.target), label: "ERG target", unit: "W", size: 13)
                }
            }
            SessionZoneBar(seconds: data.zoneSeconds)
            Divider().overlay(.white.opacity(0.12))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
                GridRow {
                    reading("Cadence", value: decimal(data.cadence, places: 0), unit: "rpm", slot: 3)
                    reading("Heart rate", value: integer(data.heartRate), unit: "bpm", slot: 3)
                }
                GridRow {
                    reading("Avg power", value: integer(data.averagePower), unit: "W", slot: 4)
                    reading("Work", value: decimal(data.work, places: 0), unit: "kJ", slot: 4)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: HUDLayout.effortWidth, alignment: .leading)
        .modifier(HUDSurface(floating: floating))
    }

    private func reading(_ label: String, value: String, unit: String, slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MetricValue(value: value, label: label, unit: unit, slot: slot, size: 22)
            Text(label).font(RideTypography.label()).foregroundStyle(.white.opacity(0.88))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TotalsHUD: View {
    @ObservedObject var workout: WorkoutController
    var floating = false

    var body: some View {
        let duration = workout.plan?.duration ?? 0
        let remaining = max(0, duration - workout.elapsed)
        let timerSlots = max(6, clockString(duration).count)
        let timerSize = min(25, 150 / CGFloat(timerSlots))
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MetricValue(value: decimal(workout.summary.speed, places: 0), label: "Trainer speed", unit: "km/h", slot: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricValue(value: decimal(workout.summary.distance, places: 1), label: "Distance", unit: "km", slot: 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricValue(value: clockString(workout.elapsed), label: "Elapsed", slot: timerSlots, size: timerSize)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MetricValue(value: clockString(remaining, roundUp: true), label: "Time left", slot: timerSlots,
                            size: timerSize, tint: Color(red: 0.65, green: 0.85, blue: 1))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ProgressView(value: duration > 0 ? min(1, workout.elapsed / duration) : 0)
                .tint(PowerZone.zone2.tint)
                .accessibilityLabel("Workout progress")
            HStack {
                if let zone = workout.currentZone {
                    Text(zone.name).foregroundStyle(zone.tint)
                }
                Spacer(minLength: 8)
                Text(status).foregroundStyle(.white)
            }
            .font(RideTypography.label().weight(.semibold))
            if let message = workout.message {
                Text(message).font(RideTypography.label()).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: HUDLayout.totalsWidth)
        .modifier(HUDSurface(floating: floating))
    }

    private var status: String {
        switch workout.state {
        case .idle: "Ready to set up"
        case .starting: "Checking trainer"
        case .riding: "ERG active"
        case .paused: "Ride paused"
        case .interrupted: "Ride interrupted"
        case .ended: "Ride ended"
        }
    }
}

enum HUDLayout {
    static let effortWidth: CGFloat = 212
    static let totalsWidth: CGFloat = 432
    static let inset: CGFloat = 16
    static let menuSize: CGFloat = 44

    static func totalsStart(in width: CGFloat) -> CGFloat {
        min(max(inset + effortWidth + 12, (width - totalsWidth) / 2), max(inset, width - totalsWidth - inset))
    }
}

private func clockString(_ seconds: Double, roundUp: Bool = false) -> String {
    guard let whole = Int(exactly: max(0, roundUp ? seconds.rounded(.up) : seconds.rounded(.down))) else { return "—" }
    return String(format: "%02ld:%02ld", whole / 60, whole % 60)
}

private func integer(_ value: Int?) -> String { value.map(String.init) ?? "—" }

private func decimal(_ value: Double?, places: Int) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.locale(Locale(identifier: "en_GB"))
        .grouping(.never).precision(.fractionLength(places)))
}
