import Foundation

public struct AutopilotInputs: Equatable {
    public var cpu, gpu, battery, ssd, ambient: Double?
    /// `ProcessInfo.ThermalState` raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermalPressure: Int

    public init(cpu: Double?, gpu: Double?, battery: Double?, ssd: Double?, ambient: Double?, thermalPressure: Int) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
        self.ssd = ssd
        self.ambient = ambient
        self.thermalPressure = thermalPressure
    }
}

/// Chooses one fan speed from whichever component needs cooling most. README explains the limits.
public struct Autopilot {
    public struct Zone: Equatable {
        public let name: String
        public let soft: Double
        public let hard: Double
    }

    public struct Output: Equatable {
        /// Share of the fan's range. Nil leaves the fans to macOS.
        public var fraction: Double?
        public var reason: String
        public var demand: Double

        public init(fraction: Double?, reason: String, demand: Double) {
            self.fraction = fraction
            self.reason = reason
            self.demand = demand
        }
    }

    static let cpuZone = Zone(name: "CPU", soft: 65, hard: 85)
    static let gpuZone = Zone(name: "GPU", soft: 60, hard: 80)
    static let ssdZone = Zone(name: "SSD", soft: 50, hard: 70)
    static let pressureFloor: [Double] = [0, 0.4, 0.85, 1]

    static let attackSeconds = 4.0
    static let releaseSeconds = 45.0
    static let risePerSecond = 0.10
    static let fallPerSecond = 0.02
    static let engageDemand = 0.10
    static let calmDemand = 0.03
    static let calmSeconds = 90.0

    /// A fan cannot push the pack below room air, so the target follows a hot room up to a limit.
    public static func batteryZone(ambient: Double?) -> Zone {
        let soft = min(max(34, (ambient ?? 0) + 3), 38)
        return Zone(name: "Battery", soft: soft, hard: soft + 6)
    }

    private var filtered: [String: Double] = [:]
    private var fraction = 0.0
    private var engaged = false
    private var calmFor = 0.0

    public init() {}

    public mutating func reset() {
        self = Autopilot()
    }

    private mutating func filter(_ name: String, _ value: Double, seconds: Double) -> Double {
        guard let last = filtered[name] else {
            filtered[name] = value
            return value
        }
        let tau = value > last ? Self.attackSeconds : Self.releaseSeconds
        let next = last + (value - last) * (1 - exp(-seconds / tau))
        filtered[name] = next
        return next
    }

    public mutating func update(_ inputs: AutopilotInputs, seconds: Double) -> Output {
        let readings: [(Zone, Double?)] = [
            (Self.cpuZone, inputs.cpu), (Self.gpuZone, inputs.gpu),
            (Self.batteryZone(ambient: inputs.ambient), inputs.battery), (Self.ssdZone, inputs.ssd),
        ]
        var demand = 0.0
        var reason = ""
        for (zone, value) in readings {
            guard let value else { continue }
            let smooth = filter(zone.name, value, seconds: seconds)
            let zoneDemand = min(max((smooth - zone.soft) / (zone.hard - zone.soft), 0), 1)
            if zoneDemand > demand {
                demand = zoneDemand
                reason = zone.name
            }
        }
        let floor = Self.pressureFloor[min(max(inputs.thermalPressure, 0), 3)]
        if floor > demand {
            demand = floor
            reason = "thermal pressure"
        }

        if !engaged {
            guard demand >= Self.engageDemand else { return Output(fraction: nil, reason: reason, demand: demand) }
            engaged = true
            calmFor = 0
            fraction = 0
        }
        calmFor = demand < Self.calmDemand ? calmFor + seconds : 0
        if calmFor >= Self.calmSeconds {
            engaged = false
            fraction = 0
            return Output(fraction: nil, reason: reason, demand: demand)
        }
        let step = demand > fraction
            ? min(demand - fraction, Self.risePerSecond * seconds)
            : max(demand - fraction, -Self.fallPerSecond * seconds)
        fraction += step
        return Output(fraction: fraction, reason: reason, demand: demand)
    }
}
