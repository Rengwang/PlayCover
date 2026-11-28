//
//  Cacher.swift
//  PlayCover
//
//  Created by Amir Mohammadi on 10/2/1401 AP.
//

import Foundation
import AppKit
import DataCache
import CachedAsyncImage

private actor IconRequestDeduplicator {
    private var inFlight: [String: Task<NSImage, Never>] = [:]

    func value(for key: String, operation: @escaping @Sendable () async -> NSImage) async -> NSImage {
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task { await operation() }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }
}

class Cacher {
    static let shared = Cacher()
    @ImageCache private var imageCache
    let cache = DataCache.instance
    private let appIconCache = NSCache<NSString, NSImage>()
    private let iconRequests = IconRequestDeduplicator()
    private static let directIconQueue = DispatchQueue(
        label: "io.playcover.PlayCover.direct-icon",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let workspaceIconQueue = DispatchQueue(
        label: "io.playcover.PlayCover.workspace-icon",
        qos: .utility
    )
    /// We can create a custom cache like this (default values are as the same as below):
    /// `let cache = DataCache(name: "PlayCoverCache")`
    /// `cache.maxDiskCacheSize = 100*1024*1024`      // 100 MB
    /// `cache.maxCachePeriodInSecond = 7*86400`      // 1 week
    /// More details: https://github.com/huynguyencong/DataCache/blob/master/README.md

    init() {
        // Set image cache limit.
        ImageCache().wrappedValue.setCacheLimit(
            countLimit: 400,
            totalCostLimit: 4*1024*1024
        )
        appIconCache.countLimit = 256
        appIconCache.totalCostLimit = 16 * 1024 * 1024
    }

    private func cacheAppIcon(_ icon: NSImage, forPath path: String) {
        let estimatedCost = Int(max(1, icon.size.width * icon.size.height * 4 * 4))
        appIconCache.setObject(icon, forKey: path as NSString, cost: estimatedCost)
    }

    func removeImageCache() {
        imageCache.removeCache()
        appIconCache.removeAllObjects()
    }

    func resolveITunesData(_ link: String) async {
        _ = await getITunesData(link)
    }

    func cachedAppIcon(forPath path: String) -> NSImage? {
        appIconCache.object(forKey: path as NSString)
    }

    func loadAppIcon(forPath path: String) async -> NSImage {
        if let cached = cachedAppIcon(forPath: path) {
            return cached
        }
        return await iconRequests.value(for: path) { [weak self] in
            if let cached = self?.cachedAppIcon(forPath: path) {
                return cached
            }
            if let direct = await self?.loadDirectBundleIconAsync(forPath: path) {
                self?.cacheAppIcon(direct, forPath: path)
                return direct
            }
            let fallback = await Self.loadWorkspaceIconAsync(forPath: path)
            self?.cacheAppIcon(fallback, forPath: path)
            return fallback
        }
    }

    func getLocalIcon(bundleId: String) -> NSImage? {
        guard let app = AppsVM.shared.apps.first(where: { $0.info.bundleIdentifier == bundleId }) else {
            return nil
        }
        let path = app.url.path
        if let cached = cachedAppIcon(forPath: path) {
            return cached
        }
        let icon = Self.readDirectBundleIcon(forPath: path) ?? NSWorkspace.shared.icon(forFile: path)
        cacheAppIcon(icon, forPath: path)
        return icon
    }

    private func loadDirectBundleIconAsync(forPath path: String) async -> NSImage? {
        await withCheckedContinuation { continuation in
            Self.directIconQueue.async {
                continuation.resume(returning: Self.readDirectBundleIcon(forPath: path))
            }
        }
    }

    private static func loadWorkspaceIconAsync(forPath path: String) async -> NSImage {
        await withCheckedContinuation { continuation in
            Self.workspaceIconQueue.async {
                continuation.resume(returning: NSWorkspace.shared.icon(forFile: path))
            }
        }
    }

    /// Reads the app's icon directly from its bundle PNG/ICNS assets without invoking
    /// `NSWorkspace.icon(forFile:)`, avoiding synchronous `lsd` bundle-registration stalls.
    private static func readDirectBundleIcon(forPath path: String) -> NSImage? {
        let bundleURL = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        let infoURL = bundleURL.appendingPathComponent("Info.plist")

        var iconNames: [String] = []
        if let data = try? Data(contentsOf: infoURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for key in ["CFBundleIcons~ipad", "CFBundleIcons"] {
                if let icons = plist[key] as? [String: Any],
                   let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                   let files = primary["CFBundleIconFiles"] as? [String] {
                    iconNames.append(contentsOf: files)
                }
            }
            if let files = plist["CFBundleIconFiles"] as? [String] {
                iconNames.append(contentsOf: files)
            }
            if let single = plist["CFBundleIconFile"] as? String, !single.isEmpty {
                iconNames.append(single)
            }
        }

        let suffixes = [
            "76x76@2x~ipad.png", "60x60@3x.png", "60x60@2x.png",
            "@3x~ipad.png", "@2x~ipad.png", "@3x.png", "@2x.png",
            ".png", ".icns", ""
        ]
        var bestURL: URL?
        var bestSize = -1

        for name in iconNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            for suffix in suffixes {
                let candidateName = trimmed.hasSuffix(".png") || trimmed.hasSuffix(".icns")
                    ? trimmed : trimmed + suffix
                let candidateURL = bundleURL.appendingPathComponent(candidateName)
                if fileManager.fileExists(atPath: candidateURL.path) {
                    let size = (try? candidateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > bestSize {
                        bestSize = size
                        bestURL = candidateURL
                    }
                }
            }
        }

        if bestURL == nil,
           let items = try? fileManager.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
           ) {
            for item in items {
                let name = item.lastPathComponent
                let lower = name.lowercased()
                let isIcon = (lower.hasPrefix("appicon") || lower.hasPrefix("icon")) && lower.hasSuffix(".png")
                if isIcon || lower.hasSuffix(".icns") {
                    let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if size > bestSize {
                        bestSize = size
                        bestURL = item
                    }
                }
            }
        }

        guard let iconURL = bestURL, let image = NSImage(contentsOf: iconURL), image.isValid else {
            return nil
        }
        return image
    }

}

extension URLCache {
    static let iconCache = URLCache(memoryCapacity: 4*1024*1024, diskCapacity: 20*1024*1024) // 4MB and 20MB
}
