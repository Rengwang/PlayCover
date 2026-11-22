//
//  PlayAppExtensions.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 10/2/23.
//

import Foundation

extension PlayApp {
    func loadDiscordIPC() {
        if self.container.doesExist() {
            let appTmp = self.container.containerUrl.appendingPathComponent("Data")
                .appendingPathComponent("tmp")

            try? FileManager.default.createDirectory(at: appTmp, withIntermediateDirectories: false)

            appTmp.enumerateContents { url, _ in
                if url.lastPathComponent.range(of: "discord-ipc-[0-9]", options: .regularExpression) != nil {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch {
                        print("failed to remove discord ipc: \(error)")
                    }
                }
            }

            guard self.settings.settings.discordActivity.enable else {
                return
            }

            let userTmp = FileManager.default.temporaryDirectory.path

            for ipcPort in 0..<10 {
                let socketPath = userTmp + "/discord-ipc-\(ipcPort)"
                if FileManager.default.fileExists(atPath: socketPath) {
                    do {
                        try FileManager.default.createSymbolicLink(atPath: appTmp
                            .appendingPathComponent("discord-ipc-\(ipcPort)").path,
                                                                   withDestinationPath: socketPath)
                        print("Successfully linked discordipc for \(self.info.bundleIdentifier)")
                        return
                    } catch {
                        print(error)
                        continue
                    }
                }
            }

            print("Unable to link discordipc for \(self.info.bundleIdentifier)")
        }
    }

    func createAlias() {
        do {
            try FileManager.default.createDirectory(atPath: aliasURL.path,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            url.enumerateContents(options: [.skipsSubdirectoryDescendants]) { ctxUrl, _ in
                let aliasItem = self.aliasURL.appendingPathComponent(ctxUrl.lastPathComponent)

                // LaunchServices on macOS 27 will not open the alias while Info.plist is a
                // symlink: it fails with -54 (permErr) and the user sees "does not have
                // permission to open (null)". Use a real copy and refresh it after signing.
                if ctxUrl.lastPathComponent == "Info.plist" {
                    try FileManager.default.copyItem(at: ctxUrl, to: aliasItem)
                } else {
                    try FileManager.default.createSymbolicLink(at: aliasItem,
                                                               withDestinationURL: ctxUrl)
                }
            }
        } catch {
            Log.shared.log(error.localizedDescription)
        }
    }

    func removeAlias() {
        FileManager.default.delete(at: aliasURL)
    }

    func ensureAliasIfNeeded() {
        let fileManager = FileManager.default
        let aliasInfo = aliasURL.appendingPathComponent("Info.plist")
        let srcInfo = url.appendingPathComponent("Info.plist")
        let aliasExec = aliasURL.appendingPathComponent(info.executableName)
        let srcExec = url.appendingPathComponent(info.executableName)

        let resourceKeys: Set<URLResourceKey> = [
            .isSymbolicLinkKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        if fileManager.fileExists(atPath: aliasURL.path),
           fileManager.fileExists(atPath: aliasInfo.path),
           fileManager.fileExists(atPath: srcInfo.path),
           let aliasInfoValues = try? aliasInfo.resourceValues(forKeys: resourceKeys),
           let srcInfoValues = try? srcInfo.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
           aliasInfoValues.isSymbolicLink == false,
           let aliasSize = aliasInfoValues.fileSize,
           let srcSize = srcInfoValues.fileSize,
           aliasSize == srcSize,
           let aliasDate = aliasInfoValues.contentModificationDate,
           let srcDate = srcInfoValues.contentModificationDate,
           aliasDate >= srcDate,
           !info.executableName.isEmpty,
           let execDest = try? fileManager.destinationOfSymbolicLink(atPath: aliasExec.path) {
            let resolvedDest = URL(fileURLWithPath: execDest, relativeTo: aliasURL)
                .standardizedFileURL.path
            if resolvedDest == srcExec.standardizedFileURL.path,
               fileManager.fileExists(atPath: aliasExec.path) {
                return
            }
        }

        removeAlias()
        createAlias()
    }
}
