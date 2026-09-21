import SwiftUI

enum IslandContentMode: Equatable {
    case production
    case windowEnhancementShell
}

enum IslandShellMetrics {
    /// Mirrors AppState's compact shell geometry without consulting
    /// `compactPresentationModule`, whose production path eagerly creates the
    /// Now Playing/MediaRemote stack.
    @MainActor
    static func compactSurfaceSize(for appState: AppState) -> CGSize {
        if appState.presentationHasNotch {
            return CGSize(
                width: max(Constants.compactNotchMinimumWidth, CGFloat(appState.compactIslandWidth)),
                height: max(Constants.compactNotchMinimumHeight, CGFloat(appState.compactIslandHeight))
            )
        }

        let contentSize = Constants.nonNotchCompactSize
        let topCornerRadius = min(Constants.compactCornerRadius, contentSize.height / 2)
        return CGSize(
            width: contentSize.width + topCornerRadius * 2,
            height: contentSize.height
        )
    }

    /// The real island temporarily expands for readable feedback, then returns
    /// to the production compact geometry. Extra height keeps the message below
    /// a physical camera notch instead of creating a permanently large debug UI.
    @MainActor
    static func feedbackSurfaceSize(for appState: AppState) -> CGSize {
        let compactSize = compactSurfaceSize(for: appState)
        return CGSize(
            width: max(360, compactSize.width),
            height: max(56, compactSize.height)
        )
    }
}

