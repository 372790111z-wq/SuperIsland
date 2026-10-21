import AppKit
import AVFoundation
import AVKit
import Carbon
import Combine
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers
import Darwin
import CoreGraphics

@MainActor enum ScreenshotLineText {
    static var translate: (String) -> String = { $0 }
}

@MainActor private func SL(_ text: String) -> String { ScreenshotLineText.translate(text) }

private enum ScreenshotLinePrefs {
    static var domain: CFString {
        (ProcessInfo.processInfo.environment["SCREENSHOT_LINE_CAPTURE_DOMAIN"] ?? "com.apple.screencapture") as CFString
    }
    static let keys = ["location", "location-screenshot", "location-screenrecording", "target", "target-screenshot", "target-screenrecording", "show-thumbnail"]

    struct Value: Codable, Equatable {
        var text: String?
        var flag: Bool?
        var exists: Bool { text != nil || flag != nil }

        static func read(_ key: String) -> Value {
            CFPreferencesAppSynchronize(domain)
            let value = CFPreferencesCopyAppValue(key as CFString, domain)
            if let string = value as? String { return Value(text: string) }
            if let number = value as? NSNumber { return Value(flag: number.boolValue) }
            return Value()
        }

        func write(_ key: String) {
            let value: CFPropertyList?
            if let text { value = text as CFString }
            else if let flag { value = flag ? kCFBooleanTrue : kCFBooleanFalse }
            else { value = nil }
            CFPreferencesSetAppValue(key as CFString, value, domain)
            CFPreferencesAppSynchronize(domain)
        }
    }

    struct Snapshot: Codable {
        var original: [String: Value]
        var owned: [String: Value]
    }

    static func screenshotFolder() -> URL {
        let raw = [Value.read("location-screenshot").text, Value.read("location").text]
            .compactMap { $0 }.first { !$0.isEmpty }
        return raw.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    static func savesScreenshotFile() -> Bool {
        let target = Value.read("target-screenshot").text ?? Value.read("target").text
        return target == nil || target == "file"
    }

    static func isOtherAppFolder(_ url: URL, ownName: String) -> Bool {
        let normalized = url.standardizedFileURL
        let path = normalized.path
        let marker = normalized.deletingLastPathComponent().appendingPathComponent(".screenshot-line-owner")
        if let owner = try? String(contentsOf: marker, encoding: .utf8),
           ["SuperIsland", "ZIsland"].contains(owner), owner != ownName { return true }
        return ["SuperIsland", "ZIsland"].contains { name in
            name != ownName && path.contains("/\(name)/ScreenshotLine/")
        }
    }

    static func otherAppOwnsCapture(ownName: String) -> Bool {
        ["location", "location-screenshot", "location-screenrecording"].contains { key in
            Value.read(key).text.map { isOtherAppFolder(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath), ownName: ownName) } ?? false
        }
    }
}

private enum ScreenshotLineError: Error {
    case anotherOwner, unverified, invalidDirectory, unavailable, fileMissing, missingSnapshot
    @MainActor var message: String {
        switch self {
        case .anotherOwner: SL("另一款 App 正在接管或使用它的托管目录；请先在那里关闭接管。")
        case .unverified: SL("系统设置未能回读确认，已尝试恢复原值。")
        case .invalidDirectory: SL("截图目录不可用或无访问权限。")
        case .unavailable: SL("系统编辑器当前不可用。")
        case .fileMissing: SL("原文件已移动或删除。")
        case .missingSnapshot: SL("存在未完成的接管恢复记录，或无法确认原始设置；请先检查系统截图选项。")
        }
    }
}

struct ScreenshotLineItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case image, recording }
    let id: UUID
    var path: String
    var kind: Kind
    var owned: Bool
    var createdAt: Date
    var url: URL { URL(fileURLWithPath: path) }
}

/// An app-owned line. The two products each compile their own copy and keep
/// their own index, managed files, settings, and menu-bar status item.
@MainActor
final class ScreenshotLineFeature: NSObject, ObservableObject {
    static let shared = ScreenshotLineFeature()

