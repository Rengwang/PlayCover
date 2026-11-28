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

class Cacher {
    static let shared = Cacher()
    @ImageCache private var imageCache
    let cache = DataCache.instance
    private let appIconCache = NSCache<NSString, NSImage>()
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
        let icon = await Task.detached(priority: .userInitiated) {
            NSWorkspace.shared.icon(forFile: path)
        }.value
        cacheAppIcon(icon, forPath: path)
        return icon
    }

    func getLocalIcon(bundleId: String) -> NSImage? {
        guard let app = AppsVM.shared.apps.first(where: { $0.info.bundleIdentifier == bundleId }) else {
            return nil
        }
        let path = app.url.path
        if let cached = cachedAppIcon(forPath: path) {
            return cached
        }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cacheAppIcon(icon, forPath: path)
        return icon
    }

}

extension URLCache {
    static let iconCache = URLCache(memoryCapacity: 4*1024*1024, diskCapacity: 20*1024*1024) // 4MB and 20MB
}
