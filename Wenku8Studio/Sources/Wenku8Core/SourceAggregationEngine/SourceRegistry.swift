import Foundation

public final class SourceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var orderedIds: [String] = []
    private var pluginsById: [String: any BookSourcePlugin] = [:]
    private var enabledStateById: [String: Bool] = [:]

    public init(plugins: [any BookSourcePlugin] = []) {
        for plugin in plugins {
            register(plugin)
        }
    }

    public static func makeDefaultRegistry(
        wenku8Client: Wenku8Client = Wenku8Client(),
        bilinovelPlugin: BilinovelPlugin = BilinovelPlugin(),
        copymangaPlugin: CopymangaPlugin = CopymangaPlugin(),
        localLibraryPlugin: LocalLibraryPlugin? = nil
    ) -> SourceRegistry {
        let registry = SourceRegistry()
        registry.register(wenku8Client, enabled: true)
        registry.register(bilinovelPlugin, enabled: true)
        registry.register(copymangaPlugin, enabled: true)
        if let localLibraryPlugin {
            registry.register(localLibraryPlugin, enabled: true)
        }
        return registry
    }

    public func allOnlinePlugins() -> [any BookSourcePlugin] {
        allPlugins().filter { !$0.descriptor.isLocalSource }
    }

    public func enabledOnlinePlugins(matching contentKind: ContentKind? = nil) -> [any BookSourcePlugin] {
        enabledPlugins(matching: contentKind).filter { !$0.descriptor.isLocalSource }
    }

    public func register(_ plugin: any BookSourcePlugin, enabled: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let id = plugin.descriptor.id
        if pluginsById[id] == nil {
            orderedIds.append(id)
        }
        pluginsById[id] = plugin
        if enabledStateById[id] == nil {
            enabledStateById[id] = enabled
        }
    }

    public func allPlugins() -> [any BookSourcePlugin] {
        lock.lock()
        defer { lock.unlock() }
        return orderedIds.compactMap { pluginsById[$0] }
    }

    public func enabledPlugins(matching contentKind: ContentKind? = nil) -> [any BookSourcePlugin] {
        lock.lock()
        defer { lock.unlock() }
        return orderedIds.compactMap { id in
            guard enabledStateById[id] ?? true,
                  let plugin = pluginsById[id] else { return nil }
            if let contentKind {
                guard plugin.descriptor.contentKind == contentKind || plugin.descriptor.contentKind == .mixed else {
                    return nil
                }
            }
            return plugin
        }
    }

    public func plugin(for id: String) -> (any BookSourcePlugin)? {
        lock.lock()
        defer { lock.unlock() }
        return pluginsById[id]
    }

    public func isEnabled(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledStateById[id] ?? true
    }

    public func setEnabled(_ enabled: Bool, for id: String) {
        lock.lock()
        defer { lock.unlock() }
        enabledStateById[id] = enabled
    }

    /// Resolves raw user input (explicit prefix, full URL, or numeric/slug ID) to the matching plugin + extracted work ID.
    /// Explicitly matches URLs & prefixes first, then falls back to `preferredSourceId`.
    public func routeBookInput(_ rawInput: String, preferredSourceId: String = "wenku8") -> (plugin: any BookSourcePlugin, bookId: String)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let active = enabledPlugins()
        let isExplicitURLOrPrefix = trimmed.contains("://") || trimmed.contains(".") || trimmed.contains("/") || trimmed.contains(":")

        if isExplicitURLOrPrefix {
            for plugin in active {
                if let bookId = plugin.canHandle(rawInput: trimmed), !bookId.isEmpty {
                    return (plugin, bookId)
                }
            }
            return nil
        }

        if let preferred = plugin(for: preferredSourceId),
           isEnabled(preferredSourceId),
           let bookId = preferred.canHandle(rawInput: trimmed),
           !bookId.isEmpty {
            return (preferred, bookId)
        }

        for plugin in active {
            if let bookId = plugin.canHandle(rawInput: trimmed), !bookId.isEmpty {
                return (plugin, bookId)
            }
        }
        return nil
    }

    /// Returns other enabled plugins that could also interpret the same bare input (e.g., numeric IDs shared by Wenku8 & Bilinovel).
    public func alternativeRoutes(for rawInput: String, excludingSourceId: String) -> [(plugin: any BookSourcePlugin, bookId: String)] {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("://"),
              !trimmed.contains(":") else { return [] }
        return enabledPlugins().compactMap { plugin in
            guard plugin.descriptor.id != excludingSourceId,
                  let bid = plugin.canHandle(rawInput: trimmed),
                  !bid.isEmpty else { return nil }
            return (plugin, bid)
        }
    }

    public func updateAllConfigs(_ configs: [String: SourceRuntimeConfig]) async {
        let all = allPlugins()
        for plugin in all {
            if let cfg = configs[plugin.descriptor.id] {
                setEnabled(cfg.isEnabled, for: plugin.descriptor.id)
                await plugin.updateConfig(cfg)
            }
        }
    }

    public func setBrowserRuntime(_ runtime: (any SourceBrowserRuntime)?) async {
        for plugin in allPlugins() {
            await plugin.setBrowserRuntime(runtime)
        }
    }
}
