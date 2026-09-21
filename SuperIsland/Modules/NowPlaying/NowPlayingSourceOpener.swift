import AppKit
import ApplicationServices
import Carbon

/// Opens the already-running source without issuing any playback or navigation command.
@MainActor
final class NowPlayingSourceOpener {
    struct Snapshot: Equatable, Sendable {
        let bundleIdentifier: String
        let title: String
        let artist: String
        let browserURL: String
        let isPlaying: Bool
    }

    enum Outcome: Equatable { case openedApp, openedTab, unavailable, cancelled }

    struct BrowserTab: Equatable, Sendable {
        let windowID: String
        let tabID: String
        let url: String
        let title: String
        let artist: String
        let hasMedia: Bool
        let isPlaying: Bool
    }

    struct Dependencies {
        var runningPID: (String) -> pid_t?
        var hasAutomationPermission: (pid_t) -> Bool
        var executeScript: (String) async -> String?
        var activateApplication: (pid_t, _ allowReopen: Bool) async -> Bool
        /// nil means that browser identity could not be safely determined.
        var isWebBrowser: (String) -> Bool? = { _ in nil }
    }

    struct ActivationObservation {
        let isRunning: Bool
        let isFrontmost: Bool
        let hasVisibleWindow: Bool
    }

    struct ActivationEnvironment {
        var observe: () -> ActivationObservation
        var requestActivation: () -> Void
        var reopen: () -> Bool
        var wait: () async -> Void
    }

