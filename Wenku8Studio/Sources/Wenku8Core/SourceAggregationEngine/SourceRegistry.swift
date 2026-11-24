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
        bilinovelPlugin: BilinovelPlugin = BilinovelPlugin()
    ) -> SourceRegistry {
        let registry = SourceRegistry()
        registry.register(wenku8Client, enabled: true)
        // Hot-pluggable plugin retained in codebase, disabled by default until further site adaptation.
        registry.register(bilinovelPlugin, enabled: false)
        return registry
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

    public func enabledPlugins() -> [any BookSourcePlugin] {
        lock.lock()
        defer { lock.unlock() }
        return orderedIds.compactMap { id in
            guard enabledStateById[id] ?? true else { return nil }
            return pluginsById[id]
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

    /// Resolves raw user input (full URL or numeric ID) to the matching plugin + extracted book ID.
    /// Explicitly matches domain-specific URLs first, then falls back to `preferredSourceId`.
    public func routeBookInput(_ rawInput: String, preferredSourceId: String = "wenku8") -> (plugin: any BookSourcePlugin, bookId: String)? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let active = enabledPlugins()
        let isURL = trimmed.contains("://") || trimmed.contains(".") || trimmed.contains("/")

        if isURL {
            for plugin in active {
                if let bookId = plugin.canHandle(rawInput: trimmed), !bookId.isEmpty {
                    return (plugin, bookId)
                }
            }
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
