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
    @Published var expanded = false
    @Published var message = NotchMessage(title: "", detail: "", symbol: "fanblades.fill", tint: .blue)
}

@MainActor
final class NotchController {
    private static let size = CGSize(width: 400, height: 64)
    private static let displaySeconds = 4.0
    private static let animationSeconds = 0.35

    private var panel: NotchPanel?
    private let state = NotchState()
    private var queue: [NotchMessage] = []
    private var showing = false
    private var dismissal: DispatchWorkItem?

    func show(_ message: NotchMessage) {
        if queue.last == message { return }
        queue.append(message)
        if !showing { showNext() }
    }

    private func showNext() {
        guard !queue.isEmpty else { showing = false; return }
        showing = true
        let message = queue.removeFirst()
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let layout = NotchLayout(screen: screen, expanded: Self.size)
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: NotchView(state: state, layout: layout) { [weak self] in self?.dismiss() })
        panel.setFrame(layout.frame(on: screen), display: true)
        state.message = message
        state.expanded = false
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [state] in
            withAnimation(.spring(response: Self.animationSeconds, dampingFraction: 0.78)) { state.expanded = true }
        }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.displaySeconds, execute: work)
    }

    private func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        withAnimation(.easeIn(duration: Self.animationSeconds * 0.7)) { state.expanded = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationSeconds) { [weak self] in
            self?.panel?.orderOut(nil)
            self?.showNext()
        }
    }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

private struct NotchLayout {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let expanded: CGSize

    init(screen: NSScreen, expanded: CGSize) {
        self.expanded = expanded
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = top
        } else {
            // No notch on this display: grow a pill out of the top edge.
            notchWidth = 180
            notchHeight = 0
        }
    }

    var totalHeight: CGFloat { notchHeight + expanded.height }

    func frame(on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.midX - expanded.width / 2, y: screen.frame.maxY - totalHeight,
               width: expanded.width, height: totalHeight)
    }
}

private struct NotchView: View {
    @ObservedObject var state: NotchState
    let layout: NotchLayout
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                UnevenRoundedRectangle(bottomLeadingRadius: state.expanded ? 22 : 10, bottomTrailingRadius: state.expanded ? 22 : 10)
                    .fill(.black)
                content
                    .frame(height: layout.expanded.height)
                    .opacity(state.expanded ? 1 : 0)
            }
            .frame(width: state.expanded ? layout.expanded.width : layout.notchWidth,
                   height: state.expanded ? layout.totalHeight : layout.notchHeight)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            Spacer(minLength: 0)
        }
        .frame(width: layout.expanded.width, height: layout.totalHeight)
    }

    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: state.message.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(state.message.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.message.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(state.message.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
    }
}
