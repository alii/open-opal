import AppKit

@main
struct MenuBarDockingTests {
    @MainActor
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1060)
        func accepts(top: CGFloat, ready: Bool = false, x horizontal: CGFloat = 400) -> Bool {
            MenuBarPanelController.shouldDock(
                panelFrame: NSRect(x: horizontal, y: top - 200, width: 440, height: 200),
                screenFrame: screen, visibleFrame: visible, wasReady: ready)
        }
        precondition(!accepts(top: 1027))
        precondition(accepts(top: 1028))
        precondition(accepts(top: 1060))
        precondition(accepts(top: 1112))
        precondition(!accepts(top: 1113))
        precondition(accepts(top: 1004, ready: true))
        precondition(!accepts(top: 1003, ready: true))
        precondition(accepts(top: 1136, ready: true))
        precondition(!accepts(top: 1137, ready: true))
        precondition(!accepts(top: 1060, x: 1920))
        precondition(!accepts(top: 1060, x: -440))
        precondition(MenuBarPanelController.shouldDock(
            panelFrame: NSRect(x: -800, y: 860, width: 440, height: 200),
            screenFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1060), wasReady: false))
        precondition(!MenuBarPanelController.shouldDock(
            panelFrame: NSRect(x: 400, y: 860, width: 440, height: 200),
            screenFrame: screen, visibleFrame: screen, wasReady: false))
        print("Docking: entry and release boundaries, separate displays and hidden menu bars passed")
    }
}
