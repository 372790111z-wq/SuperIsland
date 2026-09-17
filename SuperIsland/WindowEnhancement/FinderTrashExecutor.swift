import AppKit
import ApplicationServices
import Foundation

enum FinderTrashFailure: Error, Equatable {
    case accessibilityUnavailable
    case finderNotFrontmost
    case unsafeFocus
    case commandUnavailable
    case ambiguousCommand
    case commandDisabled
    case commandNotPressable
    case contextChanged
    case timedOut
    case requestUnconfirmed

    var message: String {
        switch self {
        case .accessibilityUnavailable: return "请先允许 WE1 使用辅助功能"
        case .finderNotFrontmost: return "仅在 Finder 或桌面选中文件时可用"
        case .unsafeFocus: return "当前正在输入、显示对话框，或无法确认文件选择区域"
        case .commandUnavailable: return "无法确认 Finder 的“移到废纸篓”命令，未执行操作"
        case .ambiguousCommand: return "Finder 命令不唯一，未执行操作"
        case .commandDisabled: return "Finder 当前无法移到废纸篓，请先选中可移除的文件"
        case .commandNotPressable: return "Finder 当前不允许执行“移到废纸篓”"
        case .contextChanged: return "Finder 焦点或操作上下文已变化，请重新触发"
        case .timedOut: return "Finder 响应超时，未继续执行操作"
        case .requestUnconfirmed: return "无法确认 Finder 是否已接收命令，请先检查文件状态"
        }
    }
}

/// Only structural AX metadata is used. File names, paths and document contents
/// are neither needed nor retained to invoke Finder's own selection command.
struct FinderTrashFocusNode: Equatable {
    var role: String?
    var subrole: String? = nil
    var editable: Bool? = nil
    var modal: Bool? = nil
    var selectedChildrenCount: Int? = nil
}

enum FinderTrashFocusPolicy {
    static let maximumDepth = 8
    private static let contentRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXGrid",
        "AXLayoutArea", "AXScrollArea"
    ]
    private static let itemRoles: Set<String> = [
        "AXCell", "AXRow", "AXImage", "AXStaticText"
    ]
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXSplitGroup", "AXWindow", "AXApplication"
    ]

    static func selectionAttributes(for role: String?, isFocused: Bool = false) -> [String] {
        if role == "AXGroup", isFocused { return ["AXSelectedChildren"] }
        guard let role, contentRoles.contains(role) else { return [] }
        return role == "AXOutline" || role == "AXTable"
            ? ["AXSelectedChildren", "AXSelectedRows"] : ["AXSelectedChildren"]
    }

    /// The path must be complete, from the focused content/item to the exact
    /// Finder application root. A text editor nested in a file list is unsafe.
    static func allows(_ path: [FinderTrashFocusNode], reachesFinderRoot: Bool) -> Bool {
        // Finder exposes selected desktop icons through a focused group, not
        // through a list or the individual image. Only this exact root path,
        // with a readable nonempty selection, can qualify as desktop content.
        let isSelectedDesktopGroup = path.count == 3 &&
            path.map(\.role) == ["AXGroup", "AXScrollArea", "AXApplication"] &&
            path.allSatisfy { $0.modal == false } &&
            path[0].selectedChildrenCount.map { $0 > 0 && $0 <= FinderTrashSelectionPolicy.maximumItems } == true
        guard reachesFinderRoot, !path.isEmpty, path.count <= maximumDepth,
              path.last?.role == "AXApplication",
              let firstRole = path.first?.role,
              contentRoles.contains(firstRole) || itemRoles.contains(firstRole) || isSelectedDesktopGroup,
              path.contains(where: { $0.role.map(contentRoles.contains) == true }) else {
            return false
        }
        for (index, node) in path.enumerated() {
            guard let role = node.role,
                  contentRoles.contains(role) || itemRoles.contains(role) || containerRoles.contains(role),
                  node.editable != true, node.modal != true else { return false }
            if role == "AXApplication", index != path.count - 1 { return false }
            if role == "AXWindow" {
                guard node.subrole == "AXStandardWindow", node.modal == false else { return false }
            } else if let subrole = node.subrole, !subrole.isEmpty, subrole != "AXUnknown" {
                // Finder's native file collection uses this exact role pair.
                // Other named subroles still cannot authorize a file command.
                if role == "AXList", subrole == "AXCollectionList" { continue }
                // Unknown special-purpose controls cannot authorize deletion.
                return false
            }
        }
        return true
    }
}

