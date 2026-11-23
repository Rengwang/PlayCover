// swiftlint:disable file_length
//
//  PlayApp.swift
//  PlayCover
//

import Cocoa
import Foundation
import IOKit.pwr_mgt
import Security

class PlayApp: BaseApp {
    // MARK: - Static
    public static let bundleIDCacheURL = PlayTools.playCoverContainer.appendingPathComponent("CACHE")

    public static var bundleIDCache: [String] {
        get throws {
            (try String(contentsOf: bundleIDCacheURL))
                .split(whereSeparator: \.isNewline)
                .map { String($0) }
        }
    }

    // MARK: - Instance State
    var displaySleepAssertionID: IOPMAssertionID?
    private var workspaceObservers: [NSObjectProtocol] = []
    public var isStarting = false
    var sessionDisableKeychain: Bool = false

    deinit {
        cleanupWorkspaceObservers()
        enableTimeOut()
    }

    // MARK: - Init
    override init(appUrl: URL) {
        super.init(appUrl: appUrl)
    }

    // MARK: - Computed
    var searchText: String {
        info.displayName.lowercased()
            .appending(" ")
            .appending(info.bundleName)
            .lowercased()
    }

    var name: String {
        info.displayName.isEmpty ? info.bundleName : info.displayName
    }

    // MARK: - Paths / Singletons
    static let aliasDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications")
        .appendingPathComponent("PlayCover")

    lazy var aliasURL = PlayApp.aliasDirectory.appendingPathComponent(name).appendingPathExtension("app")
    lazy var playChainURL = KeyCover.playChainPath.appendingPathComponent(info.bundleIdentifier)

    lazy var settings = AppSettings(info)
    lazy var keymapping = Keymapping(info)
    lazy var container = AppContainer(bundleId: info.bundleIdentifier)

    // MARK: - Launch
    func launch() async {
        do {
            isStarting = true
            defer { isStarting = false }

            if prohibitedToPlay {
                await clearAllCache()
                throw PlayCoverError.appProhibited
            } else if maliciousProhibited {
                await clearAllCache()
                deleteApp()
                throw PlayCoverError.appMaliciousProhibited
            }

            if await VersionCheck.shared.checkNewVersion(myApp: self) { return }

            settings.sync()

            // Remove legacy ProxyShield.dylib LSEnvironment entry if present.
            let cleanedProxyShield = PlayTools.removeLegacyProxyShield(for: url)

            // Auto-repair previously installed bundles whose Mach-O binaries were skipped
            // (e.g. executable names containing dots) and remain unconverted.
            let didRepairMacho = try await repairMachOsIfNeeded()
            let updatedMarketplaceKit = try PlayTools.configureMarketplaceKitCompatibility(info, in: url)

            // Install PlugIns/localizations before signing so the bundle is fully
            // assembled before its signature is sealed over its contents.
            // If the app does not have PlayTools, do not install PlugIns
            let playToolsInstalled = hasPlayTools()
            if playToolsInstalled {
                try PlayTools.installPluginInIPA(url, reusingInstalledFiles: true,
                                                 willChange: invalidatePlayToolsResourceSeal)
            }

            // Neutralize any __RESTRICT/__restrict segment in place so dyld allows
            // @rpath expansion and DYLD_INSERT_LIBRARIES on macOS even for previously
            // installed bundles.
            let strippedRestrict = (try? Macho.stripRestrictSegment(atURL: executable)) ?? false

            if try updatedMarketplaceKit || cleanedProxyShield || didRepairMacho || strippedRestrict
                || !Entitlements.areEntitlementsValid(app: self) {
                if playToolsInstalled {
                    try invalidatePlayToolsResourceSeal()
                }
                try signBundle()
            }

            if try !isInfoPlistSigned() {
                try Shell.signApp(executable)
            }

            if playToolsInstalled {
                try info.enableMacResizingForLegacyPortraitApp {
                    try Shell.signApp(self.executable)
                }
                try verifyPlayToolsResourceSealIfNeeded()
            }

            if !settings.openWithLLDB {
                PlayTools.reportUnresolvedLaunchDependencies(info, in: url)
            }

            // Wait for keychain unlock to finish before continuing
            await unlockKeyCover()

            if try !PlayTools.isInstalled() {
                Log.shared.error("PlayTools are not installed! Please move PlayCover.app into Applications!")
            } else if try !Macho.isMachoValidArch(executable) {
                Log.shared.error("The app threw an error during conversion.")
            } else {
                // Clear any debug-related env vars that could affect the launched app
                self.clearDebugAffectingEnvironment()

                if settings.openWithLLDB {
                    try Shell.lldb(executable, withTerminalWindow: settings.openLLDBWithTerminal)
                } else {
                    // Refresh the copied Info.plist only when its source changed.
                    ensureAliasIfNeeded()
                    loadDiscordIPC()

                    runAppExec() // Splitting to reduce complexity
                }
            }
        } catch {
            Log.shared.error(error)
        }
    }

