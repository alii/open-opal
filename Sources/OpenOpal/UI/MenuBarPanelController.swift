import AppKit
import SwiftUI

/// One persistent panel owns the controls in both presentations.
@MainActor
@Observable
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    private(set) var isFloating = false
    private(set) var snapReady = false
    private(set) var anchorOffset: CGFloat = 200
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var panel: ControlsPanel!
    private var clickMonitor: Any?
    private var dragMonitor: Any?
    private var isDragging = false
    private var floatingSize = NSSize(width: 440, height: 780)
    /// Called whenever the controls are brought on screen.
    var onShow: (() -> Void)?

    func install(content: NSViewController) {
        let panel = ControlsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 780),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.title = "Open Opal"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 400, height: 480)
        panel.contentViewController = content
        panel.delegate = self
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.aperture", accessibilityDescription: "Open Opal")
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Open Opal controls"
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                // A floating window stays put, like any other window.
                guard let self, !self.isDragging, !self.isFloating else { return }
                // WindowServer can consume resize-edge clicks before AppKit.
                guard !self.panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) else { return }
                self.panel.orderOut(nil)
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private var anchor: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func toggle() {
        // An accessory app has no Dock icon to quit from, so right-click is
        // the way out that does not depend on the panel.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
            return
        }
        if panel.isVisible && !isFloating {
            panel.orderOut(nil)
        } else {
            if !isFloating { positionAtStatusItem() }
            panel.makeKeyAndOrderFront(nil)
            onShow?()
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Open Opal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    func detach() {
        guard !isFloating else { return }
        isFloating = true
        panel.styleMask.insert(.resizable)
        let top = panel.frame.maxY
        let screen = panel.screen?.visibleFrame ?? panel.frame
        let size = NSSize(width: min(floatingSize.width, screen.width), height: min(floatingSize.height, screen.height))
        panel.setFrame(
            NSRect(
                x: min(panel.frame.minX, screen.maxX - size.width),
                y: max(screen.minY, top - size.height), width: size.width, height: size.height), display: true)
    }

    func dock() {
        if isFloating { floatingSize = panel.frame.size }
        isFloating = false
        snapReady = false
        statusItem.button?.highlight(false)
        panel.styleMask.remove(.resizable)
        positionAtStatusItem()
        panel.makeKeyAndOrderFront(nil)
        onShow?()
    }

    func hide() { panel.orderOut(nil) }

    func drag(with event: NSEvent) {
        isDragging = true
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        // Keep the grab point stable. Resizing is available after detaching.
        isFloating = true
        panel.styleMask.insert(.resizable)
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated { self?.updateSnapTarget() }
            return event
        }
        panel.performDrag(with: event)
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        dragMonitor = nil
        updateSnapTarget()
        isDragging = false
        if snapReady { dock() } else { screenChanged() }
        snapReady = false
        statusItem.button?.highlight(false)
    }

    private func updateSnapTarget() {
        snapReady = anchor?.insetBy(dx: -32, dy: -28).contains(NSEvent.mouseLocation) == true
        statusItem.button?.highlight(snapReady)
    }

    private func positionAtStatusItem() {
        guard let anchor,
            let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })
        else { return }
        let visible = screen.visibleFrame
        let width = min(400, visible.width)
        let height = min(780, visible.height - 8)
        panel.setFrame(
            NSRect(
                x: max(visible.minX, min(anchor.midX - width / 2, visible.maxX - width)),
                y: visible.maxY - height - 4, width: width, height: height), display: true)
        anchorOffset = anchor.midX - panel.frame.minX
    }

    @objc private func screenChanged() {
        guard isFloating else {
            if panel.isVisible { positionAtStatusItem() }
            return
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        panel.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        if !isDragging && !isFloating { panel.orderOut(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func shutdown() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        NotificationCenter.default.removeObserver(self)
        NSStatusBar.system.removeStatusItem(statusItem)
        panel.orderOut(nil)
    }
}

private final class ControlsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

struct PanelDragHandle: NSViewRepresentable {
    let controller: MenuBarPanelController

    func makeNSView(context: Context) -> DragView { DragView(controller: controller) }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        let controller: MenuBarPanelController
        init(controller: MenuBarPanelController) {
            self.controller = controller
            super.init(frame: .zero)
            toolTip = "Drag to float. Drop near the Open Opal menu bar icon to dock."
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) { controller.drag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
