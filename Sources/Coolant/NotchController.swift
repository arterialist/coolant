import AppKit
import SwiftUI

struct NotchMessage: Equatable {
    var title: String
    var detail: String
    var symbol: String
    var tint: Color
}

/// Lets the overlay sit on top of the menu bar instead of being pushed below it.
private final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
}

private final class NotchState: ObservableObject {
    @Published var open = false
    @Published var message = NotchMessage(title: "", detail: "", symbol: "fanblades.fill", tint: .blue)
}

/// The panel stays on screen for the app's lifetime with the shell hidden inside the hardware
/// notch, so showing a message never pays for creating a window or a first layout.
@MainActor
final class NotchController {
    private enum Phase { case idle, open, closing }

    private static let displaySeconds = 3.0
    private static let closeSeconds = 0.46
    private static let swapSeconds = 0.32

    private var panel: NotchPanel?
    private var host: NSHostingView<NotchView>?
    private let state = NotchState()
    private var layout: NotchLayout?
    private var screen: NSScreen?
    private var phase = Phase.idle
    private var queue: [NotchMessage] = []
    private var dismissal: DispatchWorkItem?
    private var monitors: [Any] = []
    private var hovering = false
    /// `--notch-slow` stretches every animation so its frames can be inspected.
    private let timeScale: Double = CommandLine.arguments.contains("--notch-slow") ? 6 : 1

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepare() }
        }
    }

    func prepare() {
        guard phase == .idle else { return }
        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let newLayout = NotchLayout(screen: target)
        let panel = panel ?? makePanel()
        self.panel = panel
        screen = target
        if newLayout != layout || host == nil {
            layout = newLayout
            let view = NotchView(state: state, layout: newLayout, timeScale: timeScale) { [weak self] in self?.advance() }
            if let host {
                host.rootView = view
            } else {
                let created = NSHostingView(rootView: view)
                host = created
                panel.contentView = created
            }
        }
        panel.setFrame(newLayout.panelFrame(on: target), display: false)
        panel.orderFrontRegardless()
    }

    func show(_ message: NotchMessage) {
        if queue.last == message || (phase == .open && queue.isEmpty && state.message == message) { return }
        queue.append(message)
        if phase == .idle { present() }
    }

    private func present() {
        guard !queue.isEmpty else { return }
        prepare()
        guard layout != nil else { return }
        phase = .open
        state.message = queue.removeFirst()
        state.open = true
        startTrackingMouse()
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.expire() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displaySeconds * timeScale, execute: work)
    }

    /// Keeps the message open while the pointer is on it.
    private func expire() {
        if hovering {
            scheduleDismissal()
        } else {
            advance()
        }
    }

    private func advance() {
        guard phase == .open else { return }
        if queue.isEmpty {
            close()
        } else {
            // Stay open and swap the content in place.
            withAnimation(.smooth(duration: Self.swapSeconds * timeScale)) { state.message = queue.removeFirst() }
            scheduleDismissal()
        }
    }

    private func close() {
        dismissal?.cancel()
        dismissal = nil
        phase = .closing
        stopTrackingMouse()
        panel?.ignoresMouseEvents = true
        state.open = false
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeSeconds * timeScale) { [weak self] in
            guard let self else { return }
            self.phase = .idle
            self.present()
        }
    }

    /// Only the visible shell takes clicks. The transparent rest of the panel passes them through.
    private func startTrackingMouse() {
        stopTrackingMouse()
        let update: () -> Void = { [weak self] in self?.mouseMoved() }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in
            MainActor.assumeIsolated { update() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            MainActor.assumeIsolated { update() }
            return event
        }) { monitors.append(local) }
        mouseMoved()
    }

    private func stopTrackingMouse() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        hovering = false
    }

    private func mouseMoved() {
        guard let layout, let screen else { return }
        hovering = layout.openShellFrame(on: screen).contains(NSEvent.mouseLocation)
        panel?.ignoresMouseEvents = !hovering
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

private struct NotchLayout: Equatable {
    static let openBody = CGSize(width: 300, height: 48)
    static let openShoulder: CGFloat = 12

    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = top
        } else {
            // No notch on this display: the shell grows out of the top edge.
            notchWidth = 180
            notchHeight = 0
        }
    }

    var openHeight: CGFloat { notchHeight + Self.openBody.height }
    var openWidth: CGFloat { Self.openBody.width + Self.openShoulder * 2 }
    /// Slightly narrower than the hardware so the closed shell can never peek out.
    var closedWidth: CGFloat { max(notchWidth - 8, 0) }
    var closedHeight: CGFloat { max(notchHeight - 2, 0) }

    func panelFrame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - openWidth / 2, y: screen.frame.maxY - openHeight, width: openWidth, height: openHeight)
    }

    func openShellFrame(on screen: NSScreen) -> NSRect {
        panelFrame(on: screen).insetBy(dx: Self.openShoulder, dy: 0)
    }
}

