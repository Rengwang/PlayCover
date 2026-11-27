//
//  PlayTools.swift
//  PlayCover
//

import Foundation
import injection

// This has so many functionality in it that 250 lines is darn near impossible
// swiftlint:disable:next type_body_length
class PlayTools {
    private static let frameworksURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Frameworks")
    private static let playToolsFramework = frameworksURL
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")
    private static let playToolsPath = playToolsFramework
        .appendingPathComponent("PlayTools")
    private static let akInterfacePath = playToolsFramework
        .appendingPathComponent("PlugIns")
        .appendingPathComponent("AKInterface")
        .appendingPathExtension("bundle")
    private static let marketplaceKitCompatibility = playToolsFramework
        .appendingPathComponent("Resources")
        .appendingPathComponent("MarketplaceKitCompatibility")
    private static let bundledPlayToolsFramework = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Frameworks")
        .appendingPathComponent("PlayTools")
        .appendingPathExtension("framework")
    /// iOS slice shipped alongside the app for `export == true` (real-device IPAs must not
    /// receive the Mac Catalyst binary).
    private static let bundledIOSPlayToolsFramework = Bundle.main.bundleURL
        .appendingPathComponent("Contents")
        .appendingPathComponent("Resources")
        .appendingPathComponent("PlayTools-iOS")
        .appendingPathExtension("framework")

    public static var playCoverContainer: URL {
        let playCoverPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Containers")
            .appendingPathComponent("io.playcover.PlayCover")
        if !FileManager.default.fileExists(atPath: playCoverPath.path) {
            do {
                try FileManager.default.createDirectory(at: playCoverPath,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                Log.shared.error(error)
            }
        }

        return playCoverPath
    }

    static func installOnSystem() {
        Task.detached(priority: .background) {
            do {
                try installOnSystemSync()
            } catch {
                Log.shared.error(error)
            }
        }
    }

    static func installOnSystemSync() throws {
        Log.shared.log("Installing PlayTools")

        if !FileManager.default.fileExists(atPath: frameworksURL.path) {
            try FileManager.default.createDirectory(atPath: frameworksURL.path,
                                                    withIntermediateDirectories: true,
                                                    attributes: [:])
        }

        // Stage first, verify, then swap atomically. Removing the live framework before the copy
        // would leave every installed app without PlayTools if the copy fails halfway.
        let staging = frameworksURL.appendingPathComponent("PlayTools.framework.staging-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.copyItem(at: bundledPlayToolsFramework, to: staging)

        guard try Macho.buildPlatform(at: staging.appendingPathComponent("PlayTools")) == 6 else {
            throw NSError(domain: "PlayCover", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Bundled PlayTools is not a Mac Catalyst binary"
            ])
        }
        try Shell.run("/usr/bin/codesign", "-v", staging.path)

        if FileManager.default.fileExists(atPath: playToolsFramework.path) {
            _ = try FileManager.default.replaceItemAt(playToolsFramework, withItemAt: staging)
        } else {
            // `fileExists` is false for a dangling symlink; remove it before moving in.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: playToolsFramework.path)) != nil {
                try FileManager.default.removeItem(at: playToolsFramework)
            }
            try FileManager.default.moveItem(at: staging, to: playToolsFramework)
        }
    }

    private static let marketplaceCompatibilityLock = NSLock()
    private static var cleanMarketplaceCompatibilityKeys: Set<String> = []

