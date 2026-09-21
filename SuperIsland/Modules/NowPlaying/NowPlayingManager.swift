import AppKit
import Combine
import Darwin
import ImageIO

// MARK: - MediaRemote Function Types
private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
private typealias MRMediaRemoteGetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
private typealias MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
private typealias MRMediaRemoteSendCommandFunction = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
private typealias MRMediaRemoteSetElapsedTimeFunction = @convention(c) (Double) -> Void

// MediaRemote command constants
private let kMRPlay: UInt32 = 0
private let kMRPause: UInt32 = 1
private let kMRTogglePlayPause: UInt32 = 2
private let kMRStop: UInt32 = 3
private let kMRNextTrack: UInt32 = 4
private let kMRPreviousTrack: UInt32 = 5

// MediaRemote info keys
private let kMRMediaRemoteNowPlayingInfoTitle = "kMRMediaRemoteNowPlayingInfoTitle"
private let kMRMediaRemoteNowPlayingInfoArtist = "kMRMediaRemoteNowPlayingInfoArtist"
private let kMRMediaRemoteNowPlayingInfoAlbum = "kMRMediaRemoteNowPlayingInfoAlbum"
private let kMRMediaRemoteNowPlayingInfoArtworkData = "kMRMediaRemoteNowPlayingInfoArtworkData"
private let kMRMediaRemoteNowPlayingInfoDuration = "kMRMediaRemoteNowPlayingInfoDuration"
private let kMRMediaRemoteNowPlayingInfoElapsedTime = "kMRMediaRemoteNowPlayingInfoElapsedTime"
private let kMRMediaRemoteNowPlayingInfoPlaybackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

private let nowPlayingBrowserDetectionEnabledKey = "nowPlaying.browserDetection.enabled"
private let nowPlayingAllowedBrowserBundleIDsKey = "nowPlaying.browserDetection.allowedBrowserBundleIDs"
private let nowPlayingDefaultAllowedBrowserBundleIDs = ["com.google.Chrome"]
private let nowPlayingSupportedBrowserTargets = [
    NowPlayingBrowserTarget(
        id: "com.google.Chrome",
        displayName: "Google Chrome",
        applicationName: "Google Chrome",
        processName: "Google Chrome"
    ),
    NowPlayingBrowserTarget(
        id: "com.google.Chrome.canary",
        displayName: "Google Chrome Canary",
        applicationName: "Google Chrome Canary",
        processName: "Google Chrome Canary"
    )
]

