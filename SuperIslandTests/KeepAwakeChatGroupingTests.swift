import AppKit
import XCTest
import SQLite3
@testable import SuperIsland

final class KeepAwakeChatGroupingTests: XCTestCase {
    typealias G = KeepAwakeChatGrouping
    typealias R = KeepAwakeRecap
    func h(_ value: String) -> String { KeepAwakeHookContract.anonymousIdentity(value) }
    func task(_ session: String, turn: String = "1", root: String = "main", source: String = "codex-desktop", scope: String = "profile", state: R.State = .completed, runtime: G.Runtime = .idle, rootRuntime: G.Runtime = .idle, kind: R.Kind = .user, ordinal: Int = 1, at: Double = 5) -> R.Task {
        .init(id: h(session+turn+source+scope), source: source, kind: kind, state: state, ordinal: ordinal, changedAt: 5,
              chat: .init(scope: h(scope), session: h(session), root: h(root), parent: session == root ? nil : h(root), sessionRuntime: runtime, rootRuntime: rootRuntime, observedAt: at))
    }
    func group(_ tasks: [R.Task]) throws -> G.Group { try XCTUnwrap(G.project(tasks).groups.first) }
    func testRootRunningSurvivesThreeCompletedChildrenAndIsNotThreeChats() throws {
        let tasks = [task("a", rootRuntime:.running), task("b", rootRuntime:.running, ordinal:2), task("c", rootRuntime:.running, ordinal:3)]
        let p=G.project(tasks);XCTAssertEqual(p.groups.count,1);XCTAssertEqual(p.groups[0].children.count,3)
        XCTAssertEqual(p.groups[0].state,.running);XCTAssertTrue(tasks.allSatisfy { $0.state == .completed })
    }
    func testNewRoundOverridesOldCompletedButDoesNotDuplicateChild() throws {
        let tasks=[task("a"),task("a",turn:"2",state:.running,runtime:.running,ordinal:2,at:6)]
        let g=try group(tasks);XCTAssertEqual(g.children.count,1);XCTAssertEqual(g.children[0].tasks.count,2);XCTAssertEqual(g.state,.running)
        XCTAssertEqual(g.children[0].tasks.map(\.state),[.completed,.running])
    }
    func testOpenAndCompletedRoundCannotInventRuntimeOrWholeCompletion() throws {
        let t=task("child",runtime:.unknown,rootRuntime:.unknown)
        XCTAssertEqual(try group([t]).state,.unknown);XCTAssertEqual(try group([t]).children[0].runtime,.unknown)
        XCTAssertEqual(G.roundTitle(.completed),"本轮已完成")
    }
    func testFreshRuntimeDoesNotInheritOldCompletedRound() throws {
        XCTAssertEqual(try group([task("child",runtime:.running)]).state,.running)
        XCTAssertEqual(try group([task("child",runtime:.waiting)]).state,.waiting)
    }
    func testRootIdleDoesNotHideWaitingOrUnknownChild() throws {
        XCTAssertEqual(try group([task("a",state:.waiting,runtime:.waiting)]).state,.waiting)
        XCTAssertEqual(try group([task("a",state:.unknown,runtime:.unknown)]).state,.unknown)
        let running=try group([task("a",state:.running,runtime:.running),task("b",runtime:.unknown,ordinal:2)])
        XCTAssertEqual(running.state,.running);XCTAssertTrue(running.hasUnknownMembers)
    }
    func testKnownIdleAndEveryRoundTerminalMeansThisExecutionEndedNotSuccess() throws {
        let g=try group([task("a"),task("b",state:.failed,ordinal:2),task("c",state:.cancelled,ordinal:3)])
        XCTAssertEqual(g.state,.ended);XCTAssertEqual(g.tasks.map(\.state),[.completed,.failed,.cancelled])
        XCTAssertEqual(g.state.title,"本次执行已结束")
    }
    func testRootSourceScopeAndClassificationCannotSilentlyMerge() throws {
        let rows=[task("a"),task("b",root:"different",ordinal:2),task("a",source:"codex-cli",ordinal:3),task("a",scope:"other-profile",ordinal:4)]
        XCTAssertEqual(G.project(rows).groups.count,4)
        let mixed=try group([task("a"),task("b",kind:.unclassified,ordinal:2)])
        XCTAssertEqual(mixed.kind,.unclassified)
        var legacy=task("legacy");legacy.chat=nil
        XCTAssertEqual(G.project([legacy]).unassigned.count,1)
    }
    func testConflictingCurrentRuntimeEvidenceAndInvalidHashesFailClosed() throws {
        let a=task("a",rootRuntime:.idle),b=task("b",rootRuntime:.running,ordinal:2)
        XCTAssertEqual(try group([a,b]).rootRuntime,.unknown)
        var broken=a;broken.chat?.scope="bad";XCTAssertTrue(G.project([broken]).groups.isEmpty)
        var selfParent=a;let selfSession=selfParent.chat?.session;selfParent.chat?.parent=selfSession;XCTAssertFalse(selfParent.chat!.valid)
    }
    func testTitlesOnlyInMemoryOldSummaryStillLoadsAndOpenSnapshotIsFrozen() throws {
        func frame(_ n: Double,_ closed: Bool,_ tasks:[R.TaskInput],titles:[String:String]=[:])->R.Frame {
            .init(stamp:.init(continuous:n,awake:n,wall:1000+n),notebook:true,closed:closed,enabled:true,actualHold:true,lidRequired:true,lidApplied:true,released:false,protection:false,error:false,automatic:true,tasks:tasks,chatTitles:titles)
        }
        let t=task("child",state:.running,runtime:.running,rootRuntime:.running)
        let input=R.TaskInput(id:t.id,source:t.source,kind:t.kind,state:t.state,started:true,chat:t.chat)
        var r=R();r.observe(frame(0,false,[]));r.observe(frame(1,true,[input],titles:[t.chat!.titleKey:"PRIVATE TITLE NOT FOR DISK"]))
        r.observe(frame(2,false,[]));let before=try XCTUnwrap(r.latest)
        XCTAssertEqual(before.displayTitles[t.chat!.titleKey],"PRIVATE TITLE NOT FOR DISK")
        var after=input;after.state = .completed;r.observe(frame(3,false,[after]));XCTAssertEqual(r.latest,before)
        let data=try JSONEncoder().encode(r);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("PRIVATE TITLE"))
        let restored=try JSONDecoder().decode(R.self,from:data);XCTAssertTrue(restored.latest!.displayTitles.isEmpty)
        XCTAssertEqual(restored.latest!.tasks[0].chat,t.chat);XCTAssertTrue(restored.validate())
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any]);var cycle=object["latest"] as! [String:Any]
        var tasks=cycle["tasks"] as! [[String:Any]];tasks[0].removeValue(forKey:"chat");cycle["tasks"]=tasks;object["latest"]=cycle
        let old=try JSONDecoder().decode(R.self,from:JSONSerialization.data(withJSONObject:object));XCTAssertTrue(old.validate());XCTAssertNil(old.latest!.tasks[0].chat)
        r.redactChatTitles();XCTAssertTrue(r.latest!.displayTitles.isEmpty)
    }
    func testSafeTitleRejectsControlsBidiAndOversize() {
        XCTAssertNil(G.safeTitle("\n "));XCTAssertNil(G.safeTitle("abc\u{202e}xyz"));XCTAssertNil(G.safeTitle(String(repeating:"大",count:200)))
        XCTAssertEqual(G.safeTitle("  主聊天  "),"主聊天")
    }
    @MainActor func testNativeGroupedPanelRendersBothAppearancesWithoutActivatingUserApps() async throws {
        let rows=[task("child",rootRuntime:.running), task("child",turn:"2",state:.running,runtime:.running,rootRuntime:.running,ordinal:2,at:6)]
        let g=try group(rows)
        var cycle=R.Cycle(start:.init(continuous:1,awake:1,wall:1001),end:.init(continuous:20,awake:20,wall:1020),last:.init(continuous:20,awake:20,wall:1020),autoEligible:false)
        cycle.tasks=rows;cycle.displayTitles[g.titleKey]="示例主聊天";cycle.power = .holding
        let output=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/ChatGroupingRepair.noindex/NativeViews")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            let panel=KeepAwakeRecapPanel(summary:cycle,autoShow:true,editable:false,toggle:{_ in false})
            panel.presentation.expandedChats=[g.id];panel.presentation.expandedMembers=[g.id+":"+h("child")]
            panel.panel.appearance=NSAppearance(named:appearance)
            let view=try XCTUnwrap(panel.panel.contentView)
            view.layoutSubtreeIfNeeded();try? await Task.sleep(nanoseconds:50_000_000);view.layoutSubtreeIfNeeded()
            let bitmap=try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:output.appendingPathComponent(appearance.rawValue+".png"))
            XCTAssertEqual(panel.panel.frame.width,300);XCTAssertTrue(panel.panel.isOpaque);XCTAssertFalse(panel.panel.isVisible)
            XCTAssertEqual(panel.presentation.summary.chatProjection.groups[0].state,.running)
        }
    }
    func fixture(_ sql: String) throws -> URL {
        // SQLite NOFOLLOW rejects /var itself, a macOS symlink. Foundation's
        // resolvingSymlinksInPath normalizes it back; retain the physical path.
        let temporary = FileManager.default.temporaryDirectory.path
        let physical = temporary.hasPrefix("/var/") ? "/private" + temporary : temporary
        let dir=URL(fileURLWithPath:physical).appendingPathComponent("KA2Hierarchy-"+UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:dir) }
        let url=dir.appendingPathComponent("state_5.sqlite");var db:OpaquePointer?;XCTAssertEqual(sqlite3_open(url.path,&db),SQLITE_OK);defer{sqlite3_close(db)}
        let schema="CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,attached_thread_parent_id TEXT,secret TEXT);CREATE TABLE thread_spawn_edges(parent_thread_id TEXT,child_thread_id TEXT,status TEXT);"
        XCTAssertEqual(sqlite3_exec(db,schema+sql,nil,nil,nil),SQLITE_OK);return url
    }
    func testReaderResolvesNestedParentsEmptyChildTitleAndOpenAvailabilityOnly() throws {
        let db=try fixture("INSERT INTO threads VALUES('root','主聊天',NULL,'NO READ'),('child','',NULL,'NO READ'),('grand','',NULL,'NO READ'),('unrelated','PRIVATE UNRELATED',NULL,'NO READ');INSERT INTO thread_spawn_edges VALUES('root','child','open'),('child','grand','open');")
        let result=KeepAwakeCodexChatMetadata.read(database:db,sessions:[h("grand"),h("child")])
        XCTAssertEqual(result.nodes.count,2);XCTAssertEqual(result.nodes[h("grand")]?.root,h("root"));XCTAssertEqual(result.nodes[h("grand")]?.parent,h("child"))
        XCTAssertNil(result.nodes[h("child")]?.title);XCTAssertEqual(result.titles,[h("root"):"主聊天"])
        XCTAssertNil(result.nodes[h("unrelated")]);XCTAssertFalse(result.titles.values.contains("PRIVATE UNRELATED"))
    }
    func testReaderConflictCycleMissingParentAndUnknownStatusDoNotResolve() throws {
        let db=try fixture("INSERT INTO threads VALUES('a','a','b',NULL),('b','b','a',NULL),('missing','x','absent',NULL),('conflict','c','a',NULL),('unknown','u',NULL,NULL);INSERT INTO thread_spawn_edges VALUES('b','conflict','open'),('a','unknown','new-unsupported-status');")
        XCTAssertTrue(KeepAwakeCodexChatMetadata.read(database:db,sessions:Set(["a","b","missing","conflict","unknown"].map(h))).nodes.isEmpty)
    }
    func testReaderFailsClosedOnMultipleParentsSymlinkAndBudget() throws {
        let db=try fixture("INSERT INTO threads VALUES('root','root',NULL,NULL),('child','child',NULL,NULL);INSERT INTO thread_spawn_edges VALUES('root','child','open'),('other','child','closed');")
        XCTAssertTrue(KeepAwakeCodexChatMetadata.read(database:db,sessions:[h("child")]).nodes.isEmpty)
        XCTAssertTrue(KeepAwakeCodexChatMetadata.read(database:db,sessions:[h("root")],maximumInstructions:1).nodes.isEmpty)
        let link=db.deletingLastPathComponent().appendingPathComponent("link.sqlite");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:db)
        XCTAssertTrue(KeepAwakeCodexChatMetadata.read(database:link,sessions:[h("root")]).nodes.isEmpty)
    }
    func testReaderRejectsViewThatWouldReadUnapprovedColumns() throws {
        let db=try fixture("ALTER TABLE threads RENAME TO hidden;CREATE VIEW threads AS SELECT id,secret AS title,attached_thread_parent_id FROM hidden;INSERT INTO hidden VALUES('root','public',NULL,'DO NOT READ');")
        XCTAssertTrue(KeepAwakeCodexChatMetadata.read(database:db,sessions:[h("root")]).nodes.isEmpty)
    }
    func testOversizedAdmittedTitleDoesNotDiscardHierarchyOrHealthySibling() throws {
        let oversized = String(repeating: "x", count: 17_128)
        let db = try fixture("INSERT INTO threads VALUES('root','main',NULL,NULL),('long','\(oversized)','root',NULL),('healthy','healthy','root',NULL);")
        let result = KeepAwakeCodexChatMetadata.read(database: db, sessions: [h("long"), h("healthy")])
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes[h("long")]?.root, h("root"))
        XCTAssertEqual(result.nodes[h("healthy")]?.root, h("root"))
        XCTAssertNil(result.nodes[h("long")]?.title)
        XCTAssertEqual(result.nodes[h("healthy")]?.title, "healthy")
        XCTAssertEqual(result.rejectedTitleCount, 1)
        XCTAssertEqual(result.unresolvedCount, 0)
        XCTAssertEqual(result.quality, "complete")
        XCTAssertFalse(result.titles.values.contains(oversized))
    }
    func testLargeUnapprovedColumnNeverPoisonsApprovedProjection() throws {
        let db = try fixture("INSERT INTO threads VALUES('root','main',NULL,zeroblob(2000000)),('child','child','root',zeroblob(2000000)),('unrelated','private',NULL,zeroblob(2000000));")
        let result = KeepAwakeCodexChatMetadata.read(database: db, sessions: [h("child")])
        XCTAssertEqual(result.nodes[h("child")]?.root, h("root"))
        XCTAssertEqual(result.titles, [h("root"): "main"])
        XCTAssertNil(result.nodes[h("unrelated")])
    }
    func testMalformedMemberCannotEraseIndependentlyVerifiedSibling() throws {
        let db = try fixture("INSERT INTO threads VALUES('root','main',NULL,NULL),('healthy','child','root',NULL),('bad','child',zeroblob(1500),NULL);")
        let result = KeepAwakeCodexChatMetadata.read(database: db, sessions: [h("bad"), h("healthy")])
        XCTAssertNil(result.nodes[h("bad")])
        XCTAssertEqual(result.nodes[h("healthy")]?.root, h("root"))
        XCTAssertEqual(result.unresolvedCount, 1)
        XCTAssertEqual(result.quality, "partial")
        XCTAssertEqual(result.issue, .invalidMetadata)
    }

}
