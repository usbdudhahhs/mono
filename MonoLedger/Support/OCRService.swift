//
//  OCRService.swift
//  MonoLedger
//
//  用 Vision 做端上文字识别，图片不出设备
//

import UIKit
import Vision
import ImageIO

// MARK: - 识别出的一行

struct OCRLine: Identifiable {
    let id = UUID()
    /// 文本内容
    let text: String
    /// 置信度 0...1
    let confidence: Float
    /// 归一化高度，用来判断字号大小（账单详情页的金额永远是最大的那个）
    let height: CGFloat
    /// 归一化坐标，原点在左下角
    let box: CGRect

    /// 字号是否明显大于其他文字
    func isLarge(comparedTo maxHeight: CGFloat) -> Bool {
        maxHeight > 0 && height / maxHeight > 0.72
    }
}

// MARK: - 错误

enum OCRError: LocalizedError {
    case invalidImage
    case noText

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "这张图片读不出来，换一张试试"
        case .noText:       return "图里没找到文字，可能是截得太小了"
        }
    }
}

// MARK: - 识别

enum OCRService {
    /// 识别图片中的文字，按从上到下的顺序返回
    static func recognize(_ image: UIImage) async throws -> [OCRLine] {
        guard let cgImage = prepare(image) else { throw OCRError.invalidImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        let lines: [OCRLine] = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]
                request.usesLanguageCorrection = true
                // 账单里的小字也要读到，阈值放低
                request.minimumTextHeight = 0.006

                let handler = VNImageRequestHandler(cgImage: cgImage,
                                                    orientation: orientation,
                                                    options: [:])
                do {
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let result: [OCRLine] = observations.compactMap { obs in
                        guard let candidate = obs.topCandidates(1).first else { return nil }
                        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return OCRLine(text: text,
                                       confidence: candidate.confidence,
                                       height: obs.boundingBox.height,
                                       box: obs.boundingBox)
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        guard !lines.isEmpty else { throw OCRError.noText }

        // Vision 原点在左下角，按 y 从大到小排版
        return lines.sorted { $0.box.midY > $1.box.midY }
    }

    /// 缩到合理尺寸再识别：太大拖慢速度，太小丢字
    private static func prepare(_ image: UIImage, maxDimension: CGFloat = 2400) -> CGImage? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }

        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image.cgImage }

        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.cgImage
    }
}

// MARK: - 方向映射

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up:            self = .up
        case .down:          self = .down
        case .left:          self = .left
        case .right:         self = .right
        case .upMirrored:    self = .upMirrored
        case .downMirrored:  self = .downMirrored
        case .leftMirrored:  self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default:    self = .up
        }
    }
}
