import Foundation

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

#if canImport(Vision) && canImport(UIKit)
import UIKit
import Vision
#endif

public enum ImageImportSafetyError: Error, LocalizedError, Equatable, Sendable {
    case invalidImage
    case fileTooLarge
    case pixelLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "这张图没读出来，请重新选择后再试。"
        case .fileTooLarge:
            return "这张图太大了，请先裁一下再试。"
        case .pixelLimitExceeded:
            return "这张图的尺寸太大了，请先裁一下再试。"
        }
    }
}

public struct ImagePixelDimensions: Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct ImageImportLimits: Equatable, Sendable {
    public static let `default` = ImageImportLimits()

    public let maximumPixelCount: Int
    public let maximumDimension: Int
    public let thumbnailMaximumDimension: Int

    public init(
        maximumPixelCount: Int = 24_000_000,
        maximumDimension: Int = 12_000,
        thumbnailMaximumDimension: Int = 4_096
    ) {
        self.maximumPixelCount = max(1, maximumPixelCount)
        self.maximumDimension = max(1, maximumDimension)
        self.thumbnailMaximumDimension = max(1, thumbnailMaximumDimension)
    }

    @discardableResult
    public func validate(width: Int, height: Int) throws -> ImagePixelDimensions {
        guard width > 0, height > 0 else {
            throw ImageImportSafetyError.invalidImage
        }
        guard width <= maximumDimension,
              height <= maximumDimension,
              width <= maximumPixelCount / height else {
            throw ImageImportSafetyError.pixelLimitExceeded
        }
        return ImagePixelDimensions(width: width, height: height)
    }
}

public struct ImageImportInspector: Sendable {
    public let limits: ImageImportLimits

    public init(limits: ImageImportLimits = .default) {
        self.limits = limits
    }

    public func inspectImage(at url: URL) throws -> ImagePixelDimensions {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
            throw ImageImportSafetyError.invalidImage
        }
        return try inspectImage(source: source, options: options)
        #else
        throw ImageImportSafetyError.invalidImage
        #endif
    }

    public func inspectImage(data: Data) throws -> ImagePixelDimensions {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw ImageImportSafetyError.invalidImage
        }
        return try inspectImage(source: source, options: options)
        #else
        throw ImageImportSafetyError.invalidImage
        #endif
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    func inspectImage(
        source: CGImageSource,
        options: CFDictionary
    ) throws -> ImagePixelDimensions {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            throw ImageImportSafetyError.invalidImage
        }
        return try limits.validate(width: width, height: height)
    }
    #endif
}

public struct OCRTemporaryFileStore: Sendable {
    public static let fileNamePrefix = "singready-ocr-"

    private let directory: URL
    private let maximumImageBytes: Int
    private let beforeImagePreparation: @Sendable () -> Void

    public init(
        directory: URL = FileManager.default.temporaryDirectory,
        maximumImageBytes: Int = 25_000_000
    ) {
        self.init(
            directory: directory,
            maximumImageBytes: maximumImageBytes,
            beforeImagePreparation: {}
        )
    }

    init(
        directory: URL,
        maximumImageBytes: Int = 25_000_000,
        beforeImagePreparation: @escaping @Sendable () -> Void
    ) {
        self.directory = directory
        self.maximumImageBytes = max(1, maximumImageBytes)
        self.beforeImagePreparation = beforeImagePreparation
    }

    public func makeTemporaryURL() -> URL {
        directory.appendingPathComponent(
            "\(Self.fileNamePrefix)\(UUID().uuidString).png",
            isDirectory: false
        )
    }

