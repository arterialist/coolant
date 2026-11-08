import CSMC
import Foundation

public struct Fan: Identifiable, Equatable {
    public let id: Int
    public var name: String { "Fan \(id + 1)" }
    public var current: Double
    public var minimum: Double
    public var maximum: Double
    public var target: Double
    public var isManual: Bool

    public init(id: Int, current: Double, minimum: Double, maximum: Double, target: Double, isManual: Bool) {
        self.id = id
        self.current = current
        self.minimum = minimum
        self.maximum = maximum
        self.target = target
        self.isManual = isManual
    }
}

public func readFans(_ smc: SMC) -> [Fan] {
    let count = Int(smc.uint8("FNum") ?? 0)
    return (0..<count).compactMap { i in
        guard let current = smc.float("F\(i)Ac"),
              let minimum = smc.float("F\(i)Mn"),
              let maximum = smc.float("F\(i)Mx") else { return nil }
        return Fan(id: i, current: current, minimum: minimum, maximum: maximum,
                   target: smc.float("F\(i)Tg") ?? 0, isManual: smc.uint8("F\(i)Md") == 1)
    }
}

public enum SensorGroup: String, CaseIterable, Identifiable, Codable {
    case summary = "Summary"
    case cpu = "CPU"
    case gpu = "GPU"
    case battery = "Battery"
    case storage = "Storage"
    case die = "SoC die"
    case other = "Other"
    public var id: String { rawValue }
}

public struct Sensor: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let group: SensorGroup
    public var value: Double

    public init(id: String, name: String, group: SensorGroup, value: Double) {
        self.id = id
        self.name = name
        self.group = group
        self.value = value
    }
}

/// IDs of the computed sensors that presets and triggers normally use.
public enum SensorID {
    public static let cpuHottest = "group.cpu.hottest"
    public static let cpuAverage = "group.cpu.average"
    public static let gpuHottest = "group.gpu.hottest"
    public static let gpuAverage = "group.gpu.average"
    public static let battery = "group.battery.hottest"
}

/// Key prefixes confirmed by load tests on an M3 Pro: Tp and Te follow CPU load,
/// Tg follows GPU load, TB matches the battery gas gauge.
public func smcGroup(for key: String) -> (SensorGroup, String) {
    switch String(key.prefix(2)) {
    case "Tp": return (.cpu, "CPU performance \(key)")
    case "Te": return (.cpu, "CPU efficiency \(key)")
    case "Tg": return (.gpu, "GPU \(key)")
    case "TB": return (.battery, "Battery \(key)")
    case "TH": return (.storage, "SSD \(key)")
    default: return (.other, key)
    }
}

public func plausibleTemperature(_ value: Double) -> Bool { value > 5 && value < 130 }

/// Computes the summary sensors from the individual readings.
public func summarySensors(from sensors: [Sensor]) -> [Sensor] {
    func values(_ group: SensorGroup) -> [Double] { sensors.filter { $0.group == group }.map(\.value) }
    func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
    var out: [Sensor] = []
    let cpu = values(.cpu), gpu = values(.gpu), battery = values(.battery)
    if let hot = cpu.max() {
        out.append(Sensor(id: SensorID.cpuHottest, name: "CPU hottest", group: .summary, value: hot))
        out.append(Sensor(id: SensorID.cpuAverage, name: "CPU average", group: .summary, value: mean(cpu)))
    }
    if let hot = gpu.max() {
        out.append(Sensor(id: SensorID.gpuHottest, name: "GPU hottest", group: .summary, value: hot))
        out.append(Sensor(id: SensorID.gpuAverage, name: "GPU average", group: .summary, value: mean(gpu)))
    }
    if let hot = battery.max() {
        out.append(Sensor(id: SensorID.battery, name: "Battery", group: .summary, value: hot))
    }
    return out
}

public final class SensorReader {
    private let smc: SMC
    private let keys: [String]

    public init(smc: SMC) {
        self.smc = smc
        keys = smc.allKeys()
            .filter { $0.hasPrefix("T") && smc.type(of: $0)?.hasPrefix("flt") == true }
            .sorted()
    }

    public func read() -> [Sensor] {
        var out: [Sensor] = []
        out.reserveCapacity(keys.count + 48)
        for key in keys {
            guard let value = smc.float(key), plausibleTemperature(value) else { continue }
            let (group, name) = smcGroup(for: key)
            out.append(Sensor(id: "smc.\(key)", name: name, group: group, value: value))
        }
        out.append(contentsOf: Self.readHID())
        return summarySensors(from: out) + out
    }

    private static func readHID() -> [Sensor] {
        var buffer = [csmc_hid_temp](repeating: csmc_hid_temp(), count: 128)
        let n = Int(csmc_hid_temps(&buffer, 128))
        var seen: [String: Int] = [:]
        var out: [Sensor] = []
        for i in 0..<n {
            let name = withUnsafePointer(to: buffer[i].name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) }
            }
            let value = buffer[i].value
            guard plausibleTemperature(value) else { continue }
            seen[name, default: 0] += 1
            let copy = seen[name]!
            let label = copy > 1 ? "\(name) #\(copy)" : name
            let group: SensorGroup
            if name.hasPrefix("NAND") { group = .storage }
            else if name.hasPrefix("PMU tdie") { group = .die }
            else if name.hasPrefix("gas gauge") { continue }  // duplicates TB0T..TB2T
            else { group = .other }
            out.append(Sensor(id: "hid.\(label)", name: label, group: group, value: value))
        }
        return out
    }
}
