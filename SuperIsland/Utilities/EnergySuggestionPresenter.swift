import AppKit

enum EnergySuggestionReason {
    case battery
    case sustainedActivity

    var message: String {
        switch self {
        case .battery:
            return "Your Mac switched to battery power. SuperIsland can reduce background refresh and pause inactive extension work until you switch back."
        case .sustainedActivity:
            return "SuperIsland has been doing sustained background refresh work. Low Power mode can slow non-essential refresh until you need it again."
        }
    }
}

@MainActor
final class EnergySuggestionPresenter {
    struct Context {
        var lowPowerEnabled: Bool
        var doNotAskAgain: Bool
        var managedBatteryTask: Bool
    }

    static let shared = EnergySuggestionPresenter()

    private let lastPromptKey = "energy.lowPowerSuggestion.lastPromptAt"
    private var isShowing = false
    private let defaults: UserDefaults
    private let context: @MainActor () -> Context
    private let present: @MainActor (EnergySuggestionReason) -> NSApplication.ModalResponse
    private let handleResponse: @MainActor (NSApplication.ModalResponse) -> Void

    private convenience init() {
        self.init(defaults: .standard, context: {
            let state = AppState.shared
            return Context(lowPowerEnabled: state.energyMode == .lowPower,
                           doNotAskAgain: state.lowPowerSuggestionDoNotAskAgain,
                           managedBatteryTask: BatteryManagementService.shared.suppressesEnergySuggestions)
        }, present: Self.showAlert, handleResponse: { response in
            switch response {
            case .alertFirstButtonReturn: AppState.shared.energyMode = .lowPower
            case .alertThirdButtonReturn: AppState.shared.lowPowerSuggestionDoNotAskAgain = true
            default: break
            }
        })
    }

    init(defaults: UserDefaults, context: @escaping @MainActor () -> Context,
         present: @escaping @MainActor (EnergySuggestionReason) -> NSApplication.ModalResponse,
         handleResponse: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        self.defaults = defaults; self.context = context
        self.present = present; self.handleResponse = handleResponse
    }

    private var eligible: Bool {
        let state = context()
        guard !state.lowPowerEnabled, !state.doNotAskAgain, !state.managedBatteryTask else { return false }
        let lastPrompt = defaults.double(forKey: lastPromptKey)
        return lastPrompt <= 0 || Date().timeIntervalSince1970 - lastPrompt >= 24 * 60 * 60
    }

    func suggestLowPower(reason: EnergySuggestionReason) {
        guard !isShowing, eligible else { return }
        isShowing = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isShowing = false }
            // A control request may start after the power event was queued.
            // Suppressed prompts must not consume the daily suggestion window.
            guard self.eligible else { return }
            self.defaults.set(Date().timeIntervalSince1970, forKey: self.lastPromptKey)
            self.handleResponse(self.present(reason))
        }
    }

    private static func showAlert(reason: EnergySuggestionReason) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Use Low Power mode?"
        alert.informativeText = reason.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable Low Power")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Do Not Ask Again")
        return alert.runModal()
    }
}