struct IslandContainerView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var windowEnhancementPreferences = WindowEnhancementPreferences.shared
    @State private var isHoveringIslandSurface = false
    @State private var isHoveringPreviousButton = false
    @State private var isHoveringNextButton = false
    @State private var isShelfDropTargeted = false
    @State private var windowEnhancementFeedback: WindowEnhancementFeedbackEvent?
    @State private var windowEnhancementFeedbackDismissWorkItem: DispatchWorkItem?
    private let hoverValidationTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    let contentMode: IslandContentMode

    init(contentMode: IslandContentMode = .production) {
        self.contentMode = contentMode
    }

    var body: some View {
        // No GeometryReader — just like NotchDrop. The surface sizes
        // itself from appState. Transparent areas around the surface
        // are truly empty (alpha=0), so macOS passes clicks through.
        ZStack(alignment: .top) {
            islandSurface

            if showModuleCycler {
                moduleCyclerOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: appState.zilanSuppressionRequestID) { _, requestID in
            guard requestID != nil else { return }
            isHoveringIslandSurface = false
            isHoveringPreviousButton = false
            isHoveringNextButton = false
            isShelfDropTargeted = false
        }
        .onChange(of: showModuleCycler) { _, isVisible in
            guard !isVisible else { return }
            setCycleButtonHover(false, forward: false)
            setCycleButtonHover(false, forward: true)
        }
        .onReceive(hoverValidationTimer) { _ in
            guard contentMode == .production else { return }
            validateHoverState()
        }
        .onReceive(windowEnhancementPreferences.$feedbackEvent.compactMap { $0 }) { event in
            presentWindowEnhancementFeedback(event)
        }
        .onDisappear {
            windowEnhancementFeedbackDismissWorkItem?.cancel()
            windowEnhancementFeedbackDismissWorkItem = nil
        }
    }

    // MARK: - Surface

    private var islandSurface: some View {
        let inputGeneration = appState.islandInputGeneration
        let surfaceSize: CGSize
        if contentMode == .windowEnhancementShell {
            surfaceSize = windowEnhancementFeedback == nil
                ? IslandShellMetrics.compactSurfaceSize(for: appState)
                : IslandShellMetrics.feedbackSurfaceSize(for: appState)
        } else {
            surfaceSize = appState.currentSize
        }
        return ZStack(alignment: .top) {
            islandShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.98),
                            Color.black.opacity(0.94)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            islandContent
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .clipShape(islandShape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(ambientShadowOpacity),
            radius: ambientShadowRadius,
            y: ambientShadowYOffset
        )
        .shadow(
            color: .black.opacity(keyShadowOpacity),
            radius: keyShadowRadius,
            y: keyShadowYOffset
        )
        .overlay {
            if contentMode == .production && appState.shelfEnabled && isShelfDropTargeted {
                islandShape
                    .stroke(Color.accentColor.opacity(0.92), style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(1)
            }
        }
        .contentShape(islandShape)
        .modifier(IslandSurfaceSwipeModifier(
            enabled: contentMode == .production && appState.islandSurfaceSwipeEnabled
                && !appState.isZilanInteractionSuppressed,
            isCompact: appState.currentState == .compact,
            givesNestedScrollViewsPriority: appState.isShelfPanesVisible ||
                (appState.currentState == .expanded && appState.activeBuiltInModule == .shelf),
            diagnosticModule: IslandSwipeDiagnostics.module(in: appState),
            diagnosticState: IslandSwipeDiagnostics.stateCode(appState.currentState),
            inputGeneration: inputGeneration,
            onTrackpad: {
                recordSwipeGenerationGate(captured: inputGeneration)
                guard appState.canHandleIslandInput(generation: inputGeneration) else { return }
                handleHorizontalSwipe($0)
            },
            onDragEnded: { value, generation in
                recordSwipeGenerationGate(captured: generation)
                guard appState.canHandleIslandInput(generation: generation) else { return }
                handleSwipe(value: value)
            }
        ))
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard appState.canHandleIslandInput(generation: inputGeneration) else { return }
            handleSurfaceHover(phase: phase)
        }
        .onTapGesture {
            guard appState.canHandleIslandInput(generation: inputGeneration) else { return }
            handleSurfaceTap()
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard appState.canHandleIslandInput(generation: inputGeneration) else { return }
                    ShelfDropDiagnostics.record("gesture.longpress", values: ["shelfActive": appState.isShelfDragActive ? 1 : 0])
                    AppDelegate.showSettingsWindow(
                        initialPane: contentMode == .windowEnhancementShell
                            ? .windowEnhancement
                            : .general
                    )
                }
        )
        .shelfDropTarget(.surface, isTargeted: $isShelfDropTargeted,
                         enabled: contentMode == .production && appState.shelfEnabled
                            && !appState.isShelfPanesVisible
                            && !appState.isZilanInteractionSuppressed) { providers in
            guard contentMode == .production, appState.shelfEnabled, !appState.isShelfPanesVisible,
                  appState.canHandleIslandInput(generation: inputGeneration) else { return false }
            return ShelfStore.shared.handleDrop(providers: providers) { addedCount in
                guard addedCount > 0,
                      appState.canHandleIslandInput(generation: inputGeneration) else { return }
                appState.presentShelfAfterDrop()
            }
        }
        .allowsHitTesting(!appState.isZilanInteractionSuppressed)
        .animation(islandSurfaceAnimation, value: appState.activeModule)
        .animation(windowEnhancementFeedbackAnimation, value: windowEnhancementFeedback?.id)
    }

    // MARK: - Content

    @ViewBuilder
    private var islandContent: some View {
        if contentMode == .windowEnhancementShell {
            windowEnhancementFeedbackContent
                .id(windowEnhancementFeedback?.id ?? 0)
                .transition(windowEnhancementFeedbackTransition)
        } else {
            ZStack(alignment: .bottom) {
                productionIslandContent

                if shouldShowWindowEnhancementFeedback {
                    windowEnhancementFeedbackContent
                        .id(windowEnhancementFeedback?.id ?? 0)
                        .transition(windowEnhancementFeedbackTransition)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private var productionIslandContent: some View {
        if appState.currentState == .compact {
            CompactView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .opacity(compactContentOpacity)
                .transition(contentTransition(scale: 0.85))
        } else {
            expandedIslandLayout
                .opacity(compactContentOpacity)
                .transition(contentTransition(scale: 0.5))
        }
    }

    private var shouldShowWindowEnhancementFeedback: Bool {
        contentMode == .production &&
            appState.currentState != .compact &&
            windowEnhancementFeedback != nil
    }

    @ViewBuilder
    private var windowEnhancementFeedbackContent: some View {
        let message = windowEnhancementFeedback?.message
            ?? WindowEnhancementPreferences.islandReadyMessage
        let content = HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.20, green: 0.84, blue: 0.49))
                .frame(width: 7, height: 7)
                .shadow(color: Color.green.opacity(0.45), radius: 5)

            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)

        if contentMode == .windowEnhancementShell {
            content
                .padding(.horizontal, 18)
                .padding(.bottom, appState.presentationHasNotch ? 7 : 0)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: appState.presentationHasNotch ? .bottom : .center
                )
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.13), lineWidth: 0.5))
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }

    private var windowEnhancementFeedbackTransition: AnyTransition {
        appState.shouldReduceMotion
            ? .opacity
            : .scale(scale: 0.94, anchor: .center).combined(with: .opacity)
    }

    private func presentWindowEnhancementFeedback(_ event: WindowEnhancementFeedbackEvent) {
        // Compact production islands may be hidden behind a physical notch and
        // have no room for a readable message. WindowEnhancementController uses
        // its standalone HUD there. Only expanded production islands consume
        // the event as a non-interactive overlay over the original module page.
        guard contentMode == .windowEnhancementShell || (
            appState.currentState != .compact &&
            IslandWindowController.canPresentWindowEnhancementFeedback
        ) else {
            return
        }
        windowEnhancementFeedbackDismissWorkItem?.cancel()

        withAnimation(windowEnhancementFeedbackAnimation) {
            windowEnhancementFeedback = event
        }

        let eventID = event.id
        let workItem = DispatchWorkItem {
            guard windowEnhancementFeedback?.id == eventID else { return }
            withAnimation(windowEnhancementFeedbackAnimation) {
                windowEnhancementFeedback = nil
            }
            windowEnhancementFeedbackDismissWorkItem = nil
        }
        windowEnhancementFeedbackDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1, execute: workItem)
    }

    private var windowEnhancementFeedbackAnimation: Animation {
        appState.shouldReduceMotion
            ? .easeOut(duration: 0.10)
            : .spring(response: 0.24, dampingFraction: 0.88)
    }

    // MARK: - Shape

    private var islandShape: PillShape {
        PillShape(
            topLeadingRadius: appState.currentTopLeadingCornerRadius,
            topTrailingRadius: appState.currentTopTrailingCornerRadius,
            bottomLeadingRadius: appState.currentBottomLeadingCornerRadius,
            bottomTrailingRadius: appState.currentBottomTrailingCornerRadius,
            outwardTopCorners: appState.usesOutwardTopCorners,
            topCutoutWidth: appState.currentTopCutoutWidth,
            topCutoutDepth: appState.currentTopCutoutDepth,
            topCutoutCornerRadius: appState.currentTopCutoutCornerRadius
        )
    }

    // MARK: - Appearance

    private var compactContentOpacity: Double {
        1.0
    }

    private func contentTransition(scale: CGFloat) -> AnyTransition {
        appState.shouldReduceMotion
            ? .opacity
            : .scale(scale: scale, anchor: .top).combined(with: .opacity)
    }

    // Shadows are intentionally disabled in the compact state. The island
    // panel is non-activating and sits in the transparent region around the
    // notch — any non-zero shadow pixel in that transparent region gets
    // captured by the panel's hit test and blocks clicks from reaching apps
    // underneath (see issue #1).
    private var ambientShadowOpacity: Double {
        appState.currentState == .compact ? 0.0 : 0.38
    }

    private var ambientShadowRadius: CGFloat {
        appState.currentState == .compact ? 0 : 8
    }

    private var ambientShadowYOffset: CGFloat {
        appState.currentState == .compact ? 0 : 6
    }

    private var keyShadowOpacity: Double {
        appState.currentState == .compact ? 0.0 : 0.58
    }

    private var keyShadowRadius: CGFloat {
        appState.currentState == .compact ? 0 : 14
    }

    private var keyShadowYOffset: CGFloat {
        appState.currentState == .compact ? 0 : 10
    }

    private var islandSurfaceAnimation: Animation {
        appState.shouldReduceAnimations ? .easeOut(duration: 0.12) : .spring(response: 0.48, dampingFraction: 0.8)
    }

    // MARK: - Expanded Layout

    private var expandedIslandLayout: some View {
        let surfaceSize = appState.currentSize
        let shoulderHeight = min(appState.currentContentTopInset, surfaceSize.height)
        let contentWidth = min(appState.currentContentSize.width, surfaceSize.width)
        let contentHeight = max(0, surfaceSize.height - shoulderHeight)

        return VStack(spacing: 0) {
            if appState.hasFullExpandedShoulderBarSpace {
                FullExpandedTopBarView(layout: .shoulder)
                    .environmentObject(appState)
                    .frame(
                        width: contentWidth,
                        height: shoulderHeight,
                        alignment: .top
                    )
            } else {
                Color.clear
                    .frame(height: shoulderHeight)
            }

            currentExpandedContent
                .background {
                    if contentMode == .production && IslandSwipeDiagnostics.runtimeEnabled {
                        IslandSwipePageMarker(
                            module: IslandSwipeDiagnostics.module(in: appState),
                            state: IslandSwipeDiagnostics.stateCode(appState.currentState)
                        )
                        // Only the invisible marker changes identity. The
                        // real page and its managers keep their lifecycle.
                        .id("\(IslandSwipeDiagnostics.module(in: appState).rawValue).\(IslandSwipeDiagnostics.stateCode(appState.currentState))")
                    }
                }
                .padding(.horizontal, appState.contentHorizontalPadding)
                .padding(.top, appState.contentTopPadding)
                .padding(.bottom, appState.contentBottomPadding)
                .frame(
                    width: contentWidth,
                    height: contentHeight,
                    alignment: .top
                )
                .clipped()

            Spacer(minLength: 0)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
    }

    @ViewBuilder
    private var currentExpandedContent: some View {
        switch appState.currentState {
        case .compact:
            EmptyView()
        case .expanded:
            ExpandedView()
                .scaleEffect(appState.expandedContentScale, anchor: .top)
                .padding(.top, appState.expandedContentTopOffset)
        case .fullExpanded:
            FullExpandedView()
        }
    }

    // MARK: - Gestures

    private func recordSwipeGenerationGate(captured: UInt64) {
        guard IslandSwipeDiagnostics.runtimeEnabled else { return }
        let allowed = appState.canHandleIslandInput(generation: captured)
        IslandSwipeDiagnostics.record(.generationGate, module: IslandSwipeDiagnostics.module(in: appState),
                                      reason: allowed ? .allowed : .generationRejected, values: [
            .capturedGeneration: Int64(clamping: captured),
            .generation: Int64(clamping: appState.islandInputGeneration),
            .state: IslandSwipeDiagnostics.stateCode(appState.currentState)
        ])
    }

    private func handleSwipe(value: DragGesture.Value) {
        guard !appState.isZilanInteractionSuppressed else { return }
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let velocity = sqrt(pow(value.velocity.width, 2) + pow(value.velocity.height, 2))

        guard velocity > 35 || abs(horizontal) > 14 || abs(vertical) > 18 else { return }

        if abs(horizontal) > abs(vertical) {
            if appState.currentState != .compact {
                handleHorizontalSwipe(horizontal > 0 ? .right : .left)
            }
        } else {
            if vertical < 0 {
                if appState.currentState != .fullExpanded {
                    appState.open()
                }
            } else {
                appState.dismiss()
            }
        }
    }

    private func handleHorizontalSwipe(_ direction: SwipeDirection) {
        guard !appState.isZilanInteractionSuppressed else { return }
        if appState.currentState == .expanded && appState.activeBuiltInModule == .nowPlaying {
            NowPlayingManager.shared.skipTrack(forward: direction == .left)
        } else {
            appState.cycleModule(forward: direction == .left)
        }
    }

    private func handleSurfaceTap() {
        guard !appState.isZilanInteractionSuppressed else { return }
        if contentMode == .windowEnhancementShell {
            AppDelegate.showSettingsWindow(initialPane: .windowEnhancement)
            return
        }
        if handleNotificationTapIfNeeded() {
            return
        }

        switch appState.currentState {
        case .compact, .expanded:
            appState.open()
        case .fullExpanded:
            break
        }
    }

    private func handleNotificationTapIfNeeded() -> Bool {
        guard appState.activeBuiltInModule == .notifications,
              let notification = NotificationManager.shared.latestNotification else {
            return false
        }

        if notification.tapAction != nil {
            NotificationManager.shared.activateNotification(notification)
            return true
        }

        if appState.currentState != .fullExpanded {
            appState.setActiveModule(.notifications)
            appState.fullyExpand()
            return true
        }

        return false
    }

    // MARK: - Module Cycler

    private var showModuleCycler: Bool {
        contentMode == .production &&
            appState.currentState != .compact &&
            enabledModuleCount > 1
    }

    private var enabledModuleCount: Int {
        appState.availableModules.count
    }

    private var moduleCyclerOverlay: some View {
        let windowWidth = appState.windowSize.width
        return HStack {
            moduleCycleButton(systemName: "chevron.left", forward: false)
            Spacer()
            moduleCycleButton(systemName: "chevron.right", forward: true)
        }
        .padding(.horizontal, (Constants.moduleCyclerGutterWidth - Constants.moduleCyclerButtonSize) / 2)
        .padding(.top, appState.currentContentTopInset)
        .frame(width: windowWidth, height: appState.currentContentFrameHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(appState.isHovering ? 1 : 0.78)
        .animation(appState.hoverAnimation, value: appState.isHovering)
        .transition(.opacity)
        .allowsHitTesting(appState.currentState != .compact)
    }

    private func moduleCycleButton(systemName: String, forward: Bool) -> some View {
        let inputGeneration = appState.islandInputGeneration
        return Button {
            guard appState.canHandleIslandInput(generation: inputGeneration) else { return }
            appState.cycleModule(forward: forward)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.95))
                .frame(width: Constants.moduleCyclerButtonSize, height: Constants.moduleCyclerButtonSize)
                .background(
                    Circle()
                        .fill(.black.opacity(appState.isHovering ? 0.9 : 0.8))
                )
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .onHover { hovering in
            guard appState.canHandleIslandInput(generation: inputGeneration) else { return }
            setCycleButtonHover(hovering, forward: forward)
        }
        .help(forward ? "Next module" : "Previous module")
    }

    // MARK: - Hover

    private func setIslandSurfaceHover(_ hovering: Bool) {
        guard isHoveringIslandSurface != hovering || appState.isWindowDragHoverSuppressed else { return }
        isHoveringIslandSurface = hovering
        syncHoverState()
    }

    private func handleSurfaceHover(phase: HoverPhase) {
        guard contentMode == .production else { return }
        switch phase {
        case .active:
            setIslandSurfaceHover(true)
        case .ended:
            setIslandSurfaceHover(false)
        }
    }

    private func setCycleButtonHover(_ hovering: Bool, forward: Bool) {
        if forward {
            guard isHoveringNextButton != hovering || appState.isWindowDragHoverSuppressed else { return }
            isHoveringNextButton = hovering
        } else {
            guard isHoveringPreviousButton != hovering || appState.isWindowDragHoverSuppressed else { return }
            isHoveringPreviousButton = hovering
        }
        syncHoverState()
    }

    private func syncHoverState() {
        appState.handleHoverChange(
            isHoveringIslandSurface || isHoveringPreviousButton || isHoveringNextButton
        )
    }

    private func validateHoverState() {
        // Reconcile the view's local flags even if a missed callback left the
        // public hover false, so the post-drag gate cannot wait forever after
        // a pointer exit (including a removed display).
        guard appState.isHovering || appState.isWindowDragHoverSuppressed ||
                isHoveringIslandSurface || isHoveringPreviousButton || isHoveringNextButton else { return }
        let islandPanels = NSApp.windows.compactMap { $0 as? IslandPanel }.filter(\.isVisible)

        let pointerLocation = NSEvent.mouseLocation
        // Multi-display: hover is valid if the pointer is over ANY island.
        guard !islandPanels.contains(where: { $0.frame.contains(pointerLocation) }) else { return }

        isHoveringIslandSurface = false
        isHoveringPreviousButton = false
        isHoveringNextButton = false
        syncHoverState()
    }
}