    /// Converts unconverted Mach-O slices and applies the anti-tamper trap guard.
    /// The trap scan is cached per binary fingerprint so repeat launches do not
    /// re-read every Mach-O in the bundle.
    private func repairMachOsIfNeeded() async throws -> Bool {
        self.validMachOs = nil
        let machos = Installer.resolveValidMachOs(self)

        let cachedVersion = settings.settings.machoTrapSchemaVersion
        let cachedFingerprint = settings.settings.machoScanFingerprint
        let cachedFingerprintMatches = !cachedFingerprint.isEmpty
            && cachedFingerprint == machoScanFingerprint(for: machos)
        let scanNeeded = cachedVersion != Macho.trapSchemaVersion || !cachedFingerprintMatches

        // Every binary's path, size and modification date was checked above. An unchanged
        // successful scan needs no second pass over Mach-O headers or signature pages.
        guard scanNeeded else { return false }

        var needsBundleResign = false
        var convertedAny = false
        for macho in machos {
            if try Macho.isMachoEncrypted(atURL: macho) {
                if macho == executable {
                    throw PlayCoverError.appEncrypted
                }
                print("Skipping encrypted secondary Mach-O: \(macho.lastPathComponent)")
                continue
            }
            let needsConversion = try !Macho.isMachoValidArch(macho)
            let repairedLibraries: Bool
            if needsConversion {
                try Macho.convertMacho(macho, in: url)
                convertedAny = true
                repairedLibraries = false
            } else if scanNeeded {
                repairedLibraries = try Macho.repairSystemLibraryAliases(in: macho, app: url)
            } else {
                repairedLibraries = false
            }
            let restoredSDK = scanNeeded && macho == executable
                ? try Macho.restoreApplicationSDK(at: macho, sdkName: info[string: "DTSDKName"]) : false
            var patchedTraps = 0
            // A converted slice must always be rescanned, otherwise a fresh
            // conversion would skip the guard for this launch.
            if scanNeeded || needsConversion {
                patchedTraps = try Macho.neutralizeAntiTamperTraps(at: macho)
                if patchedTraps > 0 {
                    print("Neutralized \(patchedTraps) anti-tamper trap stub(s) in \(macho.lastPathComponent)")
                }
            }
            if needsConversion || repairedLibraries || restoredSDK || patchedTraps > 0 {
                try Shell.signMacho(macho)
                needsBundleResign = true
            }
        }

        if scanNeeded {
            // Fingerprint is taken after conversion/signing so the next launch sees
            // the same sizes and timestamps.
            var updated = settings.settings
            updated.machoTrapSchemaVersion = Macho.trapSchemaVersion
            updated.machoScanFingerprint = machoScanFingerprint(for: machos)
            if updated.machoTrapSchemaVersion != cachedVersion
                || updated.machoScanFingerprint != cachedFingerprint {
                settings.settings = updated
            }
        }

        guard needsBundleResign || convertedAny else { return false }

        try executable.setBinaryPosixPermissions(0o755)
        if !hasPlayTools() {
            try await PlayTools.installInIPA(executable)
        }
        return true
    }

