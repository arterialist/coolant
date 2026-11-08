import AppKit
import Combine
import CoolantCore

enum HelperState: Equatable { case missing, ready, failed(String) }

@MainActor
final class AppModel: ObservableObject {
    static let tickSeconds = 2.0
    static let foreignControllerID = "com.crystalidea.macsfancontrol"
    static let minimumRPMChange = 25.0
    static let failureGraceSeconds = 20.0
    static let autopilotNoticeSeconds = 300.0

    @Published private(set) var fans: [Fan] = []
    @Published private(set) var sensors: [Sensor] = []
    @Published private(set) var helperState: HelperState = .missing
    @Published private(set) var foreignControllerRunning = false
    @Published private(set) var triggeringRule: Rule?
    @Published private(set) var failsafeEngaged = false
    @Published private(set) var autopilotOutput = Autopilot.Output(fraction: 0, reason: "", demand: 0)
    @Published var config: Config { didSet { if config != oldValue { ConfigStore.save(config) } } }

    let notch = NotchController()
    var onRefresh: (() -> Void)?

    private let smc: SMC
    private let reader: SensorReader
    private let helper = HelperClient()
    private var rules = RuleEngine()
    private var failsafe = Failsafe()
    private var autopilot = Autopilot()
    private var autopilotCoolingHard = false
    private var lastAutopilotNotice: Date?
    private let hardwareQueue = DispatchQueue(label: "coolant.hardware", qos: .userInitiated)
    private var reading = false
    private var ramps: [Int: FanRamp] = [:]
    private var commanded: [Int: Double] = [:]
    private var timer: Timer?
    private var asleep = false
    private var reportedError: String?
    private var failingSince: Date?
    private var temperatures: [String: Double] = [:]

    init?() {
        guard let smc = SMC() else { return nil }
        self.smc = smc
        reader = SensorReader(smc: smc)
        let fanCount = readFans(smc).count
        config = ConfigStore.load() ?? Config.starter(fanCount: fanCount)
        ConfigStore.save(config)
        readHardware()
    }

