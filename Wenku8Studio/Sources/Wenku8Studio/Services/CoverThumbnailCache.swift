import AppKit
import Foundation
import ImageIO
import SwiftUI
import Wenku8Core

/// Dedicated cover thumbnail downloader & downsampler isolated from `StudioViewModel`'s
/// `@Published` state so loading cover images never triggers whole-app SwiftUI invalidations.
@MainActor
final class CoverThumbnailCache {
    static let shared = CoverThumbnailCache()

    private let memoryCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 320
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private var inflightTasks: [String: Task<NSImage?, Never>] = [:]

    private init() {}

    func cachedImage(urlString: String, sourceId: String) -> NSImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return memoryCache.object(forKey: Self.cacheKey(urlString: trimmed, sourceId: sourceId) as NSString)
    }

    func loadThumbnail(
        urlString: String,
        sourceId: String,
        registry: SourceRegistry,
        referer: String,
        maxPixelSize: CGFloat = 320
    ) async -> NSImage? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let key = Self.cacheKey(urlString: trimmed, sourceId: sourceId)
        if let hit = memoryCache.object(forKey: key as NSString) {
            return hit
        }

        if let existing = inflightTasks[key] {
            return await existing.value
        }

        let resolvedSourceId: String = {
            if !sourceId.isEmpty { return sourceId }
            if trimmed.contains("linovelib") || trimmed.contains("readpai") || trimmed.contains("bilinovel") {
                return "bilinovel"
            }
            return "wenku8"
        }()

        let task = Task<NSImage?, Never> { [weak self] in
            guard let plugin = registry.plugin(for: resolvedSourceId) ?? registry.allPlugins().first else {
                return nil
            }
            guard let asset = try? await plugin.downloadImage(url: trimmed, referer: referer) else {
                return nil
            }
            let imageData = asset.data
            let decoded: (image: NSImage, cost: Int)? = await Task.detached(priority: .utility) {
                Self.downsampleImage(data: imageData, maxPixelSize: maxPixelSize)
            }.value

            guard let self, let decoded else { return nil }
            self.memoryCache.setObject(decoded.image, forKey: key as NSString, cost: decoded.cost)
            return decoded.image
        }

        inflightTasks[key] = task
        let result = await task.value
        inflightTasks.removeValue(forKey: key)
        return result
    }

    private static func cacheKey(urlString: String, sourceId: String) -> String {
        "\(sourceId)::\(urlString)"
    }

    nonisolated private static func downsampleImage(data: Data, maxPixelSize: CGFloat) -> (image: NSImage, cost: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let src = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) {
            let thumbOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) {
                let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                let byteCost = max(1, cgImg.width * cgImg.height * 4)
                return (nsImg, byteCost)
            }
        }
        if let fallback = NSImage(data: data) {
            let cost = max(1, Int(fallback.size.width * fallback.size.height * 4))
            return (fallback, cost)
        }
        return nil
    }
}

struct AsyncCoverThumbnail: View {
    @EnvironmentObject var vm: StudioViewModel

    let urlString: String
    let sourceId: String
    var maxPixelSize: CGFloat = 320

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.14)
                    Image(systemName: "book.closed.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: "\(sourceId)::\(urlString)") {
            if let cached = CoverThumbnailCache.shared.cachedImage(urlString: urlString, sourceId: sourceId) {
                self.image = cached
                return
            }
            self.image = nil
            let referer = vm.sourceConfig(for: sourceId).baseURL
            let loaded = await CoverThumbnailCache.shared.loadThumbnail(
                urlString: urlString,
                sourceId: sourceId,
                registry: vm.sourceRegistry,
                referer: referer,
                maxPixelSize: maxPixelSize
            )
            if !Task.isCancelled, let loaded {
                self.image = loaded
            }
        }
    }
}
