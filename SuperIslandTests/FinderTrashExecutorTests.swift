import XCTest
import ApplicationServices
@testable import SuperIsland

final class FinderTrashExecutorTests: XCTestCase {
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
