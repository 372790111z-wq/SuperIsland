import AppKit
import ApplicationServices
import CoreGraphics

enum ControlCenterAdjustmentIdentity {
    static func kind(for identifier: String) -> SystemFeedbackKind? {
        switch identifier {
        case "controlcenter-volume-slider": return .volume
        case "controlcenter-display-brightness-slider": return .brightness
        default: return nil
        }
    }
}

/// Observes a mouse gesture on the two public Control Center slider nodes.
/// No values are written and no generic keyboard or message text is read.
@MainActor
final class ControlCenterSystemAdjustmentMonitor {
    static let shared = ControlCenterSystemAdjustmentMonitor()
    private var volumeEnabled = false
    private var brightnessEnabled = false
    private var timer: Timer?

    func apply(volumeEnabled: Bool, brightnessEnabled: Bool) {
        self.volumeEnabled = volumeEnabled
        self.brightnessEnabled = brightnessEnabled
        guard volumeEnabled || brightnessEnabled else {
            timer?.invalidate(); timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleGesture() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sampleGesture() {
        guard NSEvent.pressedMouseButtons & 1 != 0, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.controlcenter" }) else { return }
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - mouse.y)
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard windows.contains(where: { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.contains(point)
        }) else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.03)
        var hit: AXUIElement?
        if AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success {
            for _ in 0..<6 {
                guard let element = hit else { break }
                if presentFeedbackIfSlider(element, at: point) { return }
                if let parent = Self.attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() {
                    hit = (parent as! AXUIElement)
                } else {
                    hit = nil
                }
            }
        }
        let deadline = CFAbsoluteTimeGetCurrent() + 0.05
        var queue = [root]
        var visited = 0
        while !queue.isEmpty, visited < 160, CFAbsoluteTimeGetCurrent() < deadline {
            let element = queue.removeFirst(); visited += 1
            if presentFeedbackIfSlider(element, at: point) { return }
            if let children = Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(160 - visited))
            }
        }
    }

    private func presentFeedbackIfSlider(_ element: AXUIElement, at point: CGPoint) -> Bool {
        guard let identifier = Self.attribute(element, kAXIdentifierAttribute) as? String,
              let kind = ControlCenterAdjustmentIdentity.kind(for: identifier),
              let frame = Self.frame(element), frame.insetBy(dx: -3, dy: -3).contains(point) else { return false }
        switch kind {
        case .volume where volumeEnabled:
            VolumeManager.shared.refreshAfterSystemKeyChange()
        case .brightness where brightnessEnabled:
            ScreenBrightnessManager.shared.noteUserInitiatedChange()
        default: break
        }
        return true
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let rawPosition = attribute(element, kAXPositionAttribute),
              let rawSize = attribute(element, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero; var size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
