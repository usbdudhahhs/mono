//
//  LatestScreenshot.swift
//  MonoLedger
//
//  从相册里挑出刚截的那张图。
//  用它的原因：iOS 不允许 App 在后台截取别的 App 的屏幕，
//  但「轻点背面」触发时，用户通常刚按过物理键截屏，图已经在相册里了。
//

import Foundation
import Photos
import UIKit

enum LatestScreenshotError: LocalizedError {
    case denied
    case notFound

    var errorDescription: String? {
        switch self {
        case .denied:
            return "需要相册权限才能拿到刚截的图。打开 MONO 允许一次就好。"
        case .notFound:
            return "没找到 15 分钟内的截图。先按侧边键 + 音量上键截个屏，再轻点背面。"
        }
    }
}

enum LatestScreenshot {
    /// 只认这么久以内的截图，避免把旧图记成今天这笔
    static let window: TimeInterval = 15 * 60

    /// 首次启动时问一次权限，否则后台触发时弹不出授权框
    static func prepare() {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined else { return }
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }
    }

    static var isAuthorized: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// 相册里最近的一张截图（限定时间窗口）
    static func recent(within seconds: TimeInterval = window) async throws -> UIImage {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        var current = status
        if status == .notDetermined {
            current = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard current == .authorized || current == .limited else {
            throw LatestScreenshotError.denied
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 16

        let assets = PHAsset.fetchAssets(with: .image, options: options)
        var picked: PHAsset?

        assets.enumerateObjects { asset, _, stop in
            // 相册里既有照片也有截图，只认截图
            guard asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            picked = asset
            stop.pointee = true
        }

        guard let asset = picked,
              let created = asset.creationDate,
              Date().timeIntervalSince(created) <= seconds else {
            throw LatestScreenshotError.notFound
        }

        guard let image = await load(asset) else {
            throw LatestScreenshotError.notFound
        }
        return image
    }

    private static func load(_ asset: PHAsset, maxPixel: CGFloat = 2200) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .downscale
            options.isNetworkAccessAllowed = true

            var finished = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                // 低清图先回调一次，高清再来一次，只要第一张
                guard !finished else { return }
                finished = true
                continuation.resume(returning: image)
            }
        }
    }
}
