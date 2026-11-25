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
    private var configuredRegistry: SourceRegistry?
    private var refererProvider: ((String) -> String)?

    private init() {}

    func configure(registry: SourceRegistry, refererProvider: @escaping (String) -> String) {
        self.configuredRegistry = registry
        self.refererProvider = refererProvider
    }

    func resolveRegistry() -> SourceRegistry? {
        configuredRegistry
    }

    func resolveReferer(for sourceId: String) -> String {
        refererProvider?(sourceId) ?? ""
    }

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
            if trimmed.contains("mangafun") || trimmed.contains("mangacopy") || trimmed.contains("copymanga") || trimmed.contains("hotmangasd") {
                return "copymanga"
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

/// Completely decoupled from `StudioViewModel` (`@EnvironmentObject` removed) so global VM
/// updates never invalidate 20–40 visible cover thumbnails during typing, hovering, or animations.
struct AsyncCoverThumbnail: View, Equatable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let urlString: String
    let sourceId: String
    var maxPixelSize: CGFloat = 320

    @State private var image: NSImage?
    @State private var loadedFromMemoryCache = false

    static func == (lhs: AsyncCoverThumbnail, rhs: AsyncCoverThumbnail) -> Bool {
        lhs.urlString == rhs.urlString &&
        lhs.sourceId == rhs.sourceId &&
        lhs.maxPixelSize == rhs.maxPixelSize
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .transition(loadedFromMemoryCache ? .identity : .opacity)
            } else {
                StudioBreathingPlaceholder(
                    cornerRadius: 0,
                    iconName: sourceId == "copymanga" ? "photo.stack.fill" : "book.closed.fill"
                )
            }
        }
        .task(id: "\(sourceId)::\(urlString)") {
            if let cached = CoverThumbnailCache.shared.cachedImage(urlString: urlString, sourceId: sourceId) {
                loadedFromMemoryCache = true
                self.image = cached
                return
            }
            guard let registry = CoverThumbnailCache.shared.resolveRegistry() else { return }
            loadedFromMemoryCache = false
            self.image = nil
            let referer = CoverThumbnailCache.shared.resolveReferer(for: sourceId)
            let loaded = await CoverThumbnailCache.shared.loadThumbnail(
                urlString: urlString,
                sourceId: sourceId,
                registry: registry,
                referer: referer,
                maxPixelSize: maxPixelSize
            )
            if !Task.isCancelled, let loaded {
                withAnimation(StudioMotion.animation(StudioMotion.imageFade, reduceMotion: reduceMotion)) {
                    self.image = loaded
                }
            }
        }
    }
}
