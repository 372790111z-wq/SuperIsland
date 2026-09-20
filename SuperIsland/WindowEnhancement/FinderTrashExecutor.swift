import AppKit
import ApplicationServices
import Foundation

enum FinderTrashFailure: String, Error, Equatable {
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
        case .accessibilityUnavailable: return "请在系统设置中开启本应用的辅助功能权限"
        case .finderNotFrontmost: return "请先在 Finder 或桌面选中文件"
        case .unsafeFocus: return "无法确认文件选择，请检查是否正在输入或有对话框打开"
        case .commandUnavailable: return "无法确认删除命令，未执行操作"
        case .ambiguousCommand: return "无法确认删除命令，未执行操作"
        case .commandDisabled: return "所选文件暂无法移到废纸篓"
        case .commandNotPressable: return "暂无法移到废纸篓，未执行操作"
        case .contextChanged: return "操作对象已变化，请重新选中文件"
        case .timedOut: return "Finder 响应超时，未继续执行"
        case .requestUnconfirmed: return "删除结果暂无法确认，请先检查文件状态"
        }
    }
}

/// Structural diagnostics only: unknown AX strings are reduced to fixed codes.
/// A dedicated bounded stream keeps pointer traffic from dropping first-use
/// failures or the user's immediate retry. It never reads file names or URLs.
struct FinderTrashDiagnosticTrace {
    enum Stage: String {
        case context, initialFocus, initialCommand, currentFocus, currentCommand, finalFocus, press
    }

    var stage: Stage = .context
    private(set) var focusPath = "unread"
    private(set) var focusDepth = 0
    private(set) var editable = false
    private(set) var modal = false
    private(set) var editableStates = "unread"
    private(set) var modalStates = "unread"
    private(set) var subroleStates = "unread"
    private(set) var selectionState = "unread"

    private static func booleanCode(_ value: Bool?) -> String {
        switch value {
        case true?: return "t"
        case false?: return "f"
        case nil: return "u"
        }
    }

    mutating func observeFocus(_ nodes: [FinderTrashFocusNode]) {
        focusDepth = nodes.count
        focusPath = nodes.prefix(FinderTrashFocusPolicy.maximumDepth).map { node in
            switch node.role {
            case "AXGroup": return "group"
            case "AXList": return "list"
            case "AXOutline": return "outline"
            case "AXTable": return "table"
            case "AXBrowser": return "browser"
            case "AXGrid": return "grid"
            case "AXLayoutArea": return "layout"
            case "AXScrollArea": return "scroll"
            case "AXCell": return "cell"
            case "AXRow": return "row"
            case "AXImage": return "image"
            case "AXStaticText": return "text"
            case "AXTextField", "AXTextArea", "AXComboBox": return "edit"
            case "AXWindow": return "window"
            case "AXApplication": return "app"
            case nil: return "missing"
            default: return "other"
            }
        }.joined(separator: ".")
        if focusPath.isEmpty { focusPath = "unread" }
        editable = nodes.contains { $0.editable == true }
        modal = nodes.contains { $0.modal == true }
        let boundedNodes = nodes.prefix(FinderTrashFocusPolicy.maximumDepth)
        editableStates = nodes.isEmpty ? "unread" : boundedNodes.map { Self.booleanCode($0.editable) }.joined(separator: ".")
        modalStates = nodes.isEmpty ? "unread" : boundedNodes.map { Self.booleanCode($0.modal) }.joined(separator: ".")
        // m=missing, e=empty, u=AXUnknown, s=standard window,
        // c=collection, d=dialog, q=search, o=any other subrole.
        subroleStates = nodes.isEmpty ? "unread" : boundedNodes.map { node in
            switch node.subrole {
            case nil: return "m"
            case "": return "e"
            case "AXUnknown": return "u"
            case "AXStandardWindow": return "s"
            case "AXCollectionList": return "c"
            case "AXDialog": return "d"
            case "AXSearchField": return "q"
            default: return "o"
            }
        }.joined(separator: ".")
        switch nodes.first?.selectedChildrenCount {
        case nil: selectionState = nodes.isEmpty ? "unread" : "missing"
        case 0?: selectionState = "empty"
        case let count?:
            selectionState = count < 0 ? "invalid" :
                (count > FinderTrashSelectionPolicy.maximumItems ? "oversized" : "nonempty")
        }
    }

    func metadata(failure: FinderTrashFailure?, elapsed: TimeInterval) -> [String: WindowInteractionDiagnosticValue] {
        // Clamp diagnostic conversion only; the operation's deadline is unchanged.
        let elapsedMS = elapsed.isFinite ? Int64(min(60_000, max(0, elapsed * 1_000))) : -1
        return ["stage": .code(stage.rawValue), "result": .code(failure?.rawValue ?? "requested"),
                "elapsed_ms": .integer(elapsedMS), "focus_path": .code(focusPath),
                "focus_depth": .integer(Int64(focusDepth)),
                "editable": .flag(editable), "modal": .flag(modal),
                "editable_states": .code(editableStates), "modal_states": .code(modalStates),
                "subrole_states": .code(subroleStates), "selection": .code(selectionState)]
    }

