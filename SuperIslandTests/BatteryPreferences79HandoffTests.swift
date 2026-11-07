import XCTest
import Darwin
@testable import SuperIsland

final class BatteryPreferences79HandoffTests: XCTestCase {
    func testFenceRetriesTimeoutWithANewCompleteList() throws {
        var clock: Double = 0, lists = 0, seen: [pid_t] = []
        try BatteryPreferencesProcessFence.check(caller: 99, processIDs: {
            lists += 1; return lists == 1 ? [10, 11] : [10, 11, 12]
        }, observe: { pid in
            seen.append(pid)
            if lists == 1 { clock = 1.01 }
            return .path("/usr/bin/unrelated")
        }, now: { clock })
        XCTAssertEqual(lists, 2); XCTAssertEqual(seen, [10, 10, 11, 12])
    }
    func testFenceRejectsWorkerAppearingInFreshRetryList() {
        var clock: Double = 0, lists = 0
        XCTAssertThrowsError(try BatteryPreferencesProcessFence.check(caller: 99, processIDs: {
            lists += 1; return lists == 1 ? [10] : [10, 12]
        }, observe: { pid in
            if lists == 1 { clock = 1.01 }
            return .path(pid == 12 ? "/private/cache/BatteryManagementHelper" : "/usr/bin/unrelated")
        }, now: { clock }))
        XCTAssertEqual(lists, 2)
    }
    func testFenceNeverRetriesUnknownIdentityOrKnownWorker() {
        for result in [BatteryHandoffProcessIdentity.PathResolution.unresolved("unknown"),
                       .path("/private/com.workview.SuperIsland.BatteryManagementHelper/read-workers/hash/worker")] {
            var lists = 0
            XCTAssertThrowsError(try BatteryPreferencesProcessFence.check(caller: 99, processIDs: {
                lists += 1; return [10]
            }, observe: { _ in result }, now: { 0 }))
            XCTAssertEqual(lists, 1)
        }
    }
    func testFenceLastSlowProcessCannotBeAcceptedAndRetriesAreBounded() {
        var clock: Double = 0, lists = 0, reads = 0
        XCTAssertThrowsError(try BatteryPreferencesProcessFence.check(caller: 99, processIDs: {
            lists += 1; return [10]
        }, observe: { _ in
            reads += 1; clock += 1.01; return .exited
        }, now: { clock }))
        XCTAssertEqual(lists, 2); XCTAssertEqual(reads, 2)
    }
    func testFenceOverallDeadlineCannotStartASecondScan() {
        var clock: Double = 0, lists = 0
        XCTAssertThrowsError(try BatteryPreferencesProcessFence.check(caller: 99, processIDs: {
            lists += 1; return [10]
        }, observe: { _ in clock += 3.01; return .unrelatedSigned }, now: { clock }))
        XCTAssertEqual(lists, 1)
    }
    func testFenceRejectsClockFailureAndIncompleteList() {
        var clock: Double = 2
        XCTAssertThrowsError(try BatteryPreferencesProcessFence.check(caller: 99, processIDs: { [10] },
            observe: { _ in clock = 1; return .exited }, now: { clock }))
        XCTAssertThrowsError(try BatteryPreferencesProcessFence.check(caller: 99, processIDs: { [] },
            observe: { _ in XCTFail(); return .exited }, now: { 0 }))
        XCTAssertThrowsError(try BatteryPreferencesProcessFence.check(caller: 99, processIDs: { [10] },
            observe: { _ in XCTFail(); return .exited }, now: { .nan }))
    }
    func testOnlyStableKernelZombieCanBeExcludedAsExited() {
        let value = BatteryHandoffProcessIdentity.ExitedProcess(pid: 12, birthSeconds: 50,
            birthMicroseconds: 20, uid: 501, status: SZOMB)
        XCTAssertTrue(BatteryHandoffProcessIdentity.confirmsSameExitedProcess(before: value, after: value))
        var variants = [BatteryHandoffProcessIdentity.ExitedProcess]()
        var other = value; other.pid += 1; variants.append(other)
        other = value; other.birthSeconds += 1; variants.append(other)
        other = value; other.birthMicroseconds += 1; variants.append(other)
        other = value; other.uid = 0; variants.append(other)
        other = value; other.status = SRUN; variants.append(other)
        for other in variants {
            XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsSameExitedProcess(before: value, after: other))
        }
        for status in [SRUN, SSLEEP, SSTOP, SIDL, 0] {
            other = value; other.status = status
            XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsSameExitedProcess(before: other, after: other))
        }
        other = value; other.birthSeconds = 0
        XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsSameExitedProcess(before: other, after: other))
        other = value; other.birthMicroseconds = -1
        XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsSameExitedProcess(before: other, after: other))
        other = value; other.birthMicroseconds = 1_000_000
        XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsSameExitedProcess(before: other, after: other))
        XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsExitedProcess(pid: getpid()))
        XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsExitedProcess(pid: 0))
        XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsExitedProcess(pid: 1))
    }
    func testActualUnreapedChildIsExitedEvenThoughKillZeroSucceeds() throws {
        var pid: pid_t = 0
        var arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { free(arguments[0]) }
        XCTAssertEqual(posix_spawn(&pid, arguments[0]!, nil, nil, &arguments, &environment), 0)
        guard pid > 1 else { return XCTFail("Test child was not created") }
        defer { var status: Int32 = 0; while waitpid(pid, &status, 0) == -1 && errno == EINTR {} }
        var exited = false
        for _ in 0..<200 {
            if BatteryHandoffProcessIdentity.confirmsExitedProcess(pid: pid) { exited = true; break }
            usleep(5000)
        }
        XCTAssertTrue(exited, "The unreaped /usr/bin/true child must be observed as SZOMB")
        XCTAssertEqual(kill(pid, 0), 0, "Existence does not prove the process can still execute")
        var path = [CChar](repeating: 0, count: 4096)
        XCTAssertLessThanOrEqual(proc_pidpath(pid, &path, UInt32(path.count)), 0)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsUnrelatedMissingPath(pid: pid),
            "The old signed-live-process fallback alone cannot recognize this exit")
    }
    func testConfirmedAbsenceAndZombieReapingButNeverUnknownOrPIDReuse() {
        let zombie = BatteryHandoffProcessIdentity.ExitedProcess(pid: 42, birthSeconds: 50,
            birthMicroseconds: 20, uid: 501, status: SZOMB)
        typealias State = BatteryHandoffProcessIdentity.Lifecycle
        let z = State.process(zombie)
        var live = zombie; live.status = SRUN
        var reused = zombie; reused.birthSeconds += 1
        XCTAssertTrue(BatteryHandoffProcessIdentity.confirmsExit(before: .absent, after: .absent))
        XCTAssertTrue(BatteryHandoffProcessIdentity.confirmsExit(before: z, after: .absent))
        for pair: (State, State) in [(.unknown, .absent), (.absent, .unknown), (z, .unknown),
            (.process(live), .absent), (.absent, .process(live)), (z, .process(reused)), (.absent, z)] {
            XCTAssertFalse(BatteryHandoffProcessIdentity.confirmsExit(before: pair.0, after: pair.1))
        }
    }
    func testActualReapedChildIsPositivelyAbsent() throws {
        var pid: pid_t = 0
        var args: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        var env: [UnsafeMutablePointer<CChar>?] = [nil]
        defer { free(args[0]) }
        XCTAssertEqual(posix_spawn(&pid, args[0]!, nil, nil, &args, &env), 0)
        guard pid > 1 else { return XCTFail("No child") }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        XCTAssertEqual(BatteryHandoffProcessIdentity.lifecycle(pid: pid), .absent)
        XCTAssertTrue(BatteryHandoffProcessIdentity.confirmsExitedProcess(pid: pid))
    }
    func testTransientUnknownIsResampledButNeverAcceptedAsAbsence() {
        typealias Result = BatteryHandoffProcessIdentity.PathResolution
        for accepted: Result in [.exited, .path("/tmp/BatteryManagementHelper"), .unrelatedSigned] {
            var samples = [Result.unresolved("racing"), accepted], pauses = 0
            XCTAssertEqual(BatteryHandoffProcessIdentity.resolvePath(observe: { samples.removeFirst() },
                pause: { pauses += 1 }), accepted)
            XCTAssertEqual(pauses, 1)
        }
        var reads = 0, pauses = 0
        XCTAssertEqual(BatteryHandoffProcessIdentity.resolvePath(observe: {
            reads += 1; return .unresolved("live-unknown")
        }, pause: { pauses += 1 }), .unresolved("live-unknown;live-unknown;live-unknown"))
        XCTAssertEqual(reads, 3); XCTAssertEqual(pauses, 2)
        XCTAssertEqual(BatteryHandoffProcessIdentity.resolvePath(attempts: 0, observe: {
            XCTFail("Invalid bounds must not sample"); return .exited
        }), .unresolved("invalid-attempts"))
    }
    func testCurrentLiveProcessRetainsItsPathForWorkerFence() {
        guard case .path(let path) = BatteryHandoffProcessIdentity.observePath(pid: getpid()) else {
            return XCTFail("The test process must not be classified as exited")
        }
        XCTAssertFalse(path.isEmpty)
    }
    private func unrelatedProcess() -> BatteryHandoffProcessIdentity.Snapshot {
        .init(pid: 12, birthSeconds: 50, birthMicroseconds: 20, uid: 501,
              flags: 1, identifier: "io.example.editor", team: "ABCDE12345", hash: Data(repeating: 7, count: 20))
    }
    func testMissingPathRequiresStableKernelIdentity() {
        let value = unrelatedProcess()
        XCTAssertTrue(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: value))
        var variants = [BatteryHandoffProcessIdentity.Snapshot]()
        var changed = value; changed.pid += 1; variants.append(changed)
        changed = value; changed.birthSeconds += 1; variants.append(changed)
        changed = value; changed.birthMicroseconds += 1; variants.append(changed)
        changed = value; changed.uid = 0; variants.append(changed)
        changed = value; changed.hash[0] = 8; variants.append(changed)
        changed = value; changed.identifier = "io.example.other"; variants.append(changed)
        changed = value; changed.team = "OTHER12345"; variants.append(changed)
        changed = value; changed.flags = 0; variants.append(changed)
        for other in variants {
            XCTAssertFalse(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: other))
        }
    }
    func testSignedExecutableIdentifierDoesNotRequireReverseDNS() {
        for identifier in ["extension-host", "signed-tool", "plain_identifier"] {
            var value = unrelatedProcess(); value.identifier = identifier
            XCTAssertTrue(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: value), identifier)
            var changed = value; changed.hash[0] ^= 1
            XCTAssertFalse(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: changed))
            changed = value; changed.birthMicroseconds += 1
            XCTAssertFalse(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: changed))
            value.flags = 3
            XCTAssertFalse(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: value))
            value.flags = 1; value.team = ""
            XCTAssertFalse(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: value))
        }
    }
    func testMissingPathRejectsHelpersControllersAndUnprovenSignatures() {
        var invalid = [BatteryHandoffProcessIdentity.Snapshot]()
        for id in ["com.workview.SuperIsland.BatteryManagementHelper", "com.workview.SuperIsland.BM1Debug",
                   "com.vendor.BatteryController", "com.apphousekitchen.AlDente", "BatteryManagementHelper",
                   "AlDente", "BatFi", "Ampere", "com.vendor.batfi", "com.vendor.ampere", "", "io.bad\nname"] {
            var v = unrelatedProcess(); v.identifier = id; invalid.append(v)
        }
        for team in ["", "too-short", "abcdE12345", "ABCDE1234\0"] {
            var v = unrelatedProcess(); v.team = team; invalid.append(v)
        }
        for flags: UInt32 in [0, 2, 3] { var v = unrelatedProcess(); v.flags = flags; invalid.append(v) }
        var v = unrelatedProcess(); v.hash = Data(); invalid.append(v)
        v = unrelatedProcess(); v.hash = Data(repeating: 0, count: 20); invalid.append(v)
        v = unrelatedProcess(); v.birthSeconds = 0; invalid.append(v)
        v = unrelatedProcess(); v.birthMicroseconds = 1_000_000; invalid.append(v)
        v = unrelatedProcess(); v.pid = 1; invalid.append(v)
        for value in invalid {
            XCTAssertFalse(BatteryHandoffProcessIdentity.allowsMissingPath(before: value, after: value))
        }
    }
    func testKernelIdentityBlobRejectsTruncationAndEmbeddedNulls() throws {
        func blob(_ bytes: [UInt8]) -> Data {
            let length = UInt32(8 + bytes.count)
            return Data([0, 0, 0, 0, UInt8(length >> 24), UInt8((length >> 16) & 255),
                         UInt8((length >> 8) & 255), UInt8(length & 255)] + bytes)
        }
        let valid = blob(Array("io.example.editor".utf8) + [0])
        XCTAssertEqual(try BatteryHandoffProcessIdentity.decodeKernelString(valid), "io.example.editor")
        for value in [Data(), valid.dropLast(), blob([0]), blob([97, 0, 98, 0]), blob([255, 0]), blob([97, 98])] {
            XCTAssertThrowsError(try BatteryHandoffProcessIdentity.decodeKernelString(Data(value)))
        }
        var oversized = valid; oversized[4] = 127
        XCTAssertThrowsError(try BatteryHandoffProcessIdentity.decodeKernelString(oversized))
    }
    private typealias H = BatteryPreferences79Handoff
    private typealias T = BatteryPreferences79Transaction
    private let wall = Date(timeIntervalSince1970: 1_000)

    private func fixture() throws -> (T.Record, H.Snapshot) {
        var values: [T.Key: T.Value] = [.checkpoint: .integer(2), .currentState: .integer(1),
            .mclLimitValue: .integer(80), .mclFeatureState: .integer(1),
            .initialChargeLimitSetDate: .real(100), .modeOfOperation: .integer(7)]
        let observation = T.Observation(nativeLimit: 80, nativeEnabled: 1, registrations: [80], level: 80,
            adapterPresent: true, batteryCurrent: 0, adapterPower: 20, wallDate: wall)
        let t = try T(read: { values[$0] ?? .absent }, write: { values[$0] = $1 }, save: { _ in },
                      signal: {}, inspect: { observation }, continuousNow: { 10 })
        try t.prepare(owner: UUID(), bootID: "boot", now: 10, observation: observation)
        try t.apply(bootID: "boot", now: 10)
        var record = t.record!
        // A failed observation followed by a rejected restoration can retain
        // both flags, even though every earlier child acknowledged its write.
        record.phase = .restoring; record.observationPending = true; record.mutationOutcomeUnknown = true
        values[.mclLimitValue] = .integer(85)
        return (record, .init(values: Dictionary(uniqueKeysWithValues: T.Key.allCases.map { ($0, values[$0] ?? .absent) }),
                             registrations: [85, 85], level: 85, onAC: true, current: 0, updateTime: wall, readAt: wall))
    }
    private func sample(_ base: H.Snapshot, at: Double, updated: Double = 0) -> H.Snapshot {
        var s = base; s.readAt = wall.addingTimeInterval(at); s.updateTime = wall.addingTimeInterval(updated); return s
    }
    private func ready() throws -> H.Receipt {
        let (r, s) = try fixture(); var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
        for time in [0.0, 4, 8, 12] { XCTAssertFalse(try h.observe(sample(s, at: time), now: time)) }
        XCTAssertTrue(try h.observe(sample(s, at: 16, updated: 16), now: 16))
        return try h.receipt()
    }
    func testExplicit85PreservesCompleteTypedRecordAndIsNotRestoration() throws {
        let receipt = try ready()
        XCTAssertEqual(receipt.disposition, "review-ended-preserving-external-85")
        XCTAssertEqual(receipt.policyTransferred, false)
        XCTAssertTrue(receipt.record.mutationOutcomeUnknown)
        XCTAssertEqual(receipt.record.entries.first { $0.key == .isEngaged }?.original, .absent)
        XCTAssertEqual(receipt.last.values[.mclLimitValue], .integer(85))
        XCTAssertEqual(receipt.first.values, receipt.last.values)
    }
    func testWrongOwnerAndMalformedRecordReject() throws {
        let (r, _) = try fixture()
        XCTAssertThrowsError(try H(record: r, owner: UUID(), wall: wall, now: 0))
        var bad = r; bad.entries.removeLast()
        XCTAssertThrowsError(try H(record: bad, owner: r.owner, wall: wall, now: 0))
        XCTAssertThrowsError(try H(record: r, owner: r.owner, wall: wall, now: .nan))
    }
    func test85AloneAndDuplicateBatteryUpdatesCannotAuthorizeCleanup() throws {
        let (r, s) = try fixture(); var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
        for time in stride(from: 0.0, through: 20, by: 4) { XCTAssertFalse(try h.observe(sample(s, at: time), now: time)) }
        XCTAssertThrowsError(try h.receipt())
    }
    func testStaleContextCannotBecomeFreshJustByPolling() throws {
        let (r, s) = try fixture(); var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
        for time in stride(from: 0.0, through: 24, by: 4) {
            XCTAssertFalse(try h.observe(sample(s, at: time, updated: -1), now: time))
        }
        XCTAssertThrowsError(try h.receipt())
    }
    func testPollGapRequiresNewStableSegmentAndAnotherDistinctUpdate() throws {
        let (r, s) = try fixture(); var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
        for time in [0.0, 4, 8] { XCTAssertFalse(try h.observe(sample(s, at: time), now: time)) }
        XCTAssertFalse(try h.observe(sample(s, at: 20, updated: 20), now: 20))
        for time in [24.0, 28, 32, 36] { XCTAssertFalse(try h.observe(sample(s, at: time, updated: 20), now: time)) }
        XCTAssertTrue(try h.observe(sample(s, at: 40, updated: 40), now: 40))
    }
    func testTargetGuardFlagsOverridesAndIncompleteValuesReject() throws {
        let changes: [(T.Key, T.Value)] = [(.mclLimitValue, .integer(80)), (.mclLimitValue, .integer(79)),
            (.mclLimitValue, .integer(86)), (.mclLimitValue, .bool(true)), (.mclFeatureState, .bool(false)),
            (.isEngaged, .integer(0)), (.isManuallyChargeLimited, .string("1")), (.modeOfOperation, .integer(5)),
            (.disabledUntil, .real(0)), (.mclTempDisabledUntilDate, .real(0)), (.initialChargeLimitSetDate, .real(101))]
        for (key, value) in changes {
            let (r, base) = try fixture(); var s = base; s.values[key] = value
            var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
            XCTAssertThrowsError(try h.observe(s, now: 0), key.rawValue)
            XCTAssertThrowsError(try h.receipt())
        }
        let (r, base) = try fixture(); var s = base; s.values.removeValue(forKey: .checkpoint)
        var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
        XCTAssertThrowsError(try h.observe(s, now: 0))
    }
    func testNewValueIsPreservedByRejectingEvenSameNumericTypeDrift() throws {
        let (r, s) = try fixture(); var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
        XCTAssertFalse(try h.observe(s, now: 0))
        var changed = sample(s, at: 4); changed.values[.mclLimitValue] = .real(85)
        XCTAssertThrowsError(try h.observe(changed, now: 4))
        XCTAssertThrowsError(try h.observe(sample(s, at: 8, updated: 8), now: 8), "Failure is terminal")
    }
    func testUnknownSupplyDischargeForeignRegistrationAndOutOfRangeLevelReject() throws {
        let changes: [(inout H.Snapshot) -> Void] = [
            { $0.onAC = false }, { $0.current = -.infinity }, { $0.current = -0.051 },
            { $0.registrations = [] }, { $0.registrations = [79, 85] }, { $0.level = 78 }, { $0.level = 86 }]
        for change in changes {
            let (r, base) = try fixture(); var s = base; change(&s)
            var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
            XCTAssertThrowsError(try h.observe(s, now: 0))
        }
    }
    func testClockRollbackWallJumpFutureContextAndExpiryReject() throws {
        for (time, read, update) in [(-1.0, 0.0, 0.0), (4, 10, 0), (4, 4, 7), (180, 180, 180)] {
            let (r, s) = try fixture(); var h = try H(record: r, owner: r.owner, wall: wall, now: 0)
            XCTAssertFalse(try h.observe(s, now: 0))
            let result = { try h.observe(self.sample(s, at: read, updated: update), now: time) }
            if update == 7 { XCTAssertFalse(try result()); XCTAssertThrowsError(try h.receipt()) }
            else { XCTAssertThrowsError(try result()) }
        }
    }
    func testAnyOldHelperOrProtectedWorkerBlocksProcessFence() {
        XCTAssertFalse(BatteryPreferences79HandoffRead.processAllowsHandoff(path: "", pid: 2, ownPID: 3))
        XCTAssertFalse(BatteryPreferences79HandoffRead.processAllowsHandoff(path: "Contents/MacOS/helper", pid: 2, ownPID: 3))
        XCTAssertFalse(BatteryPreferences79HandoffRead.processAllowsHandoff(path: "/Applications/Old.app/Contents/MacOS/BatteryManagementHelper", pid: 2, ownPID: 3))
        XCTAssertFalse(BatteryPreferences79HandoffRead.processAllowsHandoff(path: "/private/var/root/Library/Caches/com.workview.SuperIsland.BatteryManagementHelper/read-workers/old/hash", pid: 2, ownPID: 3))
        XCTAssertTrue(BatteryPreferences79HandoffRead.processAllowsHandoff(path: "/Applications/Review.app/Contents/MacOS/BatteryManagementHelper", pid: 3, ownPID: 3))
        XCTAssertTrue(BatteryPreferences79HandoffRead.processAllowsHandoff(path: "/usr/bin/pmset", pid: 2, ownPID: 3))
    }
    private func directory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Handoff85-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testArchiveIsDurableBeforePendingLeavesAreRemoved() throws {
        let receipt = try ready(), dir = try directory()
        let store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        let data = try JSONEncoder().encode(receipt.record); try store.save(data)
        var confirmed = false
        try store.finishHandoff85(expected: data, receipt: receipt, confirm: { _ in
            XCTAssertEqual(try store.load(), data)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("handoff85-") })
            confirmed = true
        })
        XCTAssertTrue(confirmed); XCTAssertNil(try store.load())
        let archive = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("handoff85-") }!
        let saved = try JSONDecoder().decode(H.Receipt.self, from: Data(contentsOf: archive))
        XCTAssertEqual(saved.record, receipt.record); XCTAssertEqual(saved.last.values[.mclLimitValue], .integer(85))
    }
    func testArchiveSyncOrFinalRecheckFailureKeepsResponsibility() throws {
        enum Failure: Error { case injected }
        for failSync in [false, true] {
            let receipt = try ready(), dir = try directory(); var fail = false
            let store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true,
                directorySync: { if fail { throw Failure.injected } })
            let data = try JSONEncoder().encode(receipt.record); try store.save(data); fail = failSync
            XCTAssertThrowsError(try store.finishHandoff85(expected: data, receipt: receipt, confirm: { _ in throw Failure.injected }))
            XCTAssertEqual(try store.load(), data)
        }
    }
    func testChangedOrMissingJournalCannotBeClearedByOldReceipt() throws {
        let receipt = try ready(), dir = try directory()
        let store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        let old = try JSONEncoder().encode(receipt.record)
        XCTAssertThrowsError(try store.finishHandoff85(expected: old, receipt: receipt, confirm: { _ in XCTFail() }))
        var changed = receipt.record; changed.owner = UUID()
        let new = try JSONEncoder().encode(changed); try store.save(new)
        XCTAssertThrowsError(try store.finishHandoff85(expected: old, receipt: receipt, confirm: { _ in XCTFail() }))
        XCTAssertEqual(try store.load(), new)
    }
    func testPolicyTransferOrOtherDispositionCannotClearReviewResponsibility() throws {
        let receipt = try ready(), dir = try directory()
        let store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true)
        let data = try JSONEncoder().encode(receipt.record); try store.save(data)
        for variant in 0...2 {
            var invalid = receipt
            if variant == 0 { invalid.policyTransferred = true }
            else if variant == 1 { invalid.policyTransferred = nil }
            else { invalid.disposition = "adopt-system-target" }
            XCTAssertThrowsError(try store.finishHandoff85(expected: data, receipt: invalid, confirm: { _ in XCTFail() }))
            XCTAssertEqual(try store.load(), data)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("handoff85-") })
    }
    func testCleanupSyncFailureRetainsArchiveAndPendingBackupUntilRetry() throws {
        enum Failure: Error { case injected }
        let receipt = try ready(), dir = try directory(); var calls = 0, failAt = Int.max
        let store = try BatteryPreferences79JournalStore(testDirectory: dir, mutating: true, directorySync: {
            calls += 1; if calls == failAt { throw Failure.injected }
        })
        let data = try JSONEncoder().encode(receipt.record); try store.save(data)
        failAt = calls + 3 // Archive, backup, then journal deletion fsync fails.
        XCTAssertThrowsError(try store.finishHandoff85(expected: data, receipt: receipt, confirm: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("journal.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cleanup-backup.json").path))
        XCTAssertEqual(try store.load(), data)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("handoff85-") })
        failAt = Int.max
        try store.finishHandoff85(expected: data, receipt: receipt, confirm: { _ in })
        XCTAssertNil(try store.load())
    }
}