enum FinderTrashSelectionPolicy {
    static let maximumItems = 256

    /// Missing support is allowed only when it remains missing. If Finder does
    /// expose a selection, every selected AX identity must remain the same.
    static func matches<Element>(_ initial: [Element]?, _ current: [Element]?,
                                 equal: (Element, Element) -> Bool) -> Bool {
        switch (initial, current) {
        case (nil, nil): return true
        case let (initial?, current?):
            return initial.count == current.count && initial.count <= maximumItems &&
                zip(initial, current).allSatisfy(equal)
        default: return false
        }
    }
}

/// Batch AX reads represent an unsupported optional attribute as an AXError
/// value. Other errors must not turn an unreadable safety flag into false/nil.
enum FinderTrashAttributePolicy {
    static func optionalValue(_ raw: Any) throws -> Any? {
        if raw is NSNull { return nil }
        let reference = raw as AnyObject
        guard CFGetTypeID(reference) == AXValueGetTypeID() else { return raw }
        let value = unsafeBitCast(reference, to: AXValue.self)
        var error = AXError.success
        guard AXValueGetType(value) == .axError, AXValueGetValue(value, .axError, &error),
              error == .noValue || error == .attributeUnsupported else {
            throw FinderTrashFailure.commandUnavailable
        }
        return nil
    }

    static func string(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let result = value as? String else { throw FinderTrashFailure.commandUnavailable }
        return result
    }

    static func boolean(_ value: Any?) throws -> Bool? {
        guard let value else { return nil }
        guard CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID(),
              let number = value as? NSNumber else { throw FinderTrashFailure.commandUnavailable }
        return number.boolValue
    }
}

struct FinderTrashCommandDescriptor: Equatable {
    var role: String?
    var title: String?
    var virtualKey: Int?
    var modifiers: Int?
    var enabled: Bool?
    var supportsPress: Bool
}

enum FinderTrashCommandPolicy {
    private static let acceptedTitles: Set<String> = [
        "Move to Trash", "移到废纸篓", "移至废纸篓", "移到廢紙簍",
        "移至廢紙簍", "移到垃圾桶", "移至垃圾桶", "搬到垃圾桶"
    ]

    static func hasTrashIdentity(_ command: FinderTrashCommandDescriptor) -> Bool {
        guard command.role == "AXMenuItem", let title = command.title,
              acceptedTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines)),
              command.virtualKey == 51, command.modifiers == 0 else { return false }
        // AXMenuItemModifiers 0 means Command only, not an unmodified Delete.
        // The name is also mandatory: Finder's Put Back uses the same chord.
        return true
    }

    static func resolve(_ commands: [FinderTrashCommandDescriptor]) -> Result<Int, FinderTrashFailure> {
        let matches = commands.indices.filter { hasTrashIdentity(commands[$0]) }
        guard let index = matches.first else { return .failure(.commandUnavailable) }
        guard matches.count == 1 else { return .failure(.ambiguousCommand) }
        guard commands[index].enabled == true else { return .failure(.commandDisabled) }
        guard commands[index].supportsPress else { return .failure(.commandNotPressable) }
        return .success(index)
    }
}

@MainActor
final class FinderTrashExecutor {
    typealias Reason = FinderTrashFailure

    enum Outcome: Equatable {
        case requested
        case rejected(Reason)

        var message: String {
            switch self {
            case .requested: return "已请求 Finder 移到废纸篓"
            case let .rejected(reason): return reason.message
            }
        }
    }

    private struct FocusEvidence {
        let elements: [AXUIElement]
        let nodes: [FinderTrashFocusNode]
        let selections: [SelectionEvidence]

        func matches(_ other: FocusEvidence) -> Bool {
            nodes == other.nodes && elements.count == other.elements.count &&
                zip(elements, other.elements).allSatisfy { CFEqual($0, $1) } &&
                selections.count == other.selections.count &&
                zip(selections, other.selections).allSatisfy { $0.matches($1) }
        }
    }

