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
    }

    func removeImageCache() {
        imageCache.removeCache()
    }

    func resolveITunesData(_ link: String) async {
        if let refreshedITunesData = await getITunesData(link) {
            try? cache.write(codable: refreshedITunesData, forKey: link)
        }
    }

    func getLocalIcon(bundleId: String) -> NSImage? {
        guard let app = AppsVM.shared.apps.first(where: { $0.info.bundleIdentifier == bundleId }) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: app.url.path)
    }

}

extension URLCache {
    static let iconCache = URLCache(memoryCapacity: 4*1024*1024, diskCapacity: 20*1024*1024) // 4MB and 20MB
}
