//
//  Macho.swift
//  PlayCover
//

import Foundation

class Macho {
    private struct FatTable {
        static let headerSize = MemoryLayout<fat_header>.size
        let count: Int
        let uses64BitOffsets: Bool
        let shouldSwap: Bool

        var entrySize: Int {
            uses64BitOffsets ? MemoryLayout<fat_arch_64>.size : MemoryLayout<fat_arch>.size
        }

        var byteCount: Int { count * entrySize }

        init?(headerData: Data, fileSize: UInt64) throws {
            guard headerData.count >= Self.headerSize else { throw PlayCoverError.appCorrupted }
            var header = headerData.extract(fat_header.self)
            let magic = header.magic
            uses64BitOffsets = magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64
            guard uses64BitOffsets || magic == FAT_MAGIC || magic == FAT_CIGAM else { return nil }
            shouldSwap = magic == FAT_CIGAM || magic == FAT_CIGAM_64
            if shouldSwap { swap_fat_header(&header, NXHostByteOrder()) }
            count = Int(header.nfat_arch)
            guard fileSize >= UInt64(Self.headerSize), count > 0,
                  UInt64(count) <= (fileSize - UInt64(Self.headerSize)) / UInt64(entrySize) else {
                throw PlayCoverError.appCorrupted
            }
        }

        func arm64Range(in table: Data, fileSize: UInt64) throws -> Range<UInt64> {
            guard table.count == byteCount else { throw PlayCoverError.appCorrupted }
            let firstPossibleOffset = UInt64(Self.headerSize + byteCount)
            var fallback: Range<UInt64>?
            for index in 0..<count {
                let entry = architecture(in: table, offset: index * entrySize)
                guard entry.cpu == CPU_TYPE_ARM64 else { continue }
                guard entry.offset >= firstPossibleOffset, entry.offset <= fileSize,
                      entry.size >= UInt64(MemoryLayout<mach_header_64>.size),
                      entry.size <= fileSize - entry.offset else {
                    throw PlayCoverError.appCorrupted
                }
                let range = entry.offset..<(entry.offset + entry.size)
                let subtype = UInt32(bitPattern: entry.subtype) & ~CPU_SUBTYPE_MASK
                if subtype == UInt32(CPU_SUBTYPE_ARM64_ALL) { return range }
                if fallback == nil { fallback = range }
            }
            if let fallback { return fallback }
            throw PlayCoverError.failedToStripBinary
        }

        private func architecture(in table: Data, offset: Int)
            -> (cpu: cpu_type_t, subtype: cpu_subtype_t, offset: UInt64, size: UInt64) {
            if uses64BitOffsets {
                var entry = table.extract(fat_arch_64.self, offset: offset)
                if shouldSwap { swap_fat_arch_64(&entry, 1, NXHostByteOrder()) }
                return (entry.cputype, entry.cpusubtype, entry.offset, entry.size)
            }
            var entry = table.extract(fat_arch.self, offset: offset)
            if shouldSwap { swap_fat_arch(&entry, 1, NXHostByteOrder()) }
            return (entry.cputype, entry.cpusubtype, UInt64(entry.offset), UInt64(entry.size))
        }
    }

