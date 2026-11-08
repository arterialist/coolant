import Foundation

/// Turns a temperature into a fan speed. Rises follow the temperature at once, falls wait
/// for a real drop, and both are slew-limited so the fans do not hunt or surge.
public struct FanRamp: Equatable {
    public static let riseRPMPerSecond = 500.0
    public static let fallRPMPerSecond = 150.0
    public static let fallDeadbandDegrees = 1.5

    public private(set) var rpm: Double?
    private var settledTemperature: Double?

    public init() {}

    public static func linearTarget(temperature: Double, start: Double, max maxTemperature: Double,
                                    minimum: Double, maximum: Double) -> Double {
        guard maxTemperature > start else { return temperature >= start ? maximum : minimum }
        let t = Swift.min(Swift.max((temperature - start) / (maxTemperature - start), 0), 1)
        return minimum + t * (maximum - minimum)
    }

    public mutating func next(temperature: Double, start: Double, max maxTemperature: Double,
                              minimum: Double, maximum: Double, seconds: Double) -> Double {
        let settled = settledTemperature ?? temperature
        let effective: Double
        if temperature >= settled || settled - temperature >= Self.fallDeadbandDegrees {
            effective = temperature
            settledTemperature = temperature
        } else {
            effective = settled
        }
        let wanted = Self.linearTarget(temperature: effective, start: start, max: maxTemperature,
                                       minimum: minimum, maximum: maximum)
        guard let current = rpm else {
            rpm = wanted
            return wanted
        }
        let step = wanted > current
            ? Swift.min(wanted - current, Self.riseRPMPerSecond * seconds)
            : Swift.max(wanted - current, -Self.fallRPMPerSecond * seconds)
        let result = current + step
        rpm = result
        return result
    }

    public mutating func reset() {
        rpm = nil
        settledTemperature = nil
    }
}

public struct RuleEvent: Equatable {
    public enum Kind: Equatable { case triggered, cleared }
    public var kind: Kind
    public var rule: Rule
    public var temperature: Double
}

public struct RuleEngine {
    private struct State { var pendingSince: Date?; var active = false }
    private var states: [UUID: State] = [:]

    public init() {}

    public func isActive(_ id: UUID) -> Bool { states[id]?.active == true }

    /// Returns transitions in rule order. A sensor with no reading leaves its rule unchanged.
    public mutating func evaluate(rules: [Rule], temperatures: [String: Double], now: Date) -> [RuleEvent] {
        var events: [RuleEvent] = []
        let known = Set(rules.map(\.id))
        states = states.filter { known.contains($0.key) }

        for rule in rules {
            var state = states[rule.id] ?? State()
            defer { states[rule.id] = state }

            guard rule.enabled else {
                state = State()
                continue
            }
            guard let value = temperatures[rule.sensorID] else { continue }

            let tripped = rule.whenAbove ? value >= rule.threshold : value <= rule.threshold
            let released = rule.whenAbove ? value <= rule.threshold - rule.hysteresis
                                          : value >= rule.threshold + rule.hysteresis
            if state.active {
                if released {
                    state.active = false
                    state.pendingSince = nil
                    events.append(RuleEvent(kind: .cleared, rule: rule, temperature: value))
                }
            } else if tripped {
                let since = state.pendingSince ?? now
                state.pendingSince = since
                if now.timeIntervalSince(since) >= rule.holdSeconds {
                    state.active = true
                    state.pendingSince = nil
                    events.append(RuleEvent(kind: .triggered, rule: rule, temperature: value))
                }
            } else {
                state.pendingSince = nil
            }
        }
        return events
    }

    /// The first active rule that applies a preset wins, so list order is priority.
    public func winner(in rules: [Rule]) -> Rule? {
        rules.first { $0.enabled && isActive($0.id) && $0.presetID != nil }
    }
}

public struct Failsafe {
    public private(set) var engaged = false
    public static let releaseMargin = 8.0
    public init() {}

    /// Returns true when the state changed.
    public mutating func update(hottest: Double?, limit: Double) -> Bool {
        guard let hottest else { return false }
        if !engaged, hottest >= limit { engaged = true; return true }
        if engaged, hottest <= limit - Self.releaseMargin { engaged = false; return true }
        return false
    }
}