/// The notch outline, including the concave shoulders where it meets the top of the screen.
/// Both radii animate, so the closed notch and the open panel are one continuous shape.
private struct NotchShape: Shape {
    var shoulder: CGFloat
    var corner: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, corner) }
        set { shoulder = newValue.first; corner = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(shoulder, rect.width / 2, rect.height)
        let c = min(corner, (rect.width - 2 * s) / 2, max(rect.height - s, 0))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - c))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s + c, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s - c, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - c), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

private struct NotchView: View {
    @ObservedObject var state: NotchState
    let layout: NotchLayout
    let timeScale: Double
    let onTap: () -> Void

    private func scaled(_ animation: Animation) -> Animation { animation.speed(1 / timeScale) }

    // No overshoot in either direction: movement in the corner of the eye should stop when it arrives.
    // Height leads on the way in, so the shell slides back up into the notch.
    private var widthAnimation: Animation {
        scaled(state.open ? .spring(response: 0.36, dampingFraction: 0.95) : .spring(response: 0.36, dampingFraction: 1))
    }

    private var heightAnimation: Animation {
        scaled(state.open ? .spring(response: 0.42, dampingFraction: 0.95) : .spring(response: 0.26, dampingFraction: 1))
    }

    private func contentAnimation(delay: Double) -> Animation {
        scaled(state.open ? .easeOut(duration: 0.24).delay(delay) : .easeOut(duration: 0.1))
    }

    private var shape: NotchShape {
        NotchShape(shoulder: state.open ? NotchLayout.openShoulder : 0, corner: state.open ? 20 : 9)
    }

    var body: some View {
        // The content must stay an overlay. As a stack child its fixed width sizes the shell,
        // which then never shrinks to the notch.
        shape.fill(.black)
            .overlay(alignment: .bottom) { content }
            .clipShape(shape)
        .animation(heightAnimation, value: state.open)
        .frame(width: state.open ? layout.openWidth : layout.closedWidth)
        .animation(widthAnimation, value: state.open)
        .frame(height: state.open ? layout.openHeight : layout.closedHeight)
        .animation(heightAnimation, value: state.open)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .frame(width: layout.openWidth, height: layout.openHeight, alignment: .top)
        .drawingGroup()
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: state.message.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(state.message.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 22)
                .blur(radius: state.open ? 0 : 3)
                .opacity(state.open ? 1 : 0)
                .animation(contentAnimation(delay: 0.1), value: state.open)
            ZStack(alignment: .leading) {
                text
                    .id(state.message.title + state.message.detail)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)),
                                            removal: .opacity.combined(with: .offset(y: -6))))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20 + NotchLayout.openShoulder)
        .frame(width: layout.openWidth, height: NotchLayout.openBody.height)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.message.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .blur(radius: state.open ? 0 : 3)
                .opacity(state.open ? 1 : 0)
                .animation(contentAnimation(delay: 0.12), value: state.open)
            Text(state.message.detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
                .blur(radius: state.open ? 0 : 3)
                .opacity(state.open ? 1 : 0)
                .animation(contentAnimation(delay: 0.14), value: state.open)
        }
        .lineLimit(1)
    }
}