    @Published private(set) var items: [ScreenshotLineItem] = []
    @Published private(set) var status = ""
    @Published private(set) var takeoverActive = false
    @Published private(set) var shortcutConflict = false
    @Published private(set) var page = 0
    @Published private(set) var lineExpanded = false
    @Published private(set) var fallingItemIDs = Set<UUID>()
    @Published private(set) var copiedItemID: UUID?
    @Published private(set) var thumbnailRevision = 0
    @Published var watchEnabled: Bool { didSet { defaults.set(watchEnabled, forKey: "screenshotLine.watch"); refreshWatch() } }
    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: "screenshotLine.clipboard"); refreshClipboard() } }
    @Published var peekEnabled: Bool { didSet { defaults.set(peekEnabled, forKey: "screenshotLine.peek") } }
    @Published var fullscreenEnabled: Bool { didSet { defaults.set(fullscreenEnabled, forKey: "screenshotLine.fullscreen"); updatePanelSpaces() } }
    @Published var lineSize: Int { didSet { defaults.set(lineSize, forKey: "screenshotLine.size"); placePanel() } }
    @Published var keepAfterFinder: Bool { didSet { defaults.set(keepAfterFinder, forKey: "screenshotLine.keepAfterFinder") } }

    private let defaults = UserDefaults.standard
    private var appName = "ScreenshotLine"
    private var support = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var pointerTimer: Timer?
    private var clipboardTimer: Timer?
    private var watcher: ScreenshotLineWatcher?
    private var hotKey: ScreenshotLineHotKey?
    private var menuBarSince: Date?
    private var awaySince: Date?
    private var peekUntil = Date.distantPast
    private var pinned = false
    private var interactionInProgress = false
    private var revealed = false
    private var started = false
    private var lastClipboardChange = NSPasteboard.general.changeCount
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var watchedSystemFolder: URL?
    private var watchedSystemSavesFile = true
    private var nextWatchCheck = Date.distantPast
    private var menuHoverSuppressed = false
    private var menuClickMonitor: Any?
    private var localMenuClickMonitor: Any?
    private var scrollMonitor: Any?
    private var animationGeneration = 0

    var photoBounds: CGSize {
        switch lineSize {
        case 0: CGSize(width: 105, height: 86)
        case 2: CGSize(width: 180, height: 148)
        default: CGSize(width: 145, height: 116)
        }
    }
    var slotWidth: CGFloat { photoBounds.width + 30 }
    private var pageCapacity: Int { max(1, Int(((panel?.frame.width ?? 960) - 100) / slotWidth)) }

    private override init() {
        watchEnabled = defaults.object(forKey: "screenshotLine.watch") as? Bool ?? true
        clipboardEnabled = defaults.bool(forKey: "screenshotLine.clipboard")
        peekEnabled = defaults.object(forKey: "screenshotLine.peek") as? Bool ?? true
        fullscreenEnabled = defaults.bool(forKey: "screenshotLine.fullscreen")
        lineSize = min(2, max(0, defaults.object(forKey: "screenshotLine.size") as? Int ?? 1))
        keepAfterFinder = defaults.bool(forKey: "screenshotLine.keepAfterFinder")
        super.init()
    }

    var managedFolder: URL { support.appendingPathComponent("Screenshots", isDirectory: true) }
    var clipboardFolder: URL { support.appendingPathComponent("Clipboard", isDirectory: true) }
    var clipboardExportFolder: URL { support.appendingPathComponent("ClipboardExports", isDirectory: true) }
    var originalsFolder: URL { support.appendingPathComponent("Originals", isDirectory: true) }
    var accessibilityPrefix: String { appName == "ZIsland" ? "zi.sl." : "si.sc." }
    var watchFolder: URL { takeoverActive ? managedFolder : (customWatchFolder ?? ScreenshotLinePrefs.screenshotFolder()) }
    var customWatchFolder: URL? {
        (ProcessInfo.processInfo.environment["SCREENSHOT_LINE_WATCH_DIR"] ?? defaults.string(forKey: "screenshotLine.watchFolder"))
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    var visibleItems: [ScreenshotLineItem] {
        let count = pageCapacity
        let ordered = items.sorted { $0.createdAt < $1.createdAt }
        let end = max(0, ordered.count - page * count)
        return Array(ordered[max(0, end - count)..<end])
    }
    var hasOlder: Bool { items.count > (page + 1) * pageCapacity }

    func start(appName: String) {
        guard !started else { return }
        started = true
        self.appName = appName
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        support = ProcessInfo.processInfo.environment["SCREENSHOT_LINE_SUPPORT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? base.appendingPathComponent(appName, isDirectory: true).appendingPathComponent("ScreenshotLine", isDirectory: true)
        try? FileManager.default.createDirectory(at: managedFolder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: clipboardFolder, withIntermediateDirectories: true)
        try? appName.write(to: support.appendingPathComponent(".screenshot-line-owner"), atomically: true, encoding: .utf8)
        restoreIndex()
        restoreInterruptedTakeover()
        makePanel()
        makeMenu()
        registerHotKey()
        refreshWatch()
        refreshClipboard()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        menuClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.menuBarClicked() }
        }
        localMenuClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            DispatchQueue.main.async { self?.menuBarClicked() }
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLineScroll(event) }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placePanel() }
        }
    }

    func stop() {
        watcher?.stop(); watcher = nil
        clipboardTimer?.invalidate(); clipboardTimer = nil
        pointerTimer?.invalidate(); pointerTimer = nil
        hotKey = nil
        for monitor in [menuClickMonitor, localMenuClickMonitor, scrollMonitor] { if let monitor { NSEvent.removeMonitor(monitor) } }
        menuClickMonitor = nil; localMenuClickMonitor = nil; scrollMonitor = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if takeoverActive { restoreTakeover() }
        panel?.orderOut(nil)
    }

    private func setStatus(_ message: String) { status = message }

    private func persistIndex() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: support.appendingPathComponent("index.json"), options: .atomic)
        } catch { setStatus(SL("挂绳记录保存失败：") + error.localizedDescription) }
    }

    private func restoreIndex() {
        guard let data = try? Data(contentsOf: support.appendingPathComponent("index.json")),
              let old = try? JSONDecoder().decode([ScreenshotLineItem].self, from: data) else { return }
        items = old.filter { FileManager.default.fileExists(atPath: $0.path) }
        if items.count != old.count { persistIndex() }
    }

    private func add(_ url: URL, owned: Bool) {
        guard FileManager.default.fileExists(atPath: url.path), !items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let kind: ScreenshotLineItem.Kind = ["mov", "mp4"].contains(url.pathExtension.lowercased()) ? .recording : .image
        if kind == .recording {
            let preview = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            guard (try? preview.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)) != nil else { return }
        } else { guard NSImage(contentsOf: url) != nil else { return } }
        items.append(.init(id: UUID(), path: url.path, kind: kind, owned: owned, createdAt: Date()))
        page = 0
        setStatus("")
        persistIndex()
        placePanel()
        if peekEnabled && !menuHoverSuppressed { reveal(peek: true) }
    }

    private func removeRecord(_ item: ScreenshotLineItem) {
        items.removeAll { $0.id == item.id }
        page = min(page, max(0, (items.count - 1) / pageCapacity))
        persistIndex()
        if items.isEmpty { hideLine() }
    }

    private func isManaged(_ item: ScreenshotLineItem) -> Bool {
        let path = item.url.resolvingSymlinksInPath().standardizedFileURL.path
        return item.owned && [managedFolder, clipboardFolder].contains {
            path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/")
        }
    }

    func close(_ item: ScreenshotLineItem) {
        guard let current = items.first(where: { $0.id == item.id }), !fallingItemIDs.contains(item.id) else { return }
        if isManaged(current) { trash(current) }
        else { animateRemoval(current) }
    }

    private func animateRemoval(_ item: ScreenshotLineItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        fallingItemIDs.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.42)) { [weak self] in
            guard let self else { return }
            self.fallingItemIDs.remove(item.id)
            self.removeRecord(item)
        }
    }

    func trash(_ item: ScreenshotLineItem) {
        guard let current = items.first(where: { $0.id == item.id }), !fallingItemIDs.contains(item.id) else { return }
        if !isManaged(current) {
            let alert = NSAlert()
            alert.messageText = SL("将外部原图移到废纸篓？")
            alert.informativeText = current.url.path + "\n" + SL("这可能是唯一副本；取消不会改变原文件或挂绳。")
            alert.addButton(withTitle: SL("移到废纸篓"))
            alert.addButton(withTitle: SL("取消"))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try FileManager.default.trashItem(at: current.url, resultingItemURL: nil)
            animateRemoval(current)
        } catch { setStatus(SL("移动失败：") + error.localizedDescription) }
    }

    func copy(_ item: ScreenshotLineItem) {
        guard FileManager.default.fileExists(atPath: item.path) else { setStatus(ScreenshotLineError.fileMissing.message); return }
        let pb = NSPasteboard.general
        let objects: [NSPasteboardWriting]
        var exportedURL: URL?
        if item.kind == .image {
            guard let image = NSImage(contentsOf: item.url), let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
                setStatus(SL("复制失败。")); return
            }
            let entry = NSPasteboardItem()
            entry.setData(png, forType: .png)
            objects = [entry]
        } else {
            do {
                try FileManager.default.createDirectory(at: clipboardExportFolder, withIntermediateDirectories: true)
                let export = clipboardExportFolder.appendingPathComponent(UUID().uuidString + "-" + item.url.lastPathComponent)
                try FileManager.default.copyItem(at: item.url, to: export)
                exportedURL = export
                objects = [export as NSURL]
            } catch { setStatus(SL("复制失败：") + error.localizedDescription); return }
        }
        pb.clearContents()
        let wrote = pb.writeObjects(objects)
        lastClipboardChange = pb.changeCount
        guard wrote else {
            if let exportedURL { try? FileManager.default.trashItem(at: exportedURL, resultingItemURL: nil) }
            setStatus(SL("复制失败。")); return
        }
        copiedItemID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.copiedItemID == item.id { self?.copiedItemID = nil }
        }
    }

    func open(_ item: ScreenshotLineItem) { NSWorkspace.shared.open(item.url) }
    func revealInFinder(_ item: ScreenshotLineItem) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
    func quickLook(_ item: ScreenshotLineItem) { ScreenshotLinePreview.shared.show(item.url) }

    func saveToFolder(_ item: ScreenshotLineItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = SL("保存到这里")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var target = folder.appendingPathComponent(item.url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + " \(n)." + item.url.pathExtension)
            n += 1
        }
        do {
            let managed = isManaged(item)
            if managed { try FileManager.default.moveItem(at: item.url, to: target) }
            else { try FileManager.default.copyItem(at: item.url, to: target) }
            guard FileManager.default.fileExists(atPath: target.path) else { throw ScreenshotLineError.fileMissing }
            completeFinderTransfer(item, destination: target, managedMoved: managed)
        } catch { setStatus(SL("保存失败：") + error.localizedDescription) }
    }

    func edit(_ item: ScreenshotLineItem) {
        guard FileManager.default.fileExists(atPath: item.path) else { setStatus(ScreenshotLineError.fileMissing.message); return }
        var target = item.url
        var backup: URL?
        if item.owned {
            let original = originalsFolder.appendingPathComponent("Original-" + UUID().uuidString + "-" + item.url.lastPathComponent)
            do {
                try FileManager.default.createDirectory(at: originalsFolder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: item.url, to: original)
                backup = original
            } catch {
                try? FileManager.default.removeItem(at: original)
                setStatus(SL("无法备份原文件：") + error.localizedDescription)
                return
            }
        }
        if !item.owned {
            target = managedFolder.appendingPathComponent(UUID().uuidString + "." + item.url.pathExtension)
            do { try FileManager.default.copyItem(at: item.url, to: target) }
            catch { setStatus(SL("无法建立编辑副本：") + error.localizedDescription); return }
        }
        let sourceID = item.id
        let createdCopy = !item.owned
        let completion: (URL?) -> Void = { [weak self] result in
            guard let self else { return }
            guard let result else {
                if createdCopy { try? FileManager.default.removeItem(at: target) }
                if let backup { try? FileManager.default.removeItem(at: backup) }
                return
            }
            if let index = self.items.firstIndex(where: { $0.id == sourceID }) {
                self.items[index].path = result.path
                self.items[index].owned = true
                self.persistIndex()
            }
            self.thumbnailRevision += 1
            self.objectWillChange.send()
        }
        if item.kind == .image { ScreenshotLineMarkup.shared.edit(target, completion: completion) }
        else { ScreenshotLineTrimmer.shared.edit(target, completion: completion) }
    }

    func chooseWatchFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.prompt = SL("监听")
        if picker.runModal() == .OK, let folder = picker.url {
            defaults.set(folder.path, forKey: "screenshotLine.watchFolder")
            refreshWatch()
        }
    }

    func resetWatchFolder() {
        defaults.removeObject(forKey: "screenshotLine.watchFolder")
        refreshWatch()
    }

    private func refreshWatch() {
        watcher?.stop(); watcher = nil
        guard started, watchEnabled else { return }
        watchedSystemSavesFile = ScreenshotLinePrefs.savesScreenshotFile()
        if customWatchFolder == nil, !takeoverActive, !watchedSystemSavesFile {
            watchedSystemFolder = ScreenshotLinePrefs.screenshotFolder()
            setStatus(SL("系统当前未保存截图文件，挂绳无法监听新截图。"))
            return
        }
        let folder = takeoverActive ? managedFolder : watchFolder
        watchedSystemFolder = customWatchFolder == nil && !takeoverActive ? folder : nil
        guard !ScreenshotLinePrefs.isOtherAppFolder(folder, ownName: appName) else {
            setStatus(SL("另一款 App 的托管目录不会自动监听。"))
            return
        }
        let owned = folder.standardizedFileURL == managedFolder.standardizedFileURL
        watcher = ScreenshotLineWatcher(folder: folder, acceptsAnyImage: owned || customWatchFolder != nil,
                                        acceptsRecording: owned) { [weak self] url in
            self?.add(url, owned: owned)
        } onFailure: { [weak self] in self?.setStatus(SL("截图目录不可用或无访问权限：") + folder.path) }
        watcher?.start()
    }

    private func refreshClipboard() {
        clipboardTimer?.invalidate(); clipboardTimer = nil
        lastClipboardChange = NSPasteboard.general.changeCount
        guard started, clipboardEnabled else { return }
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readClipboard() }
        }
    }

    private func readClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastClipboardChange else { return }
        lastClipboardChange = pb.changeCount
        guard let entries = pb.pasteboardItems, entries.count == 1, let entry = entries.first else { return }
        let types = Set(entry.types)
        guard !types.contains(.string), !types.contains(.fileURL), !types.contains(.URL),
              !types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
              !types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) else { return }
        guard let data = entry.data(forType: .png) ?? entry.data(forType: .tiff), data.count <= 64 * 1024 * 1024,
              let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = clipboardFolder.appendingPathComponent(UUID().uuidString + ".png")
        do { try png.write(to: url, options: .atomic); add(url, owned: true) }
        catch { setStatus(SL("剪贴板图片保存失败：") + error.localizedDescription) }
    }

    private var snapshotURL: URL { support.appendingPathComponent("takeover-snapshot.json") }
    private var takeoverValues: [String: ScreenshotLinePrefs.Value] {
        var values: [String: ScreenshotLinePrefs.Value] = [:]
        for key in ["location", "location-screenshot", "location-screenrecording"] { values[key] = .init(text: managedFolder.path) }
        for key in ["target", "target-screenshot", "target-screenrecording"] { values[key] = .init(text: "file") }
        values["show-thumbnail"] = .init(flag: false)
        return values
    }

    func enableTakeover() {
        guard !takeoverActive else { return }
        let current = ScreenshotLinePrefs.screenshotFolder()
        if FileManager.default.fileExists(atPath: snapshotURL.path)
            || ["location", "location-screenshot", "location-screenrecording"].contains(where: {
                ScreenshotLinePrefs.Value.read($0).text.map { URL(fileURLWithPath: $0).standardizedFileURL == managedFolder.standardizedFileURL } ?? false
            }) {
            setStatus(ScreenshotLineError.missingSnapshot.message); return
        }
        guard !ScreenshotLinePrefs.isOtherAppFolder(current, ownName: appName),
              !ScreenshotLinePrefs.otherAppOwnsCapture(ownName: appName) else {
            setStatus(ScreenshotLineError.anotherOwner.message); return
        }
        let alert = NSAlert()
        alert.messageText = SL("让 App 接管截图与录屏？").replacingOccurrences(of: "App", with: appName)
        alert.informativeText = SL("系统保存目标会暂时改为 ") + managedFolder.path + SL("。关闭接管或正常退出时恢复原设置。")
        alert.addButton(withTitle: SL("开启接管")); alert.addButton(withTitle: SL("取消"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.createDirectory(at: managedFolder, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: snapshotURL.path) else { throw ScreenshotLineError.anotherOwner }
            let original = Dictionary(uniqueKeysWithValues: ScreenshotLinePrefs.keys.map { ($0, ScreenshotLinePrefs.Value.read($0)) })
            let snapshot = ScreenshotLinePrefs.Snapshot(original: original, owned: takeoverValues)
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            for (key, value) in snapshot.owned { value.write(key) }
            guard snapshot.owned.allSatisfy({ ScreenshotLinePrefs.Value.read($0.key) == $0.value }) else {
                restoreTakeover(); throw ScreenshotLineError.unverified
            }
            takeoverActive = true
            setStatus("")
            refreshWatch()
        } catch {
            setStatus(SL("接管失败：") + ((error as? ScreenshotLineError)?.message ?? error.localizedDescription))
        }
    }

    func restoreTakeover() {
        guard let data = try? Data(contentsOf: snapshotURL),
              var snapshot = try? JSONDecoder().decode(ScreenshotLinePrefs.Snapshot.self, from: data) else {
            let wasActive = takeoverActive
            takeoverActive = false
            if wasActive || FileManager.default.fileExists(atPath: snapshotURL.path) { setStatus(ScreenshotLineError.missingSnapshot.message) }
            refreshWatch(); return
        }
        var unresolved: [String: ScreenshotLinePrefs.Value] = [:]
        for (key, original) in snapshot.original {
            guard let expected = snapshot.owned[key] else { continue }
            if ScreenshotLinePrefs.Value.read(key) == expected {
                original.write(key)
                if ScreenshotLinePrefs.Value.read(key) != original { unresolved[key] = original }
            } else if ScreenshotLinePrefs.Value.read(key) != original { unresolved[key] = original }
        }
        if unresolved.isEmpty {
            try? FileManager.default.removeItem(at: snapshotURL)
            setStatus("")
        }
        else {
            snapshot.original = unresolved
            try? JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            setStatus(SL("部分系统设置已由其他程序改动，未覆盖；请检查截图选项。"))
        }
        takeoverActive = false
        refreshWatch()
    }

    private func restoreInterruptedTakeover() {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        restoreTakeover()
        if !FileManager.default.fileExists(atPath: snapshotURL.path) {
            setStatus(SL("已检查并恢复上次中断的截图设置。"))
        }
    }

    private func makePanel() {
        let panel = ScreenshotLinePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ScreenshotLineOverlay(feature: self))
        self.panel = panel
        updatePanelSpaces()
        placePanel()
    }

    private func updatePanelSpaces() {
        guard let panel else { return }
        let dismissFromFullscreen = !fullscreenEnabled && panel.collectionBehavior.contains(.canJoinAllApplications) && revealed
        panel.collectionBehavior = fullscreenEnabled
            ? [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.level = fullscreenEnabled ? .screenSaver : .floating
        if dismissFromFullscreen { hideLine() }
        else if fullscreenEnabled && revealed { panel.orderFrontRegardless() }
    }

    private func placePanel() {
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.minX, y: visible.maxY - 250, width: visible.width, height: 250), display: true)
        objectWillChange.send()
    }

    private func reveal(peek: Bool = false) {
        placePanel()
        guard let panel else { return }
        animationGeneration += 1
        revealed = true
        if peek { peekUntil = Date().addingTimeInterval(2.5) }
        else { pinned = true }
        panel.orderFrontRegardless()
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86)) {
            lineExpanded = true
        }
        objectWillChange.send()
    }

    private func hideLine() {
        revealed = false; pinned = false
        panel?.ignoresMouseEvents = true
        animationGeneration += 1
        let generation = animationGeneration
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeIn(duration: 0.22)) {
            lineExpanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.24)) { [weak self] in
            guard let self, self.animationGeneration == generation, !self.revealed else { return }
            self.panel?.orderOut(nil)
        }
        objectWillChange.send()
    }

    func toggleLine() { revealed ? hideLine() : reveal() }
    func older() { if hasOlder { page += 1 } }
    func newer() { page = max(0, page - 1) }
    func interactionBegan() { interactionInProgress = true; awaySince = nil }
    func interactionEnded() { interactionInProgress = false; awaySince = nil }
    func finishedDrag(_ item: ScreenshotLineItem, operation: NSDragOperation) {
        interactionEnded()
        if operation.contains(.delete) { trash(item); return }
    }

    func promisedFileWritten(_ item: ScreenshotLineItem, to destination: URL, inFinder: Bool) {
        guard inFinder, FileManager.default.fileExists(atPath: destination.path) else { return }
        guard let current = items.first(where: { $0.id == item.id }) else { return }
        if isManaged(current) {
            do {
                let sourceSize = try current.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                let destinationSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard sourceSize == destinationSize else { throw ScreenshotLineError.unverified }
                try FileManager.default.trashItem(at: current.url, resultingItemURL: nil)
                completeFinderTransfer(current, destination: destination, managedMoved: true)
            } catch { setStatus(SL("Finder 已收到副本，但原文件未迁出：") + error.localizedDescription) }
        } else { completeFinderTransfer(current, destination: destination, managedMoved: false) }
    }

    private func completeFinderTransfer(_ item: ScreenshotLineItem, destination: URL, managedMoved: Bool) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if keepAfterFinder {
            if managedMoved { items[index].path = destination.path; items[index].owned = false }
            persistIndex()
        } else { removeRecord(item) }
        objectWillChange.send()
    }

    private func menuBarClicked() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return }
        let menuStart = min(screen.visibleFrame.maxY, screen.frame.maxY - 4)
        guard pointer.y >= menuStart else { return }
        menuHoverSuppressed = true
        menuBarSince = nil
        if revealed { hideLine() }
    }

    private func handleLineScroll(_ event: NSEvent) {
        guard revealed, let panel, panel.frame.contains(NSEvent.mouseLocation) else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if delta > 2 { older() }
        else if delta < -2 { newer() }
    }

    private func tick() {
        if Date() >= nextWatchCheck {
            nextWatchCheck = Date().addingTimeInterval(2)
            if watchEnabled, customWatchFolder == nil, !takeoverActive,
               (watchedSystemFolder != ScreenshotLinePrefs.screenshotFolder()
                || watchedSystemSavesFile != ScreenshotLinePrefs.savesScreenshotFile()) { refreshWatch() }
        }
        guard let panel else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let menuStart = min(screen.visibleFrame.maxY, screen.frame.maxY - 4)
        let inMenu = pointer.y >= menuStart && pointer.y <= screen.frame.maxY
            && pointer.x >= screen.frame.minX && pointer.x <= screen.frame.maxX
        if !inMenu { menuHoverSuppressed = false }
        if !revealed {
            if items.isEmpty || menuHoverSuppressed { return }
            if inMenu {
                if menuBarSince == nil { menuBarSince = Date() }
                if Date().timeIntervalSince(menuBarSince!) >= 0.25 { menuBarSince = nil; reveal() }
            } else { menuBarSince = nil }
            return
        }
        if inMenu, !interactionInProgress, panel.screen != screen { placePanel() }
        let localX = pointer.x - panel.frame.minX
        let localY = panel.frame.maxY - pointer.y
        let visible = visibleItems
        let count = visible.count
        let step = slotWidth
        let first = panel.frame.width / 2 - CGFloat(count - 1) * step / 2
        let overCard = visible.indices.contains { index in
            let x = first + CGFloat(index) * step
            let f = x / max(panel.frame.width, 1)
            let y = 10 + 4 * min(30, panel.frame.width * 0.018) * f * (1 - f)
            return abs(localX - x) <= photoBounds.width / 2 + 14 && localY >= y - 12 && localY <= y + photoBounds.height + 65
        }
        panel.ignoresMouseEvents = !overCard
        let inside = panel.frame.contains(pointer) || inMenu
        if inside && pinned { pinned = false }
        if inside || pinned || interactionInProgress || Date() < peekUntil { awaySince = nil; return }
        if awaySince == nil { awaySince = Date() }
        if Date().timeIntervalSince(awaySince!) > 0.5 { awaySince = nil; hideLine() }
    }

    private func makeMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: appName + " " + SL("截图挂绳"))
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    private func registerHotKey() {
        hotKey = nil
        let choice = defaults.string(forKey: "screenshotLine.shortcut") ?? "ctrl-option-t"
        guard choice != "none" else { shortcutConflict = false; return }
        let config: (UInt32, UInt32)
        switch choice {
        case "ctrl-option-s": config = (UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey))
        case "cmd-shift-y": config = (UInt32(kVK_ANSI_Y), UInt32(cmdKey | shiftKey))
        default: config = (UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey))
        }
        hotKey = ScreenshotLineHotKey(keyCode: config.0, modifiers: config.1) { [weak self] in self?.toggleLine() }
        shortcutConflict = hotKey == nil
    }

    func setShortcut(_ value: String) { defaults.set(value, forKey: "screenshotLine.shortcut"); registerHotKey() }
    var shortcut: String { defaults.string(forKey: "screenshotLine.shortcut") ?? "ctrl-option-t" }
    var managedFiles: [URL] {
        let fm = FileManager.default
        return [managedFolder, clipboardFolder, clipboardExportFolder, originalsFolder].flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func trashManagedFile(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = SL("移到废纸篓？")
        alert.informativeText = url.path
        alert.addButton(withTitle: SL("移到废纸篓")); alert.addButton(withTitle: SL("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try FileManager.default.trashItem(at: url, resultingItemURL: nil); items.removeAll { $0.url == url }; persistIndex(); objectWillChange.send() }
        catch { setStatus(SL("移动失败：") + error.localizedDescription) }
    }
}

extension ScreenshotLineFeature: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
            let item = ScreenshotLineMenuItem(title: title, action: handler)
            menu.addItem(item)
            return item
        }
        action(revealed ? SL("收起挂绳") : SL("展开挂绳")) { [weak self] in self?.toggleLine() }
        action(SL("查看较早项目")) { [weak self] in self?.older() }
        action(SL("查看较新项目")) { [weak self] in self?.newer() }
        menu.addItem(.separator())
        let clipboard = action(SL("接收纯图片剪贴板")) { [weak self] in self?.clipboardEnabled.toggle() }
        clipboard.state = clipboardEnabled ? .on : .off
        let keep = action(SL("Finder 拖后保留")) { [weak self] in self?.keepAfterFinder.toggle() }
        keep.state = keepAfterFinder ? .on : .off
        let sizeMenu = NSMenu()
        for (value, title) in [(0, SL("小")), (1, SL("中")), (2, SL("大"))] {
            let choice = ScreenshotLineMenuItem(title: title) { [weak self] in self?.lineSize = value }
            choice.state = lineSize == value ? .on : .off
            sizeMenu.addItem(choice)
        }
        let sizeItem = NSMenuItem(title: SL("卡片大小"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)
        menu.addItem(.separator())
        action(SL("打开截图挂绳设置")) { [weak self] in self?.openSettings?() }
    }

    var openSettings: (() -> Void)? {
        get { ScreenshotLineSettingsBridge.shared.open }
        set { ScreenshotLineSettingsBridge.shared.open = newValue }
    }
}

