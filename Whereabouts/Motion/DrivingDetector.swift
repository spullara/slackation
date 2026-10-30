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
    static let lowSpeedThreshold: Double = 2
    static let liveLocationSafetyTimeout: TimeInterval = 3 * 60 * 60
    static let checkInterval: TimeInterval = 15
    static let historyTimeout: TimeInterval = 10
    private(set) var isDriving = false
    private(set) var lastSampleDate: Date?
    private(set) var lastAutomotiveDate: Date?
    private var automotiveSince: Date?
    private var stoppedSince: Date?

    mutating func update(samples: [MotionSample], now: Date) -> Bool {
        for sample in samples.sorted(by: { $0.date < $1.date }) where sample.date <= now {
            if let lastSampleDate, sample.date <= lastSampleDate { continue }
            advance(to: sample.date)
            lastSampleDate = sample.date
            // Uncertain samples do not change the last reliable activity.
            guard sample.confidence != .low, sample.activity != .unknown else {
                continue
            }
            switch sample.activity {
            case .automotive:
                lastAutomotiveDate = sample.date
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

    mutating func replayHistory(samples: [MotionSample], now: Date) -> Bool {
        lastSampleDate = nil
        automotiveSince = nil
        stoppedSince = nil
        return update(samples: samples, now: now)
    }

    mutating func endDriving(at date: Date) {
        isDriving = false
        automotiveSince = nil
        stoppedSince = nil
        lastSampleDate = date
    }

    private mutating func advance(to date: Date) {
        if let automotiveSince, date.timeIntervalSince(automotiveSince) >= Self.startDelay { isDriving = true }
        if let stoppedSince, date.timeIntervalSince(stoppedSince) >= Self.stopDelay { isDriving = false }
    }
}
