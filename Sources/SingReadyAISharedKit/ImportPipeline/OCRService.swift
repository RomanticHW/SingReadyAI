import Foundation

#if canImport(Vision) && canImport(UIKit)
import UIKit
import Vision
#endif

public enum OCRServiceError: Error, LocalizedError, Equatable {
    case unsupportedPlatform
    case noTextRecognized
    case imageLoadFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform: return "当前平台不支持 Vision OCR"
        case .noTextRecognized: return "未识别到歌曲，建议裁剪截图或粘贴文本"
        case .imageLoadFailed: return "图片读取失败"
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
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else {
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
