import CoreMotion
import Observation

@MainActor
protocol MotionActivitySource: AnyObject {
    var available: Bool { get }
    var denied: Bool { get }
    func start(_ receive: @escaping ([MotionSample]) -> Void)
    func stop()
    func history(from: Date, to: Date) async throws -> [MotionSample]
}

@MainActor
final class CoreMotionSource: MotionActivitySource {
    private let manager = CMMotionActivityManager()
    var available: Bool { CMMotionActivityManager.isActivityAvailable() }
    var denied: Bool { [.denied, .restricted].contains(CMMotionActivityManager.authorizationStatus()) }
    func start(_ receive: @escaping ([MotionSample]) -> Void) {
        manager.startActivityUpdates(to: .main) { activity in
            guard let activity else { return }
            Task { @MainActor in receive([Self.sample(activity)]) }
        }
    }
    func stop() { manager.stopActivityUpdates() }
    func history(from: Date, to: Date) async throws -> [MotionSample] {
        try await withCheckedThrowingContinuation { continuation in
            manager.queryActivityStarting(from: from, to: to, to: .main) { activities, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (activities ?? []).map(Self.sample)) }
            }
        }
    }
    nonisolated private static func sample(_ activity: CMMotionActivity) -> MotionSample {
        MotionSample(date: activity.startDate,
                     activity: activity.automotive ? .automotive : (activity.stationary || activity.walking ? .stopped : .unknown),
                     confidence: activity.confidence == .high ? .high : activity.confidence == .medium ? .medium : .low)
    }
}

@MainActor
@Observable
final class DrivingMonitor {
    private(set) var isDriving = false
    private(set) var issue: String?
    private(set) var isMonitoring = false
    private(set) var enabled: Bool
    private(set) var status: OtherStatus
    var onChange: (() -> Void)?
    var onMonitoringChange: ((Bool) -> Void)?
    private let source: MotionActivitySource
    private let defaults: UserDefaults
    private var detector: DrivingDetector
    private var timer: Timer?
    private var generation = 0
    private var querying = false
    private var buffered: [MotionSample] = []
    private let preview: Bool

    init(source: MotionActivitySource? = nil, defaults: UserDefaults = .standard, preview: Bool = false) {
        self.source = source ?? CoreMotionSource()
        self.defaults = defaults
        self.preview = preview
        enabled = defaults.object(forKey: "Whereabouts.detectDriving") as? Bool ?? true
        status = defaults.data(forKey: "Whereabouts.drivingStatus").flatMap { try? JSONDecoder().decode(OtherStatus.self, from: $0) }
            ?? OtherStatus(text: "Driving", emoji: ":car:", emojiUnicode: "🚗")
        detector = defaults.data(forKey: "Whereabouts.drivingDetector").flatMap { try? JSONDecoder().decode(DrivingDetector.self, from: $0) } ?? DrivingDetector()
    }

    func saveStatus(_ status: OtherStatus) {
        self.status = status
        defaults.set(try? JSONEncoder().encode(status), forKey: "Whereabouts.drivingStatus")
        onChange?()
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: "Whereabouts.detectDriving")
        if !enabled { stop(); detector = DrivingDetector(); persist(); isDriving = false; onChange?() }
        else {
            start()
            Task { await refresh() }
        }
    }

    func start() {
        guard enabled else { stop(); return }
        if preview { isDriving = true; return }
        guard source.available, !source.denied else {
            issue = source.available ? "Motion access is disabled. Allow Motion & Fitness access in Settings." : "Motion detection is not available on this device."
            stop()
            detector = DrivingDetector()
            persist()
            isDriving = false
            return
        }
        issue = nil
        guard !isMonitoring else { return }
        isMonitoring = true
        onMonitoringChange?(true)
        let token = generation
        source.start { [weak self] samples in
            guard let self, self.isMonitoring, self.generation == token else { return }
            if self.querying { self.buffered += samples }
            else { self.consume(samples) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMonitoring, !self.querying else { return }
                if self.source.denied { self.start(); self.onChange?() }
                else { self.consume([]) }
            }
        }
    }

    func refresh() async {
        start()
        guard isMonitoring, !querying else { return }
        let lease = BackgroundLease()
        defer { lease.end() }
        querying = true
        let token = generation
        let now = Date()
        let from = max(detector.lastSampleDate ?? now.addingTimeInterval(-86400), now.addingTimeInterval(-86400))
        do {
            let samples = try await source.history(from: from, to: now)
            guard generation == token, isMonitoring else { return }
            querying = false
            let all = samples + buffered
            buffered = []
            consume(all)
        } catch {
            guard generation == token, isMonitoring else { return }
            querying = false
            if source.denied { start() }
            else { issue = "Could not read motion activity. The app will try again." }
            let samples = buffered
            buffered = []
            if isMonitoring { consume(samples) }
        }
    }

    private func consume(_ samples: [MotionSample]) {
        let lease = BackgroundLease()
        defer { lease.end() }
        let next = detector.update(samples: samples, now: Date())
        persist()
        if next != isDriving { isDriving = next; onChange?() }
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(detector), forKey: "Whereabouts.drivingDetector") }
    private func stop() {
        generation += 1
        querying = false
        buffered = []
        source.stop()
        timer?.invalidate()
        timer = nil
        isMonitoring = false
        onMonitoringChange?(false)
    }
}