    func start() {
        let timer = Timer(timeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prepareForSleep() }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.asleep = false }
        }
        tick()
    }

    /// Hands every fan back to macOS. Called on quit.
    func releaseFans() {
        if !commanded.isEmpty { helper.send(HelperRequest(cmd: .resetAll)) }
        commanded.removeAll()
        helper.close()
    }

    // MARK: Control loop

    private func readHardware() {
        publish(fans: readFans(smc), sensors: reader.read())
    }

    private func publish(fans: [Fan], sensors: [Sensor]) {
        self.fans = fans
        self.sensors = sensors
        temperatures = Dictionary(sensors.map { ($0.id, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// SMC reads run off the main thread so they cannot hitch the notch animation.
    func tick() {
        guard !reading else { return }
        reading = true
        let smc = smc, reader = reader
        hardwareQueue.async { [weak self] in
            let fans = readFans(smc)
            let sensors = reader.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishTick(fans: fans, sensors: sensors) }
            }
        }
    }

    private func finishTick(fans: [Fan], sensors: [Sensor]) {
        reading = false
        publish(fans: fans, sensors: sensors)
        foreignControllerRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.foreignControllerID).isEmpty

        if !asleep {
            evaluateRules()
            evaluateFailsafe()
            evaluateAutopilot()
            applyControls()
        }
        onRefresh?()
    }

    private func evaluateAutopilot() {
        guard fans.contains(where: { selectedControl(for: $0.id) == .autopilot }) else {
            autopilot.reset()
            autopilotOutput = Autopilot.Output(fraction: 0, reason: "", demand: 0)
            autopilotCoolingHard = false
            return
        }
        let inputs = AutopilotInputs(
            cpu: temperatures[SensorID.cpuHottest], gpu: temperatures[SensorID.gpuHottest],
            battery: temperatures[SensorID.battery], ssd: temperatures[SensorID.ssd],
            ambient: temperatures[SensorID.ambient], thermalPressure: ProcessInfo.processInfo.thermalState.rawValue)
        let output = autopilot.update(inputs, seconds: Self.tickSeconds)
        autopilotOutput = output
        noticeAutopilot(output)
    }

    private func noticeAutopilot(_ output: Autopilot.Output) {
        let fraction = output.fraction
        let hard = autopilotCoolingHard ? fraction >= 0.5 : fraction >= 0.9
        guard hard != autopilotCoolingHard else { return }
        autopilotCoolingHard = hard
        guard config.notifyWarnings else { return }
        if let last = lastAutopilotNotice, Date().timeIntervalSince(last) < Self.autopilotNoticeSeconds { return }
        lastAutopilotNotice = Date()
        if hard {
            notch.show(NotchMessage(title: "Autopilot: cooling hard", detail: "\(output.reason) · fans \(Int(fraction * 100))%",
                                    symbol: "fanblades.fill", tint: .orange))
        } else {
            notch.show(NotchMessage(title: "Autopilot: back to normal", detail: "Fans \(Int(fraction * 100))%",
                                    symbol: "checkmark.circle.fill", tint: .green))
        }
    }

    private func evaluateRules() {
        for event in rules.evaluate(rules: config.rules, temperatures: temperatures, now: Date()) where event.rule.notify {
            let reading = format(event.temperature)
            let presetName = event.rule.presetID.flatMap(preset(id:))?.name
            switch event.kind {
            case .triggered:
                let detail = [sensorName(event.rule.sensorID) + " " + reading, presetName].compactMap { $0 }.joined(separator: " · ")
                notch.show(NotchMessage(title: event.rule.name, detail: detail, symbol: "thermometer.high", tint: .orange))
            case .cleared:
                notch.show(NotchMessage(title: "\(event.rule.name) cleared", detail: "\(sensorName(event.rule.sensorID)) \(reading)",
                                        symbol: "checkmark.circle.fill", tint: .green))
            }
        }
        triggeringRule = rules.winner(in: config.rules)
    }

    private func evaluateFailsafe() {
        let hottest = [temperatures[SensorID.cpuHottest], temperatures[SensorID.gpuHottest]].compactMap { $0 }.max()
        guard failsafe.update(hottest: hottest, limit: config.failsafeTemperature) else { return }
        failsafeEngaged = failsafe.engaged
        guard config.notifyWarnings else { return }
        if failsafe.engaged {
            notch.show(NotchMessage(title: "Failsafe: fans at maximum",
                                    detail: "A chip reached \(format(config.failsafeTemperature))",
                                    symbol: "exclamationmark.triangle.fill", tint: .red))
        } else {
            notch.show(NotchMessage(title: "Failsafe released", detail: "Temperatures are back in range",
                                    symbol: "checkmark.circle.fill", tint: .green))
        }
    }

    /// The control in force right now. Under Autopilot a trigger can only add cooling, which
    /// `plannedRPM` handles, so the row keeps showing Autopilot.
    func effectiveControl(for fan: Int) -> FanControl {
        if failsafeEngaged && !commanded.isEmpty { return .full }
        let selected = selectedControl(for: fan)
        if selected != .autopilot, let control = triggerControl(for: fan) { return control }
        return selected
    }

    private func triggerControl(for fan: Int) -> FanControl? {
        triggeringRule?.presetID.flatMap(preset(id:))?.control(for: fan)
    }

    private func plannedRPM(for fan: Fan) -> Double? {
        let control = effectiveControl(for: fan.id)
        let rpm = targetRPM(fan: fan, control: control)
        guard control == .autopilot, let trigger = triggerControl(for: fan.id),
              let triggered = targetRPM(fan: fan, control: trigger) else { return rpm }
        return max(rpm ?? 0, triggered)
    }

    func selectedControl(for fan: Int) -> FanControl {
        guard let id = config.activePresetID else { return config.customControls[fan] ?? .auto }
        return preset(id: id)?.control(for: fan) ?? .auto
    }

    private func applyControls() {
        // Two controllers writing the same keys fight each other, so stand down.
        if foreignControllerRunning {
            if !commanded.isEmpty { releaseFans() }
            return
        }
        let plan = fans.map { (fan: $0, rpm: plannedRPM(for: $0)) }
        guard !commanded.isEmpty || plan.contains(where: { $0.rpm != nil }) else {
            helper.close()
            helperState = helper.isInstalled ? .ready : .missing
            return
        }
        guard helper.isInstalled else {
            helperState = .missing
            return
        }

        var failure: String?
        var sent = false
        for (fan, planned) in plan {
            guard let rpm = planned else {
                ramps[fan.id] = nil
                if commanded[fan.id] != nil {
                    let reply = helper.send(HelperRequest(cmd: .auto, fan: fan.id))
                    sent = true
                    if reply?.ok == true { commanded[fan.id] = nil } else { failure = reply?.error ?? "helper did not answer" }
                }
                continue
            }
            let last = commanded[fan.id]
            let changed = last == nil || abs(last! - rpm) >= Self.minimumRPMChange || !fan.isManual
            guard changed else { continue }
            let reply = helper.send(HelperRequest(cmd: .set, fan: fan.id, rpm: rpm))
            sent = true
            if reply?.ok == true { commanded[fan.id] = rpm } else { failure = reply?.error ?? "helper did not answer" }
        }
        if !sent, !commanded.isEmpty, helper.send(HelperRequest(cmd: .ping))?.ok != true {
            failure = "helper did not answer"
        }
        report(failure)
    }

    /// Nil means leave this fan to macOS.
    private func targetRPM(fan: Fan, control: FanControl) -> Double? {
        switch control {
        case .auto:
            return nil
        case .full:
            return fan.maximum
        case .autopilot:
            return fan.minimum + autopilotOutput.fraction * (fan.maximum - fan.minimum)
        case .constant(let rpm):
            return min(max(rpm, fan.minimum), fan.maximum)
        case .sensor(let id, let start, let maxTemperature):
            // A curve that lost its sensor cannot know the heat, so run the fan hard.
            guard let temperature = temperatures[id] else { return fan.maximum }
            var ramp = ramps[fan.id] ?? FanRamp()
            let rpm = ramp.next(temperature: temperature, start: start, max: maxTemperature,
                                minimum: fan.minimum, maximum: fan.maximum, seconds: Self.tickSeconds)
            ramps[fan.id] = ramp
            return rpm
        }
    }

    /// A stopped fan makes the SMC refuse manual mode for several seconds while it spins up,
    /// so only a failure that outlasts that window is worth reporting.
    private func report(_ failure: String?) {
        guard let failure else {
            failingSince = nil
            reportedError = nil
            helperState = .ready
            return
        }
        let since = failingSince ?? Date()
        failingSince = since
        guard Date().timeIntervalSince(since) >= Self.failureGraceSeconds else {
            helperState = .ready
            return
        }
        helperState = .failed(failure)
        guard failure != reportedError else { return }
        reportedError = failure
        if config.notifyWarnings {
            notch.show(NotchMessage(title: "Fan control failed", detail: failure,
                                    symbol: "exclamationmark.triangle.fill", tint: .red))
        }
    }

    private func prepareForSleep() {
        asleep = true
        releaseFans()
        ramps.removeAll()
    }

    // MARK: User actions

    var allPresets: [Preset] { [.autopilot(fanCount: fans.count), .automatic, .fullBlast(fanCount: fans.count)] + config.presets }

    func preset(id: String) -> Preset? { allPresets.first { $0.id == id } }

    var activePresetName: String {
        config.activePresetID.flatMap(preset(id:))?.name ?? "Custom*"
    }

    func applyPreset(_ id: String) {
        guard let preset = preset(id: id), config.activePresetID != id else { return }
        config.activePresetID = id
        if config.notifyPresetChanges {
            notch.show(NotchMessage(title: "Preset: \(preset.name)", detail: presetSummary(preset), symbol: "fanblades.fill", tint: .blue))
        }
        tick()
    }

    private func presetSummary(_ preset: Preset) -> String {
        guard !preset.controls.isEmpty else { return "Fans controlled by macOS" }
        return "\(preset.controls.count) fan\(preset.controls.count == 1 ? "" : "s") under control"
    }

    func setControl(_ control: FanControl, fan: Int) {
        var controls = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, selectedControl(for: $0.id)) })
        controls[fan] = control
        config.customControls = controls
        config.activePresetID = nil
        tick()
    }

    func saveCurrentAsPreset(name: String) {
        let controls = Dictionary(uniqueKeysWithValues: fans.map { ($0.id, selectedControl(for: $0.id)) })
        let preset = Preset(name: name, controls: controls)
        config.presets.append(preset)
        config.activePresetID = preset.id
    }

    func renamePreset(_ id: String, to name: String) {
        guard let i = config.presets.firstIndex(where: { $0.id == id }) else { return }
        config.presets[i].name = name
    }

    func deletePreset(_ id: String) {
        config.presets.removeAll { $0.id == id }
        for i in config.rules.indices where config.rules[i].presetID == id { config.rules[i].presetID = nil }
        if config.activePresetID == id { config.activePresetID = Preset.automaticID }
        tick()
    }

    func helperChanged() {
        helper.close()
        reportedError = nil
        tick()
    }

    // MARK: Formatting

    func format(_ celsius: Double) -> String {
        let value = config.fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: config.preciseTemperature ? "%.1f°" : "%.0f°", value)
    }

    func sensorValue(_ id: String?) -> Double? { id.flatMap { temperatures[$0] } }

    func sensorName(_ id: String) -> String { sensors.first { $0.id == id }?.name ?? id }

    func describe(_ control: FanControl) -> String {
        switch control {
        case .auto: return "Auto"
        case .full: return "Full"
        case .autopilot:
            guard !autopilotOutput.reason.isEmpty else { return "Autopilot, minimum speed" }
            return "Autopilot, \(Int(autopilotOutput.fraction * 100))% for \(autopilotOutput.reason)"
        case .constant(let rpm): return "\(Int(rpm)) rpm"
        case .sensor(let id, let start, let max): return "\(sensorName(id)), \(format(start)) to \(format(max))"
        }
    }
}
