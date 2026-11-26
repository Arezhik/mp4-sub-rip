import Foundation

// How many files Extract runs at once (issue #12). One at a Time is the 0.7.0
// behavior. Parallel fills a small number of slots. The picker is disabled
// during a run; the app stores the choice and reads it back here.

/// One at a Time or Parallel. Persisted as the raw value.
public enum ExtractionMode: String, Sendable, CaseIterable, Codable {
    case oneAtATime
    case parallel

    public static let defaultsKey = "extractionMode"

    public var title: String {
        switch self {
        case .oneAtATime: return "One at a Time"
        case .parallel: return "Parallel"
        }
    }

    /// Jobs started together. One at a Time is always 1.
    public func slotCount(activeProcessorCount: Int) -> Int {
        switch self {
        case .oneAtATime:
            return 1
        case .parallel:
            return ParallelLimit.default(activeProcessorCount: activeProcessorCount)
        }
    }

    public static func load(_ defaults: UserDefaults = .standard) -> ExtractionMode {
        guard let raw = defaults.string(forKey: defaultsKey), let mode = ExtractionMode(rawValue: raw) else {
            return .oneAtATime
        }
        return mode
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// How many files Parallel runs at once. Settings can override this later (#19).
public enum ParallelLimit {
    /// `max(2, min(activeProcessorCount / 2, 4))`. The floor of 2 is intentional:
    /// a 2-core Mac would otherwise make Parallel the same as One at a Time.
    public static func `default`(activeProcessorCount: Int) -> Int {
        let cores = max(0, activeProcessorCount)
        return max(2, min(cores / 2, 4))
    }
}