    private func machoScanFingerprint(for machos: [URL]) -> String {
        let prefix = url.standardizedFileURL.path + "/"
        let entries = machos.map { macho in
            let path = macho.standardizedFileURL.path
            let relativePath = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(relativePath):\(size):\(modified)"
        }
        let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let sdkName = info[string: "DTSDKName"] ?? ""
        return (["libraries:\(Macho.libraryRepairSchemaVersion):\(systemVersion)", "sdk:1:\(sdkName)"] + entries.sorted())
            .joined(separator: "|")
    }
}

// MARK: - Environment Management
extension PlayApp {
    static let introspection: String = "/usr/lib/system/introspection"
    static let iosFrameworks: String = "/System/iOSSupport/System/Library/Frameworks"

    /// Common Metal and capture related environment keys used in multiple places
    private static let metalEnvKeys: [String] = [
        "METAL_DEVICE_WRAPPER_TYPE",
        "METAL_DEBUG_LAYER",
        "MTL_DEBUG_LAYER",
        "METAL_API_VALIDATION",
        "METAL_SHADER_VALIDATION",
        "METAL_SHADER_VALIDATION_OPTIONS",
        "METAL_CAPTURE_ENABLED",
        "METAL_CAPTURE_OUTPUT_FILE",
        "METAL_CAPTURE_TYPE",
        "METAL_FORCE_LAZY_COMPILATION",
        "METAL_FRAME_CAPTURE_ENABLED",
        "METAL_ERROR_MODE",
        "MTLCaptureEnabled"
    ]

    // clear environment variables that can force debug wrappers or validation layers
    func clearDebugAffectingEnvironment() {
        // Clear DYLD_* variables inherited from Xcode or other debuggers
        for (key, _) in ProcessInfo.processInfo.environment where key.hasPrefix("DYLD_") {
            unsetenv(key)
        }

        // Clear common Metal debug and capture related variables
        for key in PlayApp.metalEnvKeys {
            unsetenv(key)
        }
    }

    func runAppExec() {
        let config = NSWorkspace.OpenConfiguration()

        // Prevent propagating debugging-related variables to child process
        for (key, _) in ProcessInfo.processInfo.environment where key.hasPrefix("DYLD_") {
            unsetenv(key)
        }
        for key in PlayApp.metalEnvKeys {
            unsetenv(key)
        }

        NSWorkspace.shared.openApplication(
            at: aliasURL,
            configuration: config,
            completionHandler: { runningApp, error in
                if let error = error {
                    Log.shared.error(error)
                    return
                }
                let shouldPreventSleep = self.settings.settings.disableTimeout
                let shouldLockKeyCover = KeyCover.shared.isKeyCoverEnabled() || self.sessionDisableKeychain

                DispatchQueue.main.async {
                    self.observeRunningApp(
                        runningApp,
                        shouldPreventSleep: shouldPreventSleep,
                        shouldLockKeyCover: shouldLockKeyCover
                    )
                }
            }
        )
    }

    private func observeRunningApp(
        _ runningApp: NSRunningApplication?,
        shouldPreventSleep: Bool,
        shouldLockKeyCover: Bool
    ) {
        cleanupWorkspaceObservers()
        enableTimeOut()

        guard let runningApp = runningApp else {
            if shouldLockKeyCover {
                DispatchQueue.global(qos: .background).async { self.lockKeyCover() }
            }
            return
        }

        if runningApp.isTerminated {
            scheduleKeyCoverLockIfNeeded(shouldLockKeyCover)
            return
        }

        // When display-sleep prevention and KeyCover locking are both off,
        // install zero workspace observers and zero power assertions (0 wakeups/s).
        guard shouldPreventSleep || shouldLockKeyCover else { return }

        let pid = runningApp.processIdentifier
        let center = NSWorkspace.shared.notificationCenter

        if shouldPreventSleep {
            if runningApp.isActive {
                disableTimeOut()
            }
            workspaceObservers.append(
                addWorkspaceAppObserver(
                    center: center,
                    name: NSWorkspace.didActivateApplicationNotification,
                    pid: pid
                ) { [weak self] in self?.disableTimeOut() }
            )
            workspaceObservers.append(
                addWorkspaceAppObserver(
                    center: center,
                    name: NSWorkspace.didDeactivateApplicationNotification,
                    pid: pid
                ) { [weak self] in self?.enableTimeOut() }
            )
        }

        workspaceObservers.append(
            addWorkspaceAppObserver(
                center: center,
                name: NSWorkspace.didTerminateApplicationNotification,
                pid: pid
            ) { [weak self] in
                self?.handleObservedAppTerminated(shouldLockKeyCover: shouldLockKeyCover)
            }
        )

        // Close the race window if the app already exited before observers attached.
        if runningApp.isTerminated {
            handleObservedAppTerminated(shouldLockKeyCover: shouldLockKeyCover)
        }
    }

