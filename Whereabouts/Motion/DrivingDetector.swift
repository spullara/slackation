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

    mutating func update(samples: [MotionSample], now: Date, record: (String) -> Void = { _ in }) -> Bool {
        for sample in samples.sorted(by: { $0.date < $1.date }) where sample.date <= now {
            if let lastSampleDate, sample.date <= lastSampleDate { continue }
            advance(to: sample.date, record: record)
            lastSampleDate = sample.date
            record("motion sample: \(sample.activity.rawValue), \(sample.confidence)")
            // Uncertain samples do not change the last reliable activity.
            guard sample.confidence != .low, sample.activity != .unknown else {
                continue
            }
            switch sample.activity {
            case .automotive:
                lastAutomotiveDate = sample.date
                stoppedSince = nil
                automotiveSince = automotiveSince ?? sample.date
                if sample.confidence == .high {
                    if !isDriving { record("driving start: high confidence") }
                    isDriving = true
                }
            case .stopped:
                automotiveSince = nil
                stoppedSince = stoppedSince ?? sample.date
            case .unknown: break
            }
        }
        advance(to: now, record: record)
        return isDriving
    }

    mutating func replayHistory(samples: [MotionSample], now: Date, record: (String) -> Void = { _ in }) -> Bool {
        lastSampleDate = nil
        automotiveSince = nil
        stoppedSince = nil
        return update(samples: samples, now: now, record: record)
    }

    mutating func endDriving(at date: Date) {
        isDriving = false
        automotiveSince = nil
        stoppedSince = nil
        lastSampleDate = date
    }

    private mutating func advance(to date: Date, record: (String) -> Void) {
        if let automotiveSince, date.timeIntervalSince(automotiveSince) >= Self.startDelay {
            if !isDriving { record("driving start: medium for 2 min") }
            isDriving = true
        }
        if let stoppedSince, date.timeIntervalSince(stoppedSince) >= Self.stopDelay {
            if isDriving { record("driving stop: stopped 2 min") }
            isDriving = false
        }
    }
}
