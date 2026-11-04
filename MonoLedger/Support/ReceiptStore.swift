//
//  ReceiptStore.swift
//  MonoLedger
//
//  凭证图片：压缩后随账单一起保存，随时能翻回原图
//

import UIKit

enum ReceiptStore {
    /// 长边压到 1600，JPEG 0.72 —— 一张截图大约 200~400KB，看得清字又不占地方
    static func compress(_ image: UIImage,
                         maxDimension: CGFloat = 1600,
                         quality: CGFloat = 0.72) -> Data? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }

        let longest = max(size.width, size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let target = CGSize(width: max(1, (size.width * scale).rounded()),
                            height: max(1, (size.height * scale).rounded()))

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
}
