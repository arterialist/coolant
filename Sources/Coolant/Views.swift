import CoolantCore
import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Banners(model: model)
            TabView {
                ControlTab(model: model).tabItem { Text("Fans") }
                TriggersTab(model: model).tabItem { Text("Triggers") }
                SettingsTab(model: model).tabItem { Text("Settings") }
            }
            .padding(12)
        }
        .frame(minWidth: 780, minHeight: 500)
    }
}

private struct Banners: View {
    @ObservedObject var model: AppModel
    @Local private var installing = false
    @Local private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            if model.foreignControllerRunning {
                banner("Macs Fan Control is running, so Coolant is only monitoring. Quit it to take over the fans.", .orange)
            }
            if case .failed(let reason) = model.helperState { banner("Fan control failed: \(reason)", .red) }
            if model.helperState == .missing {
                HStack {
                    Text(installError ?? "Fan control needs the helper. Monitoring works without it.")
                    Spacer()
                    Button(installing ? "Installing..." : "Install helper") { install() }.disabled(installing)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.2))
            }
            if let rule = model.triggeringRule { banner("Trigger active: \(rule.name). It overrides the selected preset.", .blue) }
            if model.failsafeEngaged { banner("Failsafe engaged: fans held at maximum.", .red) }
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(color.opacity(0.2))
    }

    private func install() {
        installing = true
        Task {
            installError = await HelperInstaller.run(script: "install-helper")
            try? await Task.sleep(for: .seconds(1))
            installing = false
            model.helperChanged()
        }
    }
}

// MARK: Fans and sensors

private struct ControlTab: View {
    @ObservedObject var model: AppModel
    @Local private var editingFan: Fan?
    @Local private var naming: PresetNaming?

    enum PresetNaming: Identifiable {
        case new, rename(Preset)
        var id: String { if case .rename(let p) = self { return p.id }; return "new" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            presetBar
            HSplitView {
                fanList.frame(minWidth: 420)
                SensorList(model: model).frame(minWidth: 260)
            }
        }
        .padding(.top, 8)
        .sheet(item: $editingFan) { fan in FanEditor(model: model, fan: fan) }
        .sheet(item: $naming) { naming in
            NameSheet(title: titleFor(naming), initial: initialFor(naming)) { name in
                switch naming {
                case .new: model.saveCurrentAsPreset(name: name)
                case .rename(let preset): model.renamePreset(preset.id, to: name)
                }
            }
        }
    }

    private func titleFor(_ naming: PresetNaming) -> String {
        if case .rename = naming { return "Rename preset" }
        return "Save preset"
    }

    private func initialFor(_ naming: PresetNaming) -> String {
        if case .rename(let preset) = naming { return preset.name }
        return ""
    }

    private var selectedCustomPreset: Preset? {
        model.config.presets.first { $0.id == model.config.activePresetID }
    }

    private var presetBar: some View {
        HStack {
            Text("Active preset")
            Picker("", selection: Binding(get: { model.config.activePresetID ?? "custom" }, set: { model.applyPreset($0) })) {
                ForEach(model.allPresets) { Text($0.name).tag($0.id) }
                if model.config.activePresetID == nil { Text("Custom*").tag("custom") }
            }
            .labelsHidden()
            .frame(width: 200)
            Button("Save as...") { naming = .new }
            if let preset = selectedCustomPreset {
                Button("Rename...") { naming = .rename(preset) }
                Button("Delete", role: .destructive) { model.deletePreset(preset.id) }
            }
            Spacer()
        }
    }

