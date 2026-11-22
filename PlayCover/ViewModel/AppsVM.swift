//
//  AppViewModel.swift
//  PlayCover
//

import Foundation

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

    private var fetchTask: Task<[PlayApp], Never>?
    private var maintenanceTask: Task<Void, Never>?
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

            let currentTask = Task.detached(priority: .userInitiated) { () -> [PlayApp] in
                var scannedApps: [PlayApp] = []

                do {
                    let directoryContents = try FileManager.default
                        .contentsOfDirectory(at: AppsVM.appDirectory,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [])

                    let subdirs = directoryContents.filter { $0.hasDirectoryPath }

                    for sub in subdirs {
                        if Task.isCancelled { return [] }
                        if sub.pathExtension.contains("app") &&
                            FileManager.default.fileExists(atPath: sub.appendingPathComponent("Info")
                                                                      .appendingPathExtension("plist")
                                                                      .path) {
                            let app = PlayApp(appUrl: sub)
                            print("Application installed under:", sub.path)
                            scannedApps.append(app)
                        }
                    }
                } catch {
                    print(error)
                }

                if Task.isCancelled { return [] }

                scannedApps.sort(by: { $0.name.lowercased() < $1.name.lowercased() })
                Self.updateBundleIDCache(for: scannedApps)
                return scannedApps
            }

            fetchTask = currentTask
            let scannedApps = await currentTask.value
            if currentTask.isCancelled || Task.isCancelled {
                return
            }

            self.apps = scannedApps
            self.applyFilter()
            self.hasLoadedOnce = true
            self.updatingApps = false

            self.maintenanceTask = Task.detached(priority: .background) {
                for app in scannedApps {
                    if Task.isCancelled { return }
                    app.ensureAliasIfNeeded()
                }
            }
        }
    }

    private static func updateBundleIDCache(for scannedApps: [PlayApp]) {
        guard !scannedApps.isEmpty else { return }
        do {
            let cacheURL = PlayApp.bundleIDCacheURL
            let existingIDs: Set<String>
            if FileManager.default.fileExists(atPath: cacheURL.path) {
                existingIDs = Set(try PlayApp.bundleIDCache)
            } else {
                existingIDs = []
            }

            var missingLines: [String] = []
            var seen = existingIDs
            for app in scannedApps {
                let bundleId = app.info.bundleIdentifier
                if !bundleId.isEmpty && seen.insert(bundleId).inserted {
                    missingLines.append(bundleId)
                }
            }

            guard !missingLines.isEmpty else { return }
            let payload = missingLines.joined(separator: "\n") + "\n"

            if !FileManager.default.fileExists(atPath: cacheURL.path) {
                try payload.write(to: cacheURL, atomically: false, encoding: .utf8)
            } else if let data = payload.data(using: .utf8) {
                let cacheFile = try FileHandle(forUpdating: cacheURL)
                defer { try? cacheFile.close() }
                try cacheFile.seekToEnd()
                try cacheFile.write(contentsOf: data)
            }
        } catch {
            Log.shared.error(error)
        }
    }
}
