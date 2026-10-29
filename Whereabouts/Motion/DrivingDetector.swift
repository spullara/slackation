import Foundation

struct MotionSample: Sendable {
    enum Activity: String, Codable { case automotive, stopped, unknown }
    enum Confidence { case low, medium, high }
    var date: Date
    var activity: Activity
    var confidence: Confidence
}

/// Activity samples describe transitions, not periodic measurements.
struct DrivingDetector: Codable {
    static let startDelay: TimeInterval = 120
    static let stopDelay: TimeInterval = 120
    static let historyTimeout: TimeInterval = 10
    private(set) var isDriving = false
    private(set) var lastSampleDate: Date?
    private var automotiveSince: Date?
    private var stoppedSince: Date?

    mutating func update(samples: [MotionSample], now: Date) -> Bool {
        for sample in samples.sorted(by: { $0.date < $1.date }) where sample.date <= now {
            if let lastSampleDate, sample.date <= lastSampleDate { continue }
            advance(to: sample.date)
            lastSampleDate = sample.date
            // Uncertain intervals cannot establish either timed threshold.
            guard sample.confidence != .low, sample.activity != .unknown else {
                automotiveSince = nil
                stoppedSince = nil
                continue
            }
            switch sample.activity {
            case .automotive:
                stoppedSince = nil
                automotiveSince = automotiveSince ?? sample.date
                if sample.confidence == .high { isDriving = true }
            case .stopped:
                automotiveSince = nil
                stoppedSince = stoppedSince ?? sample.date
            case .unknown: break
            }
        }
        advance(to: now)
        return isDriving
    }

    private mutating func advance(to date: Date) {
        if let automotiveSince, date.timeIntervalSince(automotiveSince) >= Self.startDelay { isDriving = true }
        if let stoppedSince, date.timeIntervalSince(stoppedSince) >= Self.stopDelay { isDriving = false }
    }
}