@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()

    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var albumArt: NSImage?
    @Published var albumArtColor: NSColor?
    @Published var isPlaying: Bool = false
    @Published var duration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published var playbackRate: Double = 0
    @Published var sourceName: String = "" // "Spotify", "Apple Music", "Chrome", etc.
    @Published var providerStatus: NowPlayingProviderStatus = .idle
    @Published private(set) var isOpeningPlaybackSource = false
    @Published private var failedPlaybackSource: NowPlayingSourceOpener.Snapshot?
    private let sourceOpener = NowPlayingSourceOpener()
    @Published var browserDetectionTestMessage: String = ""
    @Published var browserDetectionEnabled: Bool = UserDefaults.standard.bool(forKey: nowPlayingBrowserDetectionEnabledKey) {
        didSet {
            UserDefaults.standard.set(browserDetectionEnabled, forKey: nowPlayingBrowserDetectionEnabledKey)
            browserDetectionTestMessage = ""
            if browserDetectionEnabled {
                refreshPreferredSource()
            } else if isBrowserPlaybackSource {
                clearCurrentTrack()
                providerStatus = .browserDisabled
            }
        }
    }
    @Published var allowedBrowserBundleIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: nowPlayingAllowedBrowserBundleIDsKey) ?? nowPlayingDefaultAllowedBrowserBundleIDs
    ) {
        didSet {
            let ordered = nowPlayingSupportedBrowserTargets.map(\.id).filter { allowedBrowserBundleIDs.contains($0) }
            UserDefaults.standard.set(ordered, forKey: nowPlayingAllowedBrowserBundleIDsKey)
            if browserDetectionEnabled {
                refreshPreferredSource()
            }
        }
    }
    private var currentAlbumArtist: String = ""
    private var currentArtworkURL: String?
    private var currentArtworkIdentity: String?
    private var currentTrackIdentifier: String = ""
    private var currentTrackIsLocalFile = false

    private var handle: UnsafeMutableRawPointer?
    private var registerFunc: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
    private var getNowPlayingInfoFunc: MRMediaRemoteGetNowPlayingInfoFunction?
    private var getIsPlayingFunc: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction?
    private var sendCommandFunc: MRMediaRemoteSendCommandFunction?
    private var setElapsedTimeFunc: MRMediaRemoteSetElapsedTimeFunction?

    private var sourceRefreshToken: ModuleRefreshToken?
    private var playbackRefreshToken: ModuleRefreshToken?
    private var lastPlaybackTickDate: Date?
    private var cancellables = Set<AnyCancellable>()

    // Track whether MediaRemote is providing data
    private var mediaRemoteActive = false
    // Track last detected title to avoid re-activating the module on every poll
    private var lastDetectedTitle: String = ""
    // Track the most recent Chrome media tab and the last one paused by our controls.
    private var currentChromeTabURL: String = ""
    private var lastPausedChromeTabURL: String = ""
    private var currentBundleIdentifier: String = ""
    private var lastPlaybackUpdateDate: Date = .distantPast
    private var recentTrackChangeDate: Date = .distantPast
    private var lastKnownSnapshot: NowPlayingSnapshot?
    private var providerRefreshTask: Task<Void, Never>?
    private var artworkDownloadTask: URLSessionDownloadTask?
    private var pendingArtworkIdentity: String?
    private var artworkLoadGeneration: UInt64 = 0
    private var albumArtColorGeneration: UInt64 = 0
    private var adapterProcess: Process?
    private var adapterPipeHandler: JSONLinesPipeHandler?
    private var adapterStreamTask: Task<Void, Never>?
    private var adapterDidDeliverUpdate = false
    private let appleScriptQueue = DispatchQueue(label: "superisland.applescript", qos: .userInitiated)

    private init() {
        loadMediaRemote()
        registerForNotifications()
        Task { [weak self] in
            await self?.startMediaRemoteAdapterObserver()
        }
        fetchNowPlayingInfo()
        observeSpotify()
        observeAlbumArtColor()

        // Trigger first AppleScript check on main thread to ensure
        // the macOS automation permission dialog appears
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.refreshPreferredSource()
            self?.startPolling()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        sourceRefreshToken = ModuleRefreshScheduler.shared.register(
            id: "nowPlaying.source",
            name: "Now Playing fallback refresh",
            module: .builtIn(.nowPlaying),
            policy: .interval(5, tolerance: 2),
            enabled: { AppState.shared.nowPlayingEnabled }
        ) { [weak self] in
            guard let self else { return }
            self.refreshPreferredSource()
        }
    }

    // MARK: - MediaRemote Loading

    private func loadMediaRemote() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        guard handle != nil else {
            print("[NowPlaying] Failed to load MediaRemote framework")
            return
        }

        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerFunc = unsafeBitCast(sym, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfoFunc = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingInfoFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            getIsPlayingFunc = unsafeBitCast(sym, to: MRMediaRemoteGetNowPlayingApplicationIsPlayingFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFunc = unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimeFunc = unsafeBitCast(sym, to: MRMediaRemoteSetElapsedTimeFunction.self)
        }
    }

    // MARK: - Registration

    private func registerForNotifications() {
        registerFunc?(DispatchQueue.main)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingApplicationIsPlayingDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingApplicationDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
            object: nil
        )
    }

    // MARK: - Spotify Distributed Notifications

    private func observeAlbumArtColor() {
        $albumArt
            .removeDuplicates { previous, next in
                switch (previous, next) {
                case (nil, nil):
                    return true
                case let (previous?, next?):
                    return previous === next
                default:
                    return false
                }
            }
            .sink { [weak self] image in
                guard let self else { return }
                self.albumArtColorGeneration &+= 1
                let generation = self.albumArtColorGeneration

                guard let image else {
                    if self.albumArtColor != nil {
                        self.albumArtColor = nil
                    }
                    return
                }

                image.averageColor { [weak self, weak image] color in
                    guard let self,
                          let image,
                          generation == self.albumArtColorGeneration,
                          self.albumArt === image,
                          let color else { return }
                    let rgb = color.usingColorSpace(.sRGB) ?? color
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                    let adjustedColor = NSColor(
                        hue: h,
                        saturation: min(max(s * 1.15, 0.55), 1.0),
                        brightness: min(max(b * 1.18, 0.72), 1.0),
                        alpha: a
                    )
                    if self.albumArtColor?.isEqual(adjustedColor) != true {
                        self.albumArtColor = adjustedColor
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func observeSpotify() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyStateChanged),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
    }

    @objc private func spotifyStateChanged(_ notification: Notification) {
        refreshPreferredSource()
    }

    // MARK: - Notification Handlers

    @objc private func nowPlayingInfoDidChange() {
        refreshPreferredSource()
    }

    @objc private func nowPlayingApplicationIsPlayingDidChange() {
        refreshPreferredSource()
    }

    @objc private func nowPlayingApplicationDidChange() {
        refreshPreferredSource()
    }

    // MARK: - MediaRemote Data Fetching

    func fetchNowPlayingInfo() {
        getNowPlayingInfoFunc?(DispatchQueue.main) { [weak self] info in
            guard let self else { return }

            let newTitle = info[kMRMediaRemoteNowPlayingInfoTitle] as? String ?? ""
            let newPlaybackRate = info[kMRMediaRemoteNowPlayingInfoPlaybackRate] as? Double ?? 0

            if !newTitle.isEmpty {
                let newIsPlaying = newPlaybackRate > 0
                let newArtist = info[kMRMediaRemoteNowPlayingInfoArtist] as? String ?? ""
                let newAlbum = info[kMRMediaRemoteNowPlayingInfoAlbum] as? String ?? ""
                let newDuration = info[kMRMediaRemoteNowPlayingInfoDuration] as? TimeInterval ?? 0
                let newElapsedTime = info[kMRMediaRemoteNowPlayingInfoElapsedTime] as? TimeInterval ?? 0
                let playbackAnchorChanged =
                    self.title != newTitle ||
                    self.isPlaying != newIsPlaying ||
                    self.duration != newDuration ||
                    self.elapsedTime != newElapsedTime ||
                    self.playbackRate != newPlaybackRate

                self.mediaRemoteActive = true
                self.currentChromeTabURL = ""
                self.currentBundleIdentifier = ""
                self.currentAlbumArtist = ""
                self.cancelPendingArtworkLoad()
                self.currentArtworkURL = nil
                self.currentTrackIdentifier = ""
                self.currentTrackIsLocalFile = false
                self.assignIfChanged(newTitle, to: \NowPlayingManager.title)
                self.assignIfChanged(newArtist, to: \NowPlayingManager.artist)
                self.assignIfChanged(newAlbum, to: \NowPlayingManager.album)
                self.assignIfChanged(newDuration, to: \NowPlayingManager.duration)
                self.assignIfChanged(newElapsedTime, to: \NowPlayingManager.elapsedTime)
                self.assignIfChanged(newPlaybackRate, to: \NowPlayingManager.playbackRate)
                self.assignIfChanged(newIsPlaying, to: \NowPlayingManager.isPlaying)
                self.assignIfChanged("System Media", to: \NowPlayingManager.sourceName)
                self.assignIfChanged(
                    newIsPlaying ? .playing("System Media") : .paused("System Media"),
                    to: \NowPlayingManager.providerStatus
                )

                if let artworkData = info[kMRMediaRemoteNowPlayingInfoArtworkData] as? Data {
                    self.applyInlineArtworkData(artworkData)
                }

                self.rememberCurrentSnapshot(providerID: "system")

                // Only activate module when track changes, not on every poll
                if newIsPlaying, newTitle != self.lastDetectedTitle {
                    self.lastDetectedTitle = newTitle
                    AppState.shared.setActiveModule(.nowPlaying)
                }
                self.updatePlaybackTimer(resetTickBaseline: playbackAnchorChanged)
            } else {
                self.mediaRemoteActive = false
                if !self.showLastKnownSnapshotIfUseful() {
                    self.clearCurrentTrack()
                }
            }
        }
    }

    private func fetchPlaybackState() {
        getIsPlayingFunc?(DispatchQueue.main) { [weak self] playing in
            guard let self else { return }
            let playbackStateChanged = self.assignIfChanged(playing, to: \NowPlayingManager.isPlaying)
            self.assignIfChanged(
                playing ? .playing(self.sourceName) : .paused(self.sourceName),
                to: \NowPlayingManager.providerStatus
            )
            self.updatePlaybackTimer(resetTickBaseline: playbackStateChanged)
        }
    }

    // MARK: - MediaRemote Adapter

    private func startMediaRemoteAdapterObserver() async {
        guard adapterProcess == nil else { return }
        guard let resources = mediaRemoteAdapterResources() else {
            print("[NowPlaying] MediaRemote adapter resources not found")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [resources.scriptURL.path, resources.frameworkURL.path, "stream", "--debounce=250"]

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.adapterProcess = nil
                self?.adapterPipeHandler = nil
                self?.adapterStreamTask = nil
                self?.adapterDidDeliverUpdate = false
            }
        }

        adapterProcess = process
        adapterPipeHandler = pipeHandler

        do {
            try process.run()
            adapterStreamTask = Task { [weak self] in
                await self?.processAdapterJSONStream()
            }
        } catch {
            print("[NowPlaying] Failed to launch MediaRemote adapter: \(error)")
            adapterProcess = nil
            adapterPipeHandler = nil
        }
    }

    private func processAdapterJSONStream() async {
        guard let pipeHandler = adapterPipeHandler else { return }

        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            await self?.handleAdapterUpdate(update)
        }
    }

    private func handleAdapterUpdate(_ update: NowPlayingUpdate) async {
        adapterDidDeliverUpdate = true

        let payload = update.payload
        let diff = update.diff ?? false
        let previousElapsedTime = elapsedTime
        let previousDuration = duration
        let previousIsPlaying = isPlaying
        let previousPlaybackRate = playbackRate
        let previousPlaybackUpdateDate = lastPlaybackUpdateDate
        let incomingBundleIdentifier = payload.parentApplicationBundleIdentifier ?? payload.bundleIdentifier ?? ""
        let bundleIdentifier = incomingBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (diff ? currentBundleIdentifier : "")
            : incomingBundleIdentifier
        let resolvedTitle = payload.title ?? (diff ? title : "")
        let resolvedArtist = payload.artist ?? (diff ? artist : "")
        let resolvedAlbum = payload.album ?? (diff ? album : "")
        let resolvedAlbumArtist = payload.albumArtist ?? (diff ? currentAlbumArtist : "")
        let resolvedDuration = payload.duration ?? (diff ? duration : 0)
        let resolvedPlaybackRate = payload.playbackRate ?? (diff ? playbackRate : 1.0)
        let resolvedIsPlaying = payload.playing ?? (diff ? isPlaying : false)
        let resolvedSourceName = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (diff ? sourceName : "Unknown")
            : sourceName(forBundleIdentifier: bundleIdentifier)
        let resolvedTrackIdentifier = payload.trackIdentifier ?? (diff ? currentTrackIdentifier : "")
        let resolvedIsLocalFile = payload.isLocalFile ?? (diff ? currentTrackIsLocalFile : false)
        let previousTrackSignature = trackSignature(
            title: title,
            artist: artist,
            album: album,
            bundleIdentifier: currentBundleIdentifier
        )
        let incomingTrackSignature = trackSignature(
            title: resolvedTitle,
            artist: resolvedArtist,
            album: resolvedAlbum,
            bundleIdentifier: bundleIdentifier
        )
        let trackChanged = !resolvedTitle.isEmpty && incomingTrackSignature != previousTrackSignature
        let resolvedUpdateDate: Date

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            resolvedUpdateDate = date
        } else if diff {
            resolvedUpdateDate = previousPlaybackUpdateDate
        } else {
            resolvedUpdateDate = Date()
        }

        let resolvedElapsedTime: TimeInterval

        if let rawElapsedTime = payload.elapsedTime {
            resolvedElapsedTime = clampElapsedTime(rawElapsedTime, duration: resolvedDuration)
        } else if trackChanged {
            resolvedElapsedTime = 0
        } else if diff {
            if payload.playing == false {
                let delta = max(0, Date().timeIntervalSince(previousPlaybackUpdateDate))
                resolvedElapsedTime = clampElapsedTime(
                    previousElapsedTime + (previousPlaybackRate * delta),
                    duration: resolvedDuration
                )
            } else {
                resolvedElapsedTime = clampElapsedTime(previousElapsedTime, duration: resolvedDuration)
            }
        } else {
            resolvedElapsedTime = 0
        }

        if resolvedTitle.isEmpty, bundleIdentifier.isEmpty {
            clearCurrentTrack()
            return
        }

        if trackChanged {
            recentTrackChangeDate = Date()
            cancelPendingArtworkLoad()
        }

        let shouldResetSuspiciousElapsedTime =
            Date().timeIntervalSince(recentTrackChangeDate) < 1.5 &&
            resolvedElapsedTime > 3 &&
            resolvedDuration > 0 &&
            resolvedElapsedTime < resolvedDuration
        let publishedElapsedTime = shouldResetSuspiciousElapsedTime ? 0 : resolvedElapsedTime
        let playbackAnchorChanged =
            trackChanged ||
            previousIsPlaying != resolvedIsPlaying ||
            previousDuration != resolvedDuration ||
            previousPlaybackRate != resolvedPlaybackRate ||
            previousElapsedTime != publishedElapsedTime

        mediaRemoteActive = !resolvedTitle.isEmpty || !bundleIdentifier.isEmpty
        currentBundleIdentifier = bundleIdentifier
        currentAlbumArtist = resolvedAlbumArtist
        currentTrackIdentifier = resolvedTrackIdentifier
        currentTrackIsLocalFile = resolvedIsLocalFile
        lastPlaybackUpdateDate = resolvedUpdateDate
        assignIfChanged(resolvedTitle, to: \NowPlayingManager.title)
        assignIfChanged(resolvedArtist, to: \NowPlayingManager.artist)
        assignIfChanged(resolvedAlbum, to: \NowPlayingManager.album)
        assignIfChanged(resolvedDuration, to: \NowPlayingManager.duration)
        assignIfChanged(resolvedPlaybackRate, to: \NowPlayingManager.playbackRate)
        assignIfChanged(resolvedIsPlaying, to: \NowPlayingManager.isPlaying)
        assignIfChanged(resolvedSourceName, to: \NowPlayingManager.sourceName)
        assignIfChanged(
            resolvedIsPlaying ? .playing(resolvedSourceName) : .paused(resolvedSourceName),
            to: \NowPlayingManager.providerStatus
        )

        assignIfChanged(publishedElapsedTime, to: \NowPlayingManager.elapsedTime)

        if isChromeBundleIdentifier(bundleIdentifier) {
            if !resolvedIsPlaying && !currentChromeTabURL.isEmpty {
                lastPausedChromeTabURL = currentChromeTabURL
            }
        } else {
            currentChromeTabURL = ""
            lastPausedChromeTabURL = ""
        }

        if let artworkDataString = payload.artworkData,
           let artworkData = Data(base64Encoded: artworkDataString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            applyInlineArtworkData(artworkData)
            currentArtworkURL = nil
        } else if resolvedTitle.isEmpty {
            clearAlbumArt()
            currentArtworkURL = nil
        }

        rememberCurrentSnapshot(providerID: "mediaRemoteAdapter")

        if resolvedIsPlaying, !resolvedTitle.isEmpty, resolvedTitle != lastDetectedTitle {
            lastDetectedTitle = resolvedTitle
            AppState.shared.setActiveModule(.nowPlaying)
        } else if resolvedTitle.isEmpty {
            lastDetectedTitle = ""
        }

        updatePlaybackTimer(resetTickBaseline: playbackAnchorChanged)
    }

    private func mediaRemoteAdapterResources() -> (scriptURL: URL, frameworkURL: URL)? {
        let fm = FileManager.default

        // Xcode copies the .pl script to Contents/Resources and the .framework to
        // Contents/Frameworks — check those canonical bundle locations first.
        if let resourceURL = Bundle.main.resourceURL,
           let frameworksURL = Bundle.main.privateFrameworksURL {
            let scriptURL = resourceURL.appendingPathComponent("mediaremote-adapter.pl")
            let frameworkURL = frameworksURL.appendingPathComponent("MediaRemoteAdapter.framework")
            if fm.fileExists(atPath: scriptURL.path),
               fm.fileExists(atPath: frameworkURL.path) {
                return (scriptURL, frameworkURL)
            }
        }

        // Legacy layout: both files inside a MediaRemoteAdapter/ subfolder in Resources.
        if let resourceURL = Bundle.main.resourceURL {
            let dir = resourceURL.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
            let scriptURL = dir.appendingPathComponent("mediaremote-adapter.pl")
            let frameworkURL = dir.appendingPathComponent("MediaRemoteAdapter.framework")
            if fm.fileExists(atPath: scriptURL.path),
               fm.fileExists(atPath: frameworkURL.path) {
                return (scriptURL, frameworkURL)
            }
        }

        // Dev fallback: resolve relative to source file (only works on the build machine).
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapterDirectory = sourceRoot.appendingPathComponent("Resources/MediaRemoteAdapter", isDirectory: true)
        let scriptURL = adapterDirectory.appendingPathComponent("mediaremote-adapter.pl")
        let frameworkURL = adapterDirectory.appendingPathComponent("MediaRemoteAdapter.framework")

        guard fm.fileExists(atPath: scriptURL.path),
              fm.fileExists(atPath: frameworkURL.path) else {
            return nil
        }

        return (scriptURL, frameworkURL)
    }

    // MARK: - AppleScript Fallback

    private func refreshPreferredSource() {
        if adapterDidDeliverUpdate, !title.isEmpty {
            assignIfChanged(
                isPlaying ? .playing(sourceName) : .paused(sourceName),
                to: \NowPlayingManager.providerStatus
            )
            return
        }

        let currentSource = sourceName
        providerRefreshTask?.cancel()
        providerRefreshTask = Task { [weak self] in
            await self?.refreshProviderSnapshots(preferredSourceName: currentSource)
        }
    }

    private func refreshProviderSnapshots(preferredSourceName: String) async {
        var fallbackSnapshot: NowPlayingSnapshot?

        for provider in scriptProviders(preferredSourceName: preferredSourceName) {
            guard !Task.isCancelled else { return }
            assignIfChanged(.checking(provider.displayName), to: \NowPlayingManager.providerStatus)
            guard let snapshot = await provider.currentSnapshot() else { continue }

            if snapshot.isPlaying {
                applySnapshot(snapshot)
                fetchArtworkIfNeeded(for: snapshot)
                mediaRemoteActive = false
                return
            }

            if fallbackSnapshot == nil {
                fallbackSnapshot = snapshot
            }
        }

        if let fallbackSnapshot {
            applySnapshot(fallbackSnapshot)
            fetchArtworkIfNeeded(for: fallbackSnapshot)
            mediaRemoteActive = false
            return
        }

        if showLastKnownSnapshotIfUseful() {
            return
        }

        assignIfChanged(
            browserDetectionEnabled ? .idle : .browserDisabled,
            to: \NowPlayingManager.providerStatus
        )
        fetchNowPlayingInfo()
    }

    private func scriptProviders(preferredSourceName: String) -> [any NowPlayingProvider] {
        var providers: [any NowPlayingProvider] = []

        switch preferredSourceName {
        case "Spotify":
            providers.append(spotifyProvider)
        case "Apple Music":
            providers.append(musicProvider)
        case "YouTube", "YouTube Music", "SoundCloud", "Spotify Web", "Google Chrome", "Google Chrome Canary":
            if browserDetectionEnabled {
                providers.append(browserProvider)
            }
        default:
            break
        }

        providers.append(spotifyProvider)
        providers.append(musicProvider)

        if browserDetectionEnabled {
            providers.append(browserProvider)
        }

        var seen = Set<String>()
        return providers.filter { seen.insert($0.id).inserted }
    }

    private var spotifyProvider: any NowPlayingProvider {
        NowPlayingScriptProvider(
            id: "spotify",
            displayName: "Spotify",
            requiresPermission: true,
            currentSnapshot: { [weak self] in
                guard let self else { return nil }
                return await self.runOnAppleScriptQueue {
                    self.spotifySnapshotViaAppleScript(allowPausedFallback: true)
                }
            }
        )
    }

    private var musicProvider: any NowPlayingProvider {
        NowPlayingScriptProvider(
            id: "appleMusic",
            displayName: "Apple Music",
            requiresPermission: true,
            currentSnapshot: { [weak self] in
                guard let self else { return nil }
                return await self.runOnAppleScriptQueue {
                    self.musicSnapshotViaAppleScript(allowPausedFallback: true)
                }
            }
        )
    }

    private var browserProvider: any NowPlayingProvider {
        NowPlayingScriptProvider(
            id: "browser",
            displayName: "Browser",
            requiresPermission: true,
            currentSnapshot: { [weak self] in
                guard let self else { return nil }
                return await self.runOnAppleScriptQueue {
                    self.browserSnapshotViaAppleScript(allowPausedFallback: true)
                }
            }
        )
    }

    private func runOnAppleScriptQueue<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            appleScriptQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private var shouldUseMediaRemoteControls: Bool {
        mediaRemoteActive || (adapterDidDeliverUpdate && !currentBundleIdentifier.isEmpty)
    }

    nonisolated private func fetchSpotifyViaAppleScript(allowPausedFallback: Bool = true) -> Bool {
        guard let snapshot = spotifySnapshotViaAppleScript(allowPausedFallback: allowPausedFallback) else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.applySnapshot(snapshot)
        }
        fetchSpotifyArtwork()
        return true
    }

    nonisolated private func spotifySnapshotViaAppleScript(allowPausedFallback: Bool) -> NowPlayingSnapshot? {
        guard isApplicationInstalled(bundleIdentifier: "com.spotify.client") else { return nil }
        let pausedReturn = allowPausedFallback ? "or player state is paused" : ""
        let script = """
        tell application "System Events"
            if not (exists process "Spotify") then return "NOT_RUNNING"
        end tell
        tell application "Spotify"
            if player state is playing \(pausedReturn) then
                set playbackState to player state as string
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                set trackURL to ""
                try
                    set trackURL to spotify url of current track
                end try
                return playbackState & "||" & trackName & "||" & trackArtist & "||" & trackAlbum & "||" & (trackDuration / 1000) & "||" & trackPosition & "||" & trackURL
            else
                return "NOT_PLAYING"
            end if
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_PLAYING" else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 7 else { return nil }

        let trackURL = parts[6]
        return NowPlayingSnapshot(
            providerID: "spotify",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: TimeInterval(parts[4]) ?? 0,
            elapsedTime: TimeInterval(parts[5]) ?? 0,
            playbackRate: parts[0] == "playing" ? 1 : 0,
            isPlaying: parts[0] == "playing",
            sourceName: "Spotify",
            bundleIdentifier: "com.spotify.client",
            albumArtist: parts[2],
            artworkURL: nil,
            trackIdentifier: trackURL,
            isLocalFile: trackURL.isEmpty,
            browserTabURL: "",
            capturedAt: Date()
        )
    }

    nonisolated private func fetchSpotifyArtwork() {
        guard isApplicationInstalled(bundleIdentifier: "com.spotify.client") else { return }
        let script = """
        tell application "Spotify"
            return artwork url of current track
        end tell
        """
        guard let urlString = runAppleScript(script), URL(string: urlString) != nil else { return }
        fetchRemoteArtwork(from: urlString)
    }

    nonisolated private func fetchMusicViaAppleScript(allowPausedFallback: Bool = true) -> Bool {
        guard let snapshot = musicSnapshotViaAppleScript(allowPausedFallback: allowPausedFallback) else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.applySnapshot(snapshot)
        }
        return true
    }

    nonisolated private func musicSnapshotViaAppleScript(allowPausedFallback: Bool) -> NowPlayingSnapshot? {
        guard isApplicationInstalled(bundleIdentifier: "com.apple.Music") else { return nil }
        let pausedReturn = allowPausedFallback ? "or player state is paused" : ""
        let script = """
        tell application "System Events"
            if not (exists process "Music") then return "NOT_RUNNING"
        end tell
        tell application "Music"
            if player state is playing \(pausedReturn) then
                set playbackState to player state as string
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                set trackAlbumArtist to ""
                try
                    set trackAlbumArtist to album artist of current track
                end try
                set trackPersistentID to ""
                try
                    set trackPersistentID to persistent ID of current track
                end try
                set trackLocation to ""
                try
                    set trackLocation to POSIX path of (location of current track)
                end try
                return playbackState & "||" & trackName & "||" & trackArtist & "||" & trackAlbum & "||" & trackDuration & "||" & trackPosition & "||" & trackAlbumArtist & "||" & trackPersistentID & "||" & trackLocation
            else
                return "NOT_PLAYING"
            end if
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_PLAYING" else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 9 else { return nil }

        return NowPlayingSnapshot(
            providerID: "appleMusic",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: TimeInterval(parts[4]) ?? 0,
            elapsedTime: TimeInterval(parts[5]) ?? 0,
            playbackRate: parts[0] == "playing" ? 1 : 0,
            isPlaying: parts[0] == "playing",
            sourceName: "Apple Music",
            bundleIdentifier: "com.apple.Music",
            albumArtist: parts[6],
            artworkURL: nil,
            trackIdentifier: parts[7],
            isLocalFile: !parts[8].isEmpty,
            browserTabURL: "",
            capturedAt: Date()
        )
    }

    nonisolated private func fetchChromeViaAppleScript(allowPausedFallback: Bool = true) -> Bool {
        guard let snapshot = browserSnapshotViaAppleScript(allowPausedFallback: allowPausedFallback) else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.applySnapshot(snapshot)
            self?.fetchArtworkIfNeeded(for: snapshot)
        }
        return true
    }

    nonisolated private func browserSnapshotViaAppleScript(allowPausedFallback: Bool) -> NowPlayingSnapshot? {
        guard UserDefaults.standard.bool(forKey: nowPlayingBrowserDetectionEnabledKey) else { return nil }

        var pausedSnapshot: NowPlayingSnapshot?
        let allowedBundleIDs = Set(
            UserDefaults.standard.stringArray(forKey: nowPlayingAllowedBrowserBundleIDsKey) ?? nowPlayingDefaultAllowedBrowserBundleIDs
        )
        let targets = nowPlayingSupportedBrowserTargets.filter { allowedBundleIDs.contains($0.id) }

        for target in targets {
            guard let snapshot = browserSnapshotViaAppleScript(for: target, allowPausedFallback: allowPausedFallback) else {
                continue
            }
            if snapshot.isPlaying {
                return snapshot
            }
            if pausedSnapshot == nil {
                pausedSnapshot = snapshot
            }
        }
        return pausedSnapshot
    }

    nonisolated private func browserSnapshotViaAppleScript(
        for target: NowPlayingBrowserTarget,
        allowPausedFallback: Bool
    ) -> NowPlayingSnapshot? {
        guard isApplicationInstalled(bundleIdentifier: target.id) else { return nil }
        let pausedReturn = allowPausedFallback
            ? "if pausedURL is not \"\" then return \"PAUSED_TAB||\" & pausedTitle & \"||\" & pausedURL & \"||\" & pausedInfo"
            : ""
        let processName = escapeAppleScriptString(target.processName)
        let applicationName = escapeAppleScriptString(target.applicationName)
        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return "NOT_RUNNING"
        end tell
        tell application "\(applicationName)"
            set playingTitle to ""
            set playingURL to ""
            set playingInfo to ""
            set pausedTitle to ""
            set pausedURL to ""
            set pausedInfo to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set mediaInfo to execute t javascript "
                            (function() {
                                var media = Array.from(document.querySelectorAll('video,audio'));
                                if (!media.length) return 'NO_MEDIA';
                                var active = media.find(function(item) { return !item.paused && !item.ended; });
                                var candidate = active || media.find(function(item) { return !item.ended; }) || media[0];
                                if (!candidate) return 'NO_MEDIA';
                                var metaImage = document.querySelector('meta[property=\"og:image\"], meta[name=\"twitter:image\"], link[rel=\"image_src\"]');
                                var thumbnail = candidate.poster || (metaImage ? (metaImage.content || metaImage.href || '') : '');
                                return (active ? 'PLAYING' : 'PAUSED') + '||' + candidate.currentTime + '||' + candidate.duration + '||' + thumbnail;
                            })();
                        "
                        if mediaInfo starts with "PLAYING||" then
                            set playingTitle to title of t
                            set playingURL to URL of t
                            set playingInfo to mediaInfo
                            exit repeat
                        else if mediaInfo starts with "PAUSED||" then
                            if pausedURL is "" then
                                set pausedTitle to title of t
                                set pausedURL to URL of t
                                set pausedInfo to mediaInfo
                            end if
                        end if
                    end try
                end repeat
                if playingURL is not "" then exit repeat
            end repeat
            if playingURL is not "" then return "PLAYING_TAB||" & playingTitle & "||" & playingURL & "||" & playingInfo
            \(pausedReturn)
            return "NOT_FOUND"
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_FOUND" else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 5 else { return nil }

        let rawTitle = parts[1]
        let url = parts[2]
        let playbackState = parts[3]
        let artworkURL = parts.count >= 7 ? parts[6] : ""

        var mediaCurrentTime: TimeInterval = 0
        var mediaDuration: TimeInterval = 0
        let mediaIsPlaying = playbackState == "PLAYING"

        mediaCurrentTime = TimeInterval(parts[4]) ?? 0
        if parts.count >= 6 {
            mediaDuration = TimeInterval(parts[5]) ?? 0
        }

        // Parse YouTube title format: "Song Name - Artist - YouTube"
        let parsed = parseYouTubeTitle(rawTitle)
        let chromeSourceName = chromeSourceName(for: url, fallback: target.displayName)

        return NowPlayingSnapshot(
            providerID: "browser",
            title: parsed.title,
            artist: parsed.artist,
            album: "",
            duration: mediaDuration,
            elapsedTime: mediaCurrentTime,
            playbackRate: mediaIsPlaying ? 1 : 0,
            isPlaying: mediaIsPlaying,
            sourceName: chromeSourceName,
            bundleIdentifier: target.id,
            albumArtist: "",
            artworkURL: artworkURL.isEmpty ? nil : artworkURL,
            trackIdentifier: url,
            isLocalFile: url.hasPrefix("file://"),
            browserTabURL: url,
            capturedAt: Date()
        )
    }

    private func applySnapshot(_ snapshot: NowPlayingSnapshot, stale: Bool = false) {
        let resolvedIsPlaying = stale ? false : snapshot.isPlaying
        let resolvedProviderStatus: NowPlayingProviderStatus = stale
            ? .stale(snapshot.sourceName)
            : (snapshot.isPlaying ? .playing(snapshot.sourceName) : .paused(snapshot.sourceName))
        let playbackAnchorChanged =
            title != snapshot.title ||
            duration != snapshot.duration ||
            elapsedTime != snapshot.elapsedTime ||
            playbackRate != snapshot.playbackRate ||
            isPlaying != resolvedIsPlaying

        currentChromeTabURL = snapshot.browserTabURL
        currentBundleIdentifier = snapshot.bundleIdentifier
        currentAlbumArtist = snapshot.albumArtist
        currentTrackIdentifier = snapshot.trackIdentifier
        currentTrackIsLocalFile = snapshot.isLocalFile
        currentArtworkURL = snapshot.artworkURL
        assignIfChanged(snapshot.title, to: \NowPlayingManager.title)
        assignIfChanged(snapshot.artist, to: \NowPlayingManager.artist)
        assignIfChanged(snapshot.album, to: \NowPlayingManager.album)
        assignIfChanged(snapshot.duration, to: \NowPlayingManager.duration)
        assignIfChanged(snapshot.elapsedTime, to: \NowPlayingManager.elapsedTime)
        assignIfChanged(snapshot.playbackRate, to: \NowPlayingManager.playbackRate)
        assignIfChanged(resolvedIsPlaying, to: \NowPlayingManager.isPlaying)
        assignIfChanged(snapshot.sourceName, to: \NowPlayingManager.sourceName)
        assignIfChanged(resolvedProviderStatus, to: \NowPlayingManager.providerStatus)

        if snapshot.browserTabURL.isEmpty {
            lastPausedChromeTabURL = ""
        } else if !snapshot.isPlaying {
            lastPausedChromeTabURL = snapshot.browserTabURL
        }

        if snapshot.title != lastDetectedTitle {
            lastDetectedTitle = snapshot.title
            cancelPendingArtworkLoad()
            if snapshot.providerID == "browser" {
                clearAlbumArt()
            }
            if snapshot.isPlaying, !stale {
                AppState.shared.setActiveModule(.nowPlaying)
            }
        }

        if !stale {
            lastKnownSnapshot = snapshot
        }

        updatePlaybackTimer(resetTickBaseline: playbackAnchorChanged)
    }

    private func fetchArtworkIfNeeded(for snapshot: NowPlayingSnapshot) {
        switch snapshot.providerID {
        case "spotify":
            fetchSpotifyArtwork()
        case "browser":
            if let artworkURL = snapshot.artworkURL, !artworkURL.isEmpty {
                fetchRemoteArtwork(from: artworkURL)
            } else if snapshot.browserTabURL.contains("youtube.com") {
                fetchYouTubeThumbnail(from: snapshot.browserTabURL)
            }
        default:
            break
        }
    }

    private func rememberCurrentSnapshot(providerID: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastKnownSnapshot = NowPlayingSnapshot(
            providerID: providerID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsedTime,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            sourceName: sourceName,
            bundleIdentifier: currentBundleIdentifier,
            albumArtist: currentAlbumArtist,
            artworkURL: currentArtworkURL,
            trackIdentifier: currentTrackIdentifier,
            isLocalFile: currentTrackIsLocalFile,
            browserTabURL: currentChromeTabURL,
            capturedAt: Date()
        )
    }

    @discardableResult
    private func showLastKnownSnapshotIfUseful() -> Bool {
        guard let snapshot = lastKnownSnapshot else { return false }
        guard Date().timeIntervalSince(snapshot.capturedAt) < 600 else { return false }
        guard !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if snapshot.providerID == "browser", !browserDetectionEnabled {
            return false
        }

        applySnapshot(snapshot, stale: true)
        return true
    }

    // MARK: - YouTube Helpers

    nonisolated private func parseYouTubeTitle(_ rawTitle: String) -> (title: String, artist: String) {
        // YouTube titles are typically: "Song Name - Artist - YouTube"
        // or "Song Name - YouTube"
        let cleaned = rawTitle
            .replacingOccurrences(of: " - YouTube Music", with: "")
            .replacingOccurrences(of: " - YouTube", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Try to split on " - " to get artist and title
        let dashParts = cleaned.components(separatedBy: " - ")
        if dashParts.count >= 2 {
            // Could be "Artist - Song" or "Song - Artist"
            // YouTube Music usually does "Song - Artist"
            return (title: dashParts[0].trimmingCharacters(in: .whitespaces),
                    artist: dashParts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces))
        }

        return (title: cleaned, artist: "")
    }

    nonisolated private func fetchYouTubeThumbnail(from urlString: String) {
        // Extract video ID and fetch thumbnail
        guard let videoID = extractYouTubeVideoID(from: urlString) else { return }

        let thumbnailURL = "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg"
        fetchRemoteArtwork(from: thumbnailURL)
    }

    nonisolated private func fetchRemoteArtwork(from urlString: String) {
        Task { @MainActor [weak self] in
            self?.beginRemoteArtworkLoad(from: urlString)
        }
    }

    private func beginRemoteArtworkLoad(from urlString: String) {
        let normalizedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalizedURLString) else { return }

        let identity = "url:\(url.absoluteString)"
        currentArtworkURL = normalizedURLString

        if currentArtworkIdentity == identity {
            if pendingArtworkIdentity != nil, pendingArtworkIdentity != identity {
                cancelPendingArtworkLoad()
            }
            return
        }

        guard pendingArtworkIdentity != identity else { return }

        cancelPendingArtworkLoad()
        artworkLoadGeneration &+= 1
        let generation = artworkLoadGeneration
        pendingArtworkIdentity = identity

        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, _, _ in
            let image = location.flatMap {
                Self.decodeArtworkImage(fromFileURL: $0)
            }
            Task { @MainActor [weak self] in
                self?.completeRemoteArtworkLoad(
                    image: image,
                    identity: identity,
                    generation: generation
                )
            }
        }
        artworkDownloadTask = task
        task.resume()
    }

    private func completeRemoteArtworkLoad(image: NSImage?, identity: String, generation: UInt64) {
        guard generation == artworkLoadGeneration,
              pendingArtworkIdentity == identity else { return }

        pendingArtworkIdentity = nil
        artworkDownloadTask = nil

        guard let image else { return }
        commitAlbumArt(image, identity: identity)
    }

    private func applyInlineArtworkData(_ data: Data) {
        let identity = Self.stableArtworkIdentity(for: data)

        if currentArtworkIdentity == identity {
            if pendingArtworkIdentity != nil, pendingArtworkIdentity != identity {
                cancelPendingArtworkLoad()
            }
            return
        }

        guard let image = Self.decodeArtworkImage(from: data) else { return }
        cancelPendingArtworkLoad()
        commitAlbumArt(image, identity: identity)
    }

    private func commitAlbumArt(_ image: NSImage, identity: String) {
        currentArtworkIdentity = identity
        if albumArt !== image {
            albumArt = image
        }
    }

    private func clearAlbumArt() {
        cancelPendingArtworkLoad()
        currentArtworkIdentity = nil
        if albumArt != nil {
            albumArt = nil
        } else {
            albumArtColorGeneration &+= 1
            if albumArtColor != nil {
                albumArtColor = nil
            }
        }
    }

    private func cancelPendingArtworkLoad() {
        guard artworkDownloadTask != nil || pendingArtworkIdentity != nil else { return }
        artworkLoadGeneration &+= 1
        artworkDownloadTask?.cancel()
        artworkDownloadTask = nil
        pendingArtworkIdentity = nil
    }

    nonisolated private static func stableArtworkIdentity(for data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "data:\(data.count):\(String(hash, radix: 16))"
    }

    /// Decode artwork directly into a bounded thumbnail instead of first
    /// materializing the source image at its native resolution. Existing UI
    /// uses at most a 90-point image; 512 pixels keeps Retina detail while
    /// limiting one decoded BGRA surface to roughly 1 MiB.
    nonisolated private static func decodeArtworkImage(
        from data: Data,
        maximumPixelSize: Int = 512
    ) -> NSImage? {
        // Refuse unexpectedly large responses before ImageIO parses them. The
        // decoded surface is bounded below, but retaining an unbounded network
        // payload would still allow a malformed artwork URL to spike RSS.
        guard !data.isEmpty, data.count <= 20 * 1_024 * 1_024 else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return decodeArtworkImage(from: source, maximumPixelSize: maximumPixelSize)
    }

    nonisolated private static func decodeArtworkImage(
        fromFileURL fileURL: URL,
        maximumPixelSize: Int = 512
    ) -> NSImage? {
        guard let fileSize = try? fileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize,
              fileSize > 0,
              fileSize <= 20 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        return decodeArtworkImage(from: source, maximumPixelSize: maximumPixelSize)
    }

    nonisolated private static func decodeArtworkImage(
        from source: CGImageSource,
        maximumPixelSize: Int
    ) -> NSImage? {
        let options: CFDictionary = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options
        ) else { return nil }
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
    }

    nonisolated private func extractYouTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "v" })?.value
    }

    // MARK: - AppleScript Runner

    nonisolated private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            // Don't log "application not running" errors as they're expected
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? 0
            if errorNum != -600 && errorNum != -1728 {
                print("[NowPlaying] AppleScript error: \(error)")
            }
            return nil
        }
        return result.stringValue
    }

    // MARK: - Playback Timer

    @discardableResult
    private func assignIfChanged<Value: Equatable>(
        _ value: Value,
        to keyPath: ReferenceWritableKeyPath<NowPlayingManager, Value>
    ) -> Bool {
        guard self[keyPath: keyPath] != value else { return false }
        self[keyPath: keyPath] = value
        return true
    }

    private func updatePlaybackTimer(resetTickBaseline: Bool = false) {
        let shouldRun = isPlaying && duration > 0 && elapsedTime < duration

        if shouldRun {
            if resetTickBaseline || lastPlaybackTickDate == nil {
                lastPlaybackTickDate = Date()
            }

            guard playbackRefreshToken == nil else { return }

            playbackRefreshToken = ModuleRefreshScheduler.shared.register(
                id: "nowPlaying.progress",
                name: "Now Playing progress",
                module: .builtIn(.nowPlaying),
                policy: .visibleOnly(1, tolerance: 0.2),
                enabled: { [weak self] in
                    AppState.shared.nowPlayingEnabled && (self?.isPlaying ?? false)
                }
            ) { [weak self] in
                self?.advancePlaybackProgress()
            }
            return
        }

        guard playbackRefreshToken != nil else {
            lastPlaybackTickDate = nil
            return
        }

        ModuleRefreshScheduler.shared.unregister(playbackRefreshToken)
        playbackRefreshToken = nil
        lastPlaybackTickDate = nil
    }

    private func advancePlaybackProgress() {
        guard isPlaying, duration > 0 else {
            updatePlaybackTimer()
            return
        }

        let now = Date()
        let delta = lastPlaybackTickDate.map { now.timeIntervalSince($0) } ?? 1
        lastPlaybackTickDate = now

        elapsedTime += min(max(delta, 0.5), 5) * max(playbackRate, 1)
        if elapsedTime >= duration {
            assignIfChanged(duration, to: \NowPlayingManager.elapsedTime)
            updatePlaybackTimer()
        }
    }

    // MARK: - Playback Controls

    private var playbackSourceSnapshot: NowPlayingSourceOpener.Snapshot {
        .init(bundleIdentifier: currentBundleIdentifier, title: title, artist: artist,
              browserURL: currentChromeTabURL, isPlaying: isPlaying)
    }

    var canOpenPlaybackSource: Bool {
        !currentBundleIdentifier.isEmpty && !title.isEmpty
    }

    var playbackSourceHelp: String {
        if isOpeningPlaybackSource { return "正在打开播放来源" }
        if failedPlaybackSource == playbackSourceSnapshot { return "暂时无法打开播放来源" }
        return sourceName.isEmpty ? "打开播放来源" : "打开\(sourceName)"
    }

    func openPlaybackSource() {
        guard canOpenPlaybackSource, !isOpeningPlaybackSource else { return }
        let snapshot = playbackSourceSnapshot
        let browserAllowed = browserDetectionEnabled && isBrowserAllowed(snapshot.bundleIdentifier)
        failedPlaybackSource = nil
        isOpeningPlaybackSource = true
        Task { [weak self] in
            guard let self else { return }
            defer { isOpeningPlaybackSource = false }
            let outcome = await sourceOpener.open(snapshot, browserDetectionAllowed: browserAllowed) { [weak self] in
                self?.playbackSourceSnapshot == snapshot
            }
            guard playbackSourceSnapshot == snapshot else { return }
            switch outcome {
            case .openedApp, .openedTab:
                AppState.shared.dismiss()
            case .unavailable:
                failedPlaybackSource = snapshot
            case .cancelled:
                break
            }
        }
    }

    func togglePlayPause() {
        if sourceName == "Spotify", !isApplicationRunning("Spotify") {
            refreshPreferredSource()
            return
        }

        if sourceName == "Apple Music", !isApplicationRunning("Music") {
            refreshPreferredSource()
            return
        }

        let shouldPlay = !isPlaying

        // Immediately toggle local state for responsive UI
        isPlaying = shouldPlay
        updatePlaybackTimer()

        // Browser playback is checked first because the MediaRemote command
        // path doesn't reliably control browser-tab <video>/<audio> elements
        // even when Chrome's MediaSession registers with MediaRemote. JS
        // injection talks to the element directly.
        if isBrowserPlaybackSource {
            if controlChromePlayback(shouldPlay: shouldPlay) {
                refreshPlaybackStateAfterControlAction(preferChromeRefresh: true)
                return
            }
            // Fall through to MR/AppleScript if JS injection failed (e.g.
            // Chrome "Allow JavaScript from Apple Events" disabled).
        }

        if shouldUseMediaRemoteControls {
            _ = sendCommandFunc?(shouldPlay ? kMRPlay : kMRPause, nil)
            refreshPlaybackStateAfterControlAction()
            return
        }

        // Fallback to AppleScript
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to \(shouldPlay ? "play" : "pause")")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to \(shouldPlay ? "play" : "pause")")
        default:
            _ = sendCommandFunc?(shouldPlay ? kMRPlay : kMRPause, nil)
        }

        refreshPlaybackStateAfterControlAction()
    }

    func nextTrack() {
        if shouldUseMediaRemoteControls {
            _ = sendCommandFunc?(kMRNextTrack, nil)
            return
        }
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to next track")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to next track")
        default:
            _ = sendCommandFunc?(kMRNextTrack, nil)
        }
    }

    func previousTrack() {
        if shouldUseMediaRemoteControls {
            _ = sendCommandFunc?(kMRPreviousTrack, nil)
            return
        }
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to previous track")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to previous track")
        default:
            _ = sendCommandFunc?(kMRPreviousTrack, nil)
        }
    }

    func skipTrack(forward: Bool) {
        if forward { nextTrack() } else { previousTrack() }
    }

    func seek(to time: TimeInterval) {
        let clampedTime = max(0, min(time, duration))
        assignIfChanged(clampedTime, to: \NowPlayingManager.elapsedTime)
        updatePlaybackTimer(resetTickBaseline: true)

        if shouldUseMediaRemoteControls {
            setElapsedTimeFunc?(clampedTime)
            refreshPlaybackStateAfterControlAction()
            return
        }

        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to set player position to \(clampedTime)")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to set player position to \(clampedTime)")
        default:
            break
        }
    }

    // MARK: - Helpers

    var formattedElapsedTime: String {
        formatTime(elapsedTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return elapsedTime / duration
    }

    var browserTargets: [NowPlayingBrowserTarget] {
        nowPlayingSupportedBrowserTargets
    }

    var emptyTitle: String {
        providerStatus.title
    }

    var emptySubtitle: String {
        providerStatus.subtitle
    }

    func isBrowserAllowed(_ browserID: String) -> Bool {
        allowedBrowserBundleIDs.contains(browserID)
    }

    func setBrowser(_ browserID: String, allowed: Bool) {
        var nextAllowed = allowedBrowserBundleIDs
        if allowed {
            nextAllowed.insert(browserID)
        } else {
            nextAllowed.remove(browserID)
        }
        allowedBrowserBundleIDs = nextAllowed
    }

    func testBrowserDetection() {
        browserDetectionTestMessage = "Checking browser media..."
        guard browserDetectionEnabled else {
            assignIfChanged(.browserDisabled, to: \NowPlayingManager.providerStatus)
            browserDetectionTestMessage = "请先启用浏览器媒体检测。"
            return
        }

        Task { [weak self] in
            guard let self else { return }
            let snapshot = await self.runOnAppleScriptQueue {
                self.browserSnapshotViaAppleScript(allowPausedFallback: true)
            }

            guard let snapshot else {
                self.assignIfChanged(.permissionNeeded("浏览器媒体"), to: \NowPlayingManager.providerStatus)
                self.browserDetectionTestMessage = "未找到浏览器媒体。请检查自动化权限，以及浏览器是否允许 Apple Events 执行 JavaScript。"
                return
            }

            self.applySnapshot(snapshot)
            self.fetchArtworkIfNeeded(for: snapshot)
            self.browserDetectionTestMessage = snapshot.isPlaying
                ? "已在 \(snapshot.sourceName) 检测到媒体。"
                : "已在 \(snapshot.sourceName) 检测到暂停的媒体。"
        }
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var isBrowserPlaybackSource: Bool {
        switch sourceName {
        case "YouTube", "YouTube Music", "SoundCloud", "Spotify Web", "Google Chrome", "Google Chrome Canary":
            return true
        default:
            return !currentChromeTabURL.isEmpty && !lastPausedChromeTabURL.isEmpty
        }
    }

    private func refreshPlaybackStateAfterControlAction(preferChromeRefresh: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if preferChromeRefresh {
                _ = self?.fetchChromeViaAppleScript()
                return
            }
            self?.refreshPreferredSource()
        }
    }

    private func controlChromePlayback(shouldPlay: Bool) -> Bool {
        let target = browserTarget(for: currentBundleIdentifier) ?? browserTargets.first
        guard let target else { return false }
        let preferredURL = shouldPlay ? lastPausedChromeTabURL : currentChromeTabURL
        let js = chromeControlJavaScript(shouldPlay: shouldPlay)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPreferredURL = escapeAppleScriptString(preferredURL)
        let processName = escapeAppleScriptString(target.processName)
        let applicationName = escapeAppleScriptString(target.applicationName)

        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return "NOT_RUNNING"
        end tell
        tell application "\(applicationName)"
            set preferredURL to "\(escapedPreferredURL)"
            if preferredURL is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is preferredURL then
                            try
                                set actionResult to execute t javascript "\(js)"
                                if actionResult is "OK" then return "OK||" & (URL of t)
                            end try
                        end if
                    end repeat
                end repeat
            end if
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set actionResult to execute t javascript "\(js)"
                        if actionResult is "OK" then return "OK||" & (URL of t)
                    end try
                end repeat
            end repeat
            return "NO_MEDIA"
        end tell
        """

        guard let result = runAppleScript(script), result.hasPrefix("OK||") else {
            return false
        }

        let actedURL = String(result.dropFirst(4))
        currentChromeTabURL = actedURL
        if shouldPlay {
            if lastPausedChromeTabURL == actedURL {
                lastPausedChromeTabURL = ""
            }
        } else {
            lastPausedChromeTabURL = actedURL
        }
        return true
    }

    private func browserTarget(for bundleIdentifier: String) -> NowPlayingBrowserTarget? {
        nowPlayingSupportedBrowserTargets.first { $0.id == bundleIdentifier }
    }

    private func chromeControlJavaScript(shouldPlay: Bool) -> String {
        if shouldPlay {
            return """
            (function() {
                var media = Array.from(document.querySelectorAll('video,audio'));
                if (!media.length) return 'NO_MEDIA';
                var target = media.find(function(item) { return item.paused && !item.ended; }) || media.find(function(item) { return !item.ended; }) || media[0];
                if (!target) return 'NO_MEDIA';
                try {
                    target.play();
                    return 'OK';
                } catch (error) {
                    return 'ERROR';
                }
            })();
            """
        }

        return """
        (function() {
            var media = Array.from(document.querySelectorAll('video,audio'));
            if (!media.length) return 'NO_MEDIA';
            var handled = false;
            media.forEach(function(item) {
                if (!item.paused && !item.ended) {
                    item.pause();
                    handled = true;
                }
            });
            return handled ? 'OK' : 'NO_MATCH';
        })();
        """
    }

    nonisolated private func chromeSourceName(for url: String, fallback: String = "Google Chrome") -> String {
        if url.contains("music.youtube.com") { return "YouTube Music" }
        if url.contains("youtube.com") { return "YouTube" }
        if url.contains("soundcloud.com") { return "SoundCloud" }
        if url.contains("spotify.com") { return "Spotify Web" }
        return fallback
    }

    private func sourceName(forBundleIdentifier bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.apple.Music":
            return "Apple Music"
        case "com.spotify.client":
            return "Spotify"
        case "com.google.Chrome":
            return "Google Chrome"
        case "com.google.Chrome.canary":
            return "Google Chrome Canary"
        case "com.apple.Safari":
            return "Safari"
        case "com.microsoft.edgemac":
            return "Microsoft Edge"
        default:
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let bundle = Bundle(url: appURL),
               let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !appName.isEmpty {
                return appName
            }
            return bundleIdentifier
        }
    }

    func normalizedSnapshot() -> [String: Any]? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBundleIdentifier = currentBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedArtworkURL = normalizedArtworkSnapshotURL()

        guard !normalizedTitle.isEmpty else { return nil }
        guard !normalizedArtist.isEmpty else { return nil }

        return [
            "sourceApp": normalizedSource.isEmpty ? (normalizedBundleIdentifier.isEmpty ? "Unknown" : sourceName(forBundleIdentifier: normalizedBundleIdentifier)) : normalizedSource,
            "bundleIdentifier": normalizedBundleIdentifier.isEmpty ? NSNull() : normalizedBundleIdentifier,
            "title": normalizedTitle,
            "artist": normalizedArtist,
            "album": album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : album,
            "albumArtist": currentAlbumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : currentAlbumArtist,
            "durationSeconds": duration > 0 ? duration : NSNull(),
            "elapsedSeconds": elapsedTime >= 0 ? elapsedTime : NSNull(),
            "artworkURL": resolvedArtworkURL ?? NSNull(),
            "playbackState": isPlaying ? "playing" : "paused",
            "trackIdentifier": currentTrackIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : currentTrackIdentifier,
            "isLocalFile": currentTrackIsLocalFile,
            "capturedAtEpochMs": Int(Date().timeIntervalSince1970 * 1000)
        ]
    }

    var sourceAppIcon: NSImage? {
        guard !currentBundleIdentifier.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: currentBundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    private func trackSignature(title: String, artist: String, album: String, bundleIdentifier: String) -> String {
        [bundleIdentifier, title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "||")
    }

    private func clampElapsedTime(_ elapsedTime: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let normalizedElapsedTime = max(0, elapsedTime)
        guard duration > 0 else {
            return normalizedElapsedTime
        }
        return min(normalizedElapsedTime, duration)
    }

    private func normalizedArtworkSnapshotURL() -> String? {
        if let currentArtworkURL, currentArtworkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return currentArtworkURL
        }

        guard let albumArt,
              let tiffData = albumArt.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return "data:image/png;base64," + pngData.base64EncodedString()
    }

    private func isChromeBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.google.Chrome" || bundleIdentifier == "com.google.Chrome.canary"
    }

    nonisolated private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func isApplicationRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName == name && !app.isTerminated
        }
    }

    nonisolated private func isApplicationInstalled(bundleIdentifier: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func clearCurrentTrack() {
        assignIfChanged("", to: \NowPlayingManager.title)
        assignIfChanged("", to: \NowPlayingManager.artist)
        assignIfChanged("", to: \NowPlayingManager.album)
        clearAlbumArt()
        assignIfChanged(false, to: \NowPlayingManager.isPlaying)
        assignIfChanged(0, to: \NowPlayingManager.duration)
        assignIfChanged(0, to: \NowPlayingManager.elapsedTime)
        assignIfChanged(0, to: \NowPlayingManager.playbackRate)
        assignIfChanged("", to: \NowPlayingManager.sourceName)
        currentAlbumArtist = ""
        currentArtworkURL = nil
        currentTrackIdentifier = ""
        currentTrackIsLocalFile = false
        currentChromeTabURL = ""
        lastPausedChromeTabURL = ""
        currentBundleIdentifier = ""
        lastDetectedTitle = ""
        assignIfChanged(
            browserDetectionEnabled ? .idle : .browserDisabled,
            to: \NowPlayingManager.providerStatus
        )
        updatePlaybackTimer()
    }

    /// Stop the helper while the owning App is still alive. `shared` is a
    /// process-lifetime singleton, so relying on `deinit` leaves the Perl
    /// MediaRemote stream orphaned when AppKit terminates the application.
    func shutdownExternalProcesses() {
        adapterStreamTask?.cancel()
        adapterStreamTask = nil
        if let adapterProcess {
            Self.terminateAdapterProcess(adapterProcess)
        }
        adapterProcess = nil
        adapterPipeHandler = nil
        adapterDidDeliverUpdate = false
    }

    private nonisolated static func terminateAdapterProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminationHandler = nil
        let pid = process.processIdentifier
        process.terminate()
        let deadline = Date().addingTimeInterval(0.20)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            // This PID is the exact child Process instance launched above.
            // Bound shutdown rather than hanging the host App indefinitely.
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    deinit {
        providerRefreshTask?.cancel()
        artworkDownloadTask?.cancel()
        let sourceToken = sourceRefreshToken
        let playbackToken = playbackRefreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(sourceToken)
            ModuleRefreshScheduler.shared.unregister(playbackToken)
        }
        adapterStreamTask?.cancel()
        if let adapterPipeHandler {
            Task {
                await adapterPipeHandler.close()
            }
        }
        if let adapterProcess {
            Self.terminateAdapterProcess(adapterProcess)
        }
        if let handle {
            dlclose(handle)
        }
    }
}

private struct NowPlayingUpdate: Decodable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

private struct NowPlayingPayload: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let duration: Double?
    let elapsedTime: Double?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let trackIdentifier: String?
    let isLocalFile: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
}

private actor JSONLinesPipeHandler {
    private let pipe = Pipe()
    private lazy var fileHandle = pipe.fileHandleForReading
    private var buffer = ""

    func getPipe() -> Pipe {
        pipe
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            while true {
                let data = try await readData()
                guard !data.isEmpty else { break }

                if let chunk = String(data: data, encoding: .utf8) {
                    buffer.append(chunk)

                    while let range = buffer.range(of: "\n") {
                        let line = String(buffer[..<range.lowerBound])
                        buffer = String(buffer[range.upperBound...])

                        guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }

                        do {
                            let decoded = try JSONDecoder().decode(T.self, from: lineData)
                            await onLine(decoded)
                        } catch {
                            continue
                        }
                    }
                }
            }
        } catch {
            print("[NowPlaying] Error reading MediaRemote adapter stream: \(error)")
        }
    }

    private func readData() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            fileHandle.readabilityHandler = { handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                continuation.resume(returning: data)
            }
        }
    }

    func close() async {
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("[NowPlaying] Error closing MediaRemote adapter pipe: \(error)")
        }
    }
}
