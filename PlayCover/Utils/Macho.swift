//
//  Macho.swift
//  PlayCover
//

import Foundation

class Macho {
    static func stripBinary(_ binary: inout Data) throws {
        var header = binary.extract(fat_header.self)
        var offset = MemoryLayout.size(ofValue: header)
        let shouldSwap = header.magic == FAT_CIGAM

        if header.magic == FAT_MAGIC || header.magic == FAT_CIGAM {
            // Make sure the endianness is correct
            if shouldSwap {
                swap_fat_header(&header, NXHostByteOrder())
            }

            for _ in 0..<header.nfat_arch {
                var arch = binary.extract(fat_arch.self, offset: offset)
                if shouldSwap {
                    swap_fat_arch(&arch, 1, NXHostByteOrder())
                }

                if arch.cputype == CPU_TYPE_ARM64 {
                    print("Found ARM64 arch in fat binary")

                    binary = binary
                        .subdata(in: Int(arch.offset)..<Int(arch.offset+arch.size))

                    return
                }

                offset += Int(MemoryLayout.size(ofValue: arch))
            }

            throw PlayCoverError.failedToStripBinary
        }
    }

    static func convertMacho(_ macho: URL, in app: URL? = nil) throws {
        print("Converting MachO at \(macho.path)")

        var binary = try Data(contentsOf: macho)

        print("Stripping MachO...")
        try stripBinary(&binary)
        if try !isCatalyst(binary) {
            print("Replacing version command...")
            try replaceVersionCommand(&binary)
        }
        _ = try resolveSwiftLibraries(&binary, at: macho, in: app)
        if try stripRestrictSegment(&binary) {
            print("Neutralized __RESTRICT segment in MachO")
        }
        let trapCount = neutralizeAntiTamperTraps(&binary)
        if trapCount > 0 {
            print("Neutralized \(trapCount) anti-tamper self-destruct stub(s) in MachO")
        }

        print("Writing revised MachO...")
        try binary.write(to: macho, options: .atomic)
        try macho.setBinaryPosixPermissions(0o755)
    }

    static let swiftLibrarySchemaVersion = 1

    private static let iOSSupportSwiftDirectory = "/System/iOSSupport/usr/lib/swift"
    private static let macOSSwiftDirectory = "/usr/lib/swift"

    // Keep the Catalyst overlay for framework libraries that were previously
    // explicitly mapped and can also have a macOS overlay of the same name.
    private static let catalystFrameworkOverlays: Set<String> = [
        "libswiftUIKit.dylib", "libswiftARKit.dylib", "libswiftMapKit.dylib",
        "libswiftSceneKit.dylib", "libswiftPhotosUI.dylib", "libswiftCoreNFC.dylib",
        "libswiftPencilKit.dylib", "libswiftWebKit.dylib", "libswiftHomeKit.dylib",
        "libswiftPassKit.dylib"
    ]

    private typealias SharedCacheContainsPath = @convention(c) (UnsafePointer<CChar>) -> Bool

