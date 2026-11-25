import AppKit
import SwiftUI

@MainActor
final class SafariHUD {
    private weak var model: RideAppModel?
    private var effort: HUDPanel?
    private var totals: HUDPanel?
    private var menu: HUDPanel?

    init(model: RideAppModel) { self.model = model }

    func update() {
        guard let model, model.window?.isVisible == true, !model.demo,
              model.playback.route == .safari, model.playback.issue == nil else {
            hide()
            return
        }
        let foreground = NSWorkspace.shared.frontmostApplication
        let safariActive = foreground?.bundleIdentifier == Playback.safariIdentifier
        let menuActive = foreground?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            && menu?.isKeyWindow == true && model.sheet == nil
        guard safariActive || menuActive,
              let screen = model.window?.screen ?? NSScreen.main else {
            hide()
            return
        }

        if effort == nil {
            effort = HUDPanel(content: EffortHUD(workout: model.workout, floating: true), takesInput: false)
            totals = HUDPanel(content: TotalsHUD(workout: model.workout, floating: true), takesInput: false)
            menu = HUDPanel(content: RideMenu(
                model: model, playback: model.playback, workout: model.workout, devices: model.devices, floating: true
            ), takesInput: true)
        }
        let bounds = screen.visibleFrame
        let inset = HUDLayout.inset
        // Leave the Safari toolbar accessible when its normal window is maximised.
        let videoTop = bounds.maxY - 64
        effort?.place(left: bounds.minX + inset, top: videoTop)
        totals?.place(left: bounds.minX + HUDLayout.totalsStart(in: bounds.width), top: videoTop)
        menu?.place(left: bounds.maxX - inset - HUDLayout.menuSize,
                    top: bounds.minY + inset + HUDLayout.menuSize)
    }

    func close() { hide() }

    private func hide() {
        effort?.orderOut(nil)
        totals?.orderOut(nil)
        menu?.orderOut(nil)
    }
}

@MainActor
private final class HUDPanel: NSPanel {
    private let hosting: NSHostingView<AnyView>

    init(content: some View, takesInput: Bool) {
        hosting = NSHostingView(rootView: AnyView(content.fixedSize().preferredColorScheme(.dark)))
        let size = hosting.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        ignoresMouseEvents = !takesInput
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        level = .floating
        backgroundColor = .clear
        hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.wantsLayer = true
        effect.layer?.cornerRadius = takesInput ? 22 : 16
        effect.layer?.masksToBounds = true
        effect.addSubview(hosting)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { !ignoresMouseEvents }

    func place(left: CGFloat, top: CGFloat) {
        let measured = hosting.fittingSize
        guard measured.width > 0, measured.height > 0 else { return }
        let target = NSRect(x: left, y: top - measured.height, width: measured.width, height: measured.height)
        if target != frame { setFrame(target, display: true) }
        if !isVisible { orderFrontRegardless() }
    }
}
