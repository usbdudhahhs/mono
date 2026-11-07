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
        guard let prepared = prepare(image) else { throw OCRError.invalidImage }
        let cgImage = prepared.cgImage
        let orientation = prepared.orientation

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

    /// 预处理结果：像素 + 该像素对应的方向
    private struct Prepared {
        let cgImage: CGImage
        let orientation: CGImagePropertyOrientation
    }

    /// 缩到合理尺寸再识别：太大拖慢速度，太小丢字
    ///
    /// 方向必须跟着像素一起返回：缩放用的 `UIImage.draw(in:)` 会把方向烘焙进像素，
    /// 此时再拿原图的 orientation 交给 Vision，就会二次旋转，竖拍 / 横拍的照片整页侧躺。
    /// 未缩放时像素仍是原始朝向，才需要用原图的方向信息。
    private static func prepare(_ image: UIImage, maxDimension: CGFloat = 2400) -> Prepared? {
        guard let source = image.cgImage,
              source.width > 1, source.height > 1 else { return nil }

        // 画布尺寸要按「摆正后」的宽高算。竖拍的照片 cgImage 是横的（4032×3024），
        // 直接拿它建横画布再 draw，会把竖图压扁，字全挤在一起，识别率直线下降
        let pixelSize = ReceiptStore.pixelSize(of: image)
        let longest = max(pixelSize.width, pixelSize.height)

        guard longest > maxDimension else {
            return Prepared(cgImage: source,
                            orientation: CGImagePropertyOrientation(image.imageOrientation))
        }

        let scale = maxDimension / longest
        let target = CGSize(width: max(1, (pixelSize.width * scale).rounded()),
                            height: max(1, (pixelSize.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cgImage = resized.cgImage else { return nil }
        return Prepared(cgImage: cgImage, orientation: .up)
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
