//
//  KeyCover.swift
//  PlayCover
//
//  Created by Venti on 31/01/2023.
//

import Foundation
import CryptoKit
import SwiftUI
import Security

struct KeyCover {
    static var shared = KeyCover()
    static var playChainPath: URL {
        let playChainDir = PlayTools.playCoverContainer.appendingPathComponent("PlayChain")

        if !FileManager.default.fileExists(atPath: playChainDir.path) {
            do {
                try FileManager.default.createDirectory(at: playChainDir, withIntermediateDirectories: true)
            } catch {
                Log.shared.error(error)
            }
        }

        return playChainDir
    }

    private var passwordGeneration = UUID()
    var keyCoverPlainTextKey: String? {
        didSet { passwordGeneration = UUID() }
    }

    @MainActor private static var managedPasswordLookup: Task<Bool, Never>?
    @MainActor private static var managedPasswordAttemptedGeneration: UUID?
    @MainActor private static var managedPasswordMissing = false

    /// Share one automatic authorization attempt across app launches. KeyCover settings can retry.
    @discardableResult
    @MainActor
    static func prepareManagedPassword(retry: Bool = false) async -> Bool {
        guard KeyCoverPreferences.shared.keyCoverEnabled == .selfGeneratedPassword,
              shared.keyCoverPlainTextKey == nil else { return false }
        if let pending = managedPasswordLookup {
            return await pending.value
        }
        let generation = shared.passwordGeneration
        if !retry, managedPasswordAttemptedGeneration == generation {
            return managedPasswordMissing
        }
        let lookup = Task { @MainActor () -> Bool in
            defer { managedPasswordLookup = nil }
            let result: (password: String?, status: OSStatus) = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: KeyCoverPassword.shared.readKeyCoverPassword())
                }
            }
            guard KeyCoverPreferences.shared.keyCoverEnabled == .selfGeneratedPassword,
                  shared.passwordGeneration == generation else { return false }
            managedPasswordAttemptedGeneration = generation
            managedPasswordMissing = result.status == errSecItemNotFound
            if let password = result.password {
                shared.keyCoverPlainTextKey = password
                KeyCoverObservable.shared.update()
            }
            return managedPasswordMissing
        }
        managedPasswordLookup = lookup
        return await lookup.value
    }

    func isKeyCoverEnabled() -> Bool {
        return KeyCoverPreferences.shared.keyCoverEnabled != .disabled
    }

    func listKeychains() -> [KeyCoverKey] {
        // Enumerate all the keychains without creating duplicates from SQLite WAL/SHM sidecars.
        let keychains = try? FileManager.default
            .contentsOfDirectory(at: KeyCover.playChainPath,
                                 includingPropertiesForKeys: nil,
                                 options: .skipsHiddenFiles)
        var seen: Set<String> = []
        var keychainList: [KeyCoverKey] = []
        for keychain in keychains ?? [] {
            let ext = keychain.pathExtension
            guard ext == "db" || ext == KeyCoverKey.encryptedKeyExtension else { continue }
            let keychainName = keychain.deletingPathExtension().lastPathComponent
            guard seen.insert(keychainName).inserted else { continue }
            keychainList.append(KeyCoverKey(appBundleID: keychainName))
        }
        return keychainList
    }

    func unlockedCount() -> Int {
        var count = 0
        for keychain in listKeychains() where !keychain.chainEncryptionStatus {
            count += 1
        }
        return count
    }

    func unlockChain(_ keychain: KeyCoverKey) async throws {
        if keyCoverPlainTextKey == nil {
            // A managed password is supplied by the system keychain. Its denial
            // cannot be resolved by asking the user to type that generated password.
            guard KeyCoverPreferences.shared.keyCoverEnabled == .userProvidedPassword else { return }
            await MainActor.run {
                KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown = true
            }
            while await MainActor.run(body: { KeyCoverObservable.shared.isKeyCoverUnlockingPromptShown }) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        if keychain.chainEncryptionStatus {
            try keychain.decryptKeyDB()
        }
    }

    func lockChain(_ keychain: KeyCoverKey) throws {
        if keyCoverPlainTextKey == nil {
            return
        }
        if !keychain.chainEncryptionStatus {
            try keychain.encryptKeyDB()
        }
    }

    func lockAllChainsAsync() {
        Task {
            await KeyCover.prepareManagedPassword(retry: true)
            for keychain in KeyCover.shared.listKeychains() where !keychain.chainEncryptionStatus {
                try? keychain.encryptKeyDB()
            }
        }
    }
}