private struct IslandSurfaceSwipeModifier: ViewModifier {
    let enabled: Bool
    let isCompact: Bool
    let givesNestedScrollViewsPriority: Bool
    let diagnosticModule: IslandSwipeDiagnostics.Module
    let diagnosticState: Int64
    let inputGeneration: UInt64
    let onTrackpad: (SwipeDirection) -> Void
    let onDragEnded: (DragGesture.Value, UInt64) -> Void
    @State private var dragInputGeneration: UInt64?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onTrackpadSwipe(
                    givesNestedScrollViewsPriority: givesNestedScrollViewsPriority,
                    diagnosticModule: diagnosticModule, diagnosticState: diagnosticState,
                    diagnosticGeneration: inputGeneration
                ) { direction in
                    guard !isCompact else {
                        IslandSwipeDiagnostics.record(.generationGate, module: diagnosticModule, reason: .compact)
                        return
                    }
                    onTrackpad(direction)
                }
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            if dragInputGeneration == nil {
                                dragInputGeneration = inputGeneration
                            }
                        }
                        .onEnded { value in
                            let generation = dragInputGeneration ?? inputGeneration
                            dragInputGeneration = nil
                            onDragEnded(value, generation)
                        }
                )
        } else {
            content
        }
    }
}

private struct IslandSwipePageMarker: View {
    let module: IslandSwipeDiagnostics.Module
    let state: Int64

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onAppear {
                IslandSwipeDiagnostics.record(.pageAppeared, module: module, values: [.state: state])
            }
    }
}
