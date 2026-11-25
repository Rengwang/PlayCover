//
//  Uninstaller.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 9/26/22.
//

import SwiftUI

struct CheckBoxHelper {
    var view: NSView
    var button: NSButton
    var buttonvar: String
}

class Uninstaller {
    private enum AppDataError: Error {
        case invalidBundleIdentifier
        case itemStillExists(URL)
    }

    private static let libraryUrl = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
    private static let pruneURLs: [URL] = [
        PlayTools.playCoverContainer.appendingPathComponent("App Settings"),
        PlayTools.playCoverContainer.appendingPathComponent("Entitlements"),
        PlayTools.playCoverContainer.appendingPathComponent("Keymapping"),
        PlayTools.playCoverContainer.appendingPathComponent("PlayChain")
    ]
    private static let cacheURLs: [URL] = [
        Uninstaller.libraryUrl.appendingPathComponent("Containers"),
        Uninstaller.libraryUrl.appendingPathComponent("Application Scripts"),
        Uninstaller.libraryUrl.appendingPathComponent("Caches"),
        Uninstaller.libraryUrl.appendingPathComponent("HTTPStorages"),
        Uninstaller.libraryUrl.appendingPathComponent("Saved Application State")
    ]

    private static func createButtonView(_ yaxis: CGFloat, _ text: String, _ varname: String) -> CheckBoxHelper {
        let button = NSButton(checkboxWithTitle: text, target: self, action: nil)

        if UninstallPreferences.shared.value(forKey: varname) as? Bool ?? true {
            button.animator().setNextState()
        }

        let view = NSView(frame: NSRect(x: 0, y: yaxis,
                                        width: button.fittingSize.width,
                                        height: button.fittingSize.height))

        view.addSubview(button)

        return CheckBoxHelper(view: view, button: button, buttonvar: varname)
    }

    @MainActor
    static func uninstallPopup(_ app: PlayApp) async {
        if UninstallPreferences.shared.showUninstallPopup {
            let boxmakers: [(String, String)] = [
                ("removePlayChain", NSLocalizedString("preferences.toggle.removePlayChain", comment: "")),
                ("removeAppEntitlements", NSLocalizedString("preferences.toggle.removeEntitlements", comment: "")),
                ("removeAppSettings", NSLocalizedString("preferences.toggle.removeSetting", comment: "")),
                ("removeAppKeymap", NSLocalizedString("preferences.toggle.removeKeymap", comment: "")),
                ("clearAppData", NSLocalizedString("preferences.toggle.clearAppData", comment: ""))
            ]

            var checkboxes: [CheckBoxHelper] = []

            var viewY = 0.0

            for (buttonvar, buttontitle) in boxmakers {
                checkboxes.append(createButtonView(viewY, buttontitle, buttonvar))
                viewY += checkboxes[checkboxes.count - 1].view.frame.height
            }

            let viewWidth = checkboxes.max(by: { $0.view.frame.width < $1.view.frame.width })?.view.frame.width

            let settingsView = NSStackView(frame: NSRect(x: 0, y: 0, width: viewWidth ?? 0, height: viewY))

            for checkboxhelper in checkboxes {
                settingsView.addSubview(checkboxhelper.view)
            }

            let alert = NSAlert()
            alert.messageText = NSLocalizedString("playapp.delete", comment: "")
            alert.informativeText = String(format: NSLocalizedString("playapp.deleteMessage",
                                                                     comment: ""),
                                           arguments: [app.name])

            alert.alertStyle = .warning
            alert.accessoryView = settingsView

            let delete = alert.addButton(withTitle: NSLocalizedString("playapp.deleteConfirm", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

            alert.showsSuppressionButton = true
            alert.suppressionButton?.toolTip = NSLocalizedString("alert.supression", comment: "")

            delete.hasDestructiveAction = true

            NSApplication.shared.requestUserAttention(.criticalRequest)
            guard let window = NSApplication.shared.windows.first,
                  await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            for checkboxhelper in checkboxes {
                UninstallPreferences.shared.setValue(checkboxhelper.button.state == .on,
                                                     forKey: checkboxhelper.buttonvar)
            }

            if alert.suppressionButton?.state == .on {
                UninstallPreferences.shared.showUninstallPopup = false
            }

            await uninstall(app, in: window)
        } else {
            guard let window = NSApplication.shared.windows.first else { return }
            await uninstall(app, in: window)
        }
    }

    @MainActor
    private static func uninstall(_ app: PlayApp, in window: NSWindow) async {
        var uninstallNum = 0

        if UninstallPreferences.shared.clearAppData {
            guard await clearAppData(of: app, in: window) else { return }
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removeAppKeymap {
            FileManager.default.delete(at: app.keymapping.baseKeymapURL)
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removeAppSettings {
            FileManager.default.delete(at: app.settings.settingsUrl)
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removeAppEntitlements {
            FileManager.default.delete(at: app.entitlements)
            uninstallNum += 1
        }

        if UninstallPreferences.shared.removePlayChain {
            let url = KeyCover.playChainPath.appendingPathComponent(app.info.bundleIdentifier)
            FileManager.default.delete(at: url)

            // KeyCover encrypted chain
            let keyCoverURL = url.appendingPathExtension("keyCover")
            FileManager.default.delete(at: keyCoverURL)
            uninstallNum += 1
        }

        app.removeAlias()
        app.deleteApp()

        if uninstallNum >= 5 {
            do {
                let apps = (try PlayApp.bundleIDCache).filter({ $0 != app.info.bundleIdentifier })
                    .joined(separator: "\n") + "\n"
                try apps.write(to: PlayApp.bundleIDCacheURL, atomically: false, encoding: .utf8)
            } catch {
                Log.shared.error(error)
            }
        }
    }

    @MainActor
    static func clearCachePopup(_ app: PlayApp) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("alert.app.delete", comment: "")
        alert.alertStyle = .warning

        let proceed = alert.addButton(withTitle: NSLocalizedString("button.Proceed", comment: ""))
        proceed.hasDestructiveAction = true
        alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))

        NSApplication.shared.requestUserAttention(.criticalRequest)
        guard let window = NSApplication.shared.windows.first,
              await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }

        _ = await clearAppData(of: app, in: window)
    }

    @MainActor
    private static func clearAppData(of app: PlayApp, in window: NSWindow) async -> Bool {
        guard !app.isClearingData else { return false }
        let bundleId = app.info.bundleIdentifier
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard !app.isStarting, !runningApps.contains(where: { !$0.isTerminated }) else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("alert.appData.quitFirst", comment: "")
            alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
            _ = await alert.beginSheetModal(for: window)
            return false
        }

        app.isClearingData = true
        defer { app.isClearingData = false }
        do {
            try await Task.detached(priority: .userInitiated) {
                try clearExternalCache(bundleId, requestContainerAccess: true)
            }.value
            return true
        } catch {
            await showClearAppDataError(error, in: window)
            return false
        }
    }