    private var fanList: some View {
        List(model.fans) { fan in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(fan.name).font(.headline)
                    Text("\(Int(fan.minimum)) / \(Int(fan.current)) / \(Int(fan.maximum)) rpm")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(model.describe(model.effectiveControl(for: fan.id))).font(.callout)
                }
                Spacer()
                Button("Auto") { model.setControl(.auto, fan: fan.id) }
                    .disabled(model.selectedControl(for: fan.id) == .auto)
                Button("Custom...") { editingFan = fan }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct SensorList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ForEach(SensorGroup.allCases) { group in
                let items = model.sensors.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.rawValue) {
                        ForEach(items) { sensor in
                            HStack {
                                Text(sensor.name)
                                Spacer()
                                Text(model.format(sensor.value)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private enum ControlKind: String, CaseIterable, Identifiable {
    case constant = "Constant RPM", sensor = "Sensor-based"
    var id: String { rawValue }
}

private struct FanEditor: View {
    @ObservedObject var model: AppModel
    let fan: Fan
    @Environment(\.dismiss) private var dismiss
    @Local private var kind = ControlKind.sensor
    @Local private var rpm = 2000.0
    @Local private var sensorID = SensorID.cpuAverage
    @Local private var start = 50.0
    @Local private var maxTemperature = 80.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Control for \(fan.name)").font(.headline)
            Picker("", selection: $kind) { ForEach(ControlKind.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            if kind == .constant {
                Text("\(Int(rpm)) rpm").monospacedDigit()
                Slider(value: $rpm, in: fan.minimum...fan.maximum, step: 50)
            } else {
                SensorPicker(model: model, selection: $sensorID)
                TemperatureField(model: model, title: "Speed starts rising at", celsius: $start)
                TemperatureField(model: model, title: "Maximum speed at", celsius: $maxTemperature)
                if maxTemperature <= start { Text("The maximum must be above the start.").foregroundStyle(.red) }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(kind == .sensor && maxTemperature <= start)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private func load() {
        rpm = min(max(fan.current, fan.minimum), fan.maximum)
        switch model.selectedControl(for: fan.id) {
        case .constant(let value): kind = .constant; rpm = value
        case .sensor(let id, let s, let m): kind = .sensor; sensorID = id; start = s; maxTemperature = m
        case .full: kind = .constant; rpm = fan.maximum
        case .auto, .autopilot: break
        }
    }

    private func apply() {
        model.setControl(kind == .constant ? .constant(rpm: rpm) : .sensor(id: sensorID, start: start, max: maxTemperature), fan: fan.id)
        dismiss()
    }
}

private struct SensorPicker: View {
    @ObservedObject var model: AppModel
    @Binding var selection: String

    var body: some View {
        Picker("Sensor", selection: $selection) {
            ForEach(SensorGroup.allCases) { group in
                let items = model.sensors.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.rawValue) { ForEach(items) { Text($0.name).tag($0.id) } }
                }
            }
        }
    }
}

/// Values stay in Celsius in the model and convert only for display.
private struct TemperatureField: View {
    @ObservedObject var model: AppModel
    let title: String
    @Binding var celsius: Double

    private var fahrenheit: Bool { model.config.fahrenheit }

    private var shown: Binding<Double> {
        Binding(get: { (fahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded() },
                set: { celsius = fahrenheit ? ($0 - 32) * 5 / 9 : $0 })
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: shown, format: .number).frame(width: 60).multilineTextAlignment(.trailing)
            Stepper("", value: shown, step: 1).labelsHidden()
            Text(fahrenheit ? "°F" : "°C")
        }
    }
}

private struct NameSheet: View {
    let title: String
    let initial: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Local private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Preset name", text: $name)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { onSave(name.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { name = initial }
    }
}

// MARK: Triggers

private struct TriggersTab: View {
    @ObservedObject var model: AppModel
    @Local private var editing: Rule?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Triggers higher in the list win when several are active.").foregroundStyle(.secondary)
                Spacer()
                Button("Add trigger") {
                    editing = Rule(name: "New trigger", sensorID: SensorID.cpuHottest, threshold: 85, presetID: model.config.presets.first?.id)
                }
            }
            List {
                ForEach(model.config.rules) { rule in row(rule) }
                    .onMove { model.config.rules.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .padding(.top, 8)
        .sheet(item: $editing) { rule in RuleEditor(model: model, rule: rule) }
    }

    private func row(_ rule: Rule) -> some View {
        HStack {
            Toggle("", isOn: enabledBinding(rule)).labelsHidden()
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rule.name).font(.headline)
                    if model.triggeringRule?.id == rule.id { Text("Active").font(.caption).foregroundStyle(.orange) }
                }
                Text(summary(rule)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Edit") { editing = rule }
            Button("Delete", role: .destructive) { model.config.rules.removeAll { $0.id == rule.id } }
        }
        .padding(.vertical, 3)
    }

    private func enabledBinding(_ rule: Rule) -> Binding<Bool> {
        Binding(get: { rule.enabled }, set: { value in
            if let i = model.config.rules.firstIndex(where: { $0.id == rule.id }) { model.config.rules[i].enabled = value }
        })
    }

    private func summary(_ rule: Rule) -> String {
        let condition = "\(model.sensorName(rule.sensorID)) \(rule.whenAbove ? "at or above" : "at or below") \(model.format(rule.threshold)) for \(Int(rule.holdSeconds)) s"
        let action = rule.presetID.flatMap(model.preset(id:)).map { "apply \($0.name)" } ?? "notify only"
        return "\(condition), \(action)"
    }
}

private struct RuleEditor: View {
    @ObservedObject var model: AppModel
    @Local var rule: Rule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $rule.name)
            SensorPicker(model: model, selection: $rule.sensorID)
            Picker("When", selection: $rule.whenAbove) {
                Text("At or above").tag(true)
                Text("At or below").tag(false)
            }
            TemperatureField(model: model, title: "Temperature", celsius: $rule.threshold)
            Stepper("Must hold for \(Int(rule.holdSeconds)) s", value: $rule.holdSeconds, in: 0...600, step: 5)
            Stepper("Clears \(Int(rule.hysteresis))° past the threshold", value: $rule.hysteresis, in: 1...30)
            Picker("Action", selection: $rule.presetID) {
                Text("Notify only").tag(String?.none)
                ForEach(model.allPresets) { Text($0.name).tag(String?.some($0.id)) }
            }
            Toggle("Notch notification", isOn: $rule.notify)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 440)
    }

    private func save() {
        if let i = model.config.rules.firstIndex(where: { $0.id == rule.id }) {
            model.config.rules[i] = rule
        } else {
            model.config.rules.append(rule)
        }
        dismiss()
    }
}

// MARK: Settings

private struct SettingsTab: View {
    @ObservedObject var model: AppModel
    @Local private var message: String?
    @Local private var removing = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: launchBinding)
                Toggle("Show icon in Dock", isOn: $model.config.showDockIcon)
                Toggle("Use Fahrenheit", isOn: $model.config.fahrenheit)
                Toggle("Show tenths of a degree", isOn: $model.config.preciseTemperature)
            }
            Section("Menu bar") {
                Picker("Sensor", selection: $model.config.menuBar.sensorID) {
                    Text("None").tag(String?.none)
                    ForEach(model.sensors.filter { $0.group == .summary }) { Text($0.name).tag(String?.some($0.id)) }
                }
                Picker("Fan", selection: $model.config.menuBar.fan) {
                    Text("None").tag(Int?.none)
                    ForEach(model.fans) { Text($0.name).tag(Int?.some($0.id)) }
                }
                Toggle("Show icon", isOn: $model.config.menuBar.showIcon)
                Toggle("Stack readings on two lines", isOn: $model.config.menuBar.twoLines)
            }
            Section("Notch notifications") {
                Toggle("When the preset changes", isOn: $model.config.notifyPresetChanges)
                Toggle("Warnings and failsafe", isOn: $model.config.notifyWarnings)
                Button("Show a test notification") {
                    model.notch.show(NotchMessage(title: "Test notification", detail: "This is how triggers appear", symbol: "fanblades.fill", tint: .blue))
                }
            }
            Section("Safety") {
                VStack(alignment: .leading) {
                    Text("Failsafe: run fans at maximum at \(model.format(model.config.failsafeTemperature))")
                    Slider(value: $model.config.failsafeTemperature, in: 85...110, step: 1)
                    Text("Applies while Coolant is controlling a fan. Automatic fans stay with macOS.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Helper") {
                Text(helperText)
                if let message { Text(message).foregroundStyle(.red) }
                Button(removing ? "Removing..." : "Remove helper") { remove() }.disabled(removing || model.helperState == .missing)
            }
        }
        .formStyle(.grouped)
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { model.config.launchAtLogin }, set: {
            model.config.launchAtLogin = $0
            LaunchAtLogin.set($0)
        })
    }

    private var helperText: String {
        switch model.helperState {
        case .missing: return "Not installed"
        case .ready: return "Installed. Fans return to automatic if Coolant quits or stops responding."
        case .failed(let reason): return "Error: \(reason)"
        }
    }

    private func remove() {
        removing = true
        Task {
            message = await HelperInstaller.run(script: "uninstall-helper")
            removing = false
            model.helperChanged()
        }
    }
}