    public func prepareImageFile(from sourceURL: URL) async throws -> URL {
        let worker = Task.detached(priority: .utility) { [self] in
            try prepareImageFileSynchronously(from: sourceURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func removePreparedImage(at url: URL) async throws {
        try await Task.detached(priority: .utility) { [self] in
            try removePreparedImageSynchronously(at: url)
        }.value
    }

    public func removeOrphans() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsSubdirectoryDescendants]
        )
        for url in urls where url.lastPathComponent.hasPrefix(Self.fileNamePrefix) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepareImageFileSynchronously(from sourceURL: URL) throws -> URL {
        try Task.checkCancellation()
        let sourceValues = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceSize = sourceValues.fileSize,
              sourceSize > 0 else {
            throw ImageImportSafetyError.invalidImage
        }
        guard sourceSize <= maximumImageBytes else {
            throw ImageImportSafetyError.fileTooLarge
        }

        beforeImagePreparation()
        try Task.checkCancellation()
        _ = try ImageImportInspector().inspectImage(at: sourceURL)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let destinationURL = makeTemporaryURL()
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try Task.checkCancellation()
            let destinationValues = try destinationURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard destinationValues.isRegularFile == true,
                  destinationValues.isSymbolicLink != true,
                  let destinationSize = destinationValues.fileSize,
                  destinationSize > 0 else {
                throw ImageImportSafetyError.invalidImage
            }
            guard destinationSize <= maximumImageBytes else {
                throw ImageImportSafetyError.fileTooLarge
            }
            _ = try ImageImportInspector().inspectImage(at: destinationURL)
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func removePreparedImageSynchronously(at url: URL) throws {
        let standardizedDirectory = directory.standardizedFileURL
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.deletingLastPathComponent() == standardizedDirectory,
              standardizedURL.lastPathComponent.hasPrefix(Self.fileNamePrefix) else {
            throw ImageImportSafetyError.invalidImage
        }
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else { return }
        try FileManager.default.removeItem(at: standardizedURL)
    }
}

#if canImport(CoreGraphics) && canImport(ImageIO)
struct OCRImageLoader: Sendable {
    let limits: ImageImportLimits

    init(limits: ImageImportLimits = .default) {
        self.limits = limits
    }

    func loadThumbnail(at url: URL) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImageImportSafetyError.invalidImage
        }
        let dimensions = try ImageImportInspector(limits: limits).inspectImage(
            source: source,
            options: sourceOptions
        )
        let thumbnailSize = min(
            limits.thumbnailMaximumDimension,
            max(dimensions.width, dimensions.height)
        )
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ImageImportSafetyError.invalidImage
        }
        return image
    }
}
#endif

public enum OCRServiceError: Error, LocalizedError, Equatable {
    case unsupportedPlatform
    case noTextRecognized
    case imageLoadFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "这台设备暂时不能从截图里找歌名"
        case .noTextRecognized: return "没从截图里看到歌名，建议裁剪后再试，或直接粘贴文本"
        case .imageLoadFailed: return "这张图没读出来"
        }
    }
}

public protocol OCRServicing: Sendable {
    func recognizeText(fromImageAt url: URL) async throws -> String
}

public struct MockOCRService: OCRServicing {
    private let text: String

    public init(text: String = "周杰伦 - 晴天\n陈奕迅《十年》\n五月天 - 突然好想你") {
        self.text = text
    }

    public func recognizeText(fromImageAt url: URL) async throws -> String {
        text
    }
}

public typealias FakeOCRService = MockOCRService

#if canImport(Vision) && canImport(UIKit)
public struct VisionOCRService: OCRServicing {
    public init() {}

    public func recognizeText(fromImageAt url: URL) async throws -> String {
        let cgImage: CGImage
        do {
            cgImage = try OCRImageLoader().loadThumbnail(at: url)
        } catch let error as ImageImportSafetyError {
            if error == .invalidImage {
                throw OCRServiceError.imageLoadFailed
            }
            throw error
        } catch {
            throw OCRServiceError.imageLoadFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let text = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n") ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continuation.resume(throwing: OCRServiceError.noTextRecognized)
                } else {
                    continuation.resume(returning: text)
                }
            }
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cgImage)
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
#else
public struct VisionOCRService: OCRServicing {
    public init() {}

    public func recognizeText(fromImageAt url: URL) async throws -> String {
        throw OCRServiceError.unsupportedPlatform
    }
}
#endif
