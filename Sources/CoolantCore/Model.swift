import Foundation

public enum FanControl: Codable, Equatable, Hashable {
    case auto
    case full
    case autopilot
    case constant(rpm: Double)
    case sensor(id: String, start: Double, max: Double)
}

public struct Preset: Codable, Identifiable, Equatable {
    public static let automaticID = "builtin.automatic"
    public static let fullBlastID = "builtin.fullblast"
    public static let autopilotID = "builtin.autopilot"

    public var id: String
    public var name: String
    public var controls: [Int: FanControl]

    public init(id: String = UUID().uuidString, name: String, controls: [Int: FanControl]) {
        self.id = id
        self.name = name
        self.controls = controls
    }

    public var isBuiltIn: Bool { id.hasPrefix("builtin.") }

    public func control(for fan: Int) -> FanControl { controls[fan] ?? .auto }

    public static let automatic = Preset(id: automaticID, name: "Automatic", controls: [:])
    public static func autopilot(fanCount: Int) -> Preset {
        Preset(id: autopilotID, name: "Autopilot",
               controls: Dictionary(uniqueKeysWithValues: (0..<fanCount).map { ($0, .autopilot) }))
    }

    public static func fullBlast(fanCount: Int) -> Preset {
        Preset(id: fullBlastID, name: "Full blast",
               controls: Dictionary(uniqueKeysWithValues: (0..<fanCount).map { ($0, .full) }))
    }
}

public struct Rule: Codable, Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var sensorID: String
    public var whenAbove: Bool
    public var threshold: Double
    /// Degrees past the threshold, back toward normal, before the trigger clears.
    public var hysteresis: Double
    public var holdSeconds: Double
    /// Preset to apply while active. Nil makes it a notification-only trigger.
    public var presetID: String?
    public var notify: Bool

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, sensorID: String, whenAbove: Bool = true,
                threshold: Double, hysteresis: Double = 6, holdSeconds: Double = 10, presetID: String?, notify: Bool = true) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sensorID = sensorID
        self.whenAbove = whenAbove
        self.threshold = threshold
        self.hysteresis = hysteresis
        self.holdSeconds = holdSeconds
        self.presetID = presetID
        self.notify = notify
    }
}

public struct MenuBarOptions: Codable, Equatable {
    public var sensorID: String? = SensorID.cpuHottest
    public var fan: Int? = 0
    public var showIcon = true
    public var twoLines = true
    public init() {}
}

public struct Config: Codable, Equatable {
    /// Selected preset. Nil means the fans use `customControls` ("Custom*").
    public var activePresetID: String? = Preset.automaticID
    public var customControls: [Int: FanControl] = [:]
    public var presets: [Preset] = []
    public var rules: [Rule] = []
    public var fahrenheit = false
    public var preciseTemperature = false
    public var showDockIcon = false
    public var launchAtLogin = false
    public var notifyPresetChanges = true
    public var notifyWarnings = true
    public var failsafeTemperature = 105.0
    public var menuBar = MenuBarOptions()
    public init() {}

    public static func starter(fanCount: Int) -> Config {
        var config = Config()
        let fans = 0..<fanCount
        func curve(_ id: String, _ start: Double, _ max: Double) -> [Int: FanControl] {
            Dictionary(uniqueKeysWithValues: fans.map { ($0, .sensor(id: id, start: start, max: max)) })
        }
        let cooling = Preset(name: "Cooling", controls: curve(SensorID.cpuAverage, 50, 75))
        let gpu = Preset(name: "GPU cooling", controls: curve(SensorID.gpuAverage, 50, 80))
        let battery = Preset(name: "Battery protect", controls: curve(SensorID.battery, 33, 42))
        config.presets = [cooling, gpu, battery]
        config.rules = [
            Rule(name: "Battery warm", enabled: false, sensorID: SensorID.battery, threshold: 38, hysteresis: 3, holdSeconds: 30, presetID: battery.id),
            Rule(name: "CPU hot", enabled: false, sensorID: SensorID.cpuAverage, threshold: 85, hysteresis: 10, holdSeconds: 10, presetID: cooling.id),
            Rule(name: "GPU hot", enabled: false, sensorID: SensorID.gpuAverage, threshold: 80, hysteresis: 10, holdSeconds: 10, presetID: gpu.id),
        ]
        return config
    }
}

public enum ConfigStore {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Coolant/config.json")
    }

    public static func load() -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    public static func save(_ config: Config) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) { try? data.write(to: url, options: .atomic) }
    }
}