@MainActor private final class ScreenshotLineSettingsBridge {
    static let shared = ScreenshotLineSettingsBridge()
    var open: (() -> Void)?
}

private final class ScreenshotLineMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

@MainActor private final class ScreenshotLineHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let instance = Unmanaged<ScreenshotLineHotKey>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { instance.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x534C494E), id: 1)
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
    }
    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor private final class ScreenshotLineWatcher {
    let folder: URL
    let acceptsAnyImage: Bool
    let acceptsRecording: Bool
    let onNew: (URL) -> Void
    let onFailure: () -> Void
    private var timer: Timer?
    private var known = Set<String>()
    private var pending = [String: Int64]()
    private var listing = false
    private var first = true
    private var stopped = false
    init(folder: URL, acceptsAnyImage: Bool, acceptsRecording: Bool, onNew: @escaping (URL) -> Void, onFailure: @escaping () -> Void) {
        self.folder = folder; self.acceptsAnyImage = acceptsAnyImage; self.acceptsRecording = acceptsRecording
        self.onNew = onNew; self.onFailure = onFailure
    }
    func start() {
        stopped = false
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }
    func stop() { stopped = true; timer?.invalidate(); timer = nil }
    private func scan() {
        guard !listing else { return }
        listing = true
        let folder = folder
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.listing = false
                guard let files else { self.onFailure(); return }
                let paths = Set(files.map(\.path))
                if self.first { self.known = paths; self.first = false; return }
                for url in files where !self.known.contains(url.path) && self.accepts(url) {
                    let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    if size > 0, self.pending[url.path] == size {
                        self.onNew(url); self.known.insert(url.path); self.pending[url.path] = nil
                    } else { self.pending[url.path] = size }
                }
                self.known.formIntersection(paths)
                self.pending = self.pending.filter { paths.contains($0.key) }
            }
        }
    }
    private func accepts(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mov", "mp4"].contains(ext) { return acceptsRecording || hasCaptureMetadata(url) }
        guard ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"].contains(ext) else { return false }
        if acceptsAnyImage { return true }
        return hasCaptureMetadata(url)
    }
    private func hasCaptureMetadata(_ url: URL) -> Bool {
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
        }
    }
}