    @MainActor
    private static func showClearAppDataError(_ error: Error, in window: NSWindow) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("alert.appData.failed", comment: "")
        if isPermissionError(error) {
            alert.informativeText = NSLocalizedString("alert.appData.permission", comment: "")
            alert.addButton(withTitle: NSLocalizedString("alert.appData.openSettings", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("button.Cancel", comment: ""))
            if await alert.beginSheetModal(for: window) == .alertFirstButtonReturn,
               let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(settings)
            }
            return
        }
        if case AppDataError.itemStillExists(let url) = error {
            let format = NSLocalizedString("alert.appData.stillExists", comment: "")
            alert.informativeText = String(format: format, url.path)
        } else {
            alert.informativeText = error.localizedDescription
        }
        alert.addButton(withTitle: NSLocalizedString("button.OK", comment: ""))
        _ = await alert.beginSheetModal(for: window)
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSCocoaErrorDomain, NSFileReadNoPermissionError),
             (NSCocoaErrorDomain, NSFileWriteNoPermissionError),
             (NSPOSIXErrorDomain, Int(EPERM)),
             (NSPOSIXErrorDomain, Int(EACCES)),
             (NSOSStatusErrorDomain, -5000):
            return true
        default:
            guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
            return isPermissionError(underlying)
        }
    }

    static func clearExternalCache(_ bundleId: String, requestContainerAccess: Bool = false) throws {
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard !bundleId.isEmpty, !bundleId.hasPrefix("."),
              bundleId.unicodeScalars.allSatisfy(allowedCharacters.contains),
              bundleId.caseInsensitiveCompare("io.playcover.PlayCover") != .orderedSame,
              bundleId.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") != .orderedSame else {
            throw AppDataError.invalidBundleIdentifier
        }

        let container = AppContainer(bundleId: bundleId).containerUrl
        let data = container.appendingPathComponent("Data", isDirectory: true)
        let canAccessData: Bool
        if requestContainerAccess,
           try itemAttributes(at: container)?[.type] as? FileAttributeType == .typeDirectory,
           try itemAttributes(at: data)?[.type] as? FileAttributeType == .typeDirectory {
            // Open the selected container directly so macOS can request access before it is trashed.
            _ = try FileManager.default.contentsOfDirectory(atPath: data.path)
            canAccessData = true
        } else {
            canAccessData = false
        }

        do {
            try trashAppDataItem(container)
        } catch where canAccessData && isPermissionError(error) {
            // The container's system metadata can be protected even when its Data directory is accessible.
            try trashAppDataItem(data)
        }

        let items = cacheURLs.dropFirst().map { $0.appendingPathComponent(bundleId) } + [
            libraryUrl.appendingPathComponent("HTTPStorages").appendingPathComponent(bundleId + ".binarycookies"),
            libraryUrl.appendingPathComponent("Saved Application State").appendingPathComponent(bundleId + ".savedState")
        ]
        for item in items {
            try trashAppDataItem(item)
        }
    }

    private static func trashAppDataItem(_ url: URL) throws {
        guard try itemAttributes(at: url) != nil else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        guard try itemAttributes(at: url) == nil else { throw AppDataError.itemStillExists(url) }
    }

    private static func itemAttributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do {
            return try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) {
                return nil
            }
            throw error
        }
    }

    static func pruneFiles() {
        do {
            let bundleIds = AppsVM.shared.apps.map { $0.info.bundleIdentifier }
            let danglingItems = try PlayApp.bundleIDCache.filter { !bundleIds.contains($0) }

            var fullPruneURLs = pruneURLs
            fullPruneURLs.append(contentsOf: cacheURLs)

            var prunedIds: [String] = []

            for url in fullPruneURLs {
                url.enumerateContents(options: [.skipsSubdirectoryDescendants]) { file, _ in
                    let bundleId = file.deletingPathExtension().lastPathComponent
                    if danglingItems.contains(bundleId) {
                        try FileManager.default.trashItem(at: file, resultingItemURL: nil)
                        prunedIds.append(bundleId)
                    }
                }
            }

            try "\(PlayApp.bundleIDCache.filter({ !Set(prunedIds).contains($0) }).joined(separator: "\n"))\n"
                .write(to: PlayApp.bundleIDCacheURL, atomically: false, encoding: .utf8)
        } catch {
            Log.shared.error(error)
        }
    }
}