    private func addWorkspaceAppObserver(
        center: NotificationCenter,
        name: NSNotification.Name,
        pid: pid_t,
        handler: @escaping () -> Void
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier == pid else { return }
            handler()
        }
    }

    private func handleObservedAppTerminated(shouldLockKeyCover: Bool) {
        enableTimeOut()
        cleanupWorkspaceObservers()
        scheduleKeyCoverLockIfNeeded(shouldLockKeyCover)
    }

    private func scheduleKeyCoverLockIfNeeded(_ shouldLockKeyCover: Bool) {
        guard shouldLockKeyCover else { return }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
            self.lockKeyCover()
        }
    }
}

// MARK: - Management
extension PlayApp {
    private func cleanupWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    func disableTimeOut() {
        guard settings.settings.disableTimeout else { return }
        if displaySleepAssertionID != nil { return }

        let reason = "PlayCover: \(info.bundleIdentifier) is disabling sleep" as CFString
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )
        if result == kIOReturnSuccess {
            displaySleepAssertionID = assertionID
        }
    }

    func enableTimeOut() {
        if let assertionID = displaySleepAssertionID {
            IOPMAssertionRelease(assertionID)
            displaySleepAssertionID = nil
        }
    }
}

// MARK: - KeyCover
extension PlayApp {
    func unlockKeyCover() async {
        if KeyCover.shared.isKeyCoverEnabled() {
            await KeyCover.prepareManagedPassword()
            let keychain = KeyCover.shared.listKeychains()
                .first(where: { $0.appBundleID == self.info.bundleIdentifier })

            if let keychain = keychain, keychain.chainEncryptionStatus {
                try? await KeyCover.shared.unlockChain(keychain)

                if KeyCover.shared.keyCoverPlainTextKey == nil {
                    // Pop an alert telling the user that keychain was not unlocked
                    // and keychain is disabled for the session
                    Task { @MainActor in
                        let alert = NSAlert()
                        alert.messageText = NSLocalizedString("keycover.alert.title", comment: "")
                        alert.informativeText = NSLocalizedString("keycover.alert.content", comment: "")
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
                        alert.runModal()
                    }
                    settings.settings.playChain = false
                    sessionDisableKeychain = true
                }
            }
        }
    }

    func lockKeyCover() {
        if KeyCover.shared.isKeyCoverEnabled() {
            if sessionDisableKeychain {
                settings.settings.playChain = true
                sessionDisableKeychain = false
                return
            }

            let keychain = KeyCover.shared.listKeychains()
                .first(where: { $0.appBundleID == self.info.bundleIdentifier })

            if let keychain = keychain, !keychain.chainEncryptionStatus {
                try? KeyCover.shared.lockChain(keychain)
            }
        }
    }
}

// MARK: - Tools
extension PlayApp {
    func hasPlayTools() -> Bool {
        do {
            return try PlayTools.installedInExec(atURL: url.appendingEscapedPathComponent(info.executableName))
        } catch {
            Log.shared.error(error)
            return true
        }
    }

