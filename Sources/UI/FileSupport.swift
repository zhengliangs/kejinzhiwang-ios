import SwiftUI
import UniformTypeIdentifiers

// 文件导入导出需要的几个小组件。
// 安卓版用 ActivityResultContracts（CreateDocument / OpenDocument /
// OpenDocumentTree），iOS 对应 fileExporter / fileImporter /
// UIDocumentPickerViewController(folder)。

/// .bin 文件的导出载体
struct BinDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 选择文件夹，用于批量导出。iOS 上没有 OpenDocumentTree 的直接对应物，
/// 用 UIDocumentPickerViewController 打开 folder 并申请安全作用域访问。
struct FolderPicker: UIViewControllerRepresentable {

    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

/// 在安全作用域内把账号批量写入用户选中的目录，返回结果文案
enum AccountExporter {
    static func exportAll(_ accounts: [AccountItem], to folder: URL) -> String {
        // 选中的目录在沙箱外，必须显式申请访问
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }

        var ok = 0
        var fail = 0
        for acc in accounts {
            // 文件名里的非法字符会让创建失败
            let safe = bonSafeFileName(acc.displayName)
            let target = folder.appendingPathComponent("\(safe).bin")
            do {
                try acc.binData.write(to: target)
                ok += 1
            } catch {
                fail += 1
            }
        }
        return fail == 0 ? "已导出 \(ok) 个账号" : "已导出 \(ok) 个，失败 \(fail) 个"
    }
}