private final class ScreenshotLinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct ScreenshotLineOverlay: View {
    @ObservedObject var feature: ScreenshotLineFeature
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let items = feature.visibleItems
            let step = feature.slotWidth
            let first = width / 2 - CGFloat(items.count - 1) * step / 2
            ZStack(alignment: .topLeading) {
                ScreenshotLineRope(width: width)
                if items.isEmpty {
                    Text(SL("截图会挂在这里"))
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: width / 2, y: 10 + min(30, width * 0.018) + 34)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let x = first + CGFloat(index) * step
                    let f = x / max(width, 1)
                    let y = 10 + 4 * min(30, width * 0.018) * f * (1 - f)
                    ScreenshotLineCard(item: item, feature: feature)
                        .frame(width: step, height: feature.photoBounds.height + 46)
                        .position(x: x, y: y + (feature.photoBounds.height + 46) / 2 - 6)
                        .offset(y: feature.fallingItemIDs.contains(item.id) ? 260 : 0)
                        .rotationEffect(.degrees(feature.fallingItemIDs.contains(item.id) ? 15 : 0), anchor: .top)
                        .opacity(feature.fallingItemIDs.contains(item.id) ? 0 : 1)
                        .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .easeIn(duration: 0.42), value: feature.fallingItemIDs.contains(item.id))
                }
            }
            .offset(y: feature.lineExpanded ? 0 : -250)
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: feature.lineExpanded)
        }
    }
}

