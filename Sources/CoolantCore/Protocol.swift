import Foundation

public enum HelperPaths {
    public static let label = "com.arterialist.coolantd"
    public static let socket = "/var/run/\(label).sock"
    public static let marker = "/var/run/\(label).active"
}

/// One JSON object per line over the helper's Unix socket.
public struct HelperRequest: Codable, Equatable {
    public enum Command: String, Codable { case ping, set, auto, resetAll }
    public var cmd: Command
    public var fan: Int?
    public var rpm: Double?

    public init(cmd: Command, fan: Int? = nil, rpm: Double? = nil) {
        self.cmd = cmd
        self.fan = fan
        self.rpm = rpm
    }
}

public struct HelperReply: Codable, Equatable {
    public var ok: Bool
    public var error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

public final class HelperClient {
    private var fd: Int32 = -1

    public init() {}
    deinit { close() }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: HelperPaths.socket) }
    public var isConnected: Bool { fd >= 0 }

    public func connect() -> Bool {
        if fd >= 0 { return true }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 104) { strncpy($0, HelperPaths.socket, 103) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard ok == 0 else { Darwin.close(s); return false }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        return true
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    /// Returns nil and drops the connection if the helper did not answer.
    @discardableResult
    public func send(_ request: HelperRequest) -> HelperReply? {
        guard connect(), var data = try? JSONEncoder().encode(request) else { return nil }
        data.append(0x0a)
        let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { close(); return nil }
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while !line.contains(0x0a) {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { close(); return nil }
            line.append(buffer, count: n)
        }
        return try? JSONDecoder().decode(HelperReply.self, from: line.prefix { $0 != 0x0a })
    }
}