    private static let sharedCacheContainsPath: SharedCacheContainsPath? = {
        guard let handle = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "_dyld_shared_cache_contains_path") else { return nil }
        return unsafeBitCast(symbol, to: SharedCacheContainsPath.self)
    }()

    private static func systemLibraryExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
            || path.withCString { sharedCacheContainsPath?($0) == true }
    }

    private static func bundledLibraryExists(_ filename: String, at macho: URL, in app: URL?) -> Bool {
        let directory = macho.deletingLastPathComponent()
        var candidates = [directory.appendingPathComponent(filename)]
        if let app = app {
            candidates.append(app.appendingPathComponent("Frameworks").appendingPathComponent(filename))
        }
        return candidates.contains {
            $0.standardizedFileURL != macho.standardizedFileURL && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// Carries the same repair forward to already-installed Catalyst images.
    static func repairSwiftLibraries(in macho: URL, app: URL) throws -> Bool {
        var binary = try Data(contentsOf: macho, options: .mappedIfSafe)
        guard try resolveSwiftLibraries(&binary, at: macho, in: app, copyBeforeWriting: true) else { return false }
        let permissions = try FileManager.default.attributesOfItem(atPath: macho.path)[.posixPermissions]
        try binary.write(to: macho, options: .atomic)
        if let permissions = permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: macho.path)
        }
        return true
    }

    private static func resolveSwiftLibraries(
        _ binary: inout Data, at macho: URL, in app: URL?, copyBeforeWriting: Bool = false
    ) throws -> Bool {
        let headerSize = MemoryLayout<mach_header_64>.size
        let commandSize = MemoryLayout<dylib_command>.size
        let rpathPrefix = "@rpath/"
        var changes: [(range: Range<Int>, bytes: Data)] = []
        var malformedCommand = false
        var reversedByteOrder = false
        let oldEnd = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            reversedByteOrder = shouldSwap
            let load = binary.extract(load_command.self, offset: offset, swap: shouldSwap ? swap_load_command : nil)
            guard load.cmd == UInt32(LC_LOAD_DYLIB) || load.cmd == LC_LOAD_WEAK_DYLIB else { return false }
            guard load.cmdsize > commandSize else {
                malformedCommand = true
                return true
            }
            var command = binary.extract(dylib_command.self, offset: offset,
                                         swap: shouldSwap ? swap_dylib_command : nil)
            let nameOffset = Int(command.dylib.name.offset)
            guard nameOffset >= commandSize, nameOffset < Int(load.cmdsize) else {
                malformedCommand = true
                return true
            }
            let end = offset + Int(load.cmdsize)
            let name = binary[(offset + nameOffset)..<end]
            guard let terminator = name.firstIndex(of: 0),
                  let path = String(data: name[..<terminator], encoding: .utf8) else {
                malformedCommand = true
                return true
            }
            guard path.hasPrefix(rpathPrefix) else { return false }
            let filename = String(path.dropFirst(rpathPrefix.count))
            guard filename.hasPrefix("libswift"), filename.hasSuffix(".dylib"), !filename.contains("/"),
                  !bundledLibraryExists(filename, at: macho, in: app) else { return false }
            let replacement = iOSSupportSwiftDirectory + "/" + filename
            guard systemLibraryExists(replacement),
                  catalystFrameworkOverlays.contains(filename)
                    || !systemLibraryExists(macOSSwiftDirectory + "/" + filename) else { return false }

            let nameBytes = Data(replacement.utf8)
            let padding = 8 - (nameBytes.count % 8)
            command.dylib.name = lc_str(offset: UInt32(commandSize))
            command.cmdsize = UInt32(max(Int(load.cmdsize), commandSize + nameBytes.count + padding))
            let zeros = Int(command.cmdsize) - commandSize - nameBytes.count
            if shouldSwap { swap_dylib_command(&command, NX_BigEndian) }
            var bytes = Data(bytes: &command, count: commandSize)
            bytes.append(nameBytes)
            bytes.append(Data(count: zeros))
            changes.append((offset..<end, bytes))
            return false
        }
        guard !malformedCommand else { throw PlayCoverError.appCorrupted }
        guard !changes.isEmpty else { return false }

        // Replace in the original order. Bind opcodes reference dylib load
        // commands by ordinal, including the weak commands.
        var commands = Data()
        var cursor = headerSize
        for change in changes {
            commands.append(binary[cursor..<change.range.lowerBound])
            commands.append(change.bytes)
            cursor = change.range.upperBound
        }
        commands.append(binary[cursor..<oldEnd])
        if copyBeforeWriting {
            // A Data read with .mappedIfSafe can be backed by a read-only mapping.
            binary = binary.withUnsafeBytes { Data($0) }
        }
        try writeLoadCommands(&binary, commands: commands, start: headerSize, oldEnd: oldEnd,
                              shouldSwap: reversedByteOrder)
        return true
    }

    static func replaceVersionCommand(_ binary: inout Data) throws {

        var macCatalystCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                       cmdsize: 24,
                                                       platform: UInt32(PLATFORM_MACCATALYST),
                                                       minos: 0x000b0000,
                                                       sdk: 0x000e0000,
                                                       ntools: 0)

        try replaceLastCommand(&binary, satisfy: {data, shouldSwap in
            let loadCommand = data.extract(load_command.self,
                                           offset: data.startIndex,
                                           swap: shouldSwap ? swap_load_command:nil)
            return [UInt32(LC_VERSION_MIN_IPHONEOS),
                    UInt32(LC_VERSION_MIN_MACOSX),
                    UInt32(LC_BUILD_VERSION)]
                .contains(loadCommand.cmd)

        }, with: {shouldSwap in
            if shouldSwap {
                swap_build_version_command(&macCatalystCommand, NX_BigEndian)
            }
            return Data(bytes: &macCatalystCommand, count: MemoryLayout<build_version_command>.size)
        }, atEnd: true)
    }

    static func replaceLastCommand(_ binary: inout Data,
                                   satisfy isTargetCommand: (Data, Bool) -> Bool,
                                   with getNewCommandData: (Bool) -> Data?,
                                   atEnd shouldAppend: Bool) throws {
        let headerSize = MemoryLayout<mach_header_64>.size
        var header = binary.extract(mach_header_64.self)
        let shouldSwap = header.magic == MH_CIGAM_64
        if shouldSwap { swap_mach_header_64(&header, NXHostByteOrder()) }

        var oldCommandStart = headerSize
        var oldCommandSize: UInt32 = 0

        let movedCommandsEnd = try iterateLoadCommands(binary: binary) { offset, needSwap in
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: needSwap ? swap_load_command:nil)
            if isTargetCommand(binary[offset ..< offset+Int(loadCommand.cmdsize)], needSwap) {
                oldCommandStart = offset
                oldCommandSize = loadCommand.cmdsize
            }
            return false
        }
        guard movedCommandsEnd == headerSize + Int(header.sizeofcmds) else {
            throw PlayCoverError.appCorrupted
        }

        let oldCommandEnd = oldCommandStart + Int(oldCommandSize)
        guard let newCommandData = getNewCommandData(shouldSwap) else { return }

        var resultingCommandsData = binary[oldCommandEnd..<movedCommandsEnd]
        if shouldAppend {
            resultingCommandsData.append(newCommandData)
        } else {
            resultingCommandsData.insert(contentsOf: newCommandData, at: resultingCommandsData.startIndex)
        }
        try writeLoadCommands(&binary, commands: resultingCommandsData, start: oldCommandStart,
                              oldEnd: movedCommandsEnd, shouldSwap: shouldSwap,
                              addsCommand: oldCommandSize == 0)
    }

    private struct InsufficientLoadCommandSpace: LocalizedError {
        var errorDescription: String? { "The Mach-O has insufficient header space for its load commands." }
    }

    private static func writeLoadCommands(
        _ binary: inout Data, commands: Data, start: Int, oldEnd: Int, shouldSwap: Bool, addsCommand: Bool = false
    ) throws {
        let headerSize = MemoryLayout<mach_header_64>.size
        let newEnd = start + commands.count
        if newEnd > oldEnd {
            guard newEnd <= binary.count, newEnd <= (try firstFileDataOffset(in: binary)),
                  binary[oldEnd..<newEnd].allSatisfy({ $0 == 0 }) else {
                throw InsufficientLoadCommandSpace()
            }
        }

        var header = binary.extract(mach_header_64.self, swap: shouldSwap ? swap_mach_header_64 : nil)
        guard oldEnd == headerSize + Int(header.sizeofcmds),
              let commandSize = UInt32(exactly: newEnd - headerSize) else {
            throw PlayCoverError.appCorrupted
        }
        header.sizeofcmds = commandSize
        if addsCommand { header.ncmds += 1 }
        if shouldSwap { swap_mach_header_64(&header, NX_BigEndian) }

        if newEnd < oldEnd {
            binary.replaceSubrange(newEnd..<oldEnd, with: Data(count: oldEnd - newEnd))
        }
        binary.replaceSubrange(start..<newEnd, with: commands)
        binary.replaceSubrange(0..<headerSize, with: Data(bytes: &header, count: headerSize))
    }

    private static func firstFileDataOffset(in binary: Data) throws -> Int {
        let segmentSize = MemoryLayout<segment_command_64>.size
        let sectionSize = MemoryLayout<section_64>.size
        var firstOffset: Int?
        var malformed = false
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let load = binary.extract(load_command.self, offset: offset, swap: shouldSwap ? swap_load_command : nil)
            guard load.cmd == UInt32(LC_SEGMENT_64) else { return false }
            guard Int(load.cmdsize) >= segmentSize else {
                malformed = true
                return true
            }

            let segment = binary.extract(segment_command_64.self, offset: offset,
                                         swap: shouldSwap ? swap_segment_command_64 : nil)
            let sectionCount = Int(segment.nsects)
            guard sectionCount <= (Int(load.cmdsize) - segmentSize) / sectionSize else {
                malformed = true
                return true
            }
            if segment.fileoff > 0, segment.filesize > 0, let fileOffset = Int(exactly: segment.fileoff) {
                firstOffset = min(firstOffset ?? fileOffset, fileOffset)
            }
            for index in 0..<sectionCount {
                let sectionStart = offset + segmentSize + index * sectionSize
                let section = binary.extract(section_64.self, offset: sectionStart,
                                             swap: shouldSwap ? { swap_section_64($0, 1, $1) } : nil)
                let sectionOffset = Int(section.offset)
                if sectionOffset > 0, section.size > 0 {
                    firstOffset = min(firstOffset ?? sectionOffset, sectionOffset)
                }
            }
            return false
        }
        guard !malformed else { throw PlayCoverError.appCorrupted }
        guard let firstOffset = firstOffset, firstOffset <= binary.count else {
            throw InsufficientLoadCommandSpace()
        }
        return firstOffset
    }

    static func iterateLoadCommands(binary: Data, _ evaluate: (Int, Bool) -> Bool) throws -> Int {
        let headerSize = MemoryLayout<mach_header_64>.size
        guard binary.count >= headerSize else { throw PlayCoverError.appCorrupted }
        var header = binary.extract(mach_header_64.self)
        var offset = headerSize
        let shouldSwap = header.magic == MH_CIGAM_64
        guard header.magic == MH_MAGIC_64 || shouldSwap else { throw PlayCoverError.appCorrupted }
        if shouldSwap {
            swap_mach_header_64(&header, NXHostByteOrder())
            print("Slim Mach-O has reversed byte order")
        }

        let allCommandsEnd = headerSize + Int(header.sizeofcmds)
        if allCommandsEnd >= binary.count || allCommandsEnd <= headerSize {
            print("Cannot iterate load commands: Mach-O file is corrupted(-1)")
            throw PlayCoverError.appCorrupted
        }
        for index in 0..<header.ncmds {
            let loadCommandSize = MemoryLayout<load_command>.size
            guard offset + loadCommandSize <= allCommandsEnd else { throw PlayCoverError.appCorrupted }
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_load_command:nil)
            let commandEnd = offset + Int(loadCommand.cmdsize)
            if commandEnd > allCommandsEnd || loadCommand.cmdsize < loadCommandSize {
                print("Cannot iterate load commands: Mach-O file is corrupted(\(index))")
                throw PlayCoverError.appCorrupted
            }
            let terminated = evaluate(offset, shouldSwap)
            offset = commandEnd
            if terminated { return offset }
        }
        guard offset == allCommandsEnd else { throw PlayCoverError.appCorrupted }
        return offset
    }

    static func isMachoEncrypted(atURL url: URL) throws -> Bool {
        var binary = try Data(contentsOf: url)
        try stripBinary(&binary)
        var result = false
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = binary.extract(load_command.self,
                                             offset: offset,
                                             swap: shouldSwap ? swap_load_command:nil)
            if loadCommand.cmd == UInt32(LC_ENCRYPTION_INFO_64) {
                let infoCommand = binary.extract(encryption_info_command_64.self,
                                                 offset: offset,
                                                 swap: shouldSwap ? swap_encryption_command_64:nil)
                result = infoCommand.cryptid != 0
                return true
            }
            return false
        }
        return result
    }

    static func isMachoValidArch(_ url: URL) throws -> Bool {
        let binary = try Data(contentsOf: url, options: .mappedIfSafe)
        guard binary.count >= MemoryLayout<mach_header_64>.size else { return false }
        var header = binary.extract(mach_header_64.self)
        let shouldSwap = header.magic == MH_CIGAM_64
        guard header.magic == MH_MAGIC_64 || shouldSwap else { return false }
        if shouldSwap { swap_mach_header_64(&header, NXHostByteOrder()) }
        return try header.cputype == CPU_TYPE_ARM64 && isCatalyst(binary)
    }

    private static func isCatalyst(_ binary: Data) throws -> Bool {
        var result = false
        var malformed = false
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let loadCommand = binary.extract(load_command.self, offset: offset,
                                             swap: shouldSwap ? swap_load_command : nil)
            guard loadCommand.cmd == UInt32(LC_BUILD_VERSION) else { return false }
            guard loadCommand.cmdsize >= MemoryLayout<build_version_command>.size else {
                malformed = true
                return true
            }
            let versionCommand = binary.extract(build_version_command.self, offset: offset,
                                                swap: shouldSwap ? swap_build_version_command : nil)
            result = versionCommand.platform == PLATFORM_MACCATALYST
            return true
        }
        guard !malformed else { throw PlayCoverError.appCorrupted }
        return result
    }
}

