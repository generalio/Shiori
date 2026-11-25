import AppKit
import Foundation

/// Bounded thread-safe LRU memory cache + sliding-window prefetch planner for manga chapter pages.
public final class BoundedReaderImageCache: @unchecked Sendable {
    private struct Entry {
        let data: Data
        let image: NSImage?
        let costBytes: Int
    }

    public let maxMemoryBytes: Int
    private let lock = NSLock()
    private var storage: [String: Entry] = [:]
    private var lruOrder: [String] = [] // oldest at index 0, most-recently-used at end
    private var totalBytes: Int = 0

    public init(maxMemoryBytes: Int = 180 * 1024 * 1024) {
        self.maxMemoryBytes = max(1, maxMemoryBytes)
    }

    public var currentCostBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytes
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }

    /// Computes page indices in `[current - radius, current + radius]` ordered radially outward
    /// (`current`, `current + 1`, `current - 1`, `current + 2`, ...) so forward reading loads first.
    public static func prefetchWindowIndices(currentIndex: Int, totalCount: Int, radius: Int = 5) -> [Int] {
        guard totalCount > 0 else { return [] }
        let clampedCurrent = max(0, min(totalCount - 1, currentIndex))
        let safeRadius = max(0, radius)
        var result: [Int] = [clampedCurrent]
        if safeRadius == 0 { return result }

        for offset in 1...safeRadius {
            let next = clampedCurrent + offset
            if next < totalCount {
                result.append(next)
            }
            let prev = clampedCurrent - offset
            if prev >= 0 {
                result.append(prev)
            }
        }
        return result
    }

    public func insert(key: String, data: Data, decodedImage: NSImage? = nil, costBytes: Int? = nil) {
        let cost = max(1, costBytes ?? data.count)
        lock.lock()
        defer { lock.unlock() }

        if let old = storage[key] {
            totalBytes -= old.costBytes
            lruOrder.removeAll { $0 == key }
        }

        storage[key] = Entry(data: data, image: decodedImage, costBytes: cost)
        lruOrder.append(key)
        totalBytes += cost

        while totalBytes > maxMemoryBytes && lruOrder.count > 1 {
            let oldestKey = lruOrder.removeFirst()
            if let removed = storage.removeValue(forKey: oldestKey) {
                totalBytes -= removed.costBytes
            }
        }
    }

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        touchLocked(key)
        return entry.data
    }

    public func image(forKey key: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        touchLocked(key)
        return entry.image ?? NSImage(data: entry.data)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        lruOrder.removeAll()
        totalBytes = 0
    }

    private func touchLocked(_ key: String) {
        if let idx = lruOrder.firstIndex(of: key) {
            lruOrder.remove(at: idx)
            lruOrder.append(key)
        }
    }
}
