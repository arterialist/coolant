// Root helper. Exposes exactly one capability: set a fan to a speed inside the SMC's
// own min/max range, or give it back to macOS. Every fan returns to automatic when the
// client disconnects, stops pinging, or this process is told to exit.
import CoolantCore
import Darwin
import Foundation

let deadManSeconds = 8.0

func log(_ text: String) { fputs("coolantd: \(text)\n", stderr) }

var stopRequested: sig_atomic_t = 0

final class FanWriter {
    let smc: SMC
    var manual = Set<Int>()
    var testMode = false

    init(smc: SMC) { self.smc = smc }

    var fanCount: Int { Int(smc.uint8("FNum") ?? 0) }

    func set(fan: Int, rpm: Double) -> String? {
        guard fan >= 0, fan < fanCount else { return "no such fan" }
        guard rpm.isFinite else { return "bad rpm" }
        guard let low = smc.float("F\(fan)Mn"), let high = smc.float("F\(fan)Mx"), low < high else {
            return "fan limits unavailable"
        }
        if manual.isEmpty { FileManager.default.createFile(atPath: HelperPaths.marker, contents: nil) }
        manual.insert(fan)
        if !testMode || smc.uint8("Ftst") != 1 {
            let r = smc.write("Ftst", [1])
            if r != 0 { return "Ftst write failed (\(r))" }
            testMode = true
        }
        if smc.uint8("F\(fan)Md") != 1 {
            let r = smc.write("F\(fan)Md", [1])
            if r != 0 { return "mode write failed (\(r))" }
        }
        let r = smc.write("F\(fan)Tg", float: min(max(rpm, low), high))
        return r == 0 ? nil : "target write failed (\(r))"
    }

    func auto(fan: Int) -> String? {
        guard fan >= 0, fan < fanCount else { return "no such fan" }
        let r = smc.write("F\(fan)Md", [0])
        manual.remove(fan)
        if manual.isEmpty { releaseTestMode() }
        return r == 0 ? nil : "mode write failed (\(r))"
    }

    func resetAll() {
        for fan in manual { smc.write("F\(fan)Md", [0]) }
        manual.removeAll()
        releaseTestMode()
    }

    /// Clears fans a previous instance left in manual mode. Only runs if that instance
    /// left its marker, so a clean start never touches another app's fan control.
    func recoverIfNeeded() {
        guard FileManager.default.fileExists(atPath: HelperPaths.marker) else { return }
        log("recovering fans from an unclean exit")
        for fan in 0..<fanCount { smc.write("F\(fan)Md", [0]) }
        releaseTestMode()
    }

    private func releaseTestMode() {
        smc.write("Ftst", [0])
        testMode = false
        unlink(HelperPaths.marker)
    }
}

func parseUID() -> uid_t? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--uid"), i + 1 < args.count else { return nil }
    return uid_t(args[i + 1])
}

guard getuid() == 0 else { log("must run as root"); exit(1) }
guard let allowedUID = parseUID() else { log("usage: coolantd --uid <uid>"); exit(2) }
guard let smc = SMC() else { log("cannot open AppleSMC"); exit(3) }
let writer = FanWriter(smc: smc)
writer.recoverIfNeeded()

var action = sigaction()
action.__sigaction_u.__sa_handler = { _ in stopRequested = 1 }
sigaction(SIGTERM, &action, nil)
sigaction(SIGINT, &action, nil)
signal(SIGPIPE, SIG_IGN)

unlink(HelperPaths.socket)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
_ = withUnsafeMutablePointer(to: &address.sun_path) {
    $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, HelperPaths.socket, 103) }
}
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bound == 0, chown(HelperPaths.socket, allowedUID, 0) == 0, chmod(HelperPaths.socket, 0o600) == 0,
      listen(listener, 4) == 0 else {
    log("cannot create socket: \(String(cString: strerror(errno)))")
    exit(4)
}

var client: Int32 = -1
var lastSeen = Date()
var pending = Data()

func dropClient(_ reason: String) {
    guard client >= 0 else { return }
    log("client gone (\(reason)), returning fans to automatic")
    close(client)
    client = -1
    pending.removeAll()
    writer.resetAll()
}

func handle(_ line: Data) -> HelperReply {
    guard let request = try? JSONDecoder().decode(HelperRequest.self, from: line) else {
        return HelperReply(ok: false, error: "bad request")
    }
    var failure: String?
    switch request.cmd {
    case .ping: break
    case .resetAll: writer.resetAll()
    case .auto: failure = writer.auto(fan: request.fan ?? -1)
    case .set: failure = writer.set(fan: request.fan ?? -1, rpm: request.rpm ?? .nan)
    }
    return HelperReply(ok: failure == nil, error: failure)
}

while stopRequested == 0 {
    var fds = [pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
    if client >= 0 { fds.append(pollfd(fd: client, events: Int16(POLLIN), revents: 0)) }
    let ready = poll(&fds, nfds_t(fds.count), 1000)
    if ready < 0 { continue }

    if fds[0].revents & Int16(POLLIN) != 0 {
        let incoming = accept(listener, nil, nil)
        if incoming >= 0 {
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(incoming, &uid, &gid) == 0, uid == allowedUID || uid == 0 {
                dropClient("replaced by a new client")
                client = incoming
                lastSeen = Date()
            } else {
                log("rejected connection from uid \(uid)")
                close(incoming)
            }
        }
    }

    if client >= 0, fds.count > 1, fds[1].revents != 0 {
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = recv(client, &buffer, buffer.count, 0)
        if n <= 0 {
            dropClient("disconnected")
        } else {
            lastSeen = Date()
            pending.append(buffer, count: n)
            if pending.count > 8192 { dropClient("oversized request") }
            while let end = pending.firstIndex(of: 0x0a) {
                let line = Data(pending[pending.startIndex..<end])
                pending = Data(pending[(end + 1)...])
                var reply = (try? JSONEncoder().encode(handle(line))) ?? Data()
                reply.append(0x0a)
                _ = reply.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
            }
        }
    }

    if client >= 0, Date().timeIntervalSince(lastSeen) > deadManSeconds { dropClient("no heartbeat") }
}

log("stopping, returning fans to automatic")
writer.resetAll()
if client >= 0 { close(client) }
close(listener)
unlink(HelperPaths.socket)
