import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SingReadyAISharedKit

final class ShareViewController: UIViewController {
    private let appGroupStore = AppGroupStore()
    private let detector = ShareProviderDetector()
    private var hostController: UIHostingController<ShareExtensionView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        render(
            title: "正在接收歌单分享",
            message: "正在读取链接、文本或图片。",
            source: "识别中",
            preview: "等待分享内容",
            isDone: false
        )
        Task { await extractAndSavePayload() }
    }

    private func render(title: String, message: String, source: String, preview: String, isDone: Bool) {
        let view = ShareExtensionView(
            title: title,
            message: message,
            source: source,
            preview: preview,
            usesFallbackStore: appGroupStore.isUsingFallbackStore(),
            isDone: isDone
        ) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
        if let hostController {
            hostController.rootView = view
        } else {
            let controller = UIHostingController(rootView: view)
            addChild(controller)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            self.view.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                controller.view.topAnchor.constraint(equalTo: self.view.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            ])
            controller.didMove(toParent: self)
            hostController = controller
        }
    }

    private func extractAndSavePayload() async {
        do {
            guard let providers = extensionContext?.inputItems
                .compactMap({ $0 as? NSExtensionItem })
                .flatMap({ $0.attachments ?? [] }),
                !providers.isEmpty else {
                throw ShareExtensionError.noAttachment
            }

            let payload = try await payload(from: providers)
            try appGroupStore.savePendingImport(payload)
            await MainActor.run {
                render(
                    title: "已收到歌单分享",
                    message: "打开 App 完成分析。来源判断：\(payload.sourceHint.displayName)。",
                    source: payload.sourceHint.displayName,
                    preview: payload.previewText,
                    isDone: true
                )
            }
        } catch {
            await MainActor.run {
                render(
                    title: "导入失败",
                    message: error.localizedDescription,
                    source: "未保存",
                    preview: "请返回来源 App 后重试，或在主 App 中粘贴文本。",
                    isDone: true
                )
            }
        }
    }

    private func payload(from providers: [NSItemProvider]) async throws -> PendingImportPayload {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
           let url = try await provider.loadURL() {
            let detected = detector.detect(urlString: url.absoluteString)
            return PendingImportPayload(
                sourceHint: detected.source,
                urlString: url.absoluteString,
                hostAppName: nil,
                displayTitle: detected.source.displayName
            )
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
           let text = try await provider.loadPlainText() {
            let draft = PendingImportPayload(
                sourceHint: .plainText,
                rawText: text,
                hostAppName: nil,
                displayTitle: "分享文本"
            )
            let detected = detector.detect(payload: draft)
            var payload = draft
            payload.sourceHint = detected.source
            return payload
        }

        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
            let fileName = try await saveImage(provider: provider)
            return PendingImportPayload(
                sourceHint: .screenshot,
                imageFileName: fileName,
                hostAppName: nil,
                displayTitle: "分享图片"
            )
        }

        throw ShareExtensionError.unsupportedAttachment
    }

    private func saveImage(provider: NSItemProvider) async throws -> String {
        let directory = try appGroupStore.storeDirectoryURL()
            .appendingPathComponent("shared-images", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let fileName = "\(UUID().uuidString).png"
        let destination = directory.appendingPathComponent(fileName)
        if let sourceURL = try await provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            return "shared-images/\(fileName)"
        }
        throw ShareExtensionError.unsupportedAttachment
    }
}

private extension PendingImportPayload {
    var previewText: String {
        if let displayTitle, !displayTitle.isEmpty {
            if let urlString { return "\(displayTitle)\n\(urlString)" }
            if let rawText { return "\(displayTitle)\n\(rawText)" }
            if let imageFileName { return "\(displayTitle)\n\(imageFileName)" }
        }
        return urlString ?? rawText ?? imageFileName ?? "已保存到待分析队列"
    }
}

private enum ShareExtensionError: Error, LocalizedError {
    case noAttachment
    case unsupportedAttachment

    var errorDescription: String? {
        switch self {
        case .noAttachment: return "没有找到可导入的分享内容。"
        case .unsupportedAttachment: return "当前分享类型暂不支持。"
        }
    }
}

private extension NSItemProvider {
    func loadURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data, let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func loadPlainText() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let string = item as? String {
                    continuation.resume(returning: string)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    func loadFileRepresentation(forTypeIdentifier identifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }
}