private struct ScreenshotLineRope: View {
    let width: CGFloat
    var body: some View {
        let path = Path { p in
            p.move(to: CGPoint(x: -20, y: 10))
            p.addQuadCurve(to: CGPoint(x: width + 20, y: 10), control: CGPoint(x: width / 2, y: 10 + 2 * min(30, width * 0.018)))
        }
        ZStack {
            path.stroke(.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08), .init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
    }
}

private struct ScreenshotLineCard: View {
    let item: ScreenshotLineItem
    @ObservedObject var feature: ScreenshotLineFeature
    @State private var cachedThumbnail: NSImage?
    @State private var hovering = false
    @State private var entered = false
    private var thumbnail: NSImage? {
        if item.kind == .image { return NSImage(contentsOf: item.url) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
    private func photoSize(_ image: NSImage?) -> CGSize {
        let bounds = feature.photoBounds
        guard let image, image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: image.size.width * scale, height: image.size.height * scale)
    }
    var body: some View {
        let image = cachedThumbnail ?? thumbnail
        let size = photoSize(image)
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .overlay {
                    Group {
                        if let image { Image(nsImage: image).resizable().scaledToFit() }
                        else { Image(systemName: item.kind == .recording ? "play.rectangle" : "photo") }
                    }.padding(3)
                }
                .frame(width: size.width + 6, height: size.height + 6)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.7), lineWidth: 3))
                .padding(.top, 18)
            RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.gray, .white, .gray], startPoint: .leading, endPoint: .trailing))
                .frame(width: 9, height: 26)
            ScreenshotLineDragHandle(item: item, feature: feature)
                .frame(width: size.width + 6, height: size.height + 6)
                .padding(.top, 18)
            if item.kind == .recording {
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(9).background(.black.opacity(0.6), in: Circle())
                    .allowsHitTesting(false)
                    .position(x: feature.slotWidth / 2, y: 21 + size.height / 2)
            }
            if feature.copiedItemID == item.id {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(7).background(.green, in: Circle())
                    .allowsHitTesting(false)
                    .position(x: feature.slotWidth / 2, y: 21 + size.height / 2)
            }
            Button { feature.close(item) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).frame(width: 23, height: 23)
                .background(.black.opacity(0.65), in: Circle())
                .accessibilityIdentifier(feature.accessibilityPrefix + "remove")
                .position(x: (feature.slotWidth - size.width) / 2 + 2, y: 27)
        }
        .frame(width: feature.slotWidth, height: feature.photoBounds.height + 46)
        .contentShape(Rectangle())
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .offset(y: entered ? 0 : -24)
        .rotationEffect(.degrees(entered ? 0 : -5), anchor: .top)
        .onHover { hovering = $0 }
        .onAppear {
            cachedThumbnail = thumbnail
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.52)) {
                entered = true
            }
        }
        .onChange(of: item.path) { _, _ in cachedThumbnail = thumbnail }
        .onChange(of: feature.thumbnailRevision) { _, _ in cachedThumbnail = thumbnail }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.url.lastPathComponent)
    }
}

