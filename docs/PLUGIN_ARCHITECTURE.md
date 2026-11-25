# Shiori 多书源插件化与双媒介聚合架构方案

本文档基于对 [`ShqWW/bilinovel-download`](https://github.com/ShqWW/bilinovel-download) 与 [`ShqWW/copymanga-download`](https://github.com/ShqWW/copymanga-download) 的拆解以及 `Wenku8Core` / `Wenku8Studio` 演进实践，定义 Shiori 的**多书源（轻小说 + 漫画）热插拔聚合架构**。

- 统一领域术语定义见仓库根目录 [GLOSSARY.md](../GLOSSARY.md)。
- 关键架构取舍（App API v3 选型、外部浏览器 + 可选本地 `curl_cffi` 桥接、`LocalShelf` 源级隔离同步、`0600` 本地状态文件权限）见 [docs/adr/](adr/)。

---

## 1. 上游 `bilinovel-download` 关键特征与适配要点

经分析 `ShqWW/bilinovel-download`（`backend/bilinovel/Editer.py`、`bilinovel_router.py`、`backend/rubbish_secret_map.py` 及 `bilimanga.py`），新增异构书源时需解决 4 类典型差异：

1. **真实浏览器 DOM 渲染与混淆剔除**：
   - `linovelib.com` 会触发 Cloudflare 防护并插入 `<p\d+>` 警告块、`position: absolute` 且含 `data-*` 属性的诱导假段落；原仓库依赖 DrissionPage 驱动 Edge 获取渲染后的 DOM 样式剔除干扰节点，再用多线程 HTTP 拉取 `img3.readpai.com` 插图。
   - 在 macOS 原生客户端中，应将网络层抽象为可扩展的抓取运行时，利用原生 `WKWebView` 离屏/隐式渲染池（通过 JS 校验 `getComputedStyle(el).position === 'absolute'`）替代外部 Edge 依赖。
2. **字体暗号解密（WOFF2 PUA 映射）**：
   - 当章节出现 `woff2` 混淆标记时，正文含 `\ue000`–`\uefff` 私用区字符，需由插件自身在正文后处理阶段挂载字符映射还原（静态 `secret_map` 或动态 WOFF2 `cmap` 解码）。
3. **单章多分页拼接与目录缺链修复**：
   - 章节正文可能被分页为 `cid.html`、`cid_2.html`、`cid_3.html`…，插件需在 `fetchChapterContent` 内部循环拼接为完整 `[ChapterToken]`，并在目录存在缺链时从前一章 `"下一页"` 正向补全后续 URL。
4. **多种内容形态（Light Novel / Manga）**：
   - 需支持「图文混排轻小说」与「纯图流漫画」，因此统一模型与插件描述需声明 `ContentKind`。

---

## 2. 现有代码耦合点分析

- **可复用核心**：`EPUBBuilder.swift` 与 `ReaderPaginator.swift` 已几乎完全独立于 Wenku8 站点逻辑，只需标准 `BookDetail`、`VolumeBuildInput`、`ChapterContent` 与 `DownloadedImageAsset`。
- **需解耦位置**：
  1. `Wenku8Core/Models.swift` 中的 `AuthorBookItem`、`BookDetail`、`BookmarkEntry`、`RecommendedBook` 缺少 `sourceId`（不同站点相同数字书号会在缓存、书架和阅读进度中碰撞）。
  2. `StudioViewModel.swift` 直接持有具体实例 `private let client: Wenku8Client`（约 30 处直接调用），需要转为面向抽象协议与注册表调用。
  3. `SettingsAndAssemblyView.swift` 目前针对单一站点维护 `baseURL` 与 `customCookie`，需按 `sourceId` 隔离各书源配置与凭据。

---

## 3. 目标分层架构（4 层解耦）

```text
Wenku8Studio/Sources/
├── Wenku8Core/
│   ├── Models.swift                          # 统一领域模型（含 sourceId、向后兼容解码与 ScopedBookID）
│   ├── BookSourceKit/                        # 核心 SPI 协议、抓取运行时
│   │   ├── SourceProtocols.swift             # BookSourcePlugin + 可选能力拆分协议 + SourceBrowserRuntime
│   │   └── HTTPRuntime.swift                 # 礼貌限速、编码自识别、Cloudflare 挑战检测、并发图片下载
│   ├── SourceAggregationEngine/              # 书源注册、输入路由与并发聚合
│   │   ├── SourceRegistry.swift              # 插件注册表、启停状态与 URL/书号智能路由
│   │   └── AggregatedSearchEngine.swift      # TaskGroup 多渠道并发检索、轮询交错合并与状态提示
│   ├── Plugins/                              # 书源插件目录
│   │   ├── Wenku8Plugin.swift                # Wenku8Client 协议适配（完整 5 项能力）
│   │   └── Bilinovel/                        # linovelib / bilinovel 插件
│   │       ├── BilinovelPlugin.swift         # 多页章节拼接、缺链前向回溯修复、广告剥离、榜单与搜索
│   │       └── BilinovelSecretMap.swift      # 3,500 条 WOFF2 PUA 字体映射恢复表
│   ├── EPUBBuilder.swift                     # 独立 EPUB 2/3 构建内核
│   └── ReaderPaginator.swift                 # 独立阅读器分页、简繁转换与插图布局
└── Wenku8Studio/
    ├── Services/
    │   └── WebKitFetchService.swift          # @MainActor 无头 WKWebView DOM 抓取运行时（与 WebLoginSheet 共享会话）
    ├── StudioViewModel.swift                 # 面向 SourceRegistry 与协议调用的统一状态管理
    └── Views/                                # SwiftUI 组件化界面（遵循 DesignSystem.swift 规范）
```

### 3.1 能力拆分协议（Interface Segregation）

每个书源只需实现核心 `BookSourcePlugin` 即可获得搜书、目录、阅读与 EPUB 导出能力；其余能力按站点特性可选遵循：

- **`BookSourcePlugin`（必选核心）**：
  - `descriptor: BookSourceDescriptor`（`id`、`displayName`、`defaultMirrors`、`supportedSearchScopes`、`requiresBrowserRuntime`、`contentKind`）
  - `canHandle(urlOrInput:) -> String?`（用于顶栏网址智能路由）
  - `search(query:scope:page:) -> PagedBookResult`
  - `fetchBookDetail(bookIdOrURL:onProgress:) -> BookDetail`
  - `fetchChapterContent(chapter:book:) -> ChapterContent`
  - `downloadImage(url:referer:) -> DownloadedImageAsset`
- **可选能力协议（UI 按 `plugin as? ...` 动态适配）**：
  - `DiscoveryCapableSource`：提供站点榜单频道 `discoveryChannels()`、标签云 `fetchTags()`。
  - `AuthenticatedSource`：提供 `loginURL`、Cookie 诊断/校验/定时保活。
  - `CloudBookshelfCapableSource`：提供云端书架拉取、增删与分组移动（支持双向同步）。
  - `ReviewCapableSource`：提供书籍书评列表与楼中楼回复（决定详情页是否展示「查看书评」）。

### 3.2 复合主键与数据兼容

- 全局使用 `ScopedBookID = "\(sourceId):\(bookId)"` 作为 `bookDetailCache`、`lastReadChapterByBook`、书架收藏与历史记录主键。
- 读取历史 `state.json` 时，缺失 `sourceId` 的旧记录默认迁移为 `"wenku8"`，保证存量用户数据零丢失。

### 3.3 多源 UI 与设置集成

- **发现与检索**：在 `DiscoveryView` 顶部提供渠道过滤胶囊（全部渠道并发聚合 / 单渠道切换），`BookItemCard` 展示书源角标。
- **平台化设置区**：在 `SettingsAndAssemblyView` 左侧独立出「书源平台」分组，动态枚举注册插件，为每个插件提供独立的启用开关、镜像域名、限速延迟、网页登录与 Cookie 续期面板。

---

## 4. 新书源快速接入标准流程（3 步）

1. 在 `Sources/Plugins/<SiteName>Plugin/` 新建插件类型并实现 `BookSourcePlugin`（按需附加 `DiscoveryCapableSource` / `AuthenticatedSource` 等）。
2. 网络请求直接复用 `BookSourceKit` 中的 `HTTPRuntime`（纯接口站）或 `WebKitFetchService` + `PoliteRateLimiter`（Cloudflare/DOM 混淆站）。
3. 在 `SourceRegistry.registerBuiltInPlugins()` 中注册实例，搜索聚合、发现榜单、书架收藏、在线阅读器、EPUB 3.0 导出与设置管理界面自动生效，无需改动任何 View 代码。

---

## 5. 分阶段重构路线图

1. **Phase 1（模型域隔离）**：为 `Models.swift` 引入 `sourceId` 与 `ScopedBookID`，补充 `state.json` 兼容迁移与 XCTest 校验。
2. **Phase 2（协议抽离与 Wenku8 插件化）**：抽出 `BookSourceKit` 协议族与 `SourceRegistry`，将 `Wenku8Client` 迁入 `Wenku8Plugin`，保证现有全部测试 100% 回归通过。
3. **Phase 3（ViewModel 与设置中心改造）**：将 `StudioViewModel` 的 `client.*` 替换为插件能力调用，并在 `SettingsAndAssemblyView` 增加分书源配置列表。
4. **Phase 4（WebKit 抓取运行时与 Bilinovel 接入）**：沉淀无头 `WKWebView` 抓取器与 WOFF2 字符解码器，接入 `BilinovelPlugin` 与并发聚合搜索。
5. **Phase 5（CLI 插件化扩展）**：若需保持 Python CLI 对等能力，在 `lightnovel.py` / `Editer.py` 中对应引入源注册参数 `--source`。
