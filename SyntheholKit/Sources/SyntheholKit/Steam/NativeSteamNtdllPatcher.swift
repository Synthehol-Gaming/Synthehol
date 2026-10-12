import CryptoKit
import Foundation

/// Verified ntdll detours for the Wine build shipped by Synthehol's GPTK runtime.
/// The detour makes Wine load lsteamclient early enough to bridge Steam's IPC.
enum NativeSteamNtdllPatcher {
    struct Patch {
        let arch: String
        let cleanHash: String
        let patchedHash: String
        let payloadName: String
        let payloadHash: String
        let caveRVA: Int
        let caveSize: Int
        let hookRVA: Int
        let stolen: [UInt8]
        let machine: UInt16
        let magic: UInt16
        let imageBase: UInt64
        let appendSection: Bool
    }

    static let supportedVersion = "4.5.105-beta.1"
    static let patches = [
        Patch(
            arch: "x86_64-windows",
            cleanHash: "2fe98d74ad47cac232d9f131b16020188f61513c7ed6bb76ce470541bc4c04f8",
            patchedHash: "0d360906b445a27cbdff3d8d92d4d8223a988cf394310ed8df6c1f07e9e9947e",
            payloadName: "detour2-synthehol.bin",
            payloadHash: "8515f275c9a2a52534fd439bd1866b2aac6acc3f111658f1287df55d9bda6bd7",
            caveRVA: 0x9ea00, caveSize: 1536, hookRVA: 0x667c6,
            stolen: [0x48, 0x83, 0xbc, 0x24, 0xf0, 0, 0, 0, 0],
            machine: 0x8664, magic: 0x20b, imageBase: 0x1_7000_0000,
            appendSection: false
        ),
        Patch(
            arch: "i386-windows",
            cleanHash: "839721c3a3e2129075c4ae3af55b9a356eb8563976c672bceb39cf67c8030171",
            patchedHash: "7d0d004d7a968a1dac054fbe3af19cdde00c7b5e65016a67e966e1cfea6e8ff5",
            payloadName: "detour32-synthehol.bin",
            payloadHash: "048bcc6cfbf2b57dd7e0225669d560fe5a7235a228f3fe75dd62eaae32594f9a",
            caveRVA: 0xd5000, caveSize: 0x1000, hookRVA: 0x63ad0,
            stolen: [0xf6, 0x45, 0xb4, 0x02, 0x75, 0x29],
            machine: 0x014c, magic: 0x10b, imageBase: 0x7bc0_0000,
            appendSection: true
        ),
    ]

    static func install(
        runtime: WineRuntime, clone: URL, bridge: URL, payloadRoot: URL
    ) throws {
        guard runtime.version == supportedVersion else {
            throw NativeSteamInstallError.unsupportedRuntime(runtime.version)
        }
        for patch in patches {
            let source = runtime.librariesDirectory.appending(path: "Wine/lib/wine/\(patch.arch)/ntdll.dll")
            let live = clone.appending(path: "lib/wine/\(patch.arch)/ntdll.dll")
            let staged = bridge.appending(path: "wine/\(runtime.version)/\(patch.arch)/ntdll.dll")
            let payload = payloadRoot.appending(path: patch.payloadName)
            guard hash(source) == patch.cleanHash else {
                throw NativeSteamInstallError.runtimeComponentMismatch("\(patch.arch)/ntdll.dll")
            }
            guard hash(payload) == patch.payloadHash else {
                throw NativeSteamInstallError.payloadVerificationFailed(patch.payloadName)
            }
            let output = try apply(patch, to: Data(contentsOf: source), payload: Data(contentsOf: payload))
            guard hash(output) == patch.patchedHash else {
                throw NativeSteamInstallError.payloadVerificationFailed("patched \(patch.arch)/ntdll.dll")
            }
            try write(output, to: live)
            try write(output, to: staged)
        }
    }

