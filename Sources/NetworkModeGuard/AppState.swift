import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var profiles: [ModeProfile]
    @Published private(set) var snapshot = NetworkSnapshot.empty
    @Published private(set) var assessment = ModeAssessment(
        mode: .unknown,
        confidence: 0,
        summary: "尚未采集网络状态",
        evidence: [],
        blockers: []
    )
    @Published private(set) var transitionPlan: TransitionPlan?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?

    private let profilesKey = "network-mode-guard.mode-profiles"

    init() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let stored = try? JSONDecoder().decode([ModeProfile].self, from: data) {
            profiles = stored
        } else {
            profiles = ModeProfile.defaults
        }
    }

    func refresh() {
        isRefreshing = true
        lastError = nil
        let collector = NetworkStateCollector(profiles: profiles)
        let newSnapshot = collector.collect()
        snapshot = newSnapshot
        assessment = ModeClassifier(profiles: profiles).assess(newSnapshot)
        transitionPlan = nil
        isRefreshing = false
    }

    func prepareTransition(to profile: ModeProfile) {
        transitionPlan = TransitionPlanner(executionLayerAvailable: false).plan(
            from: assessment,
            to: profile,
            snapshot: snapshot
        )
    }

    func save(profile: ModeProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persistProfiles()
        refresh()
    }

    func profile(for mode: NetworkMode) -> ModeProfile? {
        profiles.first(where: { $0.mode == mode })
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
    }
}
