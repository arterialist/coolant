import AppKit
import CoolantCore

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let openWindow: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.imagePosition = .imageOnly
        refresh()
    }

    func refresh() {
        let options = model.config.menuBar
        var parts: [String] = []
        if let value = model.sensorValue(options.sensorID) { parts.append(model.format(value)) }
        if let index = options.fan, let fan = model.fans.first(where: { $0.id == index }) {
            parts.append("\(Int(fan.current.rounded()))")
        }
        item.button?.image = Self.render(parts: parts, showIcon: options.showIcon || parts.isEmpty, twoLines: options.twoLines)
    }

    private static func render(parts: [String], showIcon: Bool, twoLines: Bool) -> NSImage {
        let stacked = twoLines && parts.count == 2
        let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9.5 : 12.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let lines = stacked ? parts : (parts.isEmpty ? [] : [parts.joined(separator: " ")])
        let textWidth = ceil(lines.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0)
        let iconSide: CGFloat = showIcon ? 16 : 0
        let gap: CGFloat = showIcon && !lines.isEmpty ? 4 : 0
        let size = NSSize(width: iconSide + gap + textWidth, height: 22)

        let image = NSImage(size: size, flipped: false) { _ in
            if showIcon, let symbol = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: "Coolant") {
                symbol.draw(in: NSRect(x: 0, y: 3, width: iconSide, height: iconSide))
            }
            let lineHeight: CGFloat = stacked ? 11 : 16
            var y = (22 - lineHeight * CGFloat(lines.count)) / 2 + lineHeight * CGFloat(lines.count - 1)
            for line in lines {
                (line as NSString).draw(at: NSPoint(x: iconSide + gap, y: y), withAttributes: attributes)
                y -= lineHeight
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        for id in [SensorID.cpuAverage, SensorID.gpuAverage, SensorID.battery] {
            if let value = model.sensorValue(id) { addInfo("\(model.sensorName(id))  \(model.format(value))") }
        }
        menu.addItem(.separator())
        addHeader("Fans")
        for fan in model.fans {
            addInfo("\(fan.name)  \(Int(fan.current)) rpm  (\(model.describe(model.effectiveControl(for: fan.id))))")
        }
        if let rule = model.triggeringRule { addInfo("Trigger active: \(rule.name)") }
        if model.failsafeEngaged { addInfo("Failsafe: fans at maximum") }
        if model.foreignControllerRunning { addInfo("Paused: Macs Fan Control is running") }

        menu.addItem(.separator())
        addHeader("Presets")
        for preset in model.allPresets {
            let entry = NSMenuItem(title: preset.name, action: #selector(choosePreset(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preset.id
            entry.state = model.config.activePresetID == preset.id ? .on : .off
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Coolant", action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Quit Coolant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addInfo(_ title: String) {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        menu.addItem(entry)
    }

    private func addHeader(_ title: String) {
        menu.addItem(NSMenuItem.sectionHeader(title: title))
    }

    @objc private func choosePreset(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { model.applyPreset(id) }
    }

    @objc private func openMain() { openWindow() }
}
