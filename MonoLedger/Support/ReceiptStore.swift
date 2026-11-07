//
//  ReceiptStore.swift
//  MonoLedger
//
//  凭证图片：压缩后随账单一起保存，随时能翻回原图
//

import UIKit
import ImageIO

enum ReceiptStore {
    /// 长边 1080。
    ///
    /// 这个数字是按「看得清」倒推的，不是按「压得小」：
    /// - iPhone 截图宽 1170，缩到 1080 几乎不损失横向像素，正文小字不会糊
    /// - 相机照片 4032×3024 缩到 1080 后，全屏放大一倍仍能读出商户名和订单号
    /// - 再往下（800）金额末两位就开始发虚，报销对账时反而要用户重拍
    static let maxDimension: CGFloat = 1080

    /// 单张目标体积 140KB。质量不够就降档，降到底还超就认了 ——
    /// 宁可多占一点空间，也不让用户放大后看不清数字。
    static let targetBytes = 140_000

    /// JPEG 质量候选，从高往低试，取第一个满足体积的
    static let qualitySteps: [CGFloat] = [0.72, 0.62, 0.52]

    /// 摆正后的像素尺寸。
    ///
    /// 相机竖着拍的照片，`cgImage` 存的是横的（4032×3024），真正的方向记在
    /// `imageOrientation = .right` 里。只按 cgImage 的宽高算缩放，竖图会被当成横图，
    /// 压出来要么裁掉一半、要么拉成扁的 —— 报销时连金额都认不出来。
    static func pixelSize(of image: UIImage) -> CGSize {
        let raw = image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: image.size.width * image.scale,
                      height: image.size.height * image.scale)
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored:
            return CGSize(width: raw.height, height: raw.width)
        default:
            return raw
        }
    }

    /// 缩到长边 maxDimension，再按质量档位试，取第一个落在 targetBytes 以内的。
    /// 三档都不达标时返回最低档的结果（仍然比原图小得多），不返回 nil ——
    /// 返回 nil 会让调用方以为「这张图不能用」，实际上它只是有点大。
    static func compress(_ image: UIImage,
                         maxDimension: CGFloat = ReceiptStore.maxDimension) -> Data? {
        // 按像素算，不按 point：有些来源（相机、相册转码）给的 UIImage 是 2x/3x，
        // 用 size（point）判断会以为图很小而不缩，或缩完只剩三分之一分辨率，
        // 报销时放大看不清商户名
        let source = pixelSize(of: image)
        let sourceW = source.width
        let sourceH = source.height
        guard sourceW > 1, sourceH > 1 else { return nil }

        let longest = max(sourceW, sourceH)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: max(1, (sourceW * scale).rounded()),
                            height: max(1, (sourceH * scale).rounded()))

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fill(CGRect(origin: .zero, size: target))
            image.draw(in: CGRect(origin: .zero, size: target))
        }

        var fallback: Data?
        for quality in qualitySteps {
            guard let data = resized.jpegData(compressionQuality: quality) else { continue }
            if data.count <= targetBytes { return data }
            fallback = data
        }
        return fallback ?? resized.jpegData(compressionQuality: qualitySteps.last ?? 0.5)
    }

    static func image(from data: Data?) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }
        return UIImage(data: data)
    }

    // MARK: - 缩略图

    /// 附件墙用。几十张图同时出现在屏幕上，直接解全尺寸会卡，
    /// 这里让 ImageIO 只解到目标尺寸，并用 NSCache 记住结果。
    private static let thumbnailCache = NSCache<NSString, UIImage>()

    static func thumbnail(_ data: Data?, key: String, maxDimension: CGFloat = 360) -> UIImage? {
        guard let data, !data.isEmpty else { return nil }

        // 缓存键要带上图片内容指纹：换掉凭证图后 uuid 不变，
        // 只用 uuid 会一直显示换图前的旧缩略图
        let cacheKey = "\(key)-\(data.count)-\(data.hashValue)-\(Int(maxDimension))" as NSString
        if let hit = thumbnailCache.object(forKey: cacheKey) { return hit }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }

        let image = UIImage(cgImage: cg)
        thumbnailCache.setObject(image, forKey: cacheKey)
        return image
    }

    /// 给界面看的体积文案
    static func sizeText(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
        return "\(max(1, bytes / 1024)) KB"
    }
}