    func changeDyldLibraryPath(set: Bool? = nil, path: String) async -> Bool {
        info.lsEnvironment["DYLD_LIBRARY_PATH"] = info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""

        if let set = set {
            if set {
                info.lsEnvironment["DYLD_LIBRARY_PATH"]? += "\(path):"
            } else {
                info.lsEnvironment["DYLD_LIBRARY_PATH"] = info.lsEnvironment["DYLD_LIBRARY_PATH"]?
                    .replacingOccurrences(of: "\(path):", with: "")
            }

            do {
                try Shell.signApp(executable)
            } catch {
                Log.shared.error(error)
            }
        }

        guard let result = info.lsEnvironment["DYLD_LIBRARY_PATH"] else {
            return false
        }
        return result.contains(path)
    }
}

// MARK: - FS / Codesign
extension PlayApp {
    func hasAlias() -> Bool {
        FileManager.default.fileExists(atPath: aliasURL.path)
    }

    // Existing installs verify once. Invalidate the receipt before resource mutations so
    // an interrupted update still verifies and repairs the outer seal on the next launch.
    private var playToolsResourceSealReceipt: URL {
        settings.settingsUrl.deletingPathExtension().appendingPathExtension("playtools-seal-v1")
    }

    private func invalidatePlayToolsResourceSeal() throws {
        let receipt = playToolsResourceSealReceipt
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        try FileManager.default.removeItem(at: receipt)
    }

    private func verifyPlayToolsResourceSealIfNeeded() throws {
        let receipt = playToolsResourceSealReceipt
        guard !FileManager.default.fileExists(atPath: receipt.path) else { return }
        let verify = { try Shell.run(print: false, "/usr/bin/codesign", "--verify", "--strict", self.url.path) }
        do {
            _ = try verify()
        } catch {
            try signBundle()
            _ = try verify()
        }
        try Data().write(to: receipt, options: .atomic)
    }

    func isInfoPlistSigned() throws -> Bool {
        if let information = Entitlements.signingInformation(exec: executable) {
            return information[kSecCodeInfoPList as String] != nil
        }
        return try Shell.run("/usr/bin/codesign", "-dv", executable.path).contains("Info.plist entries")
    }

    func showInFinder() {
        URL(fileURLWithPath: url.path).showInFinderAndSelectLastComponent()
    }

    func openAppCache() {
        container.containerUrl.showInFinderAndSelectLastComponent()
    }

    func clearAllCache() async {
        Uninstaller.clearExternalCache(info.bundleIdentifier)
    }

    func clearPlayChain() {
        FileManager.default.delete(at: playChainURL)
        FileManager.default.delete(at: playChainURL.appendingPathExtension("keyCover"))
        FileManager.default.delete(at: playChainURL.appendingPathExtension("db"))
    }

    func deleteApp() {
        FileManager.default.delete(at: URL(fileURLWithPath: url.path))
        AppsVM.shared.fetchApps()
    }

    func signBundle() throws {
        let tmpEnts = FileManager.default.temporaryDirectory
            .appendingEscapedPathComponent(ProcessInfo().globallyUniqueString)
            .appendingPathExtension("plist")
        defer { try? FileManager.default.removeItem(at: tmpEnts) }
        let conf = try Entitlements.composeEntitlements(self)
        try conf.store(tmpEnts)
        try Shell.signAppWith(executable, entitlements: tmpEnts)
    }
}

// MARK: - Policies
extension PlayApp {
    var prohibitedToPlay: Bool {
        PlayApp.PROHIBITED_APPS.contains(info.bundleIdentifier)
    }

    var maliciousProhibited: Bool {
        PlayApp.MALICIOUS_APPS.contains(info.bundleIdentifier)
    }

    static let PROHIBITED_APPS = [
        "com.activision.callofduty.shooter",
        "com.ea.ios.apexlegendsmobilefps",
        "com.tencent.tmgp.cod",
        "com.tencent.ig",
        "com.pubg.newstate",
        "com.pubg.imobile",
        "com.tencent.tmgp.pubgmhd",
        "com.dts.freefireth",
        "com.dts.freefiremax",
        "vn.vng.codmvn",
        "com.ngame.allstar.eu",
        "com.axlebolt.standoff2",
        "com.tencent.lolm"
    ]

    static let MALICIOUS_APPS = [
        "com.zhiliaoapp.musically"
    ]
}
