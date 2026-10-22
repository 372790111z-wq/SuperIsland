import AppKit
import ApplicationServices

/// Activation policy describes Dock/menu presentation, not window capabilities.
enum WindowInteractionEligibility {
    static func allowsApplication(_ policy: NSApplication.ActivationPolicy) -> Bool {
        policy == .regular || policy == .accessory
    }

    static func isStandardWindow(role: String?, subrole: String?, modal: Bool?) -> Bool {
        role == kAXWindowRole as String && subrole == kAXStandardWindowSubrole as String && modal != true
    }

    @MainActor
    static func isOwnSettingsWindow(_ window: NSWindow, managed: NSWindow?, key: NSWindow?) -> Bool {
        window === managed && window === key && window.isVisible && !window.isMiniaturized &&
        window.level == .normal && window.styleMask.contains(.titled) &&
        window.attachedSheet == nil && NSApp.modalWindow == nil
    }
}

enum WindowSettingsGeometry {
    /// AppKit and AX use opposite vertical axes, with the primary display as origin.
    static func flipped(_ frame: CGRect, desktopTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height)
    }

    static func constrained(_ target: CGRect, minimum: CGSize, available: CGRect) -> CGRect {
        let size = CGSize(width: max(minimum.width, min(target.width, available.width)),
                          height: max(minimum.height, min(target.height, available.height)))
        return CGRect(x: max(available.minX, min(target.minX, available.maxX - size.width)),
                      y: max(available.minY, min(target.minY, available.maxY - size.height)),
                      width: size.width, height: size.height)
    }
}