    private struct SelectionEvidence {
        let pathIndex: Int
        let attribute: String
        let elements: [AXUIElement]?

        func matches(_ other: SelectionEvidence) -> Bool {
            pathIndex == other.pathIndex && attribute == other.attribute &&
                FinderTrashSelectionPolicy.matches(elements, other.elements) { CFEqual($0, $1) }
        }
    }

    private struct CommandEvidence {
        let element: AXUIElement
        let descriptor: FinderTrashCommandDescriptor
    }

    private static let durationLimit: TimeInterval = 0.250
    private static let perRequestLimit: TimeInterval = 0.020
    private static let maximumMenuNodes = 96
    private static let maximumMenuDepth = 5
    private static let fileMenuTitles: Set<String> = ["File", "文件", "檔案"]

    /// This performs no input synthesis and does not open a menu or confirm any
    /// Finder dialog. A successful AXPress only acknowledges the command request.
    func perform(expectedPID: pid_t, isCurrent: () -> Bool) -> Outcome {
        let deadline = ProcessInfo.processInfo.systemUptime + Self.durationLimit
        do {
            try validateContext(expectedPID: expectedPID, isCurrent: isCurrent, deadline: deadline)
            let application = AXUIElementCreateApplication(expectedPID)
            let initialFocus = try focusEvidence(application: application, expectedPID: expectedPID,
                                                 deadline: deadline, isCurrent: isCurrent)
            let initialCommand = try trashCommand(application: application, expectedPID: expectedPID,
                                                   deadline: deadline, isCurrent: isCurrent)
            try validateContext(expectedPID: expectedPID, isCurrent: isCurrent, deadline: deadline)
            let currentFocus = try focusEvidence(application: application, expectedPID: expectedPID,
                                                 deadline: deadline, isCurrent: isCurrent)
            guard initialFocus.matches(currentFocus) else { return .rejected(.contextChanged) }
            let currentCommand = try trashCommand(application: application, expectedPID: expectedPID,
                                                   deadline: deadline, isCurrent: isCurrent)
            guard CFEqual(initialCommand.element, currentCommand.element),
                  initialCommand.descriptor == currentCommand.descriptor else {
                return .rejected(.contextChanged)
            }
            let finalFocus = try focusEvidence(application: application, expectedPID: expectedPID,
                                               deadline: deadline, isCurrent: isCurrent)
            guard initialFocus.matches(finalFocus) else { return .rejected(.contextChanged) }
            try prepare(currentCommand.element, expectedPID: expectedPID,
                        deadline: deadline, isCurrent: isCurrent)
            try validateContext(expectedPID: expectedPID, isCurrent: isCurrent, deadline: deadline)
            let result = AXUIElementPerformAction(currentCommand.element, kAXPressAction as CFString)
            // Never retry an uncertain AXPress: Finder may already be acting.
            return result == .success ? .requested : .rejected(.requestUnconfirmed)
        } catch let failure as FinderTrashFailure {
            return .rejected(failure)
        } catch {
            return .rejected(.commandUnavailable)
        }
    }