    static func configureMarketplaceKitCompatibility(_ info: AppInfo, in bundle: URL) throws -> Bool {
        let executable = bundle.appendingEscapedPathComponent(info.executableName)
        let compatibilityBinary = marketplaceKitCompatibility
            .appendingPathComponent("MarketplaceKit.framework")
            .appendingPathComponent("MarketplaceKit")

        let execAttrs = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let execSize = (execAttrs?[.size] as? NSNumber)?.int64Value ?? -1
        let execMtime = (execAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let plistAttrs = try? FileManager.default.attributesOfItem(atPath: info.url.path)
        let plistSize = (plistAttrs?[.size] as? NSNumber)?.int64Value ?? -1
        let plistMtime = (plistAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let stubAttrs = try? FileManager.default.attributesOfItem(atPath: compatibilityBinary.path)
        let stubMtime = (stubAttrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let dyldFrameworkPath = info.lsEnvironment["DYLD_FRAMEWORK_PATH"] ?? ""
        let cacheKey = "\(executable.path)|\(execSize)|\(execMtime)|\(plistSize)|\(plistMtime)|\(stubMtime)|\(dyldFrameworkPath)"

        if execSize >= 0 {
            marketplaceCompatibilityLock.lock()
            let alreadyChecked = cleanMarketplaceCompatibilityKeys.contains(cacheKey)
            marketplaceCompatibilityLock.unlock()
            if alreadyChecked {
                return false
            }
        }

        // Enable for any app referencing unavailable MarketplaceKit (required or weak-linked)
        // if all imported symbols are covered by the stub.
        let enabled = Macho.supportsMarketplaceKitCompatibility(executable,
                                                                in: bundle,
                                                                stubBinary: compatibilityBinary)
        let changed = try info.updateManagedFrameworkPath(marketplaceKitCompatibility.path, enabled: enabled)
        if !changed && execSize >= 0 {
            marketplaceCompatibilityLock.lock()
            cleanMarketplaceCompatibilityKeys.insert(cacheKey)
            marketplaceCompatibilityLock.unlock()
        }
        return changed
    }

    private static let launchDependencyLock = NSLock()
    private static var checkedLaunchDependencies: Set<String> = []

    static func reportUnresolvedLaunchDependencies(_ info: AppInfo, in bundle: URL) {
        let managedPath = marketplaceKitCompatibility.path
        let environment = info.lsEnvironment
        guard !Macho.hasCustomLibrarySearch(environment, exceptFrameworkPath: managedPath) else { return }

        let executable = bundle.appendingEscapedPathComponent(info.executableName)
        let attrs = try? FileManager.default.attributesOfItem(atPath: executable.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let dyldFrameworkPath = environment["DYLD_FRAMEWORK_PATH"] ?? ""
        let cacheKey = "\(executable.path)|\(size)|\(mtime)|\(dyldFrameworkPath)"

        launchDependencyLock.lock()
        let alreadyChecked = checkedLaunchDependencies.contains(cacheKey)
        launchDependencyLock.unlock()
        guard !alreadyChecked else { return }

        let usingMarketplaceCompatibility = dyldFrameworkPath == managedPath
        if let missing = Macho.firstUnavailableHostLibrary(executable, in: bundle, matching: { path in
            !usingMarketplaceCompatibility || path != Macho.marketplaceKitInstallName
        }) {
            let diagnostic = missing.path == Macho.marketplaceKitInstallName
                ? PlayCoverError.marketplaceKitUnavailable
                : PlayCoverError.hostDependencyUnavailable(path: missing.path, image: missing.image)
            Log.shared.log(diagnostic.localizedDescription)
        } else {
            launchDependencyLock.lock()
            checkedLaunchDependencies.insert(cacheKey)
            launchDependencyLock.unlock()
        }
    }

    /// Path of the iOS slice used when exporting an IPA for a real device.
    private static func iosInjectPath() throws -> URL {
        let executable = bundledIOSPlayToolsFramework.appendingPathComponent("PlayTools")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw NSError(domain: "PlayCover", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "PlayTools-iOS.framework is missing from Resources; "
                    + "rebuild with ./sync_upstream.sh build"
            ])
        }
        return executable
    }

    static func installInIPA(_ exec: URL) async throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        let injectPath = playToolsPath
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Inject.injectMachO(machoPath: exec.path,
                               cmdType: .loadDylib,
                               backup: false,
                               injectPath: injectPath.path,
                               finishHandle: { result in
                guard result else {
                    continuation.resume(throwing: "Failed to inject PlayTools into \(exec.lastPathComponent)")
                    return
                }
                do {
                    let payload = exec.deletingLastPathComponent()
                    try installPluginInIPA(payload)

                    let info = AppInfo(contentsOf: payload.appendingPathComponent("Info")
                                                          .appendingPathExtension("plist"))
                    try syncUserDylibs(bundleIdentifier: info.bundleIdentifier, into: exec)

                    try Shell.signApp(exec)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            })
        }
    }

    private static let pluginInstallCacheLock = NSLock()
    private static var cleanPluginInstallStamps: [String: String] = [:]

    private static func mtimeToken(for url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size):\(mtime)"
    }