    static func stripBinary(_ binary: inout Data) throws {
        let fileSize = UInt64(binary.count)
        guard let table = try FatTable(headerData: binary, fileSize: fileSize) else { return }
        let start = FatTable.headerSize
        let entries = binary.subdata(in: start..<(start + table.byteCount))
        let range = try table.arm64Range(in: entries, fileSize: fileSize)
        binary = binary.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    /// Reads only the FAT header and architecture table for callers inspecting load commands.
    static func selectedArm64Slice(in handle: FileHandle) throws -> Range<UInt64> {
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: FatTable.headerSize) else {
            throw PlayCoverError.appCorrupted
        }
        guard let table = try FatTable(headerData: header, fileSize: fileSize) else { return 0..<fileSize }
        guard table.byteCount <= 1024 * 1024, let entries = try handle.read(upToCount: table.byteCount) else {
            throw PlayCoverError.appCorrupted
        }
        return try table.arm64Range(in: entries, fileSize: fileSize)
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
        _ = try resolveSystemLibraryAliases(&binary, at: macho, in: app)
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

    static let libraryRepairSchemaVersion = 2

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

    static let marketplaceKitInstallName = "/System/Library/Frameworks/MarketplaceKit.framework/MarketplaceKit"
    private static let catalystSystemRoot = "/System/iOSSupport"

    static func launchRequiresUnavailableMarketplaceKit(_ executable: URL, in bundle: URL) -> Bool {
        firstUnavailableHostLibrary(executable, in: bundle) { $0 == marketplaceKitInstallName } != nil
    }

    static func supportsMarketplaceKitCompatibility(_ executable: URL, in bundle: URL, stubBinary: URL) -> Bool {
        guard sharedCacheContainsPath != nil,
              FileManager.default.fileExists(atPath: stubBinary.path) else { return false }

        var requiresMarketplaceKit = false
        var marketplaceKitClients: [URL] = []
        traverseStartupGraph(executable, in: bundle) { canonicalImage, links in
            let referencesMarketplaceKit = (links.required + links.optional).contains {
                normalizedSystemPath($0) == marketplaceKitInstallName
            }
            if referencesMarketplaceKit {
                marketplaceKitClients.append(canonicalImage)
            }
            for dependency in links.required.reversed() {
                let nativePath = normalizedSystemPath(dependency)
                if nativePath == marketplaceKitInstallName, isMissingHostLibrary(nativePath) {
                    requiresMarketplaceKit = true
                }
            }
            return true
        }

        guard requiresMarketplaceKit, !marketplaceKitClients.isEmpty,
              let exportedSymbols = exportedSymbols(at: stubBinary) else {
            return false
        }

        var importedSymbols: Set<String> = []
        for client in marketplaceKitClients {
            guard let symbols = importedSymbolsFromLibrary("MarketplaceKit", at: client) else {
                return false
            }
            importedSymbols.formUnion(symbols)
        }
        return !importedSymbols.isEmpty && importedSymbols.isSubset(of: exportedSymbols)
    }

    /// Finds a missing absolute system install name in the mandatory startup graph.
    /// Unknown run-path resolutions and optional images are left to dyld.
    static func firstUnavailableHostLibrary(_ executable: URL, in bundle: URL,
                                            matching: (String) -> Bool = { _ in true })
        -> (path: String, image: String)? {
        guard sharedCacheContainsPath != nil else { return nil }

        let bundlePrefix = bundle.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var checkedSystemPaths: Set<String> = []
        var missingLibrary: (path: String, image: String)?
        traverseStartupGraph(executable, in: bundle) { canonicalImage, links in
            for dependency in links.required.reversed() {
                guard dependency.hasPrefix("/System/") || dependency.hasPrefix("/usr/lib/") else { continue }
                let nativePath = normalizedSystemPath(dependency)
                if matching(nativePath), checkedSystemPaths.insert(nativePath).inserted,
                   isMissingHostLibrary(nativePath) {
                    missingLibrary = (nativePath, String(canonicalImage.path.dropFirst(bundlePrefix.count)))
                    return false
                }
            }
            return true
        }
        return missingLibrary
    }

    private static func normalizedSystemPath(_ path: String) -> String {
        path.hasPrefix(catalystSystemRoot + "/")
            ? String(path.dropFirst(catalystSystemRoot.count))
            : path
    }

    private static func isMissingHostLibrary(_ nativePath: String) -> Bool {
        !systemLibraryExists(nativePath) && !systemLibraryExists(catalystSystemRoot + nativePath)
    }

    private static func traverseStartupGraph(
        _ executable: URL, in bundle: URL,
        visitor: (URL, (required: [String], optional: [String], runPaths: [String])) -> Bool
    ) {
        let bundlePrefix = bundle.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let executableDirectory = executable.deletingLastPathComponent().path
        var pending: [(image: URL, inheritedRunPaths: [String])] = [(executable, [])]
        var visited: Set<URL> = []
        while let (image, inheritedRunPaths) = pending.popLast() {
            let canonicalImage = image.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalImage.path.hasPrefix(bundlePrefix), visited.insert(canonicalImage).inserted,
                  let links = try? startupLinks(at: image) else { continue }

            guard visitor(canonicalImage, links) else { return }

            let loaderDirectory = image.deletingLastPathComponent().path
            func expand(_ path: String) -> String {
                if path.hasPrefix("@executable_path/") {
                    return executableDirectory + path.dropFirst("@executable_path".count)
                }
                if path.hasPrefix("@loader_path/") {
                    return loaderDirectory + path.dropFirst("@loader_path".count)
                }
                return path
            }
            let runPaths = links.runPaths.map(expand) + inheritedRunPaths
            for dependency in links.required.reversed() {
                if dependency.hasPrefix("/System/") || dependency.hasPrefix("/usr/lib/") {
                    continue
                }
                let candidates = dependency.hasPrefix("@rpath/")
                    ? runPaths.map { $0 + dependency.dropFirst("@rpath".count) }
                    : [expand(dependency)]
                guard let path = candidates.first(where: { $0.hasPrefix("/") && systemLibraryExists($0) }) else {
                    continue
                }
                pending.append((URL(fileURLWithPath: path), runPaths))
            }
        }
    }

    private static func exportedSymbols(at binary: URL) -> Set<String>? {
        guard let output = try? Shell.run(print: false, "/usr/bin/dyld_info", "-arch", "arm64", "-exports",
                                          binary.path) else {
            return nil
        }
        var exports: Set<String> = []
        var inExports = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "-exports:" {
                inExports = true
                continue
            }
            guard inExports else { continue }
            if line.hasPrefix("-") && line.hasSuffix(":") {
                inExports = false
                continue
            }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count >= 2, tokens[0].hasPrefix("0x") {
                exports.insert(tokens[1])
            }
        }
        return exports
    }

