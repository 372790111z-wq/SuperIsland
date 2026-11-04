import XCTest
import Darwin
@testable import SuperIsland

final class BatteryNativeReadTransportTests: XCTestCase {
    private let python = URL(fileURLWithPath: "/usr/bin/python3")
    private func runPython(_ code: String, _ arguments: [String] = [], timeout: TimeInterval = 0.4,
                           maximumOutput: Int = 4096) throws -> Data {
        try BatteryNativeReadProcess.run(executable: python, arguments: ["-c", code] + arguments,
                                        timeout: timeout, maximumOutput: maximumOutput)
    }
    func testEOFDoesNotStandInForRealChildExit() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let output = try runPython("import os,time;os.close(1);time.sleep(0.12)")
        XCTAssertTrue(output.isEmpty)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.12)
    }
    func testReplyDoesNotStandInForChildCleanupAndExit() throws {
        let code = "import os,time;os.write(1,b'{\"schema\":1,\"value\":80,\"phase\":\"reply\"}');time.sleep(5)"
        XCTAssertThrowsError(try runPython(code)) { error in
            let text = error.localizedDescription
            for field in ["超时", "phase=reply", "processFinished=false", "pipeFinished=false", "completionObserved=true"] {
                XCTAssertTrue(text.contains(field), text)
            }
        }
    }
    func testReapedDirectChildWithDescendantHoldingStdoutIsNeverSignalledAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BM1Descendant-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let code = "import os,sys,time\npid=os.fork()\nif pid:\n open(sys.argv[1],'w').write(str(pid));os._exit(0)\ntime.sleep(2);os._exit(0)"
        XCTAssertThrowsError(try runPython(code, [pidFile.path], timeout: 0.3)) { error in
            let text = error.localizedDescription
            for field in ["超时", "processFinished=true", "pipeFinished=false", "killResult=not-requested", "completionObserved=true"] {
                XCTAssertTrue(text.contains(field), text)
            }
        }
        let descendant = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        XCTAssertEqual(kill(descendant, 0), 0, "Only the direct child is owned; leave its descendant to finish naturally")
    }
    func testNonzeroAndSignalExitCannotBecomeSuccessfulReadbacks() {
        for code in ["import os;os.write(1,b'reply');os._exit(7)", "import os,signal;os.kill(os.getpid(),signal.SIGTERM)"] {
            XCTAssertThrowsError(try runPython(code)) { error in
                XCTAssertTrue(error.localizedDescription.contains("子进程失败"))
            }
        }
    }
    func testNonzeroStructuredWorkerErrorIsBoundedAndControlCharactersAreRemoved() {
        let code = "import os,json;os.write(1,json.dumps({'schema':1,'error':'callback\\n\\x01\\u2028\\u2029timeout'}).encode());os._exit(70)"
        XCTAssertThrowsError(try runPython(code)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("workerError=callbacktimeout"), text)
            XCTAssertFalse(text.contains("\n")); XCTAssertFalse(text.contains("\u{1}"))
        }
    }
    func testMalformedWorkerErrorsAreNotEchoedAndLongErrorsAreTruncated() {
        for output in ["not-json-do-not-echo", "{\"schema\":2,\"error\":\"do-not-echo\"}", "{\"schema\":1,\"error\":false}"] {
            let code = "import os,sys;os.write(1,sys.argv[1].encode());os._exit(70)"
            XCTAssertThrowsError(try runPython(code, [output])) { error in
                XCTAssertFalse(error.localizedDescription.contains("do-not-echo"))
                XCTAssertFalse(error.localizedDescription.contains("workerError="))
            }
        }
        XCTAssertThrowsError(try runPython("import os,json;os.write(1,json.dumps({'schema':1,'error':'x'*300}).encode());os._exit(70)")) { error in
            XCTAssertTrue(error.localizedDescription.contains("workerError=" + String(repeating: "x", count: 180)))
            XCTAssertFalse(error.localizedDescription.contains(String(repeating: "x", count: 181)))
        }
    }
    func testNonzeroWithValidValueStillFailsAndCannotBecomeNativeState() {
        XCTAssertThrowsError(try runPython("import os;os.write(1,b'{\"schema\":1,\"value\":80}');os._exit(70)")) { error in
            XCTAssertTrue(error.localizedDescription.contains("子进程失败"))
            XCTAssertFalse(error.localizedDescription.contains("workerError="))
        }
    }
    func testOverflowTakesPriorityOverConcurrentNonzeroExit() {
        XCTAssertThrowsError(try runPython("import os;os.write(1,b'x'*5000);os._exit(7)", maximumOutput: 128)) { error in
            XCTAssertTrue(error.localizedDescription.contains("响应过长"))
        }
    }
    func testNullStdinAndStderrCannotContaminateOrBlockStdout() throws {
        let output = try runPython("import os;assert os.read(0,1)==b'';os.write(2,b'x'*200000);os.write(1,b'ok')")
        XCTAssertEqual(output, Data("ok".utf8))
    }
    func testUnrelatedNonCloexecDescriptorIsNotInherited() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BM1FD-\(UUID())")
        let original = open(file.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(original, 0)
        guard original >= 0 else { return }
        defer { _ = close(original); try? FileManager.default.removeItem(at: file) }
        let inherited = fcntl(original, F_DUPFD, 100)
        XCTAssertGreaterThanOrEqual(inherited, 100)
        guard inherited >= 0 else { return }
        defer { _ = close(inherited) }
        XCTAssertEqual(fcntl(inherited, F_GETFD) & FD_CLOEXEC, 0)
        var expected = stat(); XCTAssertEqual(fstat(inherited, &expected), 0)
        let code = "import os,sys,json\ntry:\n s=os.fstat(int(sys.argv[1]));same=s.st_ino==int(sys.argv[2]) and s.st_dev==int(sys.argv[3])\nexcept OSError:\n same=False\nprint(json.dumps({'same':same}))"
        let output = try runPython(code, [String(inherited), String(expected.st_ino), String(expected.st_dev)])
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Bool])
        XCTAssertEqual(result["same"], false)
    }
    func testSuccessfulAndFailedSpawnsDoNotAccumulateParentFDs() throws {
        func countFDs() -> Int { (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count }
        let printf = URL(fileURLWithPath: "/usr/bin/printf")
        _ = try BatteryNativeReadProcess.run(executable: printf, arguments: ["ok"])
        let before = countFDs()
        for _ in 0..<20 {
            _ = try BatteryNativeReadProcess.run(executable: printf, arguments: ["ok"])
            XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/does-not-exist-bm1"), arguments: []))
        }
        XCTAssertLessThanOrEqual(countFDs(), before + 1)
    }
    func testInterruptedWaitPreservesOwnershipAndLostWaitRevokesIt() {
        var child = BatteryNativeReadProcess.ChildState(pid: 123)
        XCTAssertEqual(child.observe(wait: { _,_,_ in errno = EINTR; return -1 }), .interrupted)
        XCTAssertTrue(child.maySignal); XCTAssertFalse(child.reaped)
        XCTAssertEqual(child.observe(wait: { _,_,_ in errno = ECHILD; return -1 }), .lost(ECHILD))
        XCTAssertFalse(child.maySignal)
        var calls = 0
        _ = child.observe(wait: { _,_,_ in calls += 1; return 0 })
        XCTAssertEqual(calls, 0)
    }
    func testStoppedOrContinuedWaitNotificationsDoNotMeanReaped() {
        for status: Int32 in [0x7f, 0xffff] {
            var child = BatteryNativeReadProcess.ChildState(pid: 456)
            XCTAssertEqual(child.observe(wait: { pid,value,_ in value.pointee = status; return pid }), .running)
            XCTAssertFalse(child.reaped); XCTAssertTrue(child.maySignal)
            XCTAssertEqual(child.observe(wait: { pid,value,_ in value.pointee = 0; return pid }), .reaped)
            XCTAssertFalse(child.maySignal)
        }
    }
    func testReapedPIDCannotBeRecheckedOrSignalledEvenIfItsNumberIsReused() {
        var child = BatteryNativeReadProcess.ChildState(pid: 456)
        XCTAssertEqual(child.observe(wait: { pid,status,_ in status.pointee = 0; return pid }), .reaped)
        XCTAssertFalse(child.maySignal)
        var calls = 0
        XCTAssertEqual(child.observe(wait: { _,_,_ in calls += 1; return 0 }), .reaped)
        XCTAssertEqual(calls, 0)
    }
    func testUnconfirmedReapIsHandedOffBlocksNewSpawnAndLaterRecovers() throws {
        var allowReap = false
        var ownedPID: pid_t = 0
        let delayedWait: (pid_t, UnsafeMutablePointer<Int32>, Int32) -> pid_t = { pid,status,flags in
            ownedPID = pid
            return allowReap ? Darwin.waitpid(pid, status, flags) : 0
        }
        let reaper = BatteryNativeReadProcess.DeferredReaper(wait: delayedWait, automaticallySchedule: false)
        defer { allowReap = true; _ = reaper.reapNow() }
        let printf = URL(fileURLWithPath: "/usr/bin/printf")
        XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: printf, arguments: ["ok"],
            timeout: 0.05, maximumOutput: 4096, reaper: reaper, wait: delayedWait)) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("completionObserved=false"), text)
            XCTAssertTrue(text.contains("reapDeferred=true"), text)
        }
        XCTAssertGreaterThan(ownedPID, 0); XCTAssertEqual(reaper.pendingCount, 1)
        XCTAssertFalse(reaper.reapNow())
        XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/does-not-exist-bm1"),
            arguments: [], timeout: 0.4, maximumOutput: 4096, reaper: reaper)) { error in
            XCTAssertTrue(error.localizedDescription.contains("未启动新的只读进程"))
            XCTAssertFalse(error.localizedDescription.contains("启动失败"))
        }
        allowReap = true
        XCTAssertTrue(reaper.reapNow()); XCTAssertEqual(reaper.pendingCount, 0)
        XCTAssertEqual(kill(ownedPID, 0), -1); XCTAssertEqual(errno, ESRCH)
        let output = try BatteryNativeReadProcess.run(executable: printf, arguments: ["ok"],
            timeout: 0.4, maximumOutput: 4096, reaper: reaper)
        XCTAssertEqual(output, Data("ok".utf8))
    }
    func testDeferredReaperKeepsInterruptedWaitAndDropsOnlyReapedOrLostChildren() {
        var stage = 0, calls = 0
        let reaper = BatteryNativeReadProcess.DeferredReaper(wait: { pid,status,_ in
            calls += 1
            if stage == 0 { errno = EINTR; return -1 }
            if stage == 1 { return 0 }
            if pid == 123 { errno = ECHILD; return -1 }
            status.pointee = 0; return pid
        }, automaticallySchedule: false)
        reaper.adopt(.init(pid: 123)); reaper.adopt(.init(pid: 456))
        XCTAssertEqual(reaper.pendingCount, 2)
        XCTAssertFalse(reaper.reapNow()); XCTAssertEqual(reaper.pendingCount, 2)
        stage = 1; XCTAssertFalse(reaper.reapNow()); XCTAssertEqual(reaper.pendingCount, 2)
        stage = 2; XCTAssertTrue(reaper.reapNow()); XCTAssertEqual(reaper.pendingCount, 0)
        XCTAssertEqual(calls, 6)
    }
    func testDeferredReaperAutomaticallyFinishesPendingWaitWithoutAnotherRead() throws {
        let gate = NativeReadReapGate()
        let reaper = BatteryNativeReadProcess.DeferredReaper(wait: gate.wait)
        defer { gate.allowReap(); _ = reaper.reapNow() }
        XCTAssertThrowsError(try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["ok"], timeout: 0.05, maximumOutput: 4096, reaper: reaper, wait: gate.wait))
        XCTAssertEqual(reaper.pendingCount, 1)
        gate.allowReap()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while reaper.pendingCount > 0 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertEqual(reaper.pendingCount, 0, "Private timer must retain cleanup responsibility without another API request")
        XCTAssertEqual(kill(gate.lastPID, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    func testFoundationProcessAndPosixReaderCanRunConcurrentlyWithoutStealingWaits() {
        let failures = NativeReadInteropFailures(), group = DispatchGroup()
        for index in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    if index.isMultiple(of: 2) {
                        let process = Process()
                        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
                        process.arguments = ["ok"]
                        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                        try process.run(); process.waitUntilExit()
                        if process.terminationStatus != 0 { failures.add("Foundation child status \(process.terminationStatus)") }
                    } else {
                        let output = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["ok"])
                        if output != Data("ok".utf8) { failures.add("POSIX reply mismatch") }
                    }
                } catch { failures.add(error.localizedDescription) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(failures.values.isEmpty, failures.values.joined(separator: "; "))
    }
    @MainActor func testDirectWaitWorksWhileCallerDoesNotPumpItsMainRunLoop() throws {
        for _ in 0..<10 {
            let output = try BatteryNativeReadProcess.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["%s", "{\"schema\":1,\"value\":80}"], timeout: 0.4)
            XCTAssertEqual(try BatteryNativeReadTransport.decode(output, query: .limit), 80)
        }
    }
}

private final class NativeReadInteropFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ error: String) { lock.lock(); storage.append(error); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class NativeReadReapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = false
    private var pid: pid_t = 0
    var lastPID: pid_t { lock.lock(); defer { lock.unlock() }; return pid }
    func allowReap() { lock.lock(); allowed = true; lock.unlock() }
    func wait(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>, _ flags: Int32) -> pid_t {
        lock.lock(); self.pid = pid; let allowed = allowed; lock.unlock()
        return allowed ? Darwin.waitpid(pid, status, flags) : 0
    }
}