    private static func apply(_ patch: Patch, to image: Data, payload: Data) throws -> Data {
        var bytes = [UInt8](image)
        let pe = Int(try u32(bytes, 0x3c))
        guard try u32(bytes, pe) == 0x4550,
              try u16(bytes, pe + 4) == patch.machine,
              try u16(bytes, pe + 24) == patch.magic else {
            throw NativeSteamInstallError.runtimeComponentMismatch("\(patch.arch)/ntdll.dll headers")
        }
        let base = patch.magic == 0x20b
            ? try u64(bytes, pe + 48) : UInt64(try u32(bytes, pe + 52))
        guard base == patch.imageBase else {
            throw NativeSteamInstallError.runtimeComponentMismatch("\(patch.arch)/ntdll.dll image base")
        }
        if patch.appendSection { try addSection(patch, bytes: &bytes, pe: pe) }
        let cave = try fileOffset(patch.caveRVA, bytes)
        let hook = try fileOffset(patch.hookRVA, bytes)
        guard cave + patch.caveSize <= bytes.count,
              bytes[cave ..< cave + patch.caveSize].allSatisfy({ $0 == 0 }),
              hook + patch.stolen.count <= bytes.count,
              Array(bytes[hook ..< hook + patch.stolen.count]) == patch.stolen,
              payload.count <= patch.caveSize else {
            throw NativeSteamInstallError.runtimeComponentMismatch("\(patch.arch)/ntdll.dll patch sites")
        }
        bytes.replaceSubrange(cave ..< cave + payload.count, with: payload)
        let delta = patch.caveRVA - (patch.hookRVA + 5)
        guard let displacement = Int32(exactly: delta) else {
            throw NativeSteamInstallError.runtimeComponentMismatch("\(patch.arch)/ntdll.dll detour")
        }
        var jump = [UInt8(0xe9)]
        withUnsafeBytes(of: displacement.littleEndian) { jump.append(contentsOf: $0) }
        jump.append(contentsOf: repeatElement(0xcc, count: patch.stolen.count - 5))
        bytes.replaceSubrange(hook ..< hook + jump.count, with: jump)
        return Data(bytes)
    }

    private static func addSection(_ patch: Patch, bytes: inout [UInt8], pe: Int) throws {
        let count = Int(try u16(bytes, pe + 6))
        let optional = pe + 24
        let table = optional + Int(try u16(bytes, pe + 20))
        let header = table + count * 40
        let alignment = Int(try u32(bytes, optional + 36))
        let imageSize = Int(try u32(bytes, optional + 56))
        let headersSize = Int(try u32(bytes, optional + 60))
        guard imageSize == patch.caveRVA, alignment > 0,
              header + 40 <= headersSize,
              bytes[header ..< header + 40].allSatisfy({ $0 == 0 }) else {
            throw NativeSteamInstallError.runtimeComponentMismatch("\(patch.arch)/ntdll.dll section table")
        }
        let raw = (bytes.count + alignment - 1) & ~(alignment - 1)
        var entry = Array(".npdet".utf8) + [UInt8(0), 0]
        for field: UInt32 in [0x1000, UInt32(patch.caveRVA), 0x1000, UInt32(raw), 0, 0, 0, 0x6000_0020] {
            withUnsafeBytes(of: field.littleEndian) { entry.append(contentsOf: $0) }
        }
        bytes.replaceSubrange(header ..< header + 40, with: entry)
        put16(UInt16(count + 1), pe + 6, &bytes)
        put32(UInt32(imageSize + 0x1000), optional + 56, &bytes)
        bytes.append(contentsOf: repeatElement(0, count: raw + 0x1000 - bytes.count))
    }

    private static func fileOffset(_ rva: Int, _ bytes: [UInt8]) throws -> Int {
        let pe = Int(try u32(bytes, 0x3c))
        let count = Int(try u16(bytes, pe + 6))
        let table = pe + 24 + Int(try u16(bytes, pe + 20))
        for index in 0 ..< count {
            let item = table + index * 40
            let virtualSize = Int(try u32(bytes, item + 8))
            let virtualAddress = Int(try u32(bytes, item + 12))
            let rawSize = Int(try u32(bytes, item + 16))
            let rawOffset = Int(try u32(bytes, item + 20))
            if rawSize > 0, rawOffset > 0,
               rva >= virtualAddress, rva < virtualAddress + max(virtualSize, rawSize) {
                return rawOffset + rva - virtualAddress
            }
        }
        throw NativeSteamInstallError.runtimeComponentMismatch("ntdll.dll RVA")
    }

    private static func u16(_ b: [UInt8], _ o: Int) throws -> UInt16 {
        guard o >= 0, o + 2 <= b.count else { throw NativeSteamInstallError.runtimeComponentMismatch("ntdll.dll") }
        return UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }
    private static func u32(_ b: [UInt8], _ o: Int) throws -> UInt32 {
        guard o >= 0, o + 4 <= b.count else { throw NativeSteamInstallError.runtimeComponentMismatch("ntdll.dll") }
        return (0..<4).reversed().reduce(0) { $0 << 8 | UInt32(b[o + $1]) }
    }
    private static func u64(_ b: [UInt8], _ o: Int) throws -> UInt64 {
        guard o >= 0, o + 8 <= b.count else { throw NativeSteamInstallError.runtimeComponentMismatch("ntdll.dll") }
        return (0..<8).reversed().reduce(0) { $0 << 8 | UInt64(b[o + $1]) }
    }
    private static func put16(_ v: UInt16, _ o: Int, _ b: inout [UInt8]) {
        b[o] = UInt8(v & 0xff); b[o + 1] = UInt8(v >> 8)
    }
    private static func put32(_ v: UInt32, _ o: Int, _ b: inout [UInt8]) {
        for i in 0..<4 { b[o + i] = UInt8((v >> UInt32(i * 8)) & 0xff) }
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func hash(_ url: URL) -> String? {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).map(hash)
    }
    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
