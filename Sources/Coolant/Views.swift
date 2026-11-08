import CoolantCore
import SwiftUI

private enum Page: String, CaseIterable, Identifiable {
    case fans, triggers, settings
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .fans: return "fanblades.fill"
        case .triggers: return "thermometer.high"
        case .settings: return "gearshape.fill"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    /// `--tab=triggers` or `--tab=settings` opens that page, for documentation screenshots.
    @Local private var page: Page? = CommandLine.arguments.first { $0.hasPrefix("--tab=") }
        .flatMap { Page(rawValue: String($0.dropFirst(6))) } ?? .fans
    @Local private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(Page.allCases, selection: $page) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
            .safeAreaInset(edge: .bottom) { StatusChip(model: model).padding(10) }
            .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                Backdrop()
                VStack(spacing: 12) {
                    Banners(model: model)
                    switch page ?? .fans {
                    case .fans: FansPage(model: model)
                    case .triggers: TriggersPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .padding(.top, 34)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

private struct StatusChip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.activePresetName).font(.callout.weight(.semibold)).lineLimit(1)
            if let hottest = model.sensorValue(SensorID.cpuHottest) {
                Text("CPU \(model.format(hottest))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }
}

private struct Banners: View {
    @ObservedObject var model: AppModel
    @Local private var installing = false
    @Local private var installError: String?

    var body: some View {
        VStack(spacing: 8) {
            if model.foreignControllerRunning {
                banner("Macs Fan Control is running, so Coolant is only monitoring. Quit it to take over the fans.", symbol: "pause.circle.fill", .orange)
            }
            if case .failed(let reason) = model.helperState {
                banner("Fan control failed: \(reason)", symbol: "exclamationmark.triangle.fill", .red)
            }
            if model.helperState == .missing {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill").foregroundStyle(brandTint)
                    Text(installError ?? "Fan control needs the helper. Monitoring works without it.")
                    Spacer()
                    Button(installing ? "Installing..." : "Install helper") { install() }
                        .glassButton()
                        .disabled(installing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassCard(cornerRadius: 14)
            }
            if let rule = model.triggeringRule {
                banner("Trigger active: \(rule.name)", symbol: "thermometer.high", .orange)
            }
            if model.failsafeEngaged {
                banner("Failsafe engaged: fans held at maximum.", symbol: "exclamationmark.triangle.fill", .red)
            }
        }
    }

    private func banner(_ text: String, symbol: String, _ color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassCard(cornerRadius: 14)
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

private struct FansPage: View {
    @ObservedObject var model: AppModel
    @Local private var editingFan: Fan?
    @Local private var naming: PresetNaming?

    enum PresetNaming: Identifiable {
        case new, rename(Preset)
        var id: String { if case .rename(let p) = self { return p.id }; return "new" }
    }

    var body: some View {
        VStack(spacing: 12) {
            presetBar
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    ForEach(model.fans) { fan in FanCard(model: model, fan: fan) { editingFan = fan } }
                    Spacer(minLength: 0)
                }
                .frame(minWidth: 320, maxWidth: .infinity)
                SensorList(model: model).frame(minWidth: 280, maxWidth: .infinity)
            }
        }
        .sheet(item: $editingFan) { fan in FanEditor(model: model, fan: fan) }
        .onAppear { if CommandLine.arguments.contains("--edit-fan") { editingFan = model.fans.first } }
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
        HStack(spacing: 10) {
            Text("Preset").foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { model.config.activePresetID ?? "custom" }, set: { model.applyPreset($0) })) {
                ForEach(model.allPresets) { Text($0.name).tag($0.id) }
                if model.config.activePresetID == nil { Text("Custom*").tag("custom") }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 190)
            Spacer()
            if let preset = selectedCustomPreset {
                Button("Rename") { naming = .rename(preset) }.glassButton()
                Button("Delete", role: .destructive) { model.deletePreset(preset.id) }.glassButton()
            }
            Button("Save as...") { naming = .new }.glassButton()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassCard(cornerRadius: 16)
    }
}

private struct FanCard: View {
    @ObservedObject var model: AppModel
    let fan: Fan
    let onCustom: () -> Void

    private var share: Double {
        guard fan.maximum > fan.minimum else { return 0 }
        return min(max((fan.current - fan.minimum) / (fan.maximum - fan.minimum), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(fan.name).font(.headline)
                Spacer()
                Text(model.describe(model.effectiveControl(for: fan.id)))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(Int(fan.current)))
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("rpm").foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(brandTint).frame(width: max(proxy.size.width * share, 6))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.6), value: share)
            HStack {
                Text("\(Int(fan.minimum)) to \(Int(fan.maximum))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button("Auto") { model.setControl(.auto, fan: fan.id) }
                    .glassButton()
                    .disabled(model.selectedControl(for: fan.id) == .auto)
                Button("Custom...", action: onCustom).glassButton()
            }
        }
        .padding(16)
        .glassCard()
    }
}

private struct SensorList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(SensorGroup.allCases) { group in
                    let items = model.sensors.filter { $0.group == group }
                    if !items.isEmpty {
                        Text(group.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.top, group == .summary ? 0 : 12)
                        ForEach(items) { sensor in
                            HStack {
                                Text(sensor.name).lineLimit(1)
                                Spacer()
                                Text(model.format(sensor.value)).monospacedDigit()
                                    .foregroundStyle(sensor.value >= 80 ? Color.orange : Color.secondary)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
        .glassCard()
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

private struct TriggersPage: View {
    @ObservedObject var model: AppModel
    @Local private var editing: Rule?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("When several triggers are active, the highest one in this list wins.").foregroundStyle(.secondary)
                Spacer()
                Button("Add trigger") {
                    editing = Rule(name: "New trigger", sensorID: SensorID.cpuHottest, threshold: 85, presetID: model.config.presets.first?.id)
                }
                .glassButton()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassCard(cornerRadius: 16)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(model.config.rules.enumerated()), id: \.element.id) { index, rule in row(rule, index: index) }
                }
            }
            .scrollIndicators(.never)
        }
        .sheet(item: $editing) { rule in RuleEditor(model: model, rule: rule) }
    }

    private func row(_ rule: Rule, index: Int) -> some View {
        HStack(spacing: 12) {
            Toggle("", isOn: enabledBinding(rule)).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(brandTint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(rule.name).font(.headline)
                    if model.triggeringRule?.id == rule.id { Text("Active").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                }
                Text(summary(rule)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                .glassButton().disabled(index == 0).accessibilityLabel("Move up")
            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                .glassButton().disabled(index == model.config.rules.count - 1).accessibilityLabel("Move down")
            Button("Edit") { editing = rule }.glassButton()
            Button("Delete", role: .destructive) { model.config.rules.removeAll { $0.id == rule.id } }.glassButton()
        }
        .padding(14)
        .glassCard(cornerRadius: 16)
    }

    private func move(_ index: Int, by offset: Int) {
        model.config.rules.swapAt(index, index + offset)
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

private struct SettingsPage: View {
    @ObservedObject var model: AppModel
    @Local private var message: String?
    @Local private var removing = false

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                GlassSection(title: "General", symbol: "slider.horizontal.3") {
                    toggle("Launch at login", launchBinding)
                    toggle("Show icon in Dock", $model.config.showDockIcon)
                    toggle("Use Fahrenheit", $model.config.fahrenheit)
                    toggle("Show tenths of a degree", $model.config.preciseTemperature)
                }
                GlassSection(title: "Menu bar", symbol: "menubar.rectangle") {
                    SettingRow(title: "Sensor") {
                        Picker("", selection: $model.config.menuBar.sensorID) {
                            Text("None").tag(String?.none)
                            ForEach(model.sensors.filter { $0.group == .summary }) { Text($0.name).tag(String?.some($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    SettingRow(title: "Fan") {
                        Picker("", selection: $model.config.menuBar.fan) {
                            Text("None").tag(Int?.none)
                            ForEach(model.fans) { Text($0.name).tag(Int?.some($0.id)) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    toggle("Show icon", $model.config.menuBar.showIcon)
                    toggle("Stack readings on two lines", $model.config.menuBar.twoLines)
                }
                GlassSection(title: "Notch notifications", symbol: "bell.fill") {
                    toggle("When the preset changes", $model.config.notifyPresetChanges)
                    toggle("Warnings and failsafe", $model.config.notifyWarnings)
                    SettingRow(title: "Preview") {
                        Button("Show test") {
                            model.notch.show(NotchMessage(title: "Test notification", detail: "This is how triggers appear", symbol: "fanblades.fill", tint: .blue))
                        }
                        .glassButton()
                    }
                }
                GlassSection(title: "Safety", symbol: "shield.lefthalf.filled") {
                    SettingRow(title: "Failsafe temperature", detail: "Holds fans at maximum while Coolant controls them") {
                        Text(model.format(model.config.failsafeTemperature)).monospacedDigit().font(.headline)
                    }
                    Slider(value: $model.config.failsafeTemperature, in: 85...110, step: 1).tint(brandTint)
                }
                GlassSection(title: "Helper", symbol: "lock.shield.fill") {
                    SettingRow(title: helperTitle, detail: helperDetail) {
                        Button(removing ? "Removing..." : "Remove") { remove() }
                            .glassButton()
                            .disabled(removing || model.helperState == .missing)
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        SettingRow(title: title) {
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(brandTint)
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { model.config.launchAtLogin }, set: {
            model.config.launchAtLogin = $0
            LaunchAtLogin.set($0)
        })
    }

    private var helperTitle: String {
        switch model.helperState {
        case .missing: return "Not installed"
        case .ready: return "Installed"
        case .failed: return "Error"
        }
    }

    private var helperDetail: String? {
        switch model.helperState {
        case .missing: return nil
        case .ready: return "Fans return to automatic if Coolant quits or stops responding"
        case .failed(let reason): return reason
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
