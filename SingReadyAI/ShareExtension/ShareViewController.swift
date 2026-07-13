import SwiftUI
import UIKit
import UniformTypeIdentifiers
import SingReadyAISharedKit

@MainActor
final class ShareViewController: UIViewController {
    private let appGroupStore = AppGroupStore()
    private let payloadAssembler = SharePayloadAssembler()
    private let fallbackPolicy = SharePayloadFallbackPolicy()
    private let extractionDeadline = ShareExtractionDeadline()
    private let representationLoadCoordinator = ShareRepresentationLoadCoordinator()
    private var hostController: UIHostingController<ShareExtensionView>?
    private var extractionTask: Task<Void, Never>?
    private var stagingCleanupTask: Task<Void, Never>?
    private var extractionGate = ShareExtractionRequestGate()
    private var extractionParts: [SharePayloadPart] = []
    private var stagedImageDuringExtraction: StagedSharedImage?
    private var extractionIncludedScreenshot = false

    override func viewDidLoad() {
        super.viewDidLoad()
        render(
            title: "正在接收这份歌单",
            message: "正在把这次分享的链接、文字或截图放进来。",
            source: "正在整理",
            preview: "等一下，正在读取分享内容",
            state: .loading
        )
        stagingCleanupTask = Task { [appGroupStore] in
            _ = try? await appGroupStore.removeExpiredStagedSharedImages(
                deadline: MonotonicOperationDeadline(timeoutNanoseconds: 250_000_000)
            )
        }
        guard let requestToken = extractionGate.beginIfIdle() else { return }
        extractionTask = Task { [weak self] in
            await self?.extractAndSavePayload(requestToken: requestToken)
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stagingCleanupTask?.cancel()
        stagingCleanupTask = nil
        cancelExtraction()
    }

    private func render(
        title: String,
        message: String,
        source: String,
        preview: String,
        fallbackCopyText: String? = nil,
        state: ShareExtensionViewState
    ) {
        let view = ShareExtensionView(
            title: title,
            message: message,
            source: source,
            preview: preview,
            fallbackCopyText: fallbackCopyText,
            state: state,
            onCopy: { UIPasteboard.general.string = $0 },
            onCancel: { [weak self] in
                self?.cancelAndCloseExtension()
            }
        ) { [weak self] in
            self?.completeExtension()
        }
        if let hostController {
            hostController.rootView = view
        } else {
            let controller = UIHostingController(rootView: view)
            controller.overrideUserInterfaceStyle = .dark
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

    private struct ExtractedSharePayload {
        let payload: PendingImportPayload
        let stagedImage: StagedSharedImage?
    }

    private func extractAndSavePayload(requestToken: UInt64) async {
        var extractedPayload: ExtractedSharePayload?
        resetExtractionProgress()
        defer { finishExtraction(requestToken: requestToken) }

        do {
            guard let providers = extensionContext?.inputItems
                .compactMap({ $0 as? NSExtensionItem })
                .flatMap({ $0.attachments ?? [] }),
                !providers.isEmpty else {
                throw ShareExtensionError.noAttachment
            }
            extractionIncludedScreenshot = providers.contains {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            }
            let operationDeadline = extractionDeadline.makeDeadline()
            let extracted = try await extractionDeadline.perform(until: operationDeadline) { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.payload(from: providers)
            }
            extractedPayload = extracted
            try ensureRequestCanCommit(requestToken)

            if appGroupStore.isUsingFallbackStore() {
                discardTrackedStagedImage()
                renderFallback(for: extracted.payload)
                return
            }

            let committedPayload = try await extractionDeadline.perform(until: operationDeadline) { [weak self] in
                guard let self else { throw CancellationError() }
                try self.ensureRequestCanCommit(requestToken)
                return try await self.appGroupStore.commitPendingImport(
                    extracted.payload,
                    stagedImage: extracted.stagedImage,
                    deadline: operationDeadline
                )
            }
            try ensureRequestCanCommit(requestToken)
            stagedImageDuringExtraction = nil
            render(
                title: "歌单已收到",
                message: "回到今晚唱什么，看一眼歌名是否正确。来自：\(committedPayload.sourceHint.displayName)。",
                source: committedPayload.sourceHint.displayName,
                preview: committedPayload.previewText,
                state: .success
            )
        } catch let error as ShareExtractionDeadlineError where error == .timedOut {
            discardTrackedStagedImage()
            guard extractionGate.canCommit(requestToken) else { return }
            renderExtractionTimeoutFallback()
        } catch let error as AppGroupStoreError where error == .operationTimedOut {
            discardTrackedStagedImage()
            guard extractionGate.canCommit(requestToken) else { return }
            renderExtractionTimeoutFallback()
        } catch is CancellationError {
            discardTrackedStagedImage()
        } catch {
            discardTrackedStagedImage()
            guard extractionGate.canCommit(requestToken) else { return }
            if let payload = extractedPayload?.payload {
                renderFallback(for: payload)
            } else {
                render(
                    title: "这次没存好",
                    message: error.localizedDescription,
                    source: "没保存",
                    preview: "可以回到刚才的页面再分享一次，或者打开今晚唱什么粘贴文本。",
                    state: .failure
                )
            }
        }
    }

    private func payload(from providers: [NSItemProvider]) async throws -> ExtractedSharePayload {
        var parts: [SharePayloadPart] = []
        var stagedImage: StagedSharedImage?
        var sawSupportedRepresentation = false
        var textualRepresentations: [ShareRepresentationLoad] = []

        do {
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    sawSupportedRepresentation = true
                    textualRepresentations.append(ShareRepresentationLoad {
                        if let url = try await provider.loadURL() {
                            return SharePayloadPart(urlString: url.absoluteString)
                        }
                        return nil
                    })
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    sawSupportedRepresentation = true
                    textualRepresentations.append(ShareRepresentationLoad {
                        if let text = try await provider.loadPlainText() {
                            return SharePayloadPart(rawText: text)
                        }
                        return nil
                    })
                }
            }

            parts = try await representationLoadCoordinator.load(
                textualRepresentations,
                onUpdate: { [weak self] loadedParts in
                    self?.extractionParts = loadedParts
                }
            )
            try Task.checkCancellation()

            if let imageProvider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            }) {
                sawSupportedRepresentation = true
                do {
                    let image = try await imageProvider.stageFileRepresentation(
                        forTypeIdentifier: UTType.image.identifier,
                        in: appGroupStore
                    )
                    stagedImage = image
                    stagedImageDuringExtraction = image
                    let part = SharePayloadPart(imageFileName: image.relativePath)
                    parts.append(part)
                    extractionParts = parts
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let hasUsableTextualPart = (try? payloadAssembler.assemble(parts: parts)) != nil
                    guard hasUsableTextualPart else { throw error }
                }
            }

            try Task.checkCancellation()
            let payload = try payloadAssembler.assemble(parts: parts)
            return ExtractedSharePayload(payload: payload, stagedImage: stagedImage)
        } catch {
            discardTrackedStagedImage()
            if !sawSupportedRepresentation {
                throw ShareExtensionError.unsupportedAttachment
            }
            throw error
        }
    }

    private func renderFallback(for payload: PendingImportPayload) {
        let presentation = fallbackPolicy.storageFailurePresentation(for: payload)
        render(
            title: presentation.title,
            message: presentation.message,
            source: presentation.source,
            preview: presentation.preview,
            fallbackCopyText: presentation.fallbackCopyText,
            state: .failure
        )
    }

    private func renderExtractionTimeoutFallback() {
        let partialPayload = try? payloadAssembler.assemble(parts: extractionParts)
        let presentation = fallbackPolicy.extractionTimeoutPresentation(
            for: partialPayload,
            includedScreenshot: extractionIncludedScreenshot
        )
        render(
            title: presentation.title,
            message: presentation.message,
            source: presentation.source,
            preview: presentation.preview,
            fallbackCopyText: presentation.fallbackCopyText,
            state: .failure
        )
    }

    private func ensureRequestCanCommit(_ requestToken: UInt64) throws {
        try Task.checkCancellation()
        guard extractionGate.canCommit(requestToken) else {
            throw CancellationError()
        }
    }

    private func finishExtraction(requestToken: UInt64) {
        guard extractionGate.finish(requestToken) else { return }
        extractionTask = nil
        resetExtractionProgress()
    }

    private func cancelExtraction() {
        extractionGate.cancel()
        extractionTask?.cancel()
        extractionTask = nil
        discardTrackedStagedImage()
        resetExtractionProgress()
    }

    private func discardTrackedStagedImage() {
        guard let stagedImageDuringExtraction else { return }
        self.stagedImageDuringExtraction = nil
        try? appGroupStore.discardStagedSharedImage(stagedImageDuringExtraction)
    }

    private func resetExtractionProgress() {
        extractionParts = []
        stagedImageDuringExtraction = nil
        extractionIncludedScreenshot = false
    }

    private func cancelAndCloseExtension() {
        cancelExtraction()
        extensionContext?.cancelRequest(
            withError: NSError(
                domain: NSCocoaErrorDomain,
                code: NSUserCancelledError,
                userInfo: [NSLocalizedDescriptionKey: "已取消本次分享"]
            )
        )
    }

    private func completeExtension() {
        cancelExtraction()
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private extension PendingImportPayload {
    var previewText: String {
        if let displayTitle, !displayTitle.isEmpty {
            if let urlString { return "\(displayTitle)\n\(urlString)" }
            if let rawText { return "\(displayTitle)\n\(rawText)" }
            if imageFileName != nil { return "\(displayTitle)\n已收到一张截图" }
        }
        return urlString ?? rawText ?? (imageFileName == nil ? nil : "已收到一张截图") ?? "已保存，回到今晚唱什么继续"
    }
}

private enum ShareExtensionError: Error, LocalizedError {
    case noAttachment
    case unsupportedAttachment

    var errorDescription: String? {
        switch self {
        case .noAttachment: return "没找到能保存的歌单内容。"
        case .unsupportedAttachment: return "这个内容暂时放不进来。"
        }
    }
}

private extension NSItemProvider {
    func loadURL() async throws -> URL? {
        try await ShareItemLoadBridge().load { completion in
            self.loadObject(ofClass: URL.self) { url, error in
                if let error {
                    _ = completion(.failure(error))
                } else {
                    _ = completion(.success(url))
                }
            }
        }
    }

    func loadPlainText() async throws -> String? {
        try await ShareItemLoadBridge().load { completion in
            self.loadFileRepresentation(forTypeIdentifier: UTType.plainText.identifier) { url, error in
                if let error {
                    _ = completion(.failure(error))
                } else if let url {
                    do {
                        _ = completion(.success(
                            try BoundedShareTextFileReader().plainText(from: url)
                        ))
                    } catch {
                        _ = completion(.failure(error))
                    }
                } else {
                    _ = completion(.failure(ShareExtensionError.unsupportedAttachment))
                }
            }
        }
    }

    func stageFileRepresentation(
        forTypeIdentifier identifier: String,
        in store: AppGroupStore
    ) async throws -> StagedSharedImage {
        try await ShareItemLoadBridge().load { completion in
            self.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                if let error {
                    _ = completion(.failure(error))
                } else if let url {
                    do {
                        let stagedImage = try store.stageSharedImage(from: url)
                        guard completion(.success(stagedImage)) else {
                            try? store.discardStagedSharedImage(stagedImage)
                            return
                        }
                    } catch {
                        _ = completion(.failure(error))
                    }
                } else {
                    _ = completion(.failure(ShareExtensionError.unsupportedAttachment))
                }
            }
        }
    }
}
