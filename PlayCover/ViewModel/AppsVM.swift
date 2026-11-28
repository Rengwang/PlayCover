//
//  AppViewModel.swift
//  PlayCover
//

import Foundation

private struct AppLibraryEntry: Sendable {
    let url: URL
    let bundleIdentifier: String
    let displayName: String
    let signature: String

    var identityKey: String {
        bundleIdentifier + "\0" + url.standardizedFileURL.path
    }
}

private enum AppLibraryScanner {
    static func scan(at directory: URL) throws -> [AppLibraryEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return urls.compactMap(makeEntry(from:)).sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame ? lhs.url.path < rhs.url.path : order == .orderedAscending
        }
    }

    private static func makeEntry(from url: URL) -> AppLibraryEntry? {
        guard url.pathExtension.lowercased() == "app",
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }
        let infoURL = url.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let values = plist as? [String: Any],
              let bundleIdentifier = values["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            return nil
        }
        let bundleName = values["CFBundleName"] as? String ?? ""
        let rawDisplayName = values["CFBundleDisplayName"] as? String ?? bundleName
        let displayName = rawDisplayName.isEmpty ? bundleIdentifier : rawDisplayName
        let resourceValues = try? infoURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let fileSize = resourceValues?.fileSize ?? data.count
        let signature = "\(bundleIdentifier)|\(fileSize)|\(modified)"
        return AppLibraryEntry(
            url: url,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            signature: signature
        )
    }
}

private enum BundleIDCacheStore {
    static func reconcile(at url: URL, discovered: [String]) {
        guard !discovered.isEmpty else { return }
        let existing = (try? String(contentsOf: url, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
        var seen = Set<String>()
        let merged = (existing + discovered).filter { !$0.isEmpty && seen.insert($0).inserted }
        let serialized = merged.map { $0 + "\n" }.joined()
        do {
            try serialized.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.shared.error(error)
        }
    }
}

class AppsVM: ObservableObject {

    public static let appDirectory = PlayTools.playCoverContainer.appendingPathComponent("Applications")

    static let shared = AppsVM()

    private init() {
        try? AppsVM.ensureBaseDirectoriesExist()
        PlayTools.installOnSystem()
        fetchApps()
    }

    static func ensureBaseDirectoriesExist() throws {
        try FileManager.default.createDirectory(
            at: appDirectory,
            withIntermediateDirectories: true
        )
    }

    @Published var filteredApps: [PlayApp] = []
    @Published var apps: [PlayApp] = []
    @Published var searchText: String = ""
    @Published var updatingApps = true

    private var fetchTask: Task<[AppLibraryEntry], Error>?
    private var maintenanceTask: Task<Void, Never>?
    private var appEntrySignatures: [String: String] = [:]
    private(set) var hasLoadedOnce = false

    @MainActor
    func applyFilter() {
        if searchText.isEmpty {
            filteredApps = apps
        } else {
            let query = searchText.lowercased()
            filteredApps = apps.filter { $0.searchText.contains(query) }
        }
    }

    func fetchApps() {
        Task { @MainActor in
            fetchTask?.cancel()
            maintenanceTask?.cancel()
            updatingApps = true

            let currentTask = Task.detached(priority: .userInitiated) { () throws -> [AppLibraryEntry] in
                try AppLibraryScanner.scan(at: AppsVM.appDirectory)
            }

            fetchTask = currentTask
            let entries: [AppLibraryEntry]
            do {
                entries = try await currentTask.value
            } catch {
                if !currentTask.isCancelled && !Task.isCancelled {
                    Log.shared.error(error)
                    self.updatingApps = false
                }
                return
            }
            if currentTask.isCancelled || Task.isCancelled {
                return
            }

            // Preserve existing PlayApp instances when the installed bundle metadata is unchanged
            // so open settings sheets do not hold stale AppSettings references.
            var existingByKey: [String: PlayApp] = [:]
            for app in self.apps {
                let key = app.info.bundleIdentifier + "\0" + app.url.standardizedFileURL.path
                existingByKey[key] = app
            }
            var nextSignatures: [String: String] = [:]
            let loadedApps = entries.map { entry -> PlayApp in
                nextSignatures[entry.identityKey] = entry.signature
                if let existing = existingByKey[entry.identityKey],
                   self.appEntrySignatures[entry.identityKey] == entry.signature {
                    return existing
                }
                return PlayApp(appUrl: entry.url)
            }

            self.appEntrySignatures = nextSignatures
            self.apps = loadedApps
            self.applyFilter()
            self.hasLoadedOnce = true
            self.updatingApps = false

            let discoveredIDs = entries.map(\.bundleIdentifier)
            self.maintenanceTask = Task.detached(priority: .background) {
                BundleIDCacheStore.reconcile(at: PlayApp.bundleIDCacheURL, discovered: discoveredIDs)
                for app in loadedApps {
                    if Task.isCancelled { return }
                    app.ensureAliasIfNeeded()
                }
            }
        }
    }
}