extension Macho {
    private static let restrictSegBytes = paddedMachOName("__RESTRICT")
    private static let restrictSectBytes = paddedMachOName("__restrict")
    private static let replacementSegBytes = paddedMachOName("__PLAYCVR")
    private static let replacementSectBytes = paddedMachOName("__playcvr")

    @discardableResult
    static func stripRestrictSegment(atURL macho: URL) throws -> Bool {
        var binary = try Data(contentsOf: macho)
        let modified = try stripRestrictSegment(&binary)
        if modified {
            try binary.write(to: macho)
        }
        return modified
    }

    /// Renames any `__RESTRICT` / `__restrict` segment and section names in-place so macOS
    /// dyld permits `@rpath` expansion and `DYLD_INSERT_LIBRARIES` on ad-hoc signed apps.
    @discardableResult
    static func stripRestrictSegment(_ binary: inout Data) throws -> Bool {
        guard binary.count >= MemoryLayout<UInt32>.size else { return false }

        let magic = binary.extract(UInt32.self)
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            return try stripRestrictSegmentInFat(&binary)
        }
        return try stripRestrictSegmentInSlice(&binary, sliceStart: 0, sliceEnd: binary.count)
    }

    private static func stripRestrictSegmentInFat(_ binary: inout Data) throws -> Bool {
        var header = binary.extract(fat_header.self)
        let shouldSwap = header.magic == FAT_CIGAM
        if shouldSwap { swap_fat_header(&header, NXHostByteOrder()) }

        var offset = MemoryLayout.size(ofValue: header)
        var modified = false
        for _ in 0..<header.nfat_arch {
            guard offset + MemoryLayout<fat_arch>.size <= binary.count else { break }
            var arch = binary.extract(fat_arch.self, offset: offset)
            if shouldSwap { swap_fat_arch(&arch, 1, NXHostByteOrder()) }
            let sliceStart = Int(arch.offset)
            let sliceEnd = sliceStart + Int(arch.size)
            if sliceStart >= 0 && sliceEnd <= binary.count && sliceStart < sliceEnd,
               try stripRestrictSegmentInSlice(&binary, sliceStart: sliceStart, sliceEnd: sliceEnd) {
                modified = true
            }
            offset += MemoryLayout<fat_arch>.size
        }
        return modified
    }

    private static func stripRestrictSegmentInSlice(
        _ binary: inout Data, sliceStart: Int, sliceEnd: Int
    ) throws -> Bool {
        let headerSize = MemoryLayout<mach_header_64>.size
        guard sliceEnd - sliceStart >= headerSize else { return false }
        var header = binary.extract(mach_header_64.self, offset: sliceStart)
        let shouldSwap = header.magic == MH_CIGAM_64
        guard header.magic == MH_MAGIC_64 || shouldSwap else { return false }
        if shouldSwap { swap_mach_header_64(&header, NXHostByteOrder()) }
        let commandsEnd = sliceStart + headerSize + Int(header.sizeofcmds)
        guard commandsEnd <= sliceEnd && commandsEnd > sliceStart + headerSize else { return false }
        var offset = sliceStart + headerSize
        var modified = false
        for _ in 0..<header.ncmds {
            guard offset + MemoryLayout<load_command>.size <= commandsEnd else { break }
            let loadCommand = binary.extract(load_command.self, offset: offset,
                                             swap: shouldSwap ? swap_load_command : nil)
            let commandEnd = offset + Int(loadCommand.cmdsize)
            guard commandEnd <= commandsEnd && commandEnd > offset else { break }
            if loadCommand.cmd == UInt32(LC_SEGMENT_64),
               offset + MemoryLayout<segment_command_64>.size <= commandEnd,
               binary[(offset + 8)..<(offset + 24)] == restrictSegBytes {
                binary.replaceSubrange((offset + 8)..<(offset + 24), with: replacementSegBytes)
                let seg = binary.extract(segment_command_64.self, offset: offset,
                                         swap: shouldSwap ? swap_segment_command_64 : nil)
                renameRestrictSections(in: &binary, segOffset: offset, commandEnd: commandEnd, nsects: Int(seg.nsects))
                modified = true
            }
            offset = commandEnd
        }
        return modified
    }

    private static func renameRestrictSections(in binary: inout Data, segOffset: Int, commandEnd: Int, nsects: Int) {
        var sectOffset = segOffset + MemoryLayout<segment_command_64>.size
        let sectSize = MemoryLayout<section_64>.size
        for _ in 0..<nsects {
            guard sectOffset + sectSize <= commandEnd else { break }
            if binary[sectOffset..<(sectOffset + 16)] == restrictSectBytes {
                binary.replaceSubrange(sectOffset..<(sectOffset + 16), with: replacementSectBytes)
            }
            if binary[(sectOffset + 16)..<(sectOffset + 32)] == restrictSegBytes {
                binary.replaceSubrange((sectOffset + 16)..<(sectOffset + 32), with: replacementSegBytes)
            }
            sectOffset += sectSize
        }
    }

    private static func paddedMachOName(_ name: String) -> Data {
        var bytes = Data(name.utf8.prefix(16))
        if bytes.count < 16 { bytes.append(Data(count: 16 - bytes.count)) }
        return bytes
    }
}

