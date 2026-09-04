import SwiftUI

// MARK: - 内置 bin 文件浏览器
//
// 全能签签名的 sideloaded App 上，SwiftUI 的 fileImporter 回调会出现
// 「选中文件 + 点打开但回调不触发」的已知问题（且无法用日志确认，因为
// 回调根本没走到 Swift 层）。这里直接从 App 自己的沙盒 Documents/Inbox
// 目录列出 .bin 文件，彻底绕开系统 picker。
//
// 需要配合 Info.plist 的 UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace：
// 开启后用户可以在 iPhone「文件 App → 我的 iPhone → 氪金之王」目录里
// 把 bin 文件手动拷进去，然后打开 App 进入此内置选择器。

struct LocalBinFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    var id: String { url.path }
}

/// 扫描 App 沙盒里所有可导入 bin 的目录（Documents/Inbox/tmp 的 bin）。
/// Documents 通过 iTunes 文件共享暴露；Inbox 是其它 App「用 xxx 打开」时
/// 系统把文件复制进来的位置。
enum LocalBinScanner {

    static let binDirectoryLabel = "我的 iPhone / 文件 App → 氪金之王 / bin"

    static func scan() -> [LocalBinFile] {
        let fm = FileManager.default
        var out: [LocalBinFile] = []

        // 1. 用户通过 Files App 主动复制进来的 bin —— 在 Documents 下
        if let docs = try? fm.url(for: .documentDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: false) {
            scanRecursively(root: docs, into: &out, maxDepth: 4)
        }

        // 2. 其它 App 通过「用 氪金之王 打开」传过来的 bin —— 在 Inbox 下
        if let docs = try? fm.url(for: .documentDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: false) {
            let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
            if fm.fileExists(atPath: inbox.path) {
                scanRecursively(root: inbox, into: &out, maxDepth: 2)
            }
        }

        // 按修改时间倒序
        out.sort { $0.modified > $1.modified }
        return out
    }

    private static func scanRecursively(root: URL, into out: inout [LocalBinFile], maxDepth: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let url as URL in enumerator {
            // 跳过 Packages 目录（Codable 文件，名字无 .bin 后缀不会被命中，但保险）
            guard url.pathExtension.lowercased() == "bin" else { continue }
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard vals?.isRegularFile == true else { continue }
            let size = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? Date.distantPast
            out.append(LocalBinFile(url: url, size: size, modified: mtime))
            _ = maxDepth // 实际深度由 enumerator 自身处理
        }
    }

    static func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - 内置选择器 UI（SwiftUI sheet）

struct LocalBinPicker: View {
    var title: String
    var multiSelect: Bool
    var onPick: ([LocalBinFile]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var files: [LocalBinFile] = []
    @State private var selected: Set<URL> = []
    @State private var refreshTrigger = 0
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                    if multiSelect {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("导入 \(selected.count) 个") {
                                let picked = files.filter { selected.contains($0.url) }
                                onPick(picked)
                                dismiss()
                            }
                            .disabled(selected.isEmpty)
                        }
                    }
                }
        }
        .onAppear { reload() }
    }

    @ViewBuilder
    private var content: some View {
        if files.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 36))
                    .foregroundStyle(palette.onSurfaceVariant)
                Text("App 沙盒里没有找到 .bin 文件")
                    .font(.subheadline)
                    .foregroundStyle(palette.onSurfaceVariant)
                Text("""
                请先在 iPhone 打开「文件 App → 我的 iPhone →
                \(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? "氪金之王")」，
                把 bin 文件拷进去或保存到这个目录，然后回这里刷新。
                """)
                    .font(.caption)
                    .foregroundStyle(palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                Button("刷新") { reload() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
            }
            .padding(20)
        } else {
            List {
                    ForEach(files) { f in
                        row(for: f)
                    }
                }
                .listStyle(.plain)
        }
    }

    @ViewBuilder
    private func row(for f: LocalBinFile) -> some View {
        let isSelected = selected.contains(f.url)
        if multiSelect {
            Button {
                if isSelected { selected.remove(f.url) } else { selected.insert(f.url) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? palette.primary : palette.onSurfaceVariant)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.url.lastPathComponent)
                            .font(.subheadline)
                            .foregroundStyle(palette.onSurface)
                        Text("\(LocalBinScanner.formatSize(f.size)) · \(f.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
            .listRowBackground(isSelected ? palette.primary.opacity(0.08) : palette.surface)
        } else {
            Button {
                onPick([f])
                dismiss()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(palette.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.url.lastPathComponent)
                            .font(.subheadline)
                            .foregroundStyle(palette.onSurface)
                        Text("\(LocalBinScanner.formatSize(f.size)) · \(f.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                }
            }
        }
    }

    private func reload() {
        files = LocalBinScanner.scan()
    }
}

// MARK: - 把诊断日志写入 Documents/import.log（让用户能从 Files App 看到）

enum LogFile {
    static var url: URL? {
        try? FileManager.default.url(for: .documentDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil, create: false)
            .appendingPathComponent("import.log")
    }

    @discardableResult
    static func append(_ line: String) -> Bool {
        guard let url else { return false }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(line)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                try h.seekToEnd()
                try h.write(contentsOf: Data(entry.utf8))
                try h.close()
            } else {
                try entry.write(to: url, atomically: true, encoding: .utf8)
            }
            return true
        } catch {
            return false
        }
    }
}