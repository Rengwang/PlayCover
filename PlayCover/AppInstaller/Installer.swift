//
//  Installer.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 24.11.2021.
//

import Darwin
import Foundation

class Installer {

    static func installPlayToolsPopup() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.install.injectPlayToolsQuestion", comment: "")
        alert.informativeText = NSLocalizedString("alert.install.playToolsInformative", comment: "")

        alert.alertStyle = .informational

        alert.showsSuppressionButton = true
        alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "String")

        let yes = alert.addButton(withTitle: NSLocalizedString("button.Yes", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("button.No", comment: ""))

        // Set default button to install playtools
        yes.keyEquivalent = "\r"

        let response = alert.runModal()

        if alert.suppressionButton?.state == .on {
            InstallPreferences.shared.showInstallPopup = false
            InstallPreferences.shared.alwaysInstallPlayTools = response == .alertFirstButtonReturn
        }

        return response == .alertFirstButtonReturn
    }

    static private func returnErrorString(error: Error) -> String {
        switch error.localizedDescription {
        case let str where str.contains("(disk full?)"): NSLocalizedString("alert.notSpace", comment: "")
        case let str where str.contains(".html"): NSLocalizedString("alert.quota.limit", comment: "")
        case let str where str.contains(".ipa"): NSLocalizedString("alert.corrupted", comment: "")
        default: NSLocalizedString(error.localizedDescription, comment: "")
        }
    }

    // swiftlint:disable:next function_body_length
    static func install(ipaUrl: URL, export: Bool, returnCompletion: @escaping (URL?) -> Void) {
        // If (the option key is held or the install playtools popup settings is true) and its not an export,
        //    then show the installer dialog
        let installPlayTools: Bool
        let applicationType = InstallPreferences.shared.defaultAppType

        if (ModifierKeyObserver.shared.isOptionKeyPressed
                || InstallPreferences.shared.showInstallPopup) && !export {
            installPlayTools = installPlayToolsPopup()
        } else {
            installPlayTools = InstallPreferences.shared.alwaysInstallPlayTools
        }

        InstallVM.shared.next(.begin, 0.0, 0.0)

        Task(priority: .userInitiated) {
            let ipa = IPA(url: ipaUrl)
            defer { ipa.releaseTempDir() }

            do {
                InstallVM.shared.next(.unzip, 0.0, 0.5)
                if !export { try AppsVM.ensureBaseDirectoriesExist() }
                try ipa.allocateTempDir(near: export ? nil : AppsVM.appDirectory)

                let app = try ipa.unzip()
                if await ipa.checkOfficialMacOS(app: IPA.Application.base(app)) {
                    InstallVM.shared.next(.failed, 0.95, 1.0)
                    returnCompletion(nil)
                    return
                }
                InstallVM.shared.next(.library, 0.5, 0.55)
                let originalEntitlements = try Entitlements.dumpEntitlements(exec: app.executable)
                if export { try originalEntitlements.store(app.entitlements) }
                let machos = resolveValidMachOs(app)
                app.validMachOs = machos

                InstallVM.shared.next(.playtools, 0.55, 0.85)

                for macho in machos {
                    if try Macho.isMachoEncrypted(atURL: macho) {
                        if macho == app.executable {
                            throw PlayCoverError.appEncrypted
                        }
                        print("Skipping encrypted secondary Mach-O: \(macho.lastPathComponent)")
                        continue
                    }

                    if !export {
                        try Macho.convertMacho(macho, in: app.url)
                        try Shell.signMacho(macho)
                    }
                }

                if export {
                    try PlayTools.injectInIPA(app.executable, payload: app.url)
                } else if installPlayTools {
                    try await PlayTools.installInIPA(app.executable)
                }

                app.info.applicationCategoryType = applicationType

                if !export {
                    // -rwxr-xr-x
                    try app.executable.setBinaryPosixPermissions(0o755)
                    try removeMobileProvision(app)
                }

                let info = app.info
                info.assert(minimumVersion: 11.0)
                try info.write()
                InstallVM.shared.next(.wrapper, 0.85, 0.95)

                var finalURL: URL

                if export {
                    finalURL = try ipa.packIPABack(app: app.url)
                    try ipa.removeQuarantine(finalURL)
                } else {
                    try ipa.removeQuarantine(app.url)
                    finalURL = try installPreparedApp(app, hasPlayTools: installPlayTools,
                                                      originalEntitlements: originalEntitlements).url
                }

                InstallVM.shared.next(.finish, 0.95, 1.0)
                returnCompletion(finalURL)
            } catch {
                Log.shared.error(returnErrorString(error: error))
                InstallVM.shared.next(.failed, 0.95, 1.0)
                returnCompletion(nil)
            }
        }
    }

    static func fromIPA(detectingAppNameInFolder folderURL: URL) throws -> BaseApp {
        let contents = try FileManager.default.contentsOfDirectory(atPath: folderURL.path)

        var url: URL?

        for entry in contents {
            guard entry.hasSuffix(".app") else {
                continue
            }

            let entryURL = folderURL.appendingEscapedPathComponent(entry)
            var isDirectory: ObjCBool = false

            guard FileManager.default.fileExists(atPath: entryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            url = entryURL
            break
        }

        guard let url = url else {
            throw PlayCoverError.infoPlistNotFound
        }

        return BaseApp(appUrl: url)
    }

    private static let nonMachOExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "svg", "ico", "icns", "heic",
        "json", "plist", "strings", "stringsdict", "nib", "storyboardc", "car",
        "ttf", "otf", "ttc", "woff", "woff2",
        "mp3", "mp4", "m4a", "mov", "wav", "caf", "aiff", "ogg", "aac",
        "html", "htm", "css", "js", "map", "txt", "md", "xml", "yaml", "yml", "pdf",
        "zip", "gz", "tar", "br", "db", "sqlite", "sqlite3",
        "cer", "der", "pem", "crt", "p12", "mobileprovision",
        "metallib", "mom", "momd", "omo", "xcprivacy", "lproj",
        "pak", "bin", "dat", "svga", "pag", "lottie", "wasm",
        "h", "m", "swift", "modulemap"
    ]

    private static let validMachOMagics: Set<[UInt8]> = [
        [0xCA, 0xFE, 0xBA, 0xBE],
        [0xBE, 0xBA, 0xFE, 0xCA],
        [0xCA, 0xFE, 0xBA, 0xBF],
        [0xBF, 0xBA, 0xFE, 0xCA],
        [0xCF, 0xFA, 0xED, 0xFE],
        [0xFE, 0xED, 0xFA, 0xCF]
    ]

    private static func isValidMachOFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }

        defer {
            do {
                try handle.close()
            } catch {
                print("Failed to close FileHandle for \(url.absoluteString): \(error.localizedDescription)")
            }
        }

        guard let data = try? handle.read(upToCount: 4), data.count == 4 else {
            return false
        }

        return validMachOMagics.contains(Array(data))
    }

    /// Returns an array of URLs to MachO files within the app
    static func resolveValidMachOs(_ baseApp: BaseApp) -> [URL] {
        if let validMachOs = baseApp.validMachOs {
            return validMachOs
        }

        var resolved: [URL] = []
        var seen: Set<URL> = []
        let serialQueue = DispatchQueue(label: "baseAppUrlResolver")

        let executableURL = baseApp.executable
        if let execAttrs = try? executableURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           execAttrs.isRegularFile == true,
           let fileSize = execAttrs.fileSize,
           fileSize > 4,
           isValidMachOFile(executableURL) {
            seen.insert(executableURL.standardizedFileURL)
            resolved.append(executableURL)
        }

        baseApp.url.enumerateContents(descendingIntoPackages: ["framework"]) { url, attributes in
            guard attributes.isRegularFile == true, let fileSize = attributes.fileSize, fileSize > 4 else {
                return
            }

            if nonMachOExtensions.contains(url.pathExtension.lowercased()) {
                return
            }

            guard isValidMachOFile(url) else {
                return
            }

            serialQueue.sync {
                let standardized = url.standardizedFileURL
                if seen.insert(standardized).inserted {
                    resolved.append(url)
                }
            }
        }

        return resolved
    }

    static func removeMobileProvision(_ baseApp: BaseApp) throws {
        let provision = baseApp.url.appendingPathComponent("embedded.mobileprovision")
        if FileManager.default.fileExists(atPath: provision.path) {
            try FileManager.default.removeItem(at: provision)
        }
    }

    private static func installPreparedApp(_ baseApp: BaseApp, hasPlayTools: Bool,
                                           originalEntitlements: [String: Any]) throws -> PlayApp {
        let candidate = PlayApp(appUrl: baseApp.url)
        let info = candidate.info
        guard try Macho.isMachoValidArch(candidate.executable) else { throw PlayCoverError.appCorrupted }
        _ = try PlayTools.configureMarketplaceKitCompatibility(info, in: candidate.url)
        PlayTools.reportUnresolvedLaunchDependencies(info, in: candidate.url)
        if hasPlayTools {
            try info.enableMacResizingForLegacyPortraitApp()
        }

        // The entitlement record travels with the signed bundle during replacement.
        try originalEntitlements.store(candidate.bundledOriginalEntitlements)
        try candidate.signBundle()
        try Shell.run(print: false, "/usr/bin/codesign", "--verify", "--deep", "--strict", candidate.url.path)

        let location = AppsVM.appDirectory
            .appendingEscapedPathComponent(info.bundleIdentifier)
            .appendingPathExtension("app")
        let installedPath = location.resolvingSymlinksInPath().path + "/"
        if NSRunningApplication.runningApplications(withBundleIdentifier: info.bundleIdentifier).contains(where: {
            !$0.isTerminated && $0.executableURL?.resolvingSymlinksInPath().path.hasPrefix(installedPath) == true
        }) {
            throw PlayCoverError.appRunningDuringInstall
        }

        try publishBundle(candidate.url, at: location)
        let installed = PlayApp(appUrl: location)
        do {
            try originalEntitlements.store(installed.entitlements)
        } catch {
            Log.shared.log("Could not update the legacy entitlement record: \(error.localizedDescription)")
        }
        installed.removeAlias()
        installed.createAlias()
        return installed
    }

    /// Both paths are on the install volume. An old bundle stays live until the kernel commits the swap.
    private static func publishBundle(_ candidate: URL, at location: URL) throws {
        if renamex_np(candidate.path, location.path, UInt32(RENAME_EXCL)) == 0 { return }
        if errno == EEXIST && renamex_np(candidate.path, location.path, UInt32(RENAME_SWAP)) == 0 { return }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

extension Installer {
    static func installCLI(ipaUrl: URL) async throws -> PlayApp {
        let applicationType = InstallPreferences.shared.defaultAppType
        let ipa = IPA(url: ipaUrl)
        defer { ipa.releaseTempDir() }

        try AppsVM.ensureBaseDirectoriesExist()
        try ipa.allocateTempDir(near: AppsVM.appDirectory)
        let app = try ipa.unzip()

        // Skip interactive Mac App Store alert (checkOfficialMacOS) in headless CLI mode.
        let originalEntitlements = try Entitlements.dumpEntitlements(exec: app.executable)
        let machos = resolveValidMachOs(app)
        app.validMachOs = machos

        for macho in machos {
            if try Macho.isMachoEncrypted(atURL: macho) {
                if macho == app.executable {
                    throw PlayCoverError.appEncrypted
                }
                print("Skipping encrypted secondary Mach-O: \(macho.lastPathComponent)")
                continue
            }
            try Macho.convertMacho(macho, in: app.url)
            try Shell.signMacho(macho)
        }

        try await PlayTools.installInIPA(app.executable)
        app.info.applicationCategoryType = applicationType

        try app.executable.setBinaryPosixPermissions(0o755)
        try removeMobileProvision(app)

        let info = app.info
        info.assert(minimumVersion: 11.0)
        try info.write()

        let playChainDir = PlayTools.playCoverContainer.appendingPathComponent("PlayChain")
        try FileManager.default.createDirectory(at: playChainDir, withIntermediateDirectories: true)
        try ipa.removeQuarantine(app.url)
        let installedApp = try installPreparedApp(app, hasPlayTools: true, originalEntitlements: originalEntitlements)
        installedApp.settings.sync()
        return installedApp
    }
}
