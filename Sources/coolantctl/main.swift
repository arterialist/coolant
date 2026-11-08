// Command-line access for diagnostics. `status` needs no helper.
import CoolantCore
import Foundation

func fail(_ text: String) -> Never { fputs("\(text)\n", stderr); exit(1) }
guard let smc = SMC() else { fail("cannot open AppleSMC") }

func status() {
    for f in readFans(smc) {
        print("\(f.name): \(Int(f.current)) rpm  range \(Int(f.minimum))-\(Int(f.maximum))  target \(Int(f.target))  \(f.isManual ? "manual" : "auto")")
    }
    print("Ftst=\(smc.uint8("Ftst").map(String.init) ?? "?")")
    for s in SensorReader(smc: smc).read() where s.group == .summary {
        print("\(s.name): \(String(format: "%.1f", s.value)) C")
    }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "status", nil:
    status()
case "hold":
    // hold <fan> <rpm> <seconds>: stays connected, then disconnects so the helper reverts.
    guard args.count == 4, let fan = Int(args[1]), let rpm = Double(args[2]), let seconds = Int(args[3]) else {
        fail("usage: coolantctl hold <fan> <rpm> <seconds>")
    }
    let helper = HelperClient()
    guard helper.connect() else { fail("helper is not running") }
    for tick in 0..<seconds {
        let reply = helper.send(HelperRequest(cmd: .set, fan: fan, rpm: rpm))
        if reply?.ok != true { print("helper:", reply?.error ?? "no reply") }
        if tick % 3 == 0, let f = readFans(smc).first(where: { $0.id == fan }) {
            print("t=\(tick)s actual \(Int(f.current)) target \(Int(f.target)) manual \(f.isManual)")
        }
        Thread.sleep(forTimeInterval: 1)
    }
    helper.close()
    Thread.sleep(forTimeInterval: 1.5)
    status()
default:
    fail("usage: coolantctl [status | hold <fan> <rpm> <seconds>]")
}