    static let recorder = WindowLifecycleDiagnosticRecorder(
        fileURL: WindowInteractionDiagnosticRecorder.diagnosticFileURL?
            .deletingLastPathComponent().appendingPathComponent("finder-shortcuts.jsonl")
    )
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

/// Finder's selection command belongs directly to File's one AXMenu. Submenus
/// such as Open With are unrelated command scopes and may contain large,
/// dynamic trees; they must neither authorize Trash nor exhaust its lookup.
enum FinderTrashMenuScope {
    static let maximumDirectItems = 96

    static func directItems<Element>(
        of fileMenuItem: Element,
        role: (Element) throws -> String?,
        children: (Element) throws -> [Element]
    ) throws -> [Element] {
        guard try role(fileMenuItem) == "AXMenuBarItem" else {
            throw FinderTrashFailure.commandUnavailable
        }
        let menus = try children(fileMenuItem)
        guard menus.count == 1, let menu = menus.first,
              try role(menu) == "AXMenu" else {
            throw FinderTrashFailure.commandUnavailable
        }
        let items = try children(menu)
        guard items.count <= maximumDirectItems else {
            throw FinderTrashFailure.commandUnavailable
        }
        for item in items {
            guard try role(item) == "AXMenuItem" else {
                throw FinderTrashFailure.commandUnavailable
            }
        }
        // Deliberately never ask for an AXMenuItem's children. Scan this entire
        // returned set before resolving the command, so duplicates fail closed.
        return items
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
            case .requested: return "已请求移到废纸篓"
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
    private static let maximumMenuNodes = FinderTrashMenuScope.maximumDirectItems
    private static let fileMenuTitles: Set<String> = ["File", "文件", "檔案"]

    /// This performs no input synthesis and does not open a menu or confirm any
    /// Finder dialog. A successful AXPress only acknowledges the command request.
    func perform(expectedPID: pid_t, isCurrent: () -> Bool) -> Outcome {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + Self.durationLimit
        var trace = FinderTrashDiagnosticTrace()
        func finish(_ outcome: Outcome) -> Outcome {
            let failure: FinderTrashFailure?
            switch outcome {
            case .requested: failure = nil
            case let .rejected(reason): failure = reason
            }
            FinderTrashDiagnosticTrace.recorder.record(event: "trashRequest", metadata: trace.metadata(
                failure: failure, elapsed: ProcessInfo.processInfo.systemUptime - startedAt))
            return outcome
        }
        do {
            try validateContext(expectedPID: expectedPID, isCurrent: isCurrent, deadline: deadline)
            let application = AXUIElementCreateApplication(expectedPID)
            trace.stage = .initialFocus
            let initialFocus = try focusEvidence(application: application, expectedPID: expectedPID,
                                                 deadline: deadline, isCurrent: isCurrent, trace: &trace)
            trace.stage = .initialCommand
            let initialCommand = try trashCommand(application: application, expectedPID: expectedPID,
                                                   deadline: deadline, isCurrent: isCurrent)
            try validateContext(expectedPID: expectedPID, isCurrent: isCurrent, deadline: deadline)
            trace.stage = .currentFocus
            let currentFocus = try focusEvidence(application: application, expectedPID: expectedPID,
                                                 deadline: deadline, isCurrent: isCurrent, trace: &trace)
            guard initialFocus.matches(currentFocus) else { return finish(.rejected(.contextChanged)) }
            trace.stage = .currentCommand
            let currentCommand = try trashCommand(application: application, expectedPID: expectedPID,
                                                   deadline: deadline, isCurrent: isCurrent)
            guard CFEqual(initialCommand.element, currentCommand.element),
                  initialCommand.descriptor == currentCommand.descriptor else {
                return finish(.rejected(.contextChanged))
            }
            trace.stage = .finalFocus
            let finalFocus = try focusEvidence(application: application, expectedPID: expectedPID,
                                               deadline: deadline, isCurrent: isCurrent, trace: &trace)
            guard initialFocus.matches(finalFocus) else { return finish(.rejected(.contextChanged)) }
            trace.stage = .press
            try prepare(currentCommand.element, expectedPID: expectedPID,
                        deadline: deadline, isCurrent: isCurrent)
            try validateContext(expectedPID: expectedPID, isCurrent: isCurrent, deadline: deadline)
            let result = AXUIElementPerformAction(currentCommand.element, kAXPressAction as CFString)
            // Never retry an uncertain AXPress: Finder may already be acting.
            return finish(result == .success ? .requested : .rejected(.requestUnconfirmed))
        } catch let failure as FinderTrashFailure {
            return finish(.rejected(failure))
        } catch {
            return finish(.rejected(.commandUnavailable))
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
                               deadline: TimeInterval, isCurrent: () -> Bool,
                               trace: inout FinderTrashDiagnosticTrace) throws -> FocusEvidence {
        trace.observeFocus([])
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
            trace.observeFocus(nodes)
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
            trace.observeFocus(nodes)
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
        let directItems = try FinderTrashMenuScope.directItems(of: fileMenu, role: { element in
            try attribute(kAXRoleAttribute as String, of: element, expectedPID: expectedPID,
                          deadline: deadline, isCurrent: isCurrent) as? String
        }, children: { element in
            try children(of: element, expectedPID: expectedPID, deadline: deadline, isCurrent: isCurrent)
        })
        var matches: [CommandEvidence] = []
        for element in directItems {
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
        }
        switch FinderTrashCommandPolicy.resolve(matches.map(\.descriptor)) {
        case let .success(index): return matches[index]
        case let .failure(failure): throw failure
        }
    }
}
