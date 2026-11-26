import SwiftUI
import Wenku8Core

struct AppleBooksImportSheet: View {
    @EnvironmentObject var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var filterMode: CandidateFilter = .all
    @State private var selectedPaths: Set<String> = []

    private enum CandidateFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case unimported = "未导入"
        case downloaded = "已在本机"
        case iCloudOnly = "iCloud 云端"
        var id: String { rawValue }
    }

    private var filteredCandidates: [AppleBooksCandidate] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return vm.appleBooksCandidates.filter { item in
            switch filterMode {
            case .all: break
            case .unimported: if item.isAlreadyImported { return false }
            case .downloaded: if !item.isDownloadedLocally { return false }
            case .iCloudOnly: if item.isDownloadedLocally { return false }
            }
            guard !q.isEmpty else { return true }
            return item.displayName.lowercased().contains(q)
        }
    }

    private var selectedCandidates: [AppleBooksCandidate] {
        vm.appleBooksCandidates.filter { selectedPaths.contains($0.filePath) }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            Divider()
            filterBar
            Divider()

            if let progress = vm.localImportProgressText, vm.isImportingLocalBooks {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress)
                        .font(.caption.weight(.medium))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color.accentColor.opacity(0.10))
                Divider()
            }

            listContent
            Divider()
            footerSection
        }
        .frame(width: 680, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 36, height: 36)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("从 Apple Books（iCloud 图书）导入")
                    .font(.headline)
                Text("仅保存原路径引用，不会重复复制文件或修改苹果图书原件；支持自动识别云端占位文件并按需拉取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StudioCircleButton(
                systemImage: "arrow.clockwise",
                variant: .secondary,
                size: .small,
                isLoading: vm.isScanningAppleBooks,
                spinIconWhenLoading: true,
                accessibilityLabel: "重新扫描 Apple Books 目录"
            ) {
                Task { await vm.refreshAppleBooksCandidates() }
            }
            .help("重新扫描 iCloud 图书目录")

            StudioCircleButton(
                systemImage: "xmark",
                variant: .subtle,
                size: .small,
                accessibilityLabel: "关闭弹窗"
            ) {
                dismiss()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            StudioSearchField(
                icon: "magnifyingglass",
                placeholder: "筛选 Apple Books 书名...",
                text: $searchText
            )
            .frame(maxWidth: 230)

            HStack(spacing: 6) {
                ForEach(CandidateFilter.allCases) { mode in
                    StudioFilterChip(title: mode.rawValue, isSelected: filterMode == mode) {
                        filterMode = mode
                    }
                }
            }

            Spacer()

            let selectable = filteredCandidates.filter { !$0.isAlreadyImported }
            StudioPillButton(
                title: selectedPaths.isEmpty ? "全选未导入" : "清空选择",
                variant: .subtle,
                size: .small,
                isDisabled: selectable.isEmpty && selectedPaths.isEmpty
            ) {
                if selectedPaths.isEmpty {
                    selectedPaths = Set(selectable.map(\.filePath))
                } else {
                    selectedPaths.removeAll()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var listContent: some View {
        if vm.isScanningAppleBooks {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在扫描 Apple Books iCloud 图书目录…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.appleBooksCandidates.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "icloud.slash")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("未在 Apple Books iCloud 目录发现可导入的无 DRM 书籍")
                    .font(.callout.weight(.medium))
                Text("检测路径：~/Library/Mobile Documents/iCloud~com~apple~iBooks/Documents\n如未开启 iCloud 图书同步，可直接使用「导入本地书籍」选择文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if filteredCandidates.isEmpty {
            Text("当前筛选条件下没有匹配的书籍")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredCandidates) { item in
                        candidateRow(item)
                    }
                }
                .padding(14)
            }
        }
    }

    private func candidateRow(_ item: AppleBooksCandidate) -> some View {
        let isSelected = selectedPaths.contains(item.filePath)
        return Button {
            guard !item.isAlreadyImported else { return }
            if isSelected {
                selectedPaths.remove(item.filePath)
            } else {
                selectedPaths.insert(item.filePath)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isAlreadyImported ? "checkmark.circle.fill" : (isSelected ? "checkmark.square.fill" : "square"))
                    .font(.body)
                    .foregroundStyle(
                        item.isAlreadyImported
                            ? Color.green
                            : (isSelected ? Color.accentColor : Color.secondary)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(item.format.displayBadge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.indigo.opacity(0.12), in: Capsule())

                        if item.isAlreadyImported {
                            Label("已导入 Shiori", systemImage: "checkmark")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else if item.isDownloadedLocally {
                            Label("已在本机", systemImage: "internaldrive")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                        } else {
                            Label("iCloud 云端（导入时自动下载）", systemImage: "icloud.and.arrow.down")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }

                        if !item.formattedSize.isEmpty {
                            Text(item.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : StudioTokens.hairlineStroke, lineWidth: 0.9)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(item.isAlreadyImported || vm.isImportingLocalBooks)
    }

    private var footerSection: some View {
        let downloadedCount = vm.appleBooksCandidates.filter(\.isDownloadedLocally).count
        return HStack(spacing: 12) {
            Text("共发现 \(vm.appleBooksCandidates.count) 本（\(downloadedCount) 本已在本机）")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            StudioPillButton(title: "取消", variant: .subtle, size: .regular) {
                dismiss()
            }

            StudioPillButton(
                title: selectedCandidates.isEmpty ? "请选择书籍" : "导入所选（\(selectedCandidates.count) 本）",
                systemImage: "square.and.arrow.down",
                variant: .primary,
                size: .regular,
                isLoading: vm.isImportingLocalBooks,
                isDisabled: selectedCandidates.isEmpty || vm.isImportingLocalBooks
            ) {
                let toImport = selectedCandidates
                selectedPaths.removeAll()
                vm.importAppleBooksCandidates(toImport)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }
}