class KeyCoverObservable: ObservableObject {
    static var shared = KeyCoverObservable()

    @Published var keyCoverEnabled = KeyCover.shared.isKeyCoverEnabled()
    @Published var managedPasswordReady = KeyCover.shared.keyCoverPlainTextKey != nil
    @Published var unlockedCount = KeyCover.shared.unlockedCount()
    @Published var keychains = KeyCover.shared.listKeychains()

    @Published var isKeyCoverUnlockingPromptShown = KeyCoverPreferences.shared.keyCoverEnabled == .selfGeneratedPassword
    ? false : KeyCoverPreferences.shared.keyCoverEnabled == .disabled
    ? false : KeyCoverPreferences.shared.promptForKeyCoverPasswordAtLaunch

    func update() {
        keyCoverEnabled = KeyCover.shared.isKeyCoverEnabled()
        managedPasswordReady = KeyCover.shared.keyCoverPlainTextKey != nil
        unlockedCount = KeyCover.shared.unlockedCount()
        keychains = KeyCover.shared.listKeychains()
    }
}

struct KeyCoverKey {
    static let encryptedKeyExtension = "keyCover"

    var appBundleID: String

    var decryptedKeyDB: URL {
        KeyCover.playChainPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension("db")
    }
    private var decryptedKeyDBWAL: URL {
        URL(fileURLWithPath: decryptedKeyDB.path + "-wal")
    }
    private var decryptedKeyDBSHM: URL {
        URL(fileURLWithPath: decryptedKeyDB.path + "-shm")
    }
    var encryptedKeyDB: URL {
        KeyCover.playChainPath
            .appendingPathComponent(appBundleID)
            .appendingPathExtension(KeyCoverKey.encryptedKeyExtension)
    }

    var chainEncryptionStatus: Bool {
        return FileManager.default.fileExists(atPath: encryptedKeyDB.path)
    }

    func encryptKeyDB() throws {
        if let plainTextKey = KeyCover.shared.keyCoverPlainTextKey {
            guard FileManager.default.fileExists(atPath: decryptedKeyDB.path) else { return }
            checkpointWALIfPresent()

            let stagedURL = URL(fileURLWithPath: encryptedKeyDB.path + ".tmp")
            try? FileManager.default.removeItem(at: stagedURL)
            let task = Process()
            task.launchPath = "/usr/bin/openssl"
            task.currentDirectoryPath = KeyCover.playChainPath.path
            task.arguments = ["enc", "-aes-256-cbc", "-A",
                                "-in", decryptedKeyDB.path,
                                "-out", stagedURL.path,
                                "-k", plainTextKey]
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: stagedURL)
                throw CocoaError(.fileWriteUnknown)
            }
            if FileManager.default.fileExists(atPath: encryptedKeyDB.path) {
                _ = try FileManager.default.replaceItemAt(encryptedKeyDB, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: encryptedKeyDB)
            }

            // Delete the decrypted db and its checkpointed WAL/SHM sidecars.
            try deleteKeyDB()

            Task { @MainActor in
                KeyCoverObservable.shared.update()
            }
        }
    }

    func decryptKeyDB() throws {
        if let plainTextKey = KeyCover.shared.keyCoverPlainTextKey {
            guard FileManager.default.fileExists(atPath: encryptedKeyDB.path) else { return }
            let hadPlainDB = FileManager.default.fileExists(atPath: decryptedKeyDB.path)
            let stagedURL = URL(fileURLWithPath: decryptedKeyDB.path + ".tmp")
            try? FileManager.default.removeItem(at: stagedURL)

            let task = Process()
            task.launchPath = "/usr/bin/openssl"
            task.arguments = ["enc", "-aes-256-cbc", "-A", "-d", "-in", encryptedKeyDB.path, "-out",
                              stagedURL.path,
                              "-k", plainTextKey]
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else {
                try? FileManager.default.removeItem(at: stagedURL)
                throw CocoaError(.fileReadUnknown)
            }

            if !hadPlainDB {
                try? FileManager.default.removeItem(at: decryptedKeyDBWAL)
                try? FileManager.default.removeItem(at: decryptedKeyDBSHM)
                try FileManager.default.moveItem(at: stagedURL, to: decryptedKeyDB)
            } else {
                try? FileManager.default.removeItem(at: stagedURL)
            }

            // Delete the encrypted key file only after decryption succeeds.
            try FileManager.default.removeItem(at: encryptedKeyDB)

            Task { @MainActor in
                KeyCoverObservable.shared.update()
            }
        }
    }

    private func checkpointWALIfPresent() {
        guard FileManager.default.fileExists(atPath: decryptedKeyDBWAL.path) else { return }
        let task = Process()
        task.launchPath = "/usr/bin/sqlite3"
        task.arguments = [decryptedKeyDB.path, "PRAGMA busy_timeout=1000; PRAGMA wal_checkpoint(TRUNCATE);"]
        try? task.run()
        task.waitUntilExit()
    }

    func deleteKeyDB() throws {
        try FileManager.default.removeItem(at: decryptedKeyDB)
        try? FileManager.default.removeItem(at: decryptedKeyDBWAL)
        try? FileManager.default.removeItem(at: decryptedKeyDBSHM)
    }

    func deleteEncryptedKeyDB() throws {
        try FileManager.default.removeItem(at: encryptedKeyDB)
    }
}