    private let dependencies: Dependencies
    private static let scriptQueue = DispatchQueue(label: "com.workview.SuperIsland.source-opener", qos: .userInitiated)
    private static let chromeBundleIDs: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary"]
    private static let otherBrowserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
        "org.mozilla.firefox", "org.mozilla.nightly", "com.brave.Browser", "com.brave.Browser.beta",
        "com.brave.Browser.nightly", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", "org.chromium.Chromium", "com.kagi.kagimacOS", "app.zen-browser.zen"
    ]

    init(dependencies: Dependencies? = nil) {
        self.dependencies = dependencies ?? Self.liveDependencies()
    }

    func open(
        _ snapshot: Snapshot,
        browserDetectionAllowed: Bool,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> Outcome {
        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        guard !snapshot.bundleIdentifier.isEmpty,
              let pid = dependencies.runningPID(snapshot.bundleIdentifier) else { return .unavailable }

        if browserDetectionAllowed,
           Self.chromeBundleIDs.contains(snapshot.bundleIdentifier),
           dependencies.hasAutomationPermission(pid),
           let readScript = Self.readScript(bundleIdentifier: snapshot.bundleIdentifier) {
            let result = await dependencies.executeScript(readScript)
            guard !Task.isCancelled, isCurrent() else { return .cancelled }
            guard dependencies.runningPID(snapshot.bundleIdentifier) == pid else { return .unavailable }
            if let result, let tabs = Self.decodeTabs(result),
               let tab = Self.selectTab(for: snapshot, among: tabs),
               let focusScript = Self.focusScript(bundleIdentifier: snapshot.bundleIdentifier, tab: tab),
               dependencies.hasAutomationPermission(pid) {
                // Re-check before dispatching the only mutating script. That script checks the
                // stable IDs, URL and live media again immediately before selecting the tab.
                guard isCurrent() else { return .cancelled }
                let focused = await dependencies.executeScript(focusScript) == "FOCUSED"
                guard !Task.isCancelled, isCurrent() else { return .cancelled }
                guard dependencies.runningPID(snapshot.bundleIdentifier) == pid else { return .unavailable }
                if focused {
                    let activated = await dependencies.activateApplication(pid, false)
                    guard !Task.isCancelled, isCurrent() else { return .cancelled }
                    return activated ? .openedTab : .unavailable
                }
            }
        }

        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        guard dependencies.runningPID(snapshot.bundleIdentifier) == pid else { return .unavailable }
        let allowReopen = snapshot.browserURL.isEmpty
            && !Self.chromeBundleIDs.contains(snapshot.bundleIdentifier)
            && !Self.otherBrowserBundleIDs.contains(snapshot.bundleIdentifier)
            && dependencies.isWebBrowser(snapshot.bundleIdentifier) == false
        let activated = await dependencies.activateApplication(pid, allowReopen)
        guard !Task.isCancelled, isCurrent() else { return .cancelled }
        return activated ? .openedApp : .unavailable
    }

    /// A successful activation request is not evidence of a visible application. Reopen is
    /// explicit and native-only: some players retain stale AX windows after their red close button.
    static func activateExistingApplication(allowReopen: Bool, environment: ActivationEnvironment) async -> Bool {
        guard !Task.isCancelled, environment.observe().isRunning else { return false }
        if allowReopen { _ = environment.reopen() }
        guard environment.observe().isRunning else { return false }
        environment.requestActivation()
        for _ in 0..<10 {
            await environment.wait()
            guard !Task.isCancelled else { return false }
            let observation = environment.observe()
            guard observation.isRunning else { return false }
            if observation.isFrontmost && observation.hasVisibleWindow { return true }
        }
        return false
    }

    /// A stale URL never wins over live metadata. Repeated matching tabs remain ambiguous
    /// unless exactly one has the expected playback state or URL.
    static func selectTab(for snapshot: Snapshot, among tabs: [BrowserTab]) -> BrowserTab? {
        let title = normalized(snapshot.title)
        guard !title.isEmpty else { return nil }
        var candidates = tabs.filter { tab in
            guard tab.hasMedia, validWebURL(tab.url) else { return false }
            let parts = parsedTitle(tab.title)
            let titleMatches = normalized(tab.title) == title || normalized(parts.title) == title
            guard titleMatches else { return false }
            let artist = normalized(snapshot.artist)
            let liveArtist = normalized(tab.artist.isEmpty ? parts.artist : tab.artist)
            return artist.isEmpty || liveArtist.isEmpty || artist == liveArtist
        }
        guard !candidates.isEmpty else { return nil }
        let sameState = candidates.filter { $0.isPlaying == snapshot.isPlaying }
        if !sameState.isEmpty { candidates = sameState }
        // A currently-playing source cannot be resolved to a paused, merely similarly named tab.
        if snapshot.isPlaying && sameState.isEmpty { return nil }
        if candidates.count == 1 { return candidates[0] }
        let sameURL = candidates.filter { $0.url == snapshot.browserURL }
        return sameURL.count == 1 ? sameURL[0] : nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func parsedTitle(_ raw: String) -> (title: String, artist: String) {
        let clean = raw.replacingOccurrences(of: " - YouTube Music", with: "")
            .replacingOccurrences(of: " - YouTube", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clean.components(separatedBy: " - ")
        return (parts[0], parts.dropFirst().joined(separator: " - "))
    }

    private static func validWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }

    private struct MediaFields: Decodable {
        let url: String
        let title: String
        let artist: String
        let hasMedia: Bool
        let isPlaying: Bool
    }

    static func decodeTabs(_ value: String) -> [BrowserTab]? {
        guard value.utf8.count <= 150_000, value != "INCOMPLETE" else { return nil }
        if value.isEmpty { return [] }
        var tabs: [BrowserTab] = []
        for line in value.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, validID(String(parts[0])), validID(String(parts[1])),
                  let fields = try? JSONDecoder().decode(MediaFields.self, from: Data(parts[2].utf8)) else { return nil }
            tabs.append(.init(windowID: String(parts[0]), tabID: String(parts[1]), url: fields.url,
                              title: fields.title, artist: fields.artist,
                              hasMedia: fields.hasMedia, isPlaying: fields.isPlaying))
        }
        return tabs.count <= 32 ? tabs : nil
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count < 32 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// Only standard media metadata and media element state are inspected, never page body text.
    private static let mediaJavaScript = """
    (() => {
      const elements = Array.from(document.querySelectorAll('audio,video'));
      const media = elements.filter(e => e.readyState > 0 && !e.ended);
      const metadata = navigator.mediaSession && navigator.mediaSession.metadata;
      return JSON.stringify({url: location.href.slice(0, 2048),
        title: String((metadata && metadata.title) || document.title || '').slice(0, 512),
        artist: String((metadata && metadata.artist) || '').slice(0, 256),
        hasMedia: media.length > 0, isPlaying: media.some(e => !e.paused)});
    })()
    """

    static func readScript(bundleIdentifier: String) -> String? {
        guard chromeBundleIDs.contains(bundleIdentifier) else { return nil }
        return """
        if application id \(appleScriptString(bundleIdentifier)) is not running then return ""
        set startedAt to current date
        set rows to ""
        set scannedCount to 0
        with timeout of 1 seconds
          tell application id \(appleScriptString(bundleIdentifier))
            if (count of windows) > 8 then return "INCOMPLETE"
            repeat with w in windows
              repeat with t in tabs of w
                set scannedCount to scannedCount + 1
                if scannedCount > 32 or ((current date) - startedAt) > 2 then return "INCOMPLETE"
                try
                  set tabURL to URL of t
                  if tabURL starts with "https://" or tabURL starts with "http://" then
                    set mediaRow to execute t javascript \(appleScriptString(mediaJavaScript))
                    set rows to rows & (id of w as text) & tab & (id of t as text) & tab & mediaRow & linefeed
                  end if
                on error
                  return "INCOMPLETE"
                end try
              end repeat
            end repeat
          end tell
        end timeout
        return rows
        """
    }

    static func focusScript(bundleIdentifier: String, tab: BrowserTab) -> String? {
        guard chromeBundleIDs.contains(bundleIdentifier), validID(tab.windowID), validID(tab.tabID),
              validWebURL(tab.url) else { return nil }
        let object: [String: Any] = ["url": tab.url, "title": tab.title, "artist": tab.artist,
                                     "hasMedia": tab.hasMedia, "isPlaying": tab.isPlaying]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let expected = String(data: data, encoding: .utf8) else { return nil }
        let check = """
        (() => { const observed = JSON.parse(\(mediaJavaScript)); const expected = \(expected);
          return Object.keys(expected).every(key => observed[key] === expected[key]) ? 'MATCH' : 'CHANGED'; })()
        """
        return """
        if application id \(appleScriptString(bundleIdentifier)) is not running then return "CHANGED"
        set startedAt to current date
        with timeout of 1 seconds
          tell application id \(appleScriptString(bundleIdentifier))
            if (count of windows) > 8 then return "CHANGED"
            repeat with w in windows
              if ((current date) - startedAt) > 2 then return "CHANGED"
              if (id of w as text) is \(appleScriptString(tab.windowID)) then
                set tabNumber to 0
                repeat with t in tabs of w
                  set tabNumber to tabNumber + 1
                  if tabNumber > 32 or ((current date) - startedAt) > 2 then return "CHANGED"
                  if (id of t as text) is \(appleScriptString(tab.tabID)) then
                    if (URL of t) is not \(appleScriptString(tab.url)) then return "CHANGED"
                    if (execute t javascript \(appleScriptString(check))) is not "MATCH" then return "CHANGED"
                    set active tab index of w to tabNumber
                    set minimized of w to false
                    set index of w to 1
                    return "FOCUSED"
                  end if
                end repeat
              end if
            end repeat
          end tell
        end timeout
        return "CHANGED"
        """
    }

    private static func liveDependencies() -> Dependencies {
        .init(runningPID: { bundleIdentifier in
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { !$0.isTerminated && $0.activationPolicy != .prohibited }
            return apps.count == 1 ? apps[0].processIdentifier : nil
        }, hasAutomationPermission: { processID in
            var processID = processID
            guard let address = NSAppleEventDescriptor(descriptorType: typeKernelProcessID,
                                                      bytes: &processID, length: MemoryLayout<pid_t>.size) else {
                return false
            }
            return AEDeterminePermissionToAutomateTarget(address.aeDesc, typeWildCard, typeWildCard, false) == noErr
        }, executeScript: { source in
            await withCheckedContinuation { continuation in
                scriptQueue.async {
                    // Every event has a one-second timeout, and each bounded loop checks a
                    // two-second budget. No Apple Event or script compilation runs on main.
                    var error: NSDictionary?
                    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                    continuation.resume(returning: error == nil ? result?.stringValue : nil)
                }
            }
        }, activateApplication: { processID, allowReopen in
            guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else { return false }
            return await activateExistingApplication(allowReopen: allowReopen, environment: .init(observe: {
                let isRunning = !app.isTerminated
                    && NSRunningApplication(processIdentifier: processID)?.isEqual(app) == true
                let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]] ?? []
                let visible = rows.contains { row in
                    guard row[kCGWindowOwnerPID as String] as? Int32 == processID,
                          row[kCGWindowLayer as String] as? Int == 0,
                          (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                          let bounds = row[kCGWindowBounds as String] as? [String: Any],
                          let width = bounds["Width"] as? Double,
                          let height = bounds["Height"] as? Double else { return false }
                    return width >= 80 && height >= 50
                }
                return .init(isRunning: isRunning,
                             isFrontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
                             hasVisibleWindow: !app.isHidden && visible)
            }, requestActivation: {
                guard !app.isTerminated else { return }
                _ = app.unhide()
                _ = app.activate(options: [])
                // The Dock preview already uses this exact AX frontmost/focus/raise sequence.
                // Do not gate it on the activation request's return value.
                guard AXIsProcessTrusted() else { return }
                let application = AXUIElementCreateApplication(processID)
                AXUIElementSetMessagingTimeout(application, 0.15)
                _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                if let window = restorableWindow(application: application, processID: processID) {
                    AXUIElementSetMessagingTimeout(window, 0.15)
                    _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    _ = AXUIElementSetAttributeValue(application, kAXFocusedWindowAttribute as CFString, window)
                    _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                    _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
            }, reopen: {
                guard !app.isTerminated else { return false }
                return sendReopen(to: processID)
            }, wait: {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }))
        }, isWebBrowser: { bundleIdentifier in
            let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { !$0.isTerminated && $0.activationPolicy != .prohibited }
            guard applications.count == 1, let appURL = applications[0].bundleURL,
                  let bundle = Bundle(url: appURL), let info = bundle.infoDictionary,
                  info["CFBundleIdentifier"] as? String == bundleIdentifier else { return nil }
            var schemes: [String] = []
            if let rawTypes = info["CFBundleURLTypes"] {
                guard let types = rawTypes as? [[String: Any]] else { return nil }
                for type in types {
                    guard let declared = type["CFBundleURLSchemes"] as? [String] else { return nil }
                    schemes.append(contentsOf: declared)
                }
            }
            // LaunchServices lookup only: these URLs are never opened or requested.
            func handlerIDs(for scheme: String) -> [String]? {
                guard let url = URL(string: "\(scheme)://example.invalid") else { return nil }
                let urls = NSWorkspace.shared.urlsForApplications(toOpen: url)
                guard !urls.isEmpty else { return nil }
                let identifiers = urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
                return identifiers.count == urls.count ? identifiers : nil
            }
            return classifyWebBrowser(bundleIdentifier: bundleIdentifier, declaredSchemes: schemes,
                                      httpHandlers: handlerIDs(for: "http"), httpsHandlers: handlerIDs(for: "https"))
        })
    }

    static func classifyWebBrowser(bundleIdentifier: String, declaredSchemes: [String],
                                   httpHandlers: [String]?, httpsHandlers: [String]?) -> Bool? {
        if declaredSchemes.contains(where: { ["http", "https"].contains($0.lowercased()) }) { return true }
        guard let httpHandlers, !httpHandlers.isEmpty, let httpsHandlers, !httpsHandlers.isEmpty else { return nil }
        return httpHandlers.contains(bundleIdentifier) || httpsHandlers.contains(bundleIdentifier)
    }

    private static func restorableWindow(application: AXUIElement, processID: pid_t) -> AXUIElement? {
        var candidates: [AXUIElement] = []
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                candidates.append(unsafeBitCast(value, to: AXUIElement.self))
            }
        }
        if candidates.isEmpty {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                candidates.append(contentsOf: windows.prefix(8))
            }
        }
        return candidates.first { window in
            var owner: pid_t = 0
            return AXUIElementGetPid(window, &owner) == .success && owner == processID
        }
    }

    /// Targeting an existing PID cannot launch an exited source. This is the reopen event
    /// used for an explicit application-open action, with no documents or playback commands.
    private static func sendReopen(to processID: pid_t) -> Bool {
        var processID = processID
        guard let address = NSAppleEventDescriptor(descriptorType: typeKernelProcessID,
                                                  bytes: &processID, length: MemoryLayout<pid_t>.size) else { return false }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                          eventID: AEEventID(kAEReopenApplication), targetDescriptor: address,
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: AEKeyword(kAEApplicationActivationExpected))
        let options = AESendMode(kAENoReply | kAENeverInteract | kAEDoNotPromptForUserConsent)
        return AESendMessage(event.aeDesc, nil, options, 15) == noErr
    }
}
