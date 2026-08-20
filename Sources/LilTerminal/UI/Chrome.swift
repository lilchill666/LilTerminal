import SwiftUI
import AppKit

/// Real NSVisualEffectView blur. SwiftUI's `.ultraThinMaterial` blurs only what
/// is inside the window; `.behindWindow` blurs the desktop and windows behind
/// it, which is the effect Finder and Mail actually use in their sidebars.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    /// `.active` keeps the blur when the window loses focus; the AppKit default
    /// dims it, which reads as the whole app greying out the moment you click
    /// somewhere else.
    var alwaysActive = true
    /// SwiftUI's `.clipShape` does not clip an NSView, so a rounded panel whose
    /// backdrop is one of these ends up with a square blur poking out past
    /// every corner. The effect view has to round itself.
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blending
        view.state = alwaysActive ? .active : .followsWindowActiveState

        // `maskImage` rather than a layer corner radius: behind-window blending
        // composites below the layer tree, where layer masking is ignored.
        if cornerRadius > 0.5 {
            if view.maskImage?.size.width != 2 * cornerRadius + 1 {
                view.maskImage = Self.roundedMask(radius: cornerRadius)
            }
        } else if view.maskImage != nil {
            view.maskImage = nil
        }
    }

    /// A nine-part stretchable rounded rectangle: the corners stay the right
    /// size at any panel dimension because the cap insets pin them.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Window geometry shared between the SwiftUI layout and the AppKit code that
/// positions the traffic lights. Both have to agree or the buttons drift out of
/// the bar, so neither side is allowed its own copy of these numbers.
enum Layout {
    static let windowMargin: CGFloat = 10
    /// The gap between two floating panels. Matches `windowMargin` so a panel
    /// is the same distance from its neighbour as from the window edge.
    static let panelGap: CGFloat = 10
    static let topBarHeight: CGFloat = 36
    /// Distance from the bar's leading edge to the first traffic light.
    static let trafficLightInset: CGFloat = 14
    /// Centre-to-centre spacing of the three buttons (the macOS standard).
    static let trafficLightPitch: CGFloat = 20

    /// Where bar content may begin without colliding with the buttons.
    static var barContentInset: CGFloat {
        trafficLightInset + trafficLightPitch * 2 + 14 + 10
    }
}