// MARK: - Anti-tamper self-destruct trap guard
//
// Hardening SDKs (mPaaS SecurityGuard / VMP and relatives) run their integrity
// verdict on a background queue and, when it fails, execute a "poison the
// frame" sequence:
//
//     mov sp,  Xn      ; add sp, Xn, #0     - stack pointer := captured value
//     mov x30, Xn      ; orr x30, xzr, Xn   - return address := same value
//     ...
//     br  Xm           ; jump to a fixed, unmapped address below 4 GiB
//
// Register numbers and the surrounding instructions vary between builds and
// between modules, so the matcher keys on the trio instead of exact instruction
// words: any `mov sp, Xn` followed within a few instructions by `mov x30, Xn`
// (same register) and then an indirect branch is a self-destruct trampoline.
//
// All three instructions are replaced with `nop`, so the block simply falls
// through and returns through the `ret` padding those stubs are built with.
// Nothing else in the app is touched, and the patch is idempotent.
extension Macho {
    /// Bumped whenever the matcher changes, so cached scan results are invalidated.
    static let trapSchemaVersion = 3

    private static let instrNop: UInt32 = 0xD503_201F
    private static let poisonPairWindow = 8   // mov sp -> mov x30
    private static let poisonBranchWindow = 24 // mov x30 -> br