    private static func pluginInstallStamp(for payload: URL) -> String {
        var parts: [String] = [mtimeToken(for: bundledPlayToolsFramework)]
        let pluginsSource = bundledPlayToolsFramework.appendingPathComponent("PlugIns")
        let pluginsTarget = payload.appendingPathComponent("PlugIns")
        let bundleNames = ((try? FileManager.default.contentsOfDirectory(atPath: pluginsSource.path)) ?? [])
            .filter { $0.hasSuffix(".bundle") }
            .sorted()
        for name in bundleNames {
            let srcBundle = pluginsSource.appendingPathComponent(name)
            let srcExec = Bundle(url: srcBundle)?.executableURL
            let dstBundle = pluginsTarget.appendingPathComponent(name)
            let dstExec = Bundle(url: dstBundle)?.executableURL
            parts.append("b:\(name):\(srcExec.map(mtimeToken(for:)) ?? "missing"):\(dstExec.map(mtimeToken(for:)) ?? "missing")")
        }

        let roots = [
            bundledPlayToolsFramework,
            bundledPlayToolsFramework.appendingPathComponent("Versions/A/Resources")
        ]
        for root in roots {
            let lprojs = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
                .filter { $0.hasSuffix(".lproj") }
                .sorted()
            for lproj in lprojs {
                let srcStrings = root.appendingPathComponent(lproj).appendingPathComponent("Playtools.strings")
                let dstStrings = payload.appendingPathComponent(lproj).appendingPathComponent("Playtools.strings")
                parts.append("s:\(lproj):\(mtimeToken(for: srcStrings)):\(mtimeToken(for: dstStrings))")
            }
        }
        return parts.joined(separator: "|")
    }

    static func installPluginInIPA(_ payload: URL, reusingInstalledFiles: Bool = false,
                                   willChange: () throws -> Void = {}) throws {
        var initialStamp: String?
        if reusingInstalledFiles {
            let stamp = pluginInstallStamp(for: payload)
            initialStamp = stamp
            pluginInstallCacheLock.lock()
            let cached = cleanPluginInstallStamps[payload.path]
            pluginInstallCacheLock.unlock()
            if cached == stamp {
                return
            }
        }

        var didChange = false
        let trackedWillChange: () throws -> Void = {
            didChange = true
            try willChange()
        }

        let allFiles = try FileManager.default.contentsOfDirectory(
            at: bundledPlayToolsFramework, includingPropertiesForKeys: [])
        for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
            try copyAsset(target: payload, directoryName: localizationDirectory.lastPathComponent,
                          component: "Playtools", pathExtension: "strings",
                          reusingInstalledFiles: reusingInstalledFiles, willChange: trackedWillChange)
        }

