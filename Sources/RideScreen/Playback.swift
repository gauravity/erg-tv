import AppKit
import SwiftUI
import WebKit

enum VideoService: String, CaseIterable, Identifiable {
    case youtube, plex, iplayer

    var id: Self { self }
    var title: String {
        switch self {
        case .youtube: "YouTube"
        case .plex: "Plex"
        case .iplayer: "BBC iPlayer"
        }
    }
    var url: URL {
        switch self {
        case .youtube: URL(string: "https://www.youtube.com/")!
        case .plex: URL(string: "https://app.plex.tv/desktop/")!
        case .iplayer: URL(string: "https://www.bbc.co.uk/iplayer")!
        }
    }
}

enum PlaybackRoute: String, CaseIterable, Identifiable {
    case safari = "Safari"
    case inApp = "In app"

    var id: Self { self }
}

@MainActor
final class Playback: ObservableObject {
    static let safariIdentifier = "com.apple.Safari"

    @Published private(set) var service: VideoService?
    @Published private(set) var route: PlaybackRoute?
    @Published private(set) var requestID = UUID()
    @Published private(set) var issue: String?

    private let preferences: UserDefaults
    private let demo: Bool

    init(preferences: UserDefaults, demo: Bool) {
        self.preferences = preferences
        self.demo = demo
    }

    func preference(for service: VideoService) -> PlaybackRoute {
        preferences.string(forKey: "video.route.\(service.rawValue)")
            .flatMap(PlaybackRoute.init(rawValue:)) ?? .inApp
    }

    func setPreference(_ route: PlaybackRoute, for service: VideoService) {
        preferences.set(route.rawValue, forKey: "video.route.\(service.rawValue)")
        if self.service == service { open(service, route: route) }
    }

    func open(_ service: VideoService, route preferredRoute: PlaybackRoute? = nil) {
        self.service = service
        issue = nil
        requestID = UUID()
        route = preferredRoute ?? preference(for: service)
        guard route == .safari, !demo else { return }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.safariIdentifier) else {
            issue = "Safari is unavailable."
            return
        }
        let opening = requestID
        NSWorkspace.shared.open([service.url], withApplicationAt: safari, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                guard let self, self.requestID == opening, error != nil else { return }
                self.issue = "Safari could not open \(service.title)."
            }
        }
    }

    func reportEmbeddedFailure(_ request: UUID) {
        guard request == requestID, route == .inApp else { return }
        issue = "Playback could not load. Open this service in Safari."
    }
}

struct EmbeddedVideo: NSViewRepresentable {
    let url: URL
    let onFailure: () -> Void

    final class Container: NSView {
        let player: WKWebView

        init(configuration: WKWebViewConfiguration) {
            player = WKWebView(frame: .zero, configuration: configuration)
            super.init(frame: .zero)
            // WebKit temporarily moves the player to its own window for fullscreen.
            player.frame = bounds
            player.translatesAutoresizingMaskIntoConstraints = true
            player.autoresizingMask = [.width, .height]
            addSubview(player)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { return nil }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onFailure: () -> Void
        init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               navigationAction.request.url?.scheme == "https" {
                webView.load(navigationAction.request)
            }
            return nil
        }

        private func report(_ error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onFailure() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFailure: onFailure) }

    func makeNSView(context: Context) -> Container {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        let container = Container(configuration: configuration)
        let player = container.player
        player.navigationDelegate = context.coordinator
        player.uiDelegate = context.coordinator
        player.load(URLRequest(url: url))
        return container
    }

    func updateNSView(_ container: Container, context: Context) {}

    static func dismantleNSView(_ container: Container, coordinator: Coordinator) {
        let player = container.player
        player.navigationDelegate = nil
        player.uiDelegate = nil
        player.stopLoading()
        player.closeAllMediaPresentations(completionHandler: nil)
        player.loadHTMLString("", baseURL: nil)
    }
}