    /// Patches every self-destruct stub found in `macho`.
    /// Returns the number of patched stubs (0 when the app has none).
    @discardableResult
    static func neutralizeAntiTamperTraps(at macho: URL) throws -> Int {
        var binary = try Data(contentsOf: macho)
        let patched = neutralizeAntiTamperTraps(&binary)
        guard patched > 0 else { return 0 }
        try binary.write(to: macho)
        return patched
    }

    @discardableResult
    static func neutralizeAntiTamperTraps(_ binary: inout Data) -> Int {
        guard binary.count >= MemoryLayout<UInt32>.size else { return 0 }
        let magic = binary.extract(UInt32.self)
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            return patchTrapsInFat(&binary)
        }
        return patchTrapsInSlice(&binary, sliceStart: 0, sliceEnd: binary.count)
    }

    private static func patchTrapsInFat(_ binary: inout Data) -> Int {
        var header = binary.extract(fat_header.self)
        let shouldSwap = header.magic == FAT_CIGAM
        if shouldSwap { swap_fat_header(&header, NXHostByteOrder()) }

        var offset = MemoryLayout.size(ofValue: header)
        var patched = 0
        for _ in 0..<header.nfat_arch {
            guard offset + MemoryLayout<fat_arch>.size <= binary.count else { break }
            var arch = binary.extract(fat_arch.self, offset: offset)
            if shouldSwap { swap_fat_arch(&arch, 1, NXHostByteOrder()) }
            let sliceStart = Int(arch.offset)
            let sliceEnd = sliceStart + Int(arch.size)
            if sliceStart >= 0 && sliceEnd <= binary.count && sliceStart < sliceEnd {
                patched += patchTrapsInSlice(&binary, sliceStart: sliceStart, sliceEnd: sliceEnd)
            }
            offset += MemoryLayout<fat_arch>.size
        }
        return patched
    }

    private static func patchTrapsInSlice(_ binary: inout Data, sliceStart: Int, sliceEnd: Int) -> Int {
        let headerSize = MemoryLayout<mach_header_64>.size
        guard sliceEnd - sliceStart >= headerSize else { return 0 }

        var header = binary.extract(mach_header_64.self, offset: sliceStart)
        let shouldSwap = header.magic == MH_CIGAM_64
        guard header.magic == MH_MAGIC_64 || shouldSwap else { return 0 }
        if shouldSwap { swap_mach_header_64(&header, NXHostByteOrder()) }

        let commandsStart = sliceStart + headerSize
        let commandsEnd = commandsStart + Int(header.sizeofcmds)
        guard commandsEnd <= sliceEnd else { return 0 }

        var textStart = -1
        var textEnd = -1
        var offset = commandsStart
        for _ in 0..<header.ncmds {
            guard offset + MemoryLayout<load_command>.size <= commandsEnd else { break }
            let loadCommand = binary.extract(load_command.self, offset: offset,
                                             swap: shouldSwap ? swap_load_command : nil)
            let commandEnd = offset + Int(loadCommand.cmdsize)
            guard commandEnd <= commandsEnd && commandEnd > offset else { break }

            if loadCommand.cmd == UInt32(LC_SEGMENT_64),
               offset + MemoryLayout<segment_command_64>.size <= commandEnd,
               binary[(offset + 8)..<(offset + 24)].starts(with: Data("__TEXT".utf8)) {
                let segment = binary.extract(segment_command_64.self, offset: offset,
                                             swap: shouldSwap ? swap_segment_command_64 : nil)
                var sectionOffset = offset + MemoryLayout<segment_command_64>.size
                for _ in 0..<Int(segment.nsects) {
                    let sectionSize = MemoryLayout<section_64>.size
                    guard sectionOffset + sectionSize <= commandEnd else { break }
                    let sectionName = binary[sectionOffset..<(sectionOffset + 16)]
                    let rawSize = readU64(binary, offset: sectionOffset + 40, swap: shouldSwap)
                    let rawOffset = readU32(binary, offset: sectionOffset + 48, swap: shouldSwap)
                    if sectionName.starts(with: Data("__text".utf8)) {
                        let start = sliceStart + Int(rawOffset)
                        let end = start + Int(rawSize)
                        if start >= sliceStart && end <= sliceEnd && start < end {
                            textStart = start
                            textEnd = end
                        }
                    }
                    sectionOffset += sectionSize
                }
            }
            offset = commandEnd
        }

        // Fall back to the whole slice when the section table is unusual.
        if textStart < 0 {
            textStart = sliceStart + headerSize
            textEnd = sliceEnd
        }

        let start = textStart & ~3
        let end = textEnd & ~3
        guard end - start >= 16 else { return 0 }

        var patched = 0
        binary.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt32.self) else { return }
            let last = end / 4
            var index = start / 4
            while index < last {
                guard let trap = locateTrap(base, at: index, last: last) else { index += 1; continue }
                base[trap.sp] = instrNop
                base[trap.lr] = instrNop
                base[trap.branch] = instrNop
                patched += 1
                index = trap.branch + 1
            }
        }
        return patched
    }

    /// Locates a self-destruct trampoline starting at `index`.
    ///
    /// Only the `mov sp, Xn -> mov x30, Xn -> br Xm` order is rewritten in place.
    ///
    /// The reversed order (`mov x30, Xn` first, usually preceded by `mov x29, Xn`,
    /// i.e. `mov x29/x30/sp, Xa -> br x16`) also exists — for example at
    /// `ChinaMobile+0x1000094d8` — but it **must not** be patched automatically:
    /// measured on the untouched binaries it matches 3,337 sites in ChinaMobile
    /// 12.5.7 and 4,755 in ICBC, because the same 4-instruction shape is also used
    /// as obfuscator decoy/filler. Rewriting thousands of `mov sp` instructions in
    /// unknown contexts would corrupt ordinary stack handling. Those sites are
    /// therefore left untouched until phase-0 evidence shows which of them are
    /// actually reached.
    private static func locateTrap(_ base: UnsafeMutablePointer<UInt32>, at index: Int,
                                   last: Int) -> (sp: Int, lr: Int, branch: Int)? {
        if let register = poisonedStackPointer(base[index]),
           let lr = nextMatch(base, from: index + 1, limit: index + poisonPairWindow, last: last,
                              matching: { movedReturnAddress($0, from: register) }),
           let branch = nextMatch(base, from: lr + 1, limit: lr + poisonBranchWindow, last: last,
                                  matching: isIndirectBranch) {
            return (index, lr, branch)
        }

        return nil
    }

    private static func nextMatch(_ base: UnsafeMutablePointer<UInt32>, from start: Int,
                                  limit: Int, last: Int,
                                  matching predicate: (UInt32) -> Bool) -> Int? {
        guard start <= last - 1 else { return nil }
        var cursor = start
        let upper = min(limit, last - 1)
        while cursor <= upper {
            if predicate(base[cursor]) { return cursor }
            cursor += 1
        }
        return nil
    }

    /// Returns the `LC_BUILD_VERSION` platform of the first architecture in `url`
    /// (2 = iOS, 6 = Mac Catalyst).
    static func buildPlatform(at url: URL) throws -> UInt32? {
        let binary = try Data(contentsOf: url)
        guard binary.count >= 32 else { return nil }

        var sliceStart = 0
        var sliceEnd = binary.count
        if binary.count >= 8 {
            let magic = binary.extract(UInt32.self)
            if magic == FAT_MAGIC || magic == FAT_CIGAM {
                var header = binary.extract(fat_header.self)
                let swapped = header.magic == FAT_CIGAM
                if swapped { swap_fat_header(&header, NXHostByteOrder()) }
                guard header.nfat_arch > 0 else { return nil }
                var arch = binary.extract(fat_arch.self, offset: MemoryLayout.size(ofValue: header))
                if swapped { swap_fat_arch(&arch, 1, NXHostByteOrder()) }
                sliceStart = Int(arch.offset)
                sliceEnd = sliceStart + Int(arch.size)
            }
        }
        guard sliceEnd <= binary.count, sliceEnd - sliceStart >= 32 else { return nil }

        var header = binary.extract(mach_header_64.self, offset: sliceStart)
        let shouldSwap = header.magic == MH_CIGAM_64
        guard header.magic == MH_MAGIC_64 || shouldSwap else { return nil }
        if shouldSwap { swap_mach_header_64(&header, NXHostByteOrder()) }

        var offset = sliceStart + MemoryLayout<mach_header_64>.size
        for _ in 0..<header.ncmds {
            guard offset + 8 <= sliceEnd else { break }
            let cmd = binary.extract(load_command.self, offset: offset,
                                     swap: shouldSwap ? swap_load_command : nil)
            if cmd.cmd == UInt32(LC_BUILD_VERSION), offset + 12 <= sliceEnd {
                return readU32(binary, offset: offset + 8, swap: shouldSwap)
            }
            guard cmd.cmdsize > 0 else { break }
            offset += Int(cmd.cmdsize)
        }
        return nil
    }

    /// `add sp, Xn, #0` returns the source register, excluding sp/fp.
    private static func poisonedStackPointer(_ word: UInt32) -> Int? {
        guard (word & 0xFFFF_FC00) == 0x9100_0000 else { return nil }
        let register = Int((word >> 5) & 0x1F)
        guard register != 29 && register != 31 else { return nil }
        return register
    }

    /// `orr x30, xzr, Xn` - identical source register as the poisoned sp.
    private static func movedReturnAddress(_ word: UInt32, from register: Int) -> Bool {
        guard (word & 0xFFE0_FFFF) == 0xAA00_03FE else { return false }
        return Int((word >> 16) & 0x1F) == register
    }

    /// `br Xm` (register branch, not `blr`).
    private static func isIndirectBranch(_ word: UInt32) -> Bool {
        (word & 0xFFFF_FC1F) == 0xD61F_0000
    }

    private static func readU32(_ binary: Data, offset: Int, swap: Bool) -> UInt32 {
        guard offset + 4 <= binary.count else { return 0 }
        let value = UInt32(binary[offset])
            | UInt32(binary[offset + 1]) << 8
            | UInt32(binary[offset + 2]) << 16
            | UInt32(binary[offset + 3]) << 24
        return swap ? value.byteSwapped : value
    }

    private static func readU64(_ binary: Data, offset: Int, swap: Bool) -> UInt64 {
        let low = UInt64(readU32(binary, offset: offset, swap: swap))
        let high = UInt64(readU32(binary, offset: offset + 4, swap: swap))
        return (high << 32) | low
    }
}
