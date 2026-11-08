import CSMC
import Foundation

/// Thin wrapper over the AppleSMC user client. Reads work unprivileged, writes need root.
public final class SMC {
    private let conn: io_connect_t
    private var sizes: [UInt32: UInt32] = [:]

    public init?() {
        conn = csmc_open()
        if conn == 0 { return nil }
    }

    deinit { csmc_close(conn) }

    public static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func name(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .isoLatin1) ?? "????"
    }

    public func type(of key: String) -> String? {
        var size: UInt32 = 0, type: UInt32 = 0, attr: UInt8 = 0
        guard csmc_info(conn, Self.code(key), &size, &type, &attr) == 0 else { return nil }
        return SMC.name(type)
    }

    private func size(of code: UInt32) -> UInt32? {
        if let known = sizes[code] { return known }
        var size: UInt32 = 0, type: UInt32 = 0, attr: UInt8 = 0
        guard csmc_info(conn, code, &size, &type, &attr) == 0 else { return nil }
        sizes[code] = size
        return size
    }

    public func bytes(_ key: String) -> [UInt8]? {
        let code = Self.code(key)
        guard let size = size(of: code), size > 0, size <= 32 else { return nil }
        var out = [UInt8](repeating: 0, count: Int(size))
        guard csmc_read(conn, code, size, &out) == 0 else { return nil }
        return out
    }

    public func float(_ key: String) -> Double? {
        guard let b = bytes(key), b.count == 4 else { return nil }
        return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
    }

    public func uint8(_ key: String) -> UInt8? { bytes(key)?.first }

    /// Returns 0 on success, otherwise the driver or SMC status code.
    @discardableResult
    public func write(_ key: String, _ value: [UInt8]) -> Int32 {
        csmc_write(conn, Self.code(key), UInt32(value.count), value)
    }

    @discardableResult
    public func write(_ key: String, float value: Double) -> Int32 {
        write(key, withUnsafeBytes(of: Float(value)) { Array($0) })
    }

    public func allKeys() -> [String] {
        guard let count = bytes("#KEY")?.reduce(UInt32(0), { ($0 << 8) | UInt32($1) }) else { return [] }
        return (0..<count).compactMap { i in
            var key: UInt32 = 0
            return csmc_key_at(conn, i, &key) == 0 ? SMC.name(key) : nil
        }
    }

    public var connection: io_connect_t { conn }
}