private struct ScreenshotLineDragHandle: NSViewRepresentable {
    let item: ScreenshotLineItem
    let feature: ScreenshotLineFeature
    func makeNSView(context: Context) -> ScreenshotLineDragView {
        ScreenshotLineDragView(item: item, feature: feature)
    }
    func updateNSView(_ view: ScreenshotLineDragView, context: Context) {
        view.item = item
    }
}

@MainActor private final class ScreenshotLineDragView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var item: ScreenshotLineItem
    private let feature: ScreenshotLineFeature
    private var pressPoint: NSPoint?
    private var holdTimer: Timer?
    private var singleClickWorkItem: DispatchWorkItem?
    private var didHold = false
    private var dragging = false
    private var promise: NSFilePromiseProvider?
    private var promisedDestination: URL?
    private var endedOverFinder = false
    private var dragEnded = false

    init(item: ScreenshotLineItem, feature: ScreenshotLineFeature) {
        self.item = item; self.feature = feature
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        singleClickWorkItem?.cancel(); singleClickWorkItem = nil
        pressPoint = convert(event.locationInWindow, from: nil)
        didHold = false
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressPoint != nil, !self.dragging else { return }
                self.didHold = true
                self.feature.edit(self.item)
            }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressPoint, !dragging, !didHold else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - pressPoint.x, point.y - pressPoint.y) > 5,
              FileManager.default.fileExists(atPath: item.path) else { return }
        singleClickWorkItem?.cancel(); singleClickWorkItem = nil
        holdTimer?.invalidate(); holdTimer = nil
        dragging = true
        promisedDestination = nil; endedOverFinder = false; dragEnded = false
        feature.interactionBegan()
        let type = UTType(filenameExtension: item.url.pathExtension)?.identifier ?? UTType.data.identifier
        let provider = NSFilePromiseProvider(fileType: type, delegate: self)
        promise = provider
        let drag = NSDraggingItem(pasteboardWriter: provider)
        let preview = NSImage(contentsOf: item.url) ?? NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
        drag.setDraggingFrame(bounds.insetBy(dx: 5, dy: 5), contents: preview)
        let session = beginDraggingSession(with: [drag], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate(); holdTimer = nil
        defer { pressPoint = nil; didHold = false }
        guard !dragging, !didHold else { return }
        if event.clickCount >= 2 {
            singleClickWorkItem?.cancel(); singleClickWorkItem = nil
            feature.open(item)
        } else {
            let item = item
            let feature = feature
            let action = DispatchWorkItem { [weak self] in
                self?.singleClickWorkItem = nil
                feature.copy(item)
            }
            singleClickWorkItem = action
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: action)
        }
    }
    override func pressureChange(with event: NSEvent) {
        guard event.pressure > 0.72, !didHold, !dragging else { return }
        didHold = true
        holdTimer?.invalidate(); holdTimer = nil
        feature.quickLook(item)
    }
    override func rightMouseDown(with event: NSEvent) {
        feature.interactionBegan()
        let menu = NSMenu()
        func add(_ label: String, _ action: @escaping () -> Void) {
            menu.addItem(ScreenshotLineMenuItem(title: label, action: action))
        }
        add(SL("复制")) { [weak self] in if let self { self.feature.copy(self.item) } }
        add(SL("打开")) { [weak self] in if let self { self.feature.open(self.item) } }
        add(SL("快速查看")) { [weak self] in if let self { self.feature.quickLook(self.item) } }
        add(SL("在访达中显示")) { [weak self] in if let self { self.feature.revealInFinder(self.item) } }
        add(item.kind == .recording ? SL("裁剪") : SL("标注")) { [weak self] in if let self { self.feature.edit(self.item) } }
        add(SL("保存到文件夹")) { [weak self] in if let self { self.feature.saveToFolder(self.item) } }
        menu.addItem(.separator())
        add(item.owned ? SL("移到废纸篓") : SL("从挂绳移除")) { [weak self] in if let self { self.feature.close(self.item) } }
        if !item.owned { add(SL("将原图移到废纸篓…")) { [weak self] in if let self { self.feature.trash(self.item) } } }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        feature.interactionEnded()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        guard context == .outsideApplication else { return [] }
        return [.copy, .delete]
    }
    func draggingSession(_ session: NSDraggingSession, endedAt point: NSPoint, operation: NSDragOperation) {
        dragging = false; pressPoint = nil
        dragEnded = true
        endedOverFinder = Self.finderWindow(at: point)
        feature.finishedDrag(item, operation: operation)
        reconcilePromise()
    }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.url.lastPathComponent
    }
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo destination: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        let source = MainActor.assumeIsolated { item.url }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                guard FileManager.default.fileExists(atPath: destination.path) else { throw ScreenshotLineError.fileMissing }
                completionHandler(nil)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self else { return }
                    self.promisedDestination = destination
                    self.reconcilePromise()
                } }
            } catch {
                completionHandler(error)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.promise = nil } }
            }
        }
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }
    private func reconcilePromise() {
        guard dragEnded, let destination = promisedDestination else { return }
        feature.promisedFileWritten(item, to: destination, inFinder: endedOverFinder)
        promise = nil
    }
    private static func finderWindow(at point: NSPoint) -> Bool {
        let y = (NSScreen.screens.first?.frame.maxY ?? 0) - point.y
        let position = CGPoint(x: point.x, y: y)
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in windows {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer > 0 { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  CGRect(x: x, y: y, width: width, height: height).contains(position) else { continue }
            let owner = info[kCGWindowOwnerName as String] as? String
            if owner == "Finder" || owner == "访达" { return true }
            if layer == 0 { return false }
        }
        return false
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { item.url.lastPathComponent }
    override func accessibilityPerformPress() -> Bool { feature.copy(item); return true }
}

@MainActor private final class ScreenshotLinePreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ScreenshotLinePreview()
    private var url: URL?
    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.delegate = self; panel.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { url == nil ? 0 : 1 } }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { MainActor.assumeIsolated { url as NSURL? } }
}

