import XCTest
import ApplicationServices
@testable import SuperIsland

final class FinderTrashExecutorTests: XCTestCase {
    func testTrashDiagnosticsRedactUnknownAXStringsAndBoundThePath() throws {
        var trace = FinderTrashDiagnosticTrace()
        trace.observeFocus([
            .init(role: "/Users/person/private-file.txt", subrole: "private document"),
            .init(role: "AXGroup"), .init(role: "AXScrollArea"), .init(role: "AXApplication")
        ])
        let metadata = trace.metadata(failure: .unsafeFocus, elapsed: 0.05)
        XCTAssertEqual(metadata["focus_path"], .code("other.group.scroll.app"))
        XCTAssertTrue(metadata.values.allSatisfy(\.isAllowed))
        let text = String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains("/Users"))

        trace.observeFocus(Array(repeating: .init(role: "AXOutline"), count: 20))
        XCTAssertTrue(trace.metadata(failure: .unsafeFocus, elapsed: 0).values.allSatisfy(\.isAllowed))
        XCTAssertEqual(trace.focusPath.split(separator: ".").count, FinderTrashFocusPolicy.maximumDepth)
    }

    func testTrashDiagnosticsPreserveStageAndFailureWithoutClaimingDeletion() {
        var trace = FinderTrashDiagnosticTrace()
        trace.stage = .initialCommand
        let rejected = trace.metadata(failure: .commandUnavailable, elapsed: 0.08)
        XCTAssertEqual(rejected["stage"], .code("initialCommand"))
        XCTAssertEqual(rejected["result"], .code("commandUnavailable"))
        XCTAssertEqual(rejected["elapsed_ms"], .integer(80))
        trace.stage = .press
        XCTAssertEqual(trace.metadata(failure: .requestUnconfirmed, elapsed: 0.1)["result"],
                       .code("requestUnconfirmed"))
        XCTAssertEqual(trace.metadata(failure: nil, elapsed: 0.1)["result"], .code("requested"))
    }

    func testTrashDiagnosticsClearEarlierFocusAndKeepUnsafeFlags() {
        var trace = FinderTrashDiagnosticTrace()
        trace.observeFocus([.init(role: "AXTextField", editable: true, modal: true)])
        XCTAssertEqual(trace.metadata(failure: .unsafeFocus, elapsed: 0)["editable"], .flag(true))
        XCTAssertEqual(trace.metadata(failure: .unsafeFocus, elapsed: 0)["modal"], .flag(true))
        trace.observeFocus([])
        XCTAssertEqual(trace.focusPath, "unread")
        XCTAssertEqual(trace.focusDepth, 0)
        XCTAssertFalse(trace.editable)
        XCTAssertFalse(trace.modal)
    }

    func testTrashDiagnosticElapsedConversionCannotTrapOrAlterOperation() {
        let trace = FinderTrashDiagnosticTrace()
        for duration in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(trace.metadata(failure: .timedOut, elapsed: duration)["elapsed_ms"], .integer(-1))
        }
        XCTAssertEqual(trace.metadata(failure: nil, elapsed: -1)["elapsed_ms"], .integer(0))
        XCTAssertEqual(trace.metadata(failure: nil, elapsed: .greatestFiniteMagnitude)["elapsed_ms"], .integer(60_000))
    }

    func testTrashDiagnosticsDistinguishDesktopMissingMetadataFromFalseAndEmpty() {
        var trace = FinderTrashDiagnosticTrace()
        trace.observeFocus([.init(role: "AXGroup", subrole: "AXUnknown", editable: nil, modal: nil),
                            .init(role: "AXScrollArea", modal: false),
                            .init(role: "AXApplication", modal: false)])
        let missing = trace.metadata(failure: .unsafeFocus, elapsed: 0)
        XCTAssertEqual(missing["modal_states"], .code("u.f.f"))
        XCTAssertEqual(missing["selection"], .code("missing"))
        XCTAssertEqual(missing["subrole_states"], .code("u.m.m"))
        for (count, expected) in [(0, "empty"), (1, "nonempty"), (257, "oversized"), (-1, "invalid")] {
            trace.observeFocus([.init(role: "AXGroup", editable: false, modal: false, selectedChildrenCount: count)])
            let metadata = trace.metadata(failure: .unsafeFocus, elapsed: 0)
            XCTAssertEqual(metadata["modal_states"], .code("f"))
            XCTAssertEqual(metadata["editable_states"], .code("f"))
            XCTAssertEqual(metadata["selection"], .code(expected))
            XCTAssertLessThanOrEqual(metadata.count, 16)
            XCTAssertTrue(metadata.values.allSatisfy(\.isAllowed))
        }
        trace.observeFocus([])
        XCTAssertEqual(trace.selectionState, "unread")
        XCTAssertEqual(trace.modalStates, "unread")
    }

    func testTrashFailureAndImmediateRetryBothSurviveDiagnosticReadback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("finder-shortcuts.jsonl")
        let recorder = WindowLifecycleDiagnosticRecorder(
            bundleIdentifier: WindowInventoryDiagnosticGate.debugBundleIdentifier, fileURL: file)
        var trace = FinderTrashDiagnosticTrace()
        trace.stage = .initialFocus
        trace.observeFocus([.init(role: "AXGroup"), .init(role: "AXScrollArea"), .init(role: "AXApplication")])
        recorder.record(event: "trashRequest", metadata: trace.metadata(failure: .unsafeFocus, elapsed: 0.01))
        trace.stage = .press
        recorder.record(event: "trashRequest", metadata: trace.metadata(failure: nil, elapsed: 0.04))
        await withCheckedContinuation { continuation in recorder.flush { continuation.resume() } }
        let rows = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, 2)
        let metadata = try rows.map { try XCTUnwrap($0["metadata"] as? [String: Any]) }
        XCTAssertEqual(metadata[0]["result"] as? String, "unsafeFocus")
        XCTAssertEqual(metadata[1]["result"] as? String, "requested")
        XCTAssertEqual(metadata[0]["focus_path"] as? String, "group.scroll.app")
    }

    private let window = FinderTrashFocusNode(role: "AXWindow", subrole: "AXStandardWindow", modal: false)
    private let application = FinderTrashFocusNode(role: "AXApplication")
    private var command: FinderTrashCommandDescriptor {
        FinderTrashCommandDescriptor(role: "AXMenuItem", title: "Move to Trash", virtualKey: 51,
                                     modifiers: 0, enabled: true, supportsPress: true)
    }

    func testKnownFinderContentCanUseEnabledNativeTrashCommand() {
        for role in ["AXOutline", "AXList", "AXTable", "AXBrowser", "AXGrid", "AXLayoutArea", "AXScrollArea"] {
            XCTAssertTrue(FinderTrashFocusPolicy.allows([
                FinderTrashFocusNode(role: role), window, application
            ], reachesFinderRoot: true))
        }
        XCTAssertEqual(FinderTrashCommandPolicy.resolve([command]), .success(0))
    }

    func testDesktopContentDoesNotRequireInventingAStandardWindow() {
        XCTAssertTrue(FinderTrashFocusPolicy.allows([
            FinderTrashFocusNode(role: "AXLayoutArea"), application
        ], reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows([application], reachesFinderRoot: true))
        XCTAssertTrue(FinderTrashFocusPolicy.allows([
            FinderTrashFocusNode(role: "AXLayoutArea", subrole: "AXUnknown"), application
        ], reachesFinderRoot: true))
    }

    func testFileItemRequiresAConfirmedContentAncestor() {
        let row = FinderTrashFocusNode(role: "AXRow")
        XCTAssertTrue(FinderTrashFocusPolicy.allows([
            row, FinderTrashFocusNode(role: "AXOutline"), window, application
        ], reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows([row, window, application], reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows([
            FinderTrashFocusNode(role: "AXGroup"), window, application
        ], reachesFinderRoot: true))
    }

    func testRenameSearchAndEditableItemsCannotAuthorizeTrash() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox"] {
            XCTAssertFalse(FinderTrashFocusPolicy.allows([
                FinderTrashFocusNode(role: role), FinderTrashFocusNode(role: "AXOutline"), window, application
            ], reachesFinderRoot: true))
        }
        for node in [FinderTrashFocusNode(role: "AXCell", editable: true),
                     FinderTrashFocusNode(role: "AXScrollArea", subrole: "AXSearchField")] {
            XCTAssertFalse(FinderTrashFocusPolicy.allows([
                node, FinderTrashFocusNode(role: "AXOutline"), window, application
            ], reachesFinderRoot: true))
        }
    }

    func testEditableOrModalAncestorIsRejectedEvenWhenLeafLooksLikeContent() {
        for ancestor in [FinderTrashFocusNode(role: "AXGroup", editable: true),
                         FinderTrashFocusNode(role: "AXGroup", modal: true),
                         FinderTrashFocusNode(role: "AXSheet"),
                         FinderTrashFocusNode(role: "AXWindow", subrole: "AXDialog", modal: true)] {
            XCTAssertFalse(FinderTrashFocusPolicy.allows([
                FinderTrashFocusNode(role: "AXList"), ancestor, application
            ], reachesFinderRoot: true))
        }
    }

    func testUnknownWindowModalityOrRoleFailsClosed() {
        for unknown in [FinderTrashFocusNode(role: nil), FinderTrashFocusNode(role: "AXUnknown"),
                        FinderTrashFocusNode(role: "AXWindow", subrole: "AXStandardWindow"),
                        FinderTrashFocusNode(role: "AXWindow", modal: false)] {
            XCTAssertFalse(FinderTrashFocusPolicy.allows([
                FinderTrashFocusNode(role: "AXList"), unknown, application
            ], reachesFinderRoot: true))
        }
    }

    func testMissingForeignOrTruncatedFocusRootFailsClosed() {
        let path = [FinderTrashFocusNode(role: "AXList"), window, application]
        XCTAssertFalse(FinderTrashFocusPolicy.allows(path, reachesFinderRoot: false))
        XCTAssertFalse(FinderTrashFocusPolicy.allows(Array(path.dropLast()), reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows([], reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows(
            [FinderTrashFocusNode(role: "AXList")] + Array(repeating: FinderTrashFocusNode(role: "AXGroup"), count: 8) + [application],
            reachesFinderRoot: true))
    }

    func testPutBackPermanentDeleteAndEmptyTrashCannotMatchTheSameShortcut() {
        for title in ["Put Back", "放回原处", "放回原處", "Delete Immediately…", "立即删除…",
                      "Empty Trash", "清倒垃圾桶", "清空废纸篓", "Move to Trash and Delete", "移到废纸篓…"] {
            var other = command
            other.title = title
            XCTAssertEqual(FinderTrashCommandPolicy.resolve([other]), .failure(.commandUnavailable), title)
        }
    }

    func testNameAloneOrShortcutAloneCannotAuthorizeCommand() {
        for virtualKey in [nil, 117, 0] as [Int?] {
            var other = command
            other.virtualKey = virtualKey
            XCTAssertFalse(FinderTrashCommandPolicy.hasTrashIdentity(other))
        }
        for modifiers in [nil, 1, 2, 4, 8] as [Int?] {
            var other = command
            other.modifiers = modifiers
            XCTAssertFalse(FinderTrashCommandPolicy.hasTrashIdentity(other))
        }
        var other = command
        other.title = nil
        XCTAssertFalse(FinderTrashCommandPolicy.hasTrashIdentity(other))
        other = command
        other.role = "AXButton"
        XCTAssertFalse(FinderTrashCommandPolicy.hasTrashIdentity(other))
    }

    func testKnownLocalizedCommandNamesStillRequireTheCanonicalChord() {
        for title in ["Move to Trash", "移到废纸篓", "移至废纸篓", "移到廢紙簍", "移至廢紙簍",
                      "移到垃圾桶", "移至垃圾桶", "搬到垃圾桶"] {
            var localized = command
            localized.title = title
            XCTAssertEqual(FinderTrashCommandPolicy.resolve([localized]), .success(0))
            localized.modifiers = 2
            XCTAssertEqual(FinderTrashCommandPolicy.resolve([localized]), .failure(.commandUnavailable))
        }
    }

    func testDisabledOrUnknownEnabledStateDoesNotSubstituteAnotherAction() {
        for enabled in [false, nil] as [Bool?] {
            var unavailable = command
            unavailable.enabled = enabled
            XCTAssertEqual(FinderTrashCommandPolicy.resolve([unavailable]), .failure(.commandDisabled))
        }
        XCTAssertEqual(FinderTrashCommandPolicy.resolve([]), .failure(.commandUnavailable))
        var nonPressable = command
        nonPressable.supportsPress = false
        XCTAssertEqual(FinderTrashCommandPolicy.resolve([nonPressable]), .failure(.commandNotPressable))
    }

    func testDuplicateTrashCommandsRemainAmbiguousEvenIfOneIsDisabled() {
        XCTAssertEqual(FinderTrashCommandPolicy.resolve([command, command]), .failure(.ambiguousCommand))
        var disabled = command
        disabled.enabled = false
        XCTAssertEqual(FinderTrashCommandPolicy.resolve([disabled, command]), .failure(.ambiguousCommand))
        var putBack = command
        putBack.title = "Put Back"
        XCTAssertEqual(FinderTrashCommandPolicy.resolve([putBack, command]), .success(1))
    }

    func testDirectMenuScopeFindsUniqueTrashWithoutReadingLargeUnrelatedSubtree() throws {
        let largeSubmenu = MenuNode("AXMenu", children: (0..<200).map { _ in MenuNode("AXMenuItem") })
        let openWith = MenuNode("AXMenuItem", children: [largeSubmenu])
        let trash = MenuNode("AXMenuItem", command: command)
        let menu = MenuNode("AXMenu", children: [openWith, trash])
        let file = MenuNode("AXMenuBarItem", children: [menu])
        var childrenRead: [MenuNode] = []

        let items = try FinderTrashMenuScope.directItems(of: file, role: { $0.role }, children: { node in
            childrenRead.append(node)
            guard node === file || node === menu else {
                XCTFail("An unrelated command subtree must not be read")
                throw FinderTrashFailure.commandUnavailable
            }
            return node.children
        })

        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0] === openWith && items[1] === trash)
        XCTAssertEqual(FinderTrashCommandPolicy.resolve(items.compactMap(\.command)), .success(0))
        XCTAssertEqual(childrenRead.count, 2)
        XCTAssertTrue(childrenRead[0] === file && childrenRead[1] === menu)
    }

    func testNestedTrashCannotAuthorizeASelectionCommand() throws {
        let nestedTrash = MenuNode("AXMenuItem", command: command)
        let submenu = MenuNode("AXMenu", children: [nestedTrash])
        let parentCommand = MenuNode("AXMenuItem", children: [submenu])
        let menu = MenuNode("AXMenu", children: [parentCommand])
        let file = MenuNode("AXMenuBarItem", children: [menu])

        let items = try FinderTrashMenuScope.directItems(of: file, role: { $0.role }, children: { node in
            guard node === file || node === menu else {
                XCTFail("Nested Trash must not be inspected")
                throw FinderTrashFailure.commandUnavailable
            }
            return node.children
        })

        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0] === parentCommand)
        XCTAssertEqual(FinderTrashCommandPolicy.resolve(items.compactMap(\.command)),
                       .failure(.commandUnavailable))
    }

    func testAllDirectCommandsAreRetainedSoALaterDuplicateRemainsAmbiguous() throws {
        var disabled = command
        disabled.enabled = false
        let first = MenuNode("AXMenuItem", command: command)
        let last = MenuNode("AXMenuItem", command: disabled)
        let menu = MenuNode("AXMenu", children: [first, MenuNode("AXMenuItem"), last])
        let file = MenuNode("AXMenuBarItem", children: [menu])

        let items = try FinderTrashMenuScope.directItems(of: file, role: { $0.role }, children: { $0.children })

        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.last === last)
        XCTAssertEqual(FinderTrashCommandPolicy.resolve(items.compactMap(\.command)),
                       .failure(.ambiguousCommand))
    }

    func testDirectMenuScopeRejectsUnknownOrAmbiguousStructure() {
        let validMenu = MenuNode("AXMenu", children: [MenuNode("AXMenuItem", command: command)])
        let invalidFiles = [
            MenuNode(nil, children: [validMenu]),
            MenuNode("AXMenu", children: [validMenu]),
            MenuNode("AXMenuBarItem"),
            MenuNode("AXMenuBarItem", children: [validMenu, validMenu]),
            MenuNode("AXMenuBarItem", children: [MenuNode("AXGroup", children: [validMenu])]),
            MenuNode("AXMenuBarItem", children: [MenuNode("AXMenu", children: [MenuNode(nil)])]),
            MenuNode("AXMenuBarItem", children: [MenuNode("AXMenu", children: [MenuNode("AXRadioGroup")])]),
            MenuNode("AXMenuBarItem", children: [MenuNode("AXMenu", children: [MenuNode("AXMenu")])])
        ]

        for file in invalidFiles {
            XCTAssertThrowsError(try FinderTrashMenuScope.directItems(
                of: file, role: { $0.role }, children: { $0.children }
            )) { error in
                XCTAssertEqual(error as? FinderTrashFailure, .commandUnavailable)
            }
        }
    }

    func testDirectMenuItemLimitIsPreservedWithoutCountingNestedDescendants() throws {
        let directItems = (0..<FinderTrashMenuScope.maximumDirectItems).map { _ in MenuNode("AXMenuItem") }
        let menu = MenuNode("AXMenu", children: directItems)
        let file = MenuNode("AXMenuBarItem", children: [menu])
        XCTAssertEqual(try FinderTrashMenuScope.directItems(
            of: file, role: { $0.role }, children: { $0.children }
        ).count, FinderTrashMenuScope.maximumDirectItems)

        let excessiveMenu = MenuNode("AXMenu", children: directItems + [MenuNode("AXMenuItem")])
        let excessiveFile = MenuNode("AXMenuBarItem", children: [excessiveMenu])
        XCTAssertThrowsError(try FinderTrashMenuScope.directItems(
            of: excessiveFile, role: { $0.role }, children: { $0.children }
        )) { error in
            XCTAssertEqual(error as? FinderTrashFailure, .commandUnavailable)
        }
    }

    func testDirectMenuScopePropagatesReadAndContextFailures() {
        let menu = MenuNode("AXMenu", children: [MenuNode("AXMenuItem", command: command)])
        let file = MenuNode("AXMenuBarItem", children: [menu])
        for failure in [FinderTrashFailure.commandUnavailable, .contextChanged, .timedOut] {
            XCTAssertThrowsError(try FinderTrashMenuScope.directItems(of: file, role: { $0.role }, children: { node in
                if node === menu { throw failure }
                return node.children
            })) { error in
                XCTAssertEqual(error as? FinderTrashFailure, failure)
            }
        }
    }

    private final class MenuNode {
        let role: String?
        let children: [MenuNode]
        let command: FinderTrashCommandDescriptor?

        init(_ role: String?, children: [MenuNode] = [], command: FinderTrashCommandDescriptor? = nil) {
            self.role = role
            self.children = children
            self.command = command
        }
    }

    func testBatchReadErrorsCannotBecomeMissingSafetyAttributes() throws {
        for code in [AXError.noValue, .attributeUnsupported] {
            var error = code
            let value = try XCTUnwrap(AXValueCreate(.axError, &error))
            XCTAssertNil(try FinderTrashAttributePolicy.optionalValue(value))
        }
        for code in [AXError.cannotComplete, .invalidUIElement, .failure, .apiDisabled] {
            var error = code
            let value = try XCTUnwrap(AXValueCreate(.axError, &error))
            XCTAssertThrowsError(try FinderTrashAttributePolicy.optionalValue(value))
        }
    }

    func testMalformedSafetyMetadataDoesNotCountAsFalseOrAbsent() throws {
        XCTAssertNil(try FinderTrashAttributePolicy.boolean(nil))
        XCTAssertEqual(try FinderTrashAttributePolicy.boolean(kCFBooleanFalse), false)
        XCTAssertEqual(try FinderTrashAttributePolicy.boolean(kCFBooleanTrue), true)
        XCTAssertThrowsError(try FinderTrashAttributePolicy.boolean("false"))
        XCTAssertThrowsError(try FinderTrashAttributePolicy.boolean(NSNumber(value: 2)))
        XCTAssertThrowsError(try FinderTrashAttributePolicy.string(NSNumber(value: false)))
    }

    func testSelectionIdentityChangesInvalidateOtherwiseStableContentFocus() {
        XCTAssertTrue(FinderTrashSelectionPolicy.matches(["item-1", "item-2"], ["item-1", "item-2"], equal: ==))
        XCTAssertFalse(FinderTrashSelectionPolicy.matches(["item-1", "item-2"], ["item-1", "item-3"], equal: ==))
        XCTAssertFalse(FinderTrashSelectionPolicy.matches(["item-1"], ["item-1", "item-2"], equal: ==))
        XCTAssertFalse(FinderTrashSelectionPolicy.matches(["item-1"], [], equal: ==))
    }

    func testSelectionSupportCannotChangeDuringOneRequestAndEnumerationIsBounded() {
        let missing: [Int]? = nil
        XCTAssertTrue(FinderTrashSelectionPolicy.matches(missing, missing, equal: ==))
        XCTAssertFalse(FinderTrashSelectionPolicy.matches(missing, [], equal: ==))
        XCTAssertFalse(FinderTrashSelectionPolicy.matches([1], missing, equal: ==))
        let excessive = Array(0...FinderTrashSelectionPolicy.maximumItems)
        XCTAssertFalse(FinderTrashSelectionPolicy.matches(excessive, excessive, equal: ==))
        XCTAssertEqual(FinderTrashFocusPolicy.selectionAttributes(for: "AXOutline"),
                       ["AXSelectedChildren", "AXSelectedRows"])
        XCTAssertEqual(FinderTrashFocusPolicy.selectionAttributes(for: "AXTextField"), [])
        XCTAssertEqual(FinderTrashFocusPolicy.selectionAttributes(for: nil), [])
    }

    func testObservedFinderCollectionListPathIsAccepted() {
        // Structural readback: no file names, paths or values are required.
        let path = [FinderTrashFocusNode(role: "AXList", subrole: "AXCollectionList"),
                    FinderTrashFocusNode(role: "AXScrollArea"),
                    FinderTrashFocusNode(role: "AXSplitGroup"),
                    FinderTrashFocusNode(role: "AXSplitGroup"),
                    window, application]
        XCTAssertTrue(FinderTrashFocusPolicy.allows(path, reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows(path, reachesFinderRoot: false))
    }

    func testCollectionListSubroleCannotBypassRoleEditingOrModalGuards() {
        let tail = [FinderTrashFocusNode(role: "AXScrollArea"), window, application]
        for leaf in [FinderTrashFocusNode(role: "AXList", subrole: "AXCollectionList", editable: true),
                     FinderTrashFocusNode(role: "AXList", subrole: "AXCollectionList", modal: true),
                     FinderTrashFocusNode(role: "AXList", subrole: "AXSearchField"),
                     FinderTrashFocusNode(role: "AXTable", subrole: "AXCollectionList"),
                     FinderTrashFocusNode(role: "AXTextField", subrole: "AXCollectionList")] {
            XCTAssertFalse(FinderTrashFocusPolicy.allows([leaf] + tail, reachesFinderRoot: true))
        }
        let leaf = FinderTrashFocusNode(role: "AXList", subrole: "AXCollectionList")
        for ancestor in [FinderTrashFocusNode(role: "AXGroup", editable: true),
                         FinderTrashFocusNode(role: "AXGroup", modal: true)] {
            XCTAssertFalse(FinderTrashFocusPolicy.allows([leaf, ancestor] + tail, reachesFinderRoot: true))
        }
    }

    func testObservedRootScrollAreaImagePathNeedsNoSpecialRoleRelaxation() {
        let path = [FinderTrashFocusNode(role: "AXImage"),
                    FinderTrashFocusNode(role: "AXGroup", modal: false),
                    FinderTrashFocusNode(role: "AXScrollArea", modal: false), application]
        XCTAssertTrue(FinderTrashFocusPolicy.allows(path, reachesFinderRoot: true))
        var editing = path
        editing[0] = FinderTrashFocusNode(role: "AXTextField")
        XCTAssertFalse(FinderTrashFocusPolicy.allows(editing, reachesFinderRoot: true))
    }

    func testObservedFocusedDesktopGroupRequiresItsOwnSelectedChildren() {
        let path = [FinderTrashFocusNode(role: "AXGroup", modal: false, selectedChildrenCount: 1),
                    FinderTrashFocusNode(role: "AXScrollArea", modal: false, selectedChildrenCount: 0),
                    FinderTrashFocusNode(role: "AXApplication", modal: false, selectedChildrenCount: 0)]
        XCTAssertTrue(FinderTrashFocusPolicy.allows(path, reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows(path, reachesFinderRoot: false))
        XCTAssertEqual(FinderTrashFocusPolicy.selectionAttributes(for: "AXGroup", isFocused: true),
                       ["AXSelectedChildren"])
        XCTAssertEqual(FinderTrashFocusPolicy.selectionAttributes(for: "AXGroup", isFocused: false), [])
        for count in [nil, 0, -1, FinderTrashSelectionPolicy.maximumItems + 1] as [Int?] {
            var invalid = path
            invalid[0].selectedChildrenCount = count
            XCTAssertFalse(FinderTrashFocusPolicy.allows(invalid, reachesFinderRoot: true))
        }
    }

    func testDesktopGroupExceptionDoesNotApplyInsideAWindowOrAnotherContainer() {
        let group = FinderTrashFocusNode(role: "AXGroup", modal: false, selectedChildrenCount: 1)
        let scroll = FinderTrashFocusNode(role: "AXScrollArea", modal: false)
        let app = FinderTrashFocusNode(role: "AXApplication", modal: false)
        XCTAssertFalse(FinderTrashFocusPolicy.allows([group, scroll, window, app], reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows([group, group, scroll, app], reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows([group, app], reachesFinderRoot: true))
        XCTAssertFalse(FinderTrashFocusPolicy.allows([group, window, app], reachesFinderRoot: true))
    }

    func testSelectedDesktopGroupStillRejectsEditingModalAndSpecialSubroles() {
        let path = [FinderTrashFocusNode(role: "AXGroup", modal: false, selectedChildrenCount: 1),
                    FinderTrashFocusNode(role: "AXScrollArea", modal: false),
                    FinderTrashFocusNode(role: "AXApplication", modal: false)]
        for index in path.indices {
            var editing = path
            editing[index].editable = true
            XCTAssertFalse(FinderTrashFocusPolicy.allows(editing, reachesFinderRoot: true))
            for modal in [nil, true] as [Bool?] {
                var dialog = path
                dialog[index].modal = modal
                XCTAssertFalse(FinderTrashFocusPolicy.allows(dialog, reachesFinderRoot: true))
            }
            var special = path
            special[index].subrole = "AXSearchField"
            XCTAssertFalse(FinderTrashFocusPolicy.allows(special, reachesFinderRoot: true))
        }
        var disguised = path
        disguised[0].subrole = "AXCollectionList"
        XCTAssertFalse(FinderTrashFocusPolicy.allows(disguised, reachesFinderRoot: true))
    }
}