        let bundledPlayToolsResources = bundledPlayToolsFramework
            .appendingPathComponent("Versions")
            .appendingPathComponent("A")
            .appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: bundledPlayToolsResources.path) {
            let allFiles = try FileManager.default.contentsOfDirectory(
                at: bundledPlayToolsResources, includingPropertiesForKeys: [])
            for localizationDirectory in allFiles where localizationDirectory.pathExtension == "lproj" {
                try copyAsset(source: bundledPlayToolsResources, target: payload,
                              directoryName: localizationDirectory.lastPathComponent,
                              component: "Playtools", pathExtension: "strings",
                              reusingInstalledFiles: reusingInstalledFiles, willChange: trackedWillChange)
            }
        }

        try installComponentBundles(into: payload, reusingInstalledFiles: reusingInstalledFiles,
                                    willChange: trackedWillChange)

        if reusingInstalledFiles {
            let stamp = didChange ? pluginInstallStamp(for: payload) : (initialStamp ?? pluginInstallStamp(for: payload))
            pluginInstallCacheLock.lock()
            cleanPluginInstallStamps[payload.path] = stamp
            pluginInstallCacheLock.unlock()
        }
    }

    private static func installComponentBundles(into payload: URL, reusingInstalledFiles: Bool,
                                                willChange: () throws -> Void) throws {
        let pluginsSource = bundledPlayToolsFramework.appendingPathComponent("PlugIns")
        let pluginsTarget = payload.appendingPathComponent("PlugIns")

        let bundleNames = try FileManager.default.contentsOfDirectory(atPath: pluginsSource.path)
        let bundles = bundleNames
            .map { pluginsSource.appendingPathComponent($0) }
            .filter { $0.pathExtension == "bundle" }

        for bundleSource in bundles {
            let bundleTarget = pluginsTarget.appendingPathComponent(bundleSource.lastPathComponent)
            // Compare the entire bundle, including the signature and nested resources.
            if reusingInstalledFiles,
               FileManager.default.contentsEqual(atPath: bundleSource.path, andPath: bundleTarget.path),
               let executable = Bundle(url: bundleTarget)?.executableURL,
               FileManager.default.isExecutableFile(atPath: executable.path) {
                continue
            }
            let fileManager = FileManager.default
            let stagingDirectory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                       appropriateFor: payload, create: true)
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            let stagedBundle = stagingDirectory.appendingPathComponent(bundleSource.lastPathComponent)
            try fileManager.copyItem(at: bundleSource, to: stagedBundle)
            try stagedBundle.fixExecutable()
            try Shell.signMacho(stagedBundle)
            try willChange()
            try fileManager.createDirectory(at: pluginsTarget, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: bundleTarget.path) {
                _ = try fileManager.replaceItemAt(bundleTarget, withItemAt: stagedBundle)
            } else {
                try fileManager.moveItem(at: stagedBundle, to: bundleTarget)
            }
        }
    }

    private static func copyAsset(source: URL = bundledPlayToolsFramework, target: URL, directoryName: String,
                                  component: String, pathExtension: String, reusingInstalledFiles: Bool,
                                  willChange: () throws -> Void) throws {
        let directory = target.appendingPathComponent(directoryName)

        let target = directory
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)

        let source = source
                    .appendingPathComponent(directoryName)
                    .appendingPathComponent(component)
                    .appendingPathExtension(pathExtension)
        if reusingInstalledFiles,
           FileManager.default.isReadableFile(atPath: target.path),
           FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) {
            return
        }
        let contents = try Data(contentsOf: source)
        try willChange()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: target, options: .atomic)
    }

    static func injectInIPA(_ exec: URL, payload: URL) throws {
        var binary = try Data(contentsOf: exec)
        try Macho.stripBinary(&binary)

        Inject.injectMachO(machoPath: exec.path,
                           cmdType: .loadDylib,
                           backup: false,
                           injectPath: "@executable_path/Frameworks/PlayTools.dylib",
                           finishHandle: { result in
            if result {
                Task(priority: .background) {
                    do {
                        if !FileManager.default.fileExists(atPath: payload.appendingPathComponent("Frameworks").path) {
                            try FileManager.default.createDirectory(
                                at: payload.appendingPathComponent("Frameworks"),
                                withIntermediateDirectories: true)
                        }

                        let libraryTarget = payload.appendingPathComponent("Frameworks")
                            .appendingPathComponent("PlayTools")
                            .appendingPathExtension("dylib")

                        // Export targets a real device: the Catalyst binary would not load there.
                        let tools = try iosInjectPath()

                        if FileManager.default.fileExists(atPath: libraryTarget.path) {
                            try FileManager.default.removeItem(at: libraryTarget)
                        }
                        try FileManager.default.copyItem(at: tools, to: libraryTarget)

                        try libraryTarget.fixExecutable()
                        try installPluginInIPA(payload)
                    } catch {
                        Log.shared.error(error)
                    }
                }
            }
        })
    }

    static func removeFromApp(_ exec: URL) async {
        do {
            let fileManager = FileManager.default
            let payload = exec.deletingLastPathComponent()
            guard let bundleIdentifier = Bundle(url: payload)?.bundleIdentifier else {
                throw PlayCoverError.infoPlistNotFound
            }
            guard try installedInExec(atURL: exec) else { return }

            let originalAttributes = try fileManager.attributesOfItem(atPath: exec.path)
            let stagingDirectory = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                       appropriateFor: payload, create: true)
            defer { try? fileManager.removeItem(at: stagingDirectory) }
            let stagedApp = stagingDirectory.appendingPathComponent(payload.lastPathComponent)
            try fileManager.copyItem(at: payload, to: stagedApp)
            let stagedExec = stagedApp.appendingPathComponent(exec.lastPathComponent)

            var removed = false
            Inject.removeMachO(machoPath: stagedExec.path, cmdType: .loadDylib, backup: false,
                               injectPath: playToolsPath.path) { removed = $0 }
            guard removed, try !installedInExec(atURL: stagedExec) else {
                throw "Failed to remove PlayTools from \(exec.lastPathComponent)"
            }

            let bridge = stagedApp.appendingPathComponent("PlugIns")
                .appendingPathComponent(akInterfacePath.lastPathComponent)
            if fileManager.fileExists(atPath: bridge.path) {
                try fileManager.removeItem(at: bridge)
            }
            // The existing app extensions already have signatures. Sign the changed outer bundle.
            try Shell.run("/usr/bin/codesign", "-fs-", "--preserve-metadata=entitlements", stagedApp.path)
            try Shell.run(print: false, "/usr/bin/codesign", "--verify", "--deep", "--strict", stagedApp.path)

            let currentAttributes = try fileManager.attributesOfItem(atPath: exec.path)
            guard currentAttributes[.systemFileNumber] as? NSNumber == originalAttributes[.systemFileNumber] as? NSNumber,
                  currentAttributes[.modificationDate] as? Date == originalAttributes[.modificationDate] as? Date else {
                throw "The app changed while removing PlayTools. Try again."
            }
            try Installer.publishBundle(stagedApp, at: payload, bundleIdentifier: bundleIdentifier, requireExisting: true)
        } catch {
            Log.shared.error(error)
        }
    }

    private struct MachOLoadCommands {
        let data: Data
        let ncmds: UInt32
        let shouldSwap: Bool
    }

    private static func loadCommandsData(
        in handle: FileHandle,
        inSlice slice: Range<UInt64>
    ) throws -> MachOLoadCommands {
        try handle.seek(toOffset: slice.lowerBound)
        let headerSize = MemoryLayout<mach_header_64>.size
        let sliceSize = slice.upperBound - slice.lowerBound
        guard sliceSize >= UInt64(headerSize), let headerData = try handle.read(upToCount: headerSize),
              headerData.count == headerSize else {
            throw PlayCoverError.appCorrupted
        }
        var header = headerData.extract(mach_header_64.self)
        let shouldSwap = header.magic == MH_CIGAM_64
        guard header.magic == MH_MAGIC_64 || shouldSwap else {
            throw PlayCoverError.appCorrupted
        }
        if shouldSwap { swap_mach_header_64(&header, NXHostByteOrder()) }

        let commandsSize = Int(header.sizeofcmds)
        guard commandsSize > 0, commandsSize <= 16 * 1024 * 1024,
              UInt64(commandsSize) <= sliceSize - UInt64(headerSize),
              let commandsData = try handle.read(upToCount: commandsSize),
              commandsData.count == commandsSize else {
            throw PlayCoverError.appCorrupted
        }
        return MachOLoadCommands(data: commandsData, ncmds: header.ncmds, shouldSwap: shouldSwap)
    }

    static func installedInExec(atURL url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let slice = try Macho.selectedArm64Slice(in: handle)
        let commands = try loadCommandsData(in: handle, inSlice: slice)
        let commandsData = commands.data

        var offset = 0
        let expectedDylib = playToolsPath.esc
        for _ in 0..<commands.ncmds {
            guard offset + MemoryLayout<load_command>.size <= commandsData.count else {
                throw PlayCoverError.appCorrupted
            }
            let loadCommand = commandsData.extract(load_command.self,
                                                   offset: offset,
                                                   swap: commands.shouldSwap ? swap_load_command : nil)
            let cmdSize = Int(loadCommand.cmdsize)
            let commandEnd = offset + cmdSize
            guard cmdSize >= MemoryLayout<load_command>.size, commandEnd <= commandsData.count else {
                throw PlayCoverError.appCorrupted
            }
            if loadCommand.cmd == UInt32(LC_LOAD_DYLIB),
               cmdSize >= MemoryLayout<dylib_command>.size {
                let dylibCommand = commandsData.extract(dylib_command.self,
                                                        offset: offset,
                                                        swap: commands.shouldSwap ? swap_dylib_command : nil)
                let strOffset = Int(dylibCommand.dylib.name.offset)
                if strOffset >= MemoryLayout<dylib_command>.size && strOffset < cmdSize {
                    let name = commandsData[(offset + strOffset)..<commandEnd]
                    let end = name.firstIndex(of: 0) ?? name.endIndex
                    let dylibName = String(bytes: name[..<end], encoding: .utf8)
                    if dylibName == expectedDylib {
                        return true
                    }
                }
            }
            offset = commandEnd
        }
        return false
    }

    static func isInstalled() throws -> Bool {
        try FileManager.default.fileExists(atPath: playToolsPath.path)
            && FileManager.default.fileExists(atPath: akInterfacePath.path)
            && Macho.isMachoValidArch(playToolsPath, allowingUniversal: true)
    }

    // User plugins loading
    private static func userPluginsStore(bundleIdentifier: String) -> URL {
        playCoverContainer
            .appendingPathComponent("PlayTools")
            .appendingPathComponent("UserPlugins")
            .appendingPathComponent(bundleIdentifier)
    }

    static func userDylibs(bundleIdentifier: String) -> [URL] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: userPluginsStore(bundleIdentifier: bundleIdentifier), includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { $0.pathExtension == "dylib" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func addUserDylib(at sourceURL: URL, bundleIdentifier: String, appExecutable: URL) throws {
        let store = userPluginsStore(bundleIdentifier: bundleIdentifier)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)

        let canonical = store.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: canonical.path) {
            try FileManager.default.removeItem(at: canonical)
        }
        try FileManager.default.copyItem(at: sourceURL, to: canonical)

        do {
            // Validate & convert the plugin
            if try !Macho.isMachoValidArch(canonical) {
                try Macho.convertMacho(canonical)
            }
        } catch {
            try? FileManager.default.removeItem(at: canonical)
            throw PlayCoverError.invalidUserDylib
        }

        // Downloaded files carry a quarantine flag that blocks dlopen(); best-effort clear it.
        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-d", "com.apple.quarantine", canonical.path)

        try syncUserDylibs(bundleIdentifier: bundleIdentifier, into: appExecutable)
    }

    static func removeUserDylib(named name: String, bundleIdentifier: String, appExecutable: URL) throws {
        let canonical = userPluginsStore(bundleIdentifier: bundleIdentifier).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: canonical.path) {
            try FileManager.default.removeItem(at: canonical)
        }
        try syncUserDylibs(bundleIdentifier: bundleIdentifier, into: appExecutable)
    }

    // Resync
    static func syncUserDylibs(bundleIdentifier: String, into appExecutable: URL) throws {
        let targetDirectory = appExecutable.deletingLastPathComponent()
            .appendingPathComponent("Frameworks")
            .appendingPathComponent("UserPlugins")

        if FileManager.default.fileExists(atPath: targetDirectory.path) {
            try FileManager.default.removeItem(at: targetDirectory)
        }

        let dylibs = userDylibs(bundleIdentifier: bundleIdentifier)
        guard !dylibs.isEmpty else { return }

        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        for source in dylibs {
            let target = targetDirectory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: target)
            try target.fixExecutable()
            try Shell.signMacho(target)
        }
    }

	static func fetchEntitlements(_ exec: URL) throws -> String {
        do {
            return try Shell.run("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", exec.path)
        } catch {
            if error.localizedDescription.contains("Document is empty") {
                // Empty entitlements
                return ""
            } else if error.localizedDescription.contains("code object is not signed at all") {
                // IPA not signed
                return ""
            } else {
                throw error
            }
        }
	}

    static var proxyShieldPath: String {
        NSString(string: "~/Library/Frameworks/PlayTools.framework/ProxyShield.dylib").expandingTildeInPath
    }

    /// Removes a legacy `ProxyShield.dylib` entry from the app's `LSEnvironment`.
    /// The name is explicit because the function never installs anything: it only
    /// strips the outdated injection left behind by older PlayCover builds.
    @discardableResult
    static func removeLegacyProxyShield(for appURL: URL) -> Bool {
        let plistURL = appURL.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil),
              var plist = decoded as? [String: Any],
              var environment = plist["LSEnvironment"] as? [String: String],
              let dyldInsert = environment["DYLD_INSERT_LIBRARIES"] else {
            return false
        }

        let isProxyShield: (String) -> Bool = { entry in
            entry == proxyShieldPath || entry == "ProxyShield.dylib" || entry.hasSuffix("/ProxyShield.dylib")
        }

        let entries = dyldInsert.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        guard entries.contains(where: isProxyShield) else {
            return false
        }

        let remaining = entries.filter { !isProxyShield($0) }
        if remaining.isEmpty {
            environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        } else {
            environment["DYLD_INSERT_LIBRARIES"] = remaining.joined(separator: ":")
        }

        if environment.isEmpty {
            plist.removeValue(forKey: "LSEnvironment")
        } else {
            plist["LSEnvironment"] = environment
        }

        guard let output = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else {
            return false
        }

        do {
            try output.write(to: plistURL)
            return true
        } catch {
            return false
        }
    }
}