class KeyCoverPassword {
    static let shared = KeyCoverPassword()

    let tag = "io.playcover.masterkey"

    func setKeyCoverPassword(_ key: String) {
        // swiftlint: disable force_unwrapping
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecValueData as String: key.data(using: .utf8)!]
        // swiftlint: enable force_unwrapping
        // thank you apple very cool
        // Get the key
        let oldKey = getKeyCoverPassword()
        // if it is not nil, then we need to decrypt all the keychains
        if oldKey != nil {
            KeyCover.shared.keyCoverPlainTextKey = oldKey
            for keychain in KeyCover.shared.listKeychains() where keychain.chainEncryptionStatus {
                try? keychain.decryptKeyDB()
            }
            KeyCover.shared.keyCoverPlainTextKey = nil
            // Remove any existing master key
            SecItemDelete(query as CFDictionary)
        }

        // Store the master key in macOS keychain
        Task(priority: .userInitiated) {
            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess {
                print("Error storing master key in keychain: \(status)")
            }
        }

        KeyCover.shared.keyCoverPlainTextKey = key

        // Encrypts all keychains
        for keychain in KeyCover.shared.listKeychains() where !keychain.chainEncryptionStatus {
            try? keychain.encryptKeyDB()
        }

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    func getKeyCoverPassword() -> String? {
        readKeyCoverPassword().password
    }

    fileprivate func readKeyCoverPassword() -> (password: String?, status: OSStatus) {
        // Get the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag,
                                    kSecReturnData as String: kCFBooleanTrue as Any,
                                    kSecMatchLimit as String: kSecMatchLimitOne]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)
        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return (String(data: data, encoding: .utf8), status)
            }
        }
        return (nil, status)
    }

    func removeKeyCoverPassword() {
        // Decrypt all key dbs
        for chain in KeyCover.shared.listKeychains() where chain.chainEncryptionStatus {
                try? chain.decryptKeyDB()
        }

        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        Task(priority: .userInitiated) {
            let status = SecItemDelete(query as CFDictionary)
            if status != errSecSuccess {
                print("Error removing master key from keychain: \(status)")
            }
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    func forceResetKeyCoverPassword() {
        // If a key is in memory, don't do anything (prevent accidental deletion)
        if KeyCover.shared.keyCoverPlainTextKey != nil {
            return
        }
        // Remove the master key from macOS keychain
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: tag,
                                    kSecAttrAccount as String: tag]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess {
            print("Error removing master key from keychain: \(status)")
        }

        KeyCoverPreferences.shared.keyCoverEnabled = .disabled
        KeyCover.shared.keyCoverPlainTextKey = nil

        // Being a force reset, we have to nuke everything (because it's useless otherwise)
        for chain in KeyCover.shared.listKeychains() {
            try? chain.deleteEncryptedKeyDB()
        }

        Task { @MainActor in
            KeyCoverObservable.shared.update()
        }
    }

    func validatePassword(_ key: String) -> Bool {
        return key == getKeyCoverPassword()
    }

    func generateVerySecurePassword() -> String {
        // oh my god
        let length = 32
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+"
        return String((0..<length).map { _ in letters.randomElement() ?? "." })
    }
}