    private static func importedSymbolsFromLibrary(_ libraryName: String, at binary: URL) -> Set<String>? {
        guard let output = try? Shell.run(print: false, "/usr/bin/dyld_info", "-arch", "arm64", "-imports",
                                          binary.path) else {
            return nil
        }
        let suffix = "(from \(libraryName))"
        var imports: Set<String> = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasSuffix(suffix) else { continue }
            line = String(line.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("[weak-import]") {
                line = String(line.dropLast("[weak-import]".count)).trimmingCharacters(in: .whitespaces)
            }
            var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count >= 2, tokens[0].hasPrefix("0x") {
                tokens.removeFirst()
            }
            if tokens.count >= 3, tokens[tokens.count - 2] == "+" {
                tokens.removeLast(2)
            }
            guard tokens.count == 1, !tokens[0].isEmpty else { return nil }
            imports.insert(tokens[0])
        }
        return imports
    }

    private static func startupLinks(at image: URL) throws
        -> (required: [String], optional: [String], runPaths: [String]) {
        var binary = try Data(contentsOf: image, options: .mappedIfSafe)
        try stripBinary(&binary)
        return try startupLinks(in: binary)
    }

    private static func startupLinks(in binary: Data) throws
        -> (required: [String], optional: [String], runPaths: [String]) {
        var required: [String] = []
        var optional: [String] = []
        var runPaths: [String] = []
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let command = binary.extract(load_command.self, offset: offset,
                                         swap: shouldSwap ? swap_load_command : nil)
            let isRunPath = command.cmd == UInt32(LC_RPATH)
            let isWeak = command.cmd == UInt32(LC_LOAD_WEAK_DYLIB)
            guard isRunPath || isWeak || command.cmd == UInt32(LC_LOAD_DYLIB)
                    || command.cmd == UInt32(LC_REEXPORT_DYLIB)
                    || command.cmd == UInt32(LC_LOAD_UPWARD_DYLIB) else { return false }
            let minimumSize = isRunPath ? MemoryLayout<rpath_command>.size : MemoryLayout<dylib_command>.size
            guard Int(command.cmdsize) >= minimumSize else { return false }
            let raw = binary.extract(lc_str.self, offset: offset + MemoryLayout<load_command>.size).offset
            let nameOffset = Int(shouldSwap ? raw.byteSwapped : raw)
            guard nameOffset >= minimumSize, nameOffset < Int(command.cmdsize) else { return false }
            let bytes = binary[(offset + nameOffset)..<(offset + Int(command.cmdsize))]
            guard let terminator = bytes.firstIndex(of: 0),
                  let name = String(bytes: bytes[..<terminator], encoding: .utf8) else { return false }
            if isRunPath {
                runPaths.append(name)
            } else if isWeak {
                optional.append(name)
            } else {
                required.append(name)
            }
            return false
        }
        return (required, optional, runPaths)
    }

    static func hasCustomLibrarySearch(_ environment: [String: String],
                                       exceptFrameworkPath: String? = nil) -> Bool {
        environment.contains { key, value in
            !value.isEmpty && key.hasPrefix("DYLD_") && (key.hasSuffix("_PATH") || key == "DYLD_IMAGE_SUFFIX")
                && !(key == "DYLD_FRAMEWORK_PATH" && value == exceptFrameworkPath)
        }
    }

    private static func appLibrarySearchDirectories(at image: URL, in app: URL?, binary: Data) -> [URL]? {
        let loaderDirectory = image.deletingLastPathComponent()
        var directories = [loaderDirectory]
        var executable = image
        if let app = app {
            directories.append(app.appendingPathComponent("Frameworks"))
            if let metadata = try? [String: Any].read(app.appendingPathComponent("Info.plist")) {
                if let environment = metadata["LSEnvironment"] as? [String: String],
                   hasCustomLibrarySearch(environment) { return nil }
                if let name = metadata["CFBundleExecutable"] as? String {
                    executable = app.appendingPathComponent(name)
                }
            }
        }
        let executableDirectory = executable.deletingLastPathComponent().path
        func expand(_ paths: [String], loader: String) -> [URL] {
            paths.compactMap { path in
                if path.hasPrefix("@executable_path/") || path == "@executable_path" {
                    return URL(fileURLWithPath: executableDirectory + path.dropFirst("@executable_path".count))
                }
                if path.hasPrefix("@loader_path/") || path == "@loader_path" {
                    return URL(fileURLWithPath: loader + path.dropFirst("@loader_path".count))
                }
                return path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
            }
        }
        directories += expand((try? startupLinks(in: binary))?.runPaths ?? [], loader: loaderDirectory.path)
        if executable.standardizedFileURL != image.standardizedFileURL {
            directories += expand((try? startupLinks(at: executable))?.runPaths ?? [], loader: executableDirectory)
        }
        return directories
    }

    private static func hostedLibraryInstallName(for suffix: String) -> String? {
        if !suffix.contains("/"), suffix.hasPrefix("libswift"), suffix.hasSuffix(".dylib") {
            let ios = iOSSupportSwiftDirectory + "/" + suffix
            let mac = macOSSwiftDirectory + "/" + suffix
            if catalystFrameworkOverlays.contains(suffix), systemLibraryExists(ios) { return ios }
            if systemLibraryExists(mac) { return mac }
            return systemLibraryExists(ios) ? ios : nil
        }
        // Only use the system counterpart of a canonical public framework install name.
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[0] == parts[1] + ".framework" else { return nil }
        let path = "/System/Library/Frameworks/" + suffix
        let ios = catalystSystemRoot + path
        if systemLibraryExists(ios) { return ios }
        return systemLibraryExists(path) ? path : nil
    }

    /// Carries the same repair forward to already-installed Catalyst images.
    static func repairSystemLibraryAliases(in macho: URL, app: URL) throws -> Bool {
        var binary = try Data(contentsOf: macho, options: .mappedIfSafe)
        guard try resolveSystemLibraryAliases(&binary, at: macho, in: app, copyBeforeWriting: true) else { return false }
        let permissions = try FileManager.default.attributesOfItem(atPath: macho.path)[.posixPermissions]
        try binary.write(to: macho, options: .atomic)
        if let permissions = permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: macho.path)
        }
        return true
    }

    private static func resolveSystemLibraryAliases(
        _ binary: inout Data, at macho: URL, in app: URL?, copyBeforeWriting: Bool = false
    ) throws -> Bool {
        let headerSize = MemoryLayout<mach_header_64>.size
        let commandSize = MemoryLayout<dylib_command>.size
        let rpathPrefix = "@rpath/"
        var changes: [(range: Range<Int>, bytes: Data)] = []
        var malformedCommand = false
        var reversedByteOrder = false
        guard let searchDirectories = appLibrarySearchDirectories(at: macho, in: app, binary: binary) else {
            return false
        }
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
            let suffix = String(path.dropFirst(rpathPrefix.count))
            guard let replacement = hostedLibraryInstallName(for: suffix),
                  !searchDirectories.contains(where: { directory in
                      let candidate = directory.appendingPathComponent(suffix).standardizedFileURL
                      if candidate == macho.standardizedFileURL { return false }
                      // Preserve custom and bundled libraries, but retain Catalyst's overlay preference
                      // when a run path selects the corresponding macOS Swift library.
                      if catalystFrameworkOverlays.contains(suffix),
                         candidate.path == macOSSwiftDirectory + "/" + suffix,
                         replacement.hasPrefix(iOSSupportSwiftDirectory + "/") { return false }
                      return systemLibraryExists(candidate.path)
                  }) else { return false }

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
        do {
            try writeLoadCommands(&binary, commands: commands, start: headerSize, oldEnd: oldEnd,
                                  shouldSwap: reversedByteOrder)
        } catch is InsufficientLoadCommandSpace {
            // The original link paths can still be resolved by dyld. Keep this repair best-effort.
            return false
        }
        return true
    }

    // iOS and Mac Catalyst share SDK version numbers for the modern UIKit
    // compatibility modes. Preserve those SDKs when converting from iOS.
    private static let modernUIKitSDK: UInt32 = 26 << 16
    private static let legacyCatalystSDK: UInt32 = 14 << 16
    private static let catalystDeploymentTarget: UInt32 = 11 << 16

    static func replaceVersionCommand(_ binary: inout Data) throws {

        var macCatalystCommand = build_version_command(cmd: UInt32(LC_BUILD_VERSION),
                                                       cmdsize: 24,
                                                       platform: UInt32(PLATFORM_MACCATALYST),
                                                       minos: catalystDeploymentTarget,
                                                       sdk: legacyCatalystSDK,
                                                       ntools: 0)

        try replaceLastCommand(&binary, satisfy: {data, shouldSwap in
            let loadCommand = data.extract(load_command.self,
                                           offset: data.startIndex,
                                           swap: shouldSwap ? swap_load_command:nil)
            if loadCommand.cmd == UInt32(LC_BUILD_VERSION),
               data.count >= MemoryLayout<build_version_command>.size {
                let original = data.extract(build_version_command.self, offset: data.startIndex,
                                            swap: shouldSwap ? swap_build_version_command : nil)
                if original.platform == PLATFORM_IOS && original.sdk >= modernUIKitSDK {
                    macCatalystCommand.sdk = original.sdk
                }
            }
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

    static func restoreApplicationSDK(at executable: URL, sdkName: String?) throws -> Bool {
        // The app's Info.plist describes its executable. Embedded frameworks
        // may have been built with different SDKs and need their own metadata.
        let prefix = "iphoneos"
        guard let sdkName, sdkName.hasPrefix(prefix) else { return false }
        let version = sdkName.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(version.count), let major = UInt16(version[0]),
              let minor = UInt8(version[1]), let patch = version.count == 3 ? UInt8(version[2]) : 0 else { return false }
        let sdk = UInt32(major) << 16 | UInt32(minor) << 8 | UInt32(patch)
        guard sdk >= modernUIKitSDK else { return false }

        var binary = try Data(contentsOf: executable)
        var replacement: (offset: Int, bytes: Data)?
        _ = try iterateLoadCommands(binary: binary) { offset, shouldSwap in
            let load = binary.extract(load_command.self, offset: offset, swap: shouldSwap ? swap_load_command : nil)
            let size = MemoryLayout<build_version_command>.size
            guard load.cmd == UInt32(LC_BUILD_VERSION), load.cmdsize == size else { return false }
            var command = binary.extract(build_version_command.self, offset: offset,
                                         swap: shouldSwap ? swap_build_version_command : nil)
            guard command.platform == PLATFORM_MACCATALYST, command.minos == catalystDeploymentTarget,
                  command.sdk == legacyCatalystSDK, command.ntools == 0 else { return false }
            command.sdk = sdk
            if shouldSwap { swap_build_version_command(&command, NX_BigEndian) }
            replacement = (offset, Data(bytes: &command, count: size))
            return true
        }
        guard let replacement else { return false }
        binary.replaceSubrange(replacement.offset..<(replacement.offset + replacement.bytes.count),
                               with: replacement.bytes)
        let permissions = try FileManager.default.attributesOfItem(atPath: executable.path)[.posixPermissions]
        try binary.write(to: executable, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: executable.path)
        }
        return true
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
        var binary = try Data(contentsOf: url, options: .mappedIfSafe)
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

    static func isMachoValidArch(_ url: URL, allowingUniversal: Bool = false) throws -> Bool {
        var binary = try Data(contentsOf: url, options: .mappedIfSafe)
        guard binary.count >= MemoryLayout<mach_header_64>.size else { return false }
        if allowingUniversal {
            do {
                try stripBinary(&binary)
            } catch PlayCoverError.failedToStripBinary {
                return false
            }
            guard binary.count >= MemoryLayout<mach_header_64>.size else { return false }
        }
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
// Also covers the consecutive reversed-order variant generated by the same
// obfuscator family (`sub/mov x29` -> `sub/mov x30` -> `mov sp, Xn` -> `br Xm`),
// where all four instructions are replaced with `nop`.
//
// Forward-order scans never cross basic-block control-flow boundaries (`ret`,
// `b`, `br`, `bl`, `blr`, `cbz/cbnz`, `tbz/tbnz`, `b.cond`, `brk/hlt/udf`),
// preventing false matches across adjacent functions or blocks.
// Nothing else in the app is touched, and the patch is idempotent.
extension Macho {
    /// Bumped whenever the matcher changes, so cached scan results are invalidated.
    static let trapSchemaVersion = 4

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
                if let fp = trap.fp {
                    base[fp] = instrNop
                }
                base[trap.sp] = instrNop
                base[trap.lr] = instrNop
                base[trap.branch] = instrNop
                patched += 1
                index = trap.branch + 1
            }
        }
        return patched
    }

    private struct TrapSite {
        let fp: Int?
        let sp: Int
        let lr: Int
        let branch: Int
    }

    /// Locates a self-destruct trampoline starting at `index`.
    ///
    /// Matches both:
    /// 1. Forward-order `mov sp, Xn -> mov x30, Xn -> br Xm` within the same basic block.
    /// 2. Consecutive reversed-order `(sub/mov x29) -> (sub/mov x30) -> mov sp, Xn -> br Xm`.
    private static func locateTrap(_ base: UnsafeMutablePointer<UInt32>, at index: Int,
                                   last: Int) -> TrapSite? {
        if let register = poisonedStackPointer(base[index]),
           let lr = nextMatch(base, from: index + 1, limit: index + poisonPairWindow, last: last,
                              matching: { movedReturnAddress($0, from: register) }),
           let branch = nextMatch(base, from: lr + 1, limit: lr + poisonBranchWindow, last: last,
                                  matching: isIndirectBranch) {
            return TrapSite(fp: nil, sp: index, lr: lr, branch: branch)
        }

        if index + 3 < last,
           let register = poisonedStackPointer(base[index + 2]),
           poisonedFramePointer(base[index], from: register),
           poisonedLinkRegister(base[index + 1], from: register),
           isIndirectBranch(base[index + 3]) {
            return TrapSite(fp: index, sp: index + 2, lr: index + 1, branch: index + 3)
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
            let word = base[cursor]
            if predicate(word) { return cursor }
            if isControlFlowBoundary(word) { return nil }
            cursor += 1
        }
        return nil
    }

    /// Returns the `LC_BUILD_VERSION` platform of the selected architecture in `url`
    /// (2 = iOS, 6 = Mac Catalyst).
    static func buildPlatform(at url: URL) throws -> UInt32? {
        var binary = try Data(contentsOf: url, options: .mappedIfSafe)
        guard (try? stripBinary(&binary)) != nil else { return nil }
        var platform: UInt32?
        guard (try? iterateLoadCommands(binary: binary, { offset, shouldSwap in
            let command = binary.extract(load_command.self, offset: offset,
                                         swap: shouldSwap ? swap_load_command : nil)
            guard command.cmd == UInt32(LC_BUILD_VERSION),
                  command.cmdsize >= MemoryLayout<build_version_command>.size else { return false }
            let version = binary.extract(build_version_command.self, offset: offset,
                                         swap: shouldSwap ? swap_build_version_command : nil)
            platform = version.platform
            return true
        })) != nil else { return nil }
        return platform
    }

    /// `add sp, Xn, #0` (`mov sp, Xn`), excluding sp/fp as the source.
    private static func poisonedStackPointer(_ word: UInt32) -> Int? {
        guard (word & 0xFFFF_FC1F) == 0x9100_001F else { return nil }
        let register = Int((word >> 5) & 0x1F)
        guard register != 29 && register != 31 else { return nil }
        return register
    }

    /// `sub x29, x29, x29`, `mov x29, xzr`, or `mov x29, Xn`.
    private static func poisonedFramePointer(_ word: UInt32, from register: Int) -> Bool {
        word == 0xCB1D_03BD
            || word == 0xAA1F_03FD
            || word == (0xAA00_03FD | UInt32(register << 16))
    }

    /// `sub x30, x30, x30`, `mov x30, xzr`, or `mov x30, Xn`.
    private static func poisonedLinkRegister(_ word: UInt32, from register: Int) -> Bool {
        word == 0xCB1E_03DE
            || word == 0xAA1F_03FE
            || word == (0xAA00_03FE | UInt32(register << 16))
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

    /// Terminators and branch instructions that end or leave the current linear instruction stream.
    private static func isControlFlowBoundary(_ word: UInt32) -> Bool {
        if (word & 0xFFFF_FC1F) == 0xD65F_0000 { return true } // ret / ret Xn
        if word == 0xD65F_0BFF || word == 0xD65F_0FFF { return true } // retaa / retab
        if isIndirectBranch(word) { return true } // br Xn
        if (word & 0xFFFF_FC1F) == 0xD63F_0000 { return true } // blr Xn
        if (word & 0xFC00_0000) == 0x1400_0000 { return true } // b imm26
        if (word & 0xFC00_0000) == 0x9400_0000 { return true } // bl imm26
        if (word & 0xFF00_0010) == 0x5400_0000 { return true } // b.cond
        if (word & 0x7E00_0000) == 0x3400_0000 { return true } // cbz / cbnz
        if (word & 0x7E00_0000) == 0x3600_0000 { return true } // tbz / tbnz
        if (word & 0xFFE0_001F) == 0xD420_0000 { return true } // brk
        if (word & 0xFFE0_001F) == 0xD440_0000 { return true } // hlt
        if (word >> 16) == 0 { return true } // udf
        return false
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
