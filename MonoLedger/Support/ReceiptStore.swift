//
//  ReceiptStore.swift
//  MonoLedger
//
//  凭证图片：压缩后随账单一起保存，随时能翻回原图
//

import UIKit
import ImageIO

enum ReceiptStore {
    /// 长边 1200 / JPEG 0.62
    ///
    /// 一张 iPhone 截图约 1170×2532，缩到长边 1200 后是原图的一半分辨率，
    /// 放进手机上双指放大，商户名、订单号、金额仍然清楚，报销对账够用；
    /// 体积从 1~3MB 降到 80~150KB，一千笔账单的凭证图也就一百多兆。
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

    static func compress(_ image: UIImage,
                         maxDimension: CGFloat = 1200,
                         quality: CGFloat = 0.62) -> Data? {
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
        return resized.jpegData(compressionQuality: quality)
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