    private func validateContext(expectedPID: pid_t, isCurrent: () -> Bool,
                                 deadline: TimeInterval) throws {
        guard isCurrent() else { throw FinderTrashFailure.contextChanged }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw FinderTrashFailure.timedOut }
        guard AXIsProcessTrusted() else { throw FinderTrashFailure.accessibilityUnavailable }
        guard expectedPID > 0, let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == expectedPID, frontmost.bundleIdentifier == "com.apple.finder",
              !frontmost.isTerminated else { throw FinderTrashFailure.finderNotFrontmost }
    }

    private func prepare(_ element: AXUIElement, expectedPID: pid_t,
                         deadline: TimeInterval, isCurrent: () -> Bool) throws {
        try validateContext(expectedPID: expectedPID, isCurrent: isCurrent, deadline: deadline)
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw FinderTrashFailure.timedOut }
        guard AXUIElementSetMessagingTimeout(element, Float(min(Self.perRequestLimit, remaining))) == .success else {
            throw FinderTrashFailure.commandUnavailable
        }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == expectedPID else {
            throw FinderTrashFailure.contextChanged
        }
    }

    private func attribute(_ name: String, of element: AXUIElement, expectedPID: pid_t,
                           deadline: TimeInterval, isCurrent: () -> Bool) throws -> CFTypeRef? {
        try prepare(element, expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if result == .noValue || result == .attributeUnsupported { return nil }
        guard result == .success else {
            throw ProcessInfo.processInfo.systemUptime >= deadline
                ? FinderTrashFailure.timedOut : FinderTrashFailure.commandUnavailable
        }
        return value
    }

    private func attributes(_ names: [String], of element: AXUIElement, expectedPID: pid_t,
                            deadline: TimeInterval, isCurrent: () -> Bool) throws -> [Any?] {
        try prepare(element, expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values)
        guard result == .success, let resultValues = values as? [Any], resultValues.count == names.count else {
            throw ProcessInfo.processInfo.systemUptime >= deadline
                ? FinderTrashFailure.timedOut : FinderTrashFailure.commandUnavailable
        }
        return try resultValues.map(FinderTrashAttributePolicy.optionalValue)
    }

    private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func children(of element: AXUIElement, expectedPID: pid_t,
                          deadline: TimeInterval, isCurrent: () -> Bool) throws -> [AXUIElement] {
        guard let raw = try attribute(kAXChildrenAttribute as String, of: element, expectedPID: expectedPID,
                                      deadline: deadline, isCurrent: isCurrent) else { return [] }
        guard let values = raw as? [AnyObject], values.count <= Self.maximumMenuNodes else {
            throw FinderTrashFailure.commandUnavailable
        }
        let result = values.compactMap { axElement($0) }
        guard result.count == values.count else { throw FinderTrashFailure.commandUnavailable }
        return result
    }

    private func focusEvidence(application: AXUIElement, expectedPID: pid_t,
                               deadline: TimeInterval, isCurrent: () -> Bool) throws -> FocusEvidence {
        guard let focused = axElement(try attribute(kAXFocusedUIElementAttribute as String, of: application,
                                                    expectedPID: expectedPID, deadline: deadline,
                                                    isCurrent: isCurrent)) else {
            throw FinderTrashFailure.unsafeFocus
        }
        var current = focused
        var elements: [AXUIElement] = []
        var nodes: [FinderTrashFocusNode] = []
        var selections: [SelectionEvidence] = []
        for _ in 0..<FinderTrashFocusPolicy.maximumDepth {
            guard !elements.contains(where: { CFEqual($0, current) }) else { throw FinderTrashFailure.unsafeFocus }
            let values = try attributes([kAXRoleAttribute as String, kAXSubroleAttribute as String,
                                         "AXEditable", kAXModalAttribute as String], of: current,
                                        expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
            elements.append(current)
            nodes.append(try FinderTrashFocusNode(role: FinderTrashAttributePolicy.string(values[0]),
                subrole: FinderTrashAttributePolicy.string(values[1]),
                editable: FinderTrashAttributePolicy.boolean(values[2]),
                modal: FinderTrashAttributePolicy.boolean(values[3])))
            for name in FinderTrashFocusPolicy.selectionAttributes(for: nodes.last?.role,
                                                                   isFocused: nodes.count == 1) {
                let selection = try selectedElements(name, of: current, expectedPID: expectedPID,
                                                     deadline: deadline, isCurrent: isCurrent)
                if name == "AXSelectedChildren" {
                    nodes[nodes.count - 1].selectedChildrenCount = selection?.count
                }
                selections.append(SelectionEvidence(pathIndex: nodes.count - 1,
                                                     attribute: name, elements: selection))
            }
            if CFEqual(current, application) {
                guard FinderTrashFocusPolicy.allows(nodes, reachesFinderRoot: true) else {
                    throw FinderTrashFailure.unsafeFocus
                }
                return FocusEvidence(elements: elements, nodes: nodes, selections: selections)
            }
            guard let parent = axElement(try attribute(kAXParentAttribute as String, of: current,
                                                       expectedPID: expectedPID, deadline: deadline,
                                                       isCurrent: isCurrent)) else {
                throw FinderTrashFailure.unsafeFocus
            }
            current = parent
        }
        throw FinderTrashFailure.unsafeFocus
    }

    private func selectedElements(_ name: String, of element: AXUIElement, expectedPID: pid_t,
                                  deadline: TimeInterval, isCurrent: () -> Bool) throws -> [AXUIElement]? {
        try prepare(element, expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
        var count: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
        if countResult == .noValue || countResult == .attributeUnsupported { return nil }
        guard countResult == .success, count >= 0, count <= FinderTrashSelectionPolicy.maximumItems else {
            throw FinderTrashFailure.unsafeFocus
        }
        guard count > 0 else { return [] }
        try prepare(element, expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, name as CFString, 0, count, &values) == .success,
              let items = values as? [AnyObject], items.count == count else {
            throw FinderTrashFailure.contextChanged
        }
        let selection = items.compactMap { axElement($0) }
        guard selection.count == count else { throw FinderTrashFailure.unsafeFocus }
        return selection
    }

    private func trashCommand(application: AXUIElement, expectedPID: pid_t,
                              deadline: TimeInterval, isCurrent: () -> Bool) throws -> CommandEvidence {
        guard let menuBar = axElement(try attribute(kAXMenuBarAttribute as String, of: application,
                                                    expectedPID: expectedPID, deadline: deadline,
                                                    isCurrent: isCurrent)) else {
            throw FinderTrashFailure.commandUnavailable
        }
        let barRole = try attribute(kAXRoleAttribute as String, of: menuBar, expectedPID: expectedPID,
                                    deadline: deadline, isCurrent: isCurrent) as? String
        guard barRole == "AXMenuBar" else { throw FinderTrashFailure.commandUnavailable }
        let topItems = try children(of: menuBar, expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
        guard topItems.count <= 24 else { throw FinderTrashFailure.commandUnavailable }
        var fileMenus: [AXUIElement] = []
        for item in topItems {
            let values = try attributes([kAXRoleAttribute as String, kAXTitleAttribute as String], of: item,
                                        expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
            if values[0] as? String == "AXMenuBarItem", let title = values[1] as? String,
               Self.fileMenuTitles.contains(title.trimmingCharacters(in: .whitespacesAndNewlines)) {
                fileMenus.append(item)
            }
        }
        guard fileMenus.count == 1, let fileMenu = fileMenus.first else {
            throw FinderTrashFailure.commandUnavailable
        }
        var queue: [(AXUIElement, Int)] = [(fileMenu, 0)]
        var visited: [AXUIElement] = []
        var matches: [CommandEvidence] = []
        var cursor = 0
        while cursor < queue.count {
            let (element, depth) = queue[cursor]
            cursor += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }
            guard visited.count < Self.maximumMenuNodes else { throw FinderTrashFailure.commandUnavailable }
            visited.append(element)
            let values = try attributes([kAXRoleAttribute as String, kAXTitleAttribute as String,
                                         kAXMenuItemCmdVirtualKeyAttribute as String,
                                         kAXMenuItemCmdModifiersAttribute as String,
                                         kAXEnabledAttribute as String], of: element,
                                        expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
            var descriptor = FinderTrashCommandDescriptor(role: values[0] as? String,
                title: values[1] as? String, virtualKey: (values[2] as? NSNumber)?.intValue,
                modifiers: (values[3] as? NSNumber)?.intValue, enabled: (values[4] as? NSNumber)?.boolValue,
                supportsPress: false)
            if FinderTrashCommandPolicy.hasTrashIdentity(descriptor) {
                try prepare(element, expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success else {
                    throw FinderTrashFailure.commandNotPressable
                }
                descriptor.supportsPress = (actions as? [String])?.contains(kAXPressAction as String) == true
                matches.append(CommandEvidence(element: element, descriptor: descriptor))
            }
            let descendants = try children(of: element, expectedPID: expectedPID,
                                            deadline: deadline, isCurrent: isCurrent)
            guard descendants.isEmpty || (depth < Self.maximumMenuDepth &&
                queue.count + descendants.count <= Self.maximumMenuNodes) else {
                throw FinderTrashFailure.commandUnavailable
            }
            queue.append(contentsOf: descendants.map { ($0, depth + 1) })
        }
        switch FinderTrashCommandPolicy.resolve(matches.map(\.descriptor)) {
        case let .success(index): return matches[index]
        case let .failure(failure): throw failure
        }
    }
}
