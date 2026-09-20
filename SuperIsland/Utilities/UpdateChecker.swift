import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    private static let lastCheckedKey = "updateChecker.lastCheckedAt"
    private static let dailyInterval: TimeInterval = 86400

    enum CheckState {
        case idle
        case checking
        case upToDate
        case noCompatibleRelease
        case updateAvailable(latestVersion: String, releaseURL: URL, downloadURL: URL?)
        case failed(String)
    }

    @Published var checkState: CheckState = .idle
    private init() {}

    var lastCheckedAt: Date? {
        let timestamp = UserDefaults.standard.double(forKey: Self.lastCheckedKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    func checkIfDue() {
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.dailyInterval { return }
        Task { await performCheck() }
    }

    func checkNow() { Task { await performCheck() } }

    private func performCheck() async {
        if case .checking = checkState { return }
        checkState = .checking
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)
        let policy = UpdateReleasePolicy.current

        do {
            var request = URLRequest(url: policy.apiURL, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                checkState = .failed("更新信息无法读取，请稍后重试")
                return
            }
            guard response.statusCode == 200 else {
                if response.statusCode == 404 {
                    checkState = .noCompatibleRelease
                } else if response.statusCode == 403 || response.statusCode == 429 {
                    checkState = .failed("检查过于频繁，请稍后重试")
                } else {
                    checkState = .failed("更新服务暂不可用，请稍后重试")
                }
                return
            }
            let result: UpdateReleasePolicy.Result
            do {
                result = try policy.selectRelease(from: data)
            } catch {
                checkState = .failed("更新信息不完整，请稍后重试")
                return
            }
            switch result {
            case .upToDate: checkState = .upToDate
            case .noCompatibleRelease: checkState = .noCompatibleRelease
            case .available(let offer):
                checkState = .updateAvailable(latestVersion: offer.version, releaseURL: offer.releaseURL, downloadURL: offer.downloadURL)
            }
        } catch {
            checkState = .failed("无法检查更新，请检查网络后重试")
        }
    }
}