@MainActor private final class ScreenshotLineMarkup: NSObject, NSSharingServiceDelegate {
    static let shared = ScreenshotLineMarkup()
    private var target: URL?
    private var completion: ((URL?) -> Void)?
    func edit(_ url: URL, completion: @escaping (URL?) -> Void) {
        guard target == nil else { completion(nil); return }
        let name = NSSharingService.Name("com.apple.MarkupUI.Markup")
        guard let service = NSSharingService(named: name), service.canPerform(withItems: [url]) else {
            completion(nil); NSSound.beep(); return
        }
        target = url; self.completion = completion
        service.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: [url])
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        MainActor.assumeIsolated {
            guard let target, let item = items.first else { finish(nil); return }
            if let url = item as? URL { save(try? Data(contentsOf: url), to: target); return }
            if let image = item as? NSImage, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff) {
                save(rep.representation(using: .png, properties: [:]), to: target); return
            }
            if let provider = item as? NSItemProvider {
                let type = provider.registeredTypeIdentifiers.first {
                    UTType($0)?.conforms(to: .image) == true
                }
                guard let type else { finish(nil); return }
                provider.loadDataRepresentation(forTypeIdentifier: type) { [weak self] data, _ in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.save(data, to: target) } }
                }
                return
            }
            finish(nil)
        }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(nil) } }
    }
    private func save(_ data: Data?, to target: URL) {
        guard let data, (try? data.write(to: target, options: .atomic)) != nil else { finish(nil); return }
        finish(target)
    }
    private func finish(_ result: URL?) {
        let callback = completion
        target = nil; completion = nil
        callback?(result)
    }
}

@MainActor private final class ScreenshotLineTrimmer: NSObject, NSWindowDelegate {
    static let shared = ScreenshotLineTrimmer()
    private var window: NSWindow?
    private var completion: ((URL?) -> Void)?
    private var target: URL?
    private var player: AVPlayerView?
    private var startSlider: NSSlider?
    private var endSlider: NSSlider?
    private var startLabel: NSTextField?
    private var endLabel: NSTextField?
    private var saveButton: NSButton?
    private var statusLabel: NSTextField?
    private var duration = 0.0
    private var exporting = false
    func windowShouldClose(_ sender: NSWindow) -> Bool { !exporting }
    func edit(_ url: URL, completion: @escaping (URL?) -> Void) {
        guard window == nil else { completion(nil); return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 610))
        let video = AVPlayerView(frame: NSRect(x: 0, y: 145, width: 760, height: 465))
        video.autoresizingMask = [.width, .height]
        video.player = AVPlayer(url: url)
        video.controlsStyle = .inline
        content.addSubview(video)