/// Reaches the hosting NSWindow to set the things SwiftUI does not expose:
/// a transparent titlebar and a non-opaque window, both required before
/// behind-window blur can show anything at all.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
            context.coordinator.observe(view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(view.window)
            context.coordinator.observe(view.window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// AppKit re-lays the traffic lights out on resize and when entering or
    /// leaving full screen, so the placement has to be re-applied rather than
    /// set once.
    final class Coordinator {
        private var observed: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        func observe(_ window: NSWindow?) {
            guard let window, observed !== window else { return }
            observed = window

            let windowEvents: [NSNotification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
            ]
            for name in windowEvents {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { note in
                    guard let window = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { WindowConfigurator.applyChrome(to: window) }
                })
            }

            // Window-level events are not enough. Anything that relayouts the
            // frame view — changing density, toggling chrome — makes AppKit put
            // the buttons back at their default spot without resizing the
            // window, so nothing above would fire. Watching the buttons
            // themselves catches every cause rather than an enumerated few.
            if let frameView = window.contentView?.superview {
                frameView.postsFrameChangedNotifications = true
                tokens.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: frameView, queue: .main
                ) { [weak window] _ in
                    guard let window else { return }
                    MainActor.assumeIsolated { WindowConfigurator.placeTrafficLights(in: window) }
                })
            }

            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for type in types {
                guard let button = window.standardWindowButton(type) else { continue }
                button.postsFrameChangedNotifications = true
                tokens.append(NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification, object: button, queue: .main
                ) { [weak window] _ in
                    guard let window else { return }
                    MainActor.assumeIsolated { WindowConfigurator.placeTrafficLights(in: window) }
                })
            }
        }

        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }
    }

    /// Moves the close/minimise/zoom buttons so they sit inside the app's own
    /// top bar: vertically centred in it, and inset from its leading edge by the
    /// same margin the buttons on the trailing edge use.
    ///
    /// They are reparented into the window's frame view because their usual home,
    /// the titlebar view, is only ~28pt tall — too short to centre them at the
    /// bar's midpoint, which would simply clip them.
    /// Guards against re-entry: repositioning a button posts the very frame
    /// notification that triggers this method.
    @MainActor private static var isPlacing = false

    /// Re-asserts the placement on every visible window.
    ///
    /// AppKit moves these buttons back whenever it relayouts the window chrome
    /// — presenting a sheet is enough — and the notifications for that are not
    /// reliable enough to be the only defence. This is called from the metrics
    /// tick that already runs once a second and no-ops when nothing moved, so
    /// the cost is a float comparison per button.
    static func enforceTrafficLights() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
            placeTrafficLights(in: window)
        }
    }

    static func placeTrafficLights(in window: NSWindow) {
        guard !isPlacing else { return }
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3,
              let frameView = window.contentView?.superview else { return }

        // Placement is measured down from the top of the frame view, so a
        // height that is not yet real puts the buttons near the bottom of the
        // window. That is exactly what happens on the first layout pass, and it
        // only corrected itself later when a resize re-ran this.
        let height = frameView.bounds.height
        guard height > 200 else { return }

        isPlacing = true
        defer { isPlacing = false }

        for button in buttons where button.superview !== frameView {
            button.removeFromSuperview()
            frameView.addSubview(button)
        }

        // AppKit's origin is bottom-left; the layout constants are measured
        // from the top, so the centre is mirrored once here.
        let centreFromTop = Layout.windowMargin + Layout.topBarHeight / 2
        let centreY = height - centreFromTop

        for (index, button) in buttons.enumerated() {
            let size = button.frame.size
            let origin = NSPoint(
                x: Layout.windowMargin + Layout.trafficLightInset
                    + CGFloat(index) * Layout.trafficLightPitch,
                y: centreY - size.height / 2
            )
            // Skipping a no-op move keeps this from churning the layout on
            // every unrelated frame notification.
            if abs(button.frame.origin.x - origin.x) > 0.5
                || abs(button.frame.origin.y - origin.y) > 0.5 {
                button.setFrameOrigin(origin)
            }
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        Self.applyChrome(to: window)
    }

    /// Everything the window needs, re-appliable at any time.
    ///
    /// `isOpaque = false` is not merely cosmetic: SwiftTerm will not composite a
    /// translucent terminal background without it, so if SwiftUI resets this the
    /// transparency setting silently stops working.
    static func applyChrome(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.styleMask.insert(.fullSizeContentView)
        // Without this a divider is drawn across the top of our own bar.
        window.titlebarSeparatorStyle = .none
        // The custom top bar covers the (now hidden) titlebar, which would
        // otherwise be the only place to drag from. Views that handle their own
        // mouse events — the terminal, sidebar rows — still take precedence,
        // so text selection and tab dragging are unaffected.
        window.isMovableByWindowBackground = true
        placeTrafficLights(in: window)
    }
}

extension Animation {
    /// One spring family for every layout move, so panes, rows, and disclosure
    /// share a physical feel instead of each easing differently.
    static let paneMove = Animation.spring(response: 0.34, dampingFraction: 0.85)
    static let rowState = Animation.easeOut(duration: 0.14)
    static let disclosure = Animation.spring(response: 0.28, dampingFraction: 0.82)

    /// Showing and hiding a whole panel travels much further than a row does.
    /// At the tighter response above it reads as a snap rather than a slide, so
    /// it gets a longer, softer spring with almost no overshoot.
    static let panelMove = Animation.spring(response: 0.46, dampingFraction: 0.92)
}

extension View {
    /// A floating frosted panel: inset from the window, rounded, and lifted off
    /// the background with a shadow rather than butting against the edges.
    func floatingPanel(theme: AppTheme, cornerRadius: CGFloat = 12,
                       blur: Bool = true, material: NSVisualEffectView.Material = .sidebar) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    if blur {
                        VisualEffect(material: material, blending: .withinWindow,
                                     cornerRadius: cornerRadius)
                        theme.chrome.opacity(0.55)
                    } else {
                        theme.chrome
                    }
                }
            }
            .clipShape(shape)
            .overlay {
                // A hairline keeps the panel from dissolving into the terminal
                // behind it when the two are close in luminance.
                shape.strokeBorder(theme.hairline.opacity(0.9), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(theme.isDark ? 0.34 : 0.14), radius: 12, x: 0, y: 4)
    }
}