        func label(_ text: String, frame: NSRect) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = frame
            content.addSubview(field)
            return field
        }
        let startLabel = label(SL("开始") + " 0.0s", frame: NSRect(x: 20, y: 112, width: 92, height: 20))
        let endLabel = label(SL("结束") + " 0.0s", frame: NSRect(x: 20, y: 77, width: 92, height: 20))
        let start = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(rangeChanged(_:)))
        let end = NSSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(rangeChanged(_:)))
        start.frame = NSRect(x: 112, y: 107, width: 625, height: 28)
        end.frame = NSRect(x: 112, y: 72, width: 625, height: 28)
        start.setAccessibilityLabel(SL("开始"))
        end.setAccessibilityLabel(SL("结束"))
        content.addSubview(start); content.addSubview(end)
        let status = label("", frame: NSRect(x: 20, y: 26, width: 445, height: 20))
        let cancel = NSButton(title: SL("取消"), target: self, action: #selector(cancelEdit))
        cancel.frame = NSRect(x: 535, y: 18, width: 92, height: 32)
        let save = NSButton(title: SL("保存裁剪"), target: self, action: #selector(saveEdit))
        save.frame = NSRect(x: 635, y: 18, width: 105, height: 32)
        save.isEnabled = false
        content.addSubview(cancel); content.addSubview(save)

        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = SL("裁剪录屏")
        window.contentView = content
        window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window; self.target = url; self.completion = completion
        self.player = video; startSlider = start; endSlider = end
        self.startLabel = startLabel; self.endLabel = endLabel
        saveButton = save; statusLabel = status; duration = 0; exporting = false
        Task { [weak self] in
            do {
                let loaded = try await AVURLAsset(url: url).load(.duration)
                guard let self, self.target == url else { return }
                let seconds = loaded.seconds
                guard seconds.isFinite, seconds > 0.05 else { self.statusLabel?.stringValue = SL("裁剪失败，请重试"); return }
                self.duration = seconds
                self.startSlider?.maxValue = seconds
                self.endSlider?.maxValue = seconds
                self.endSlider?.doubleValue = seconds
                self.endLabel?.stringValue = String(format: "%@ %.1fs", SL("结束"), seconds)
                self.saveButton?.isEnabled = true
            } catch { self?.statusLabel?.stringValue = SL("裁剪失败，请重试") }
        }
    }
    @objc private func rangeChanged(_ sender: NSSlider) {
        guard let startSlider, let endSlider else { return }
        if sender === startSlider { startSlider.doubleValue = min(startSlider.doubleValue, endSlider.doubleValue - 0.05) }
        else { endSlider.doubleValue = max(endSlider.doubleValue, startSlider.doubleValue + 0.05) }
        startLabel?.stringValue = String(format: "%@ %.1fs", SL("开始"), startSlider.doubleValue)
        endLabel?.stringValue = String(format: "%@ %.1fs", SL("结束"), endSlider.doubleValue)
        player?.player?.seek(to: CMTime(seconds: sender.doubleValue, preferredTimescale: 600))
    }
    @objc private func cancelEdit() { if !exporting { window?.close() } }
    @objc private func saveEdit() {
        guard !exporting, let target, let startSlider, let endSlider,
              duration > 0, endSlider.doubleValue > startSlider.doubleValue,
              let export = AVAssetExportSession(asset: AVURLAsset(url: target), presetName: AVAssetExportPresetPassthrough) else { return }
        exporting = true; saveButton?.isEnabled = false
        statusLabel?.stringValue = SL("裁剪中…")
        let start = CMTime(seconds: startSlider.doubleValue, preferredTimescale: 600)
        let end = CMTime(seconds: endSlider.doubleValue, preferredTimescale: 600)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".trimming-\(UUID().uuidString).\(target.pathExtension)")
        export.outputURL = temp
        export.outputFileType = target.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
        export.timeRange = CMTimeRange(start: start, end: end)
        Task { [weak self] in
            await export.export()
            guard let self else { return }
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: temp)
                self.exporting = false; self.saveButton?.isEnabled = true
                self.statusLabel?.stringValue = SL("裁剪失败，请重试")
                return
            }
            do {
                self.player?.player?.pause()
                self.player?.player?.replaceCurrentItem(with: nil)
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temp)
                let callback = self.completion
                self.completion = nil
                self.exporting = false
                self.window?.close()
                callback?(target)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                self.exporting = false; self.saveButton?.isEnabled = true
                self.statusLabel?.stringValue = SL("裁剪失败，请重试")
                self.player?.player?.replaceCurrentItem(with: AVPlayerItem(url: target))
            }
        }
    }
    func windowWillClose(_ notification: Notification) {
        player?.player?.pause()
        player?.player?.replaceCurrentItem(with: nil)
        player = nil; startSlider = nil; endSlider = nil
        startLabel = nil; endLabel = nil; saveButton = nil; statusLabel = nil
        window = nil; target = nil; exporting = false
        let callback = completion
        completion = nil
        callback?(nil)
    }
}

struct ScreenshotLineSettingsView: View {
    @ObservedObject private var line = ScreenshotLineFeature.shared
    @State private var shortcut = "ctrl-option-t"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SL("截图挂绳")).font(.title2.weight(.semibold))
                Text(SL("独立挂绳位于菜单栏下方；截图与录屏仍使用系统快捷键。"))
                    .foregroundStyle(.secondary)
                Toggle(SL("监听新截图"), isOn: $line.watchEnabled)
                    .accessibilityIdentifier(line.accessibilityPrefix + "watch-toggle")
                HStack {
                    Text(SL("监听目录：") + line.watchFolder.path).lineLimit(2)
                    Spacer()
                    Button(SL("选择目录…")) { line.chooseWatchFolder() }.disabled(line.takeoverActive)
                    Button(SL("跟随系统")) { line.resetWatchFolder() }.disabled(line.takeoverActive)
                }
                Toggle(SL("接收纯图片剪贴板"), isOn: $line.clipboardEnabled)
                    .accessibilityIdentifier(line.accessibilityPrefix + "clipboard-toggle")
                Toggle(SL("新内容短暂展开"), isOn: $line.peekEnabled)
                Toggle(SL("在全屏 App 上显示"), isOn: $line.fullscreenEnabled)
                Toggle(SL("Finder 拖后保留在挂绳"), isOn: $line.keepAfterFinder)
                    .accessibilityIdentifier(line.accessibilityPrefix + "keep-after-finder")
                Picker(SL("卡片大小"), selection: $line.lineSize) {
                    Text(SL("小")).tag(0)
                    Text(SL("中")).tag(1)
                    Text(SL("大")).tag(2)
                }.frame(maxWidth: 280).accessibilityIdentifier(line.accessibilityPrefix + "size")
                HStack {
                    Text(SL("系统截图与录屏接管"))
                    Spacer()
                    Button(line.takeoverActive ? SL("关闭并恢复") : SL("开启接管…")) {
                        if line.takeoverActive { line.restoreTakeover() } else { line.enableTakeover() }
                    }
                    .accessibilityIdentifier(line.accessibilityPrefix + "takeover-toggle")
                }
                HStack {
                    Text(SL("展开快捷键"))
                    Spacer()
                    Picker(SL("展开快捷键"), selection: $shortcut) {
                        Text("⌃⌥T").tag("ctrl-option-t")
                        Text("⌃⌥S").tag("ctrl-option-s")
                        Text("⌘⇧Y").tag("cmd-shift-y")
                        Text(SL("关闭")).tag("none")
                    }.frame(width: 130).onChange(of: shortcut) { _, value in line.setShortcut(value) }
                }
                if line.shortcutConflict { Text(SL("快捷键已被其他 App 占用，请换一个。")).foregroundStyle(.orange) }
                HStack {
                    Button(SL("展开／收起挂绳")) { line.toggleLine() }
                        .accessibilityIdentifier(line.accessibilityPrefix + "line")
                    Button(SL("打开托管文件夹")) { NSWorkspace.shared.open(line.managedFolder) }
                }
                if !line.status.isEmpty { Text(line.status).foregroundStyle(.orange) }
                Divider()
                Text(SL("托管文件不会自动过期；点击卡片 × 后移入可恢复的废纸篓。"))
                    .foregroundStyle(.secondary)
                Text(SL("复制录屏会留下独立副本，保证撤卡后剪贴板仍可使用；可在下方手动清理。"))
                    .foregroundStyle(.secondary)
                Text(SL("编辑前的原件保存在 Originals；可在下方手动清理。"))
                    .foregroundStyle(.secondary)
                ForEach(line.managedFiles, id: \.path) { url in
                    HStack {
                        Text(url.lastPathComponent).lineLimit(1)
                        Spacer()
                        Button(SL("打开")) { NSWorkspace.shared.open(url) }
                        Button(SL("移到废纸篓")) { line.trashManagedFile(url) }
                    }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { shortcut = line.shortcut }
    }
}
