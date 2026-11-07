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

        let cutoff = Date().addingTimeInterval(-max(0, seconds))
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // 不在 predicate 里做 mediaSubtype 位运算：那要求 KVC 认识 "mediaSubtype"
        // 这个键，不同系统版本上会抛「not key value coding-compliant」直接崩掉。
        // 取最近几十张，在内存里按 mediaSubtypes 筛，稳定且够快。
        options.fetchLimit = 60
        let assets = PHAsset.fetchAssets(with: .image, options: options)

        var candidate: PHAsset?
        assets.enumerateObjects { asset, _, stop in
            guard let created = asset.creationDate, created >= cutoff, created <= Date() else { return }
            guard asset.mediaSubtypes.contains(.photoScreenshot) else { return }
            candidate = asset
            stop.pointee = true
        }

        guard let asset = candidate else {
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

            // 回调可能在任意线程来，而且还可能先给一张模糊的、再给清晰的，
            // 没上锁的话两次回调会同时 resume，直接崩在 continuation 上
            let once = ResumeOnce()

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard once.claim() else { return }
                if (info?[PHImageCancelledKey] as? Bool) == true
                    || info?[PHImageErrorKey] != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: image)
                }
            }

            // 兜底：iCloud 原图没下载完、网络断了的时候，PHImageManager 有可能
            // 只给一张 degraded 就再也不回调。不设超时的话快捷指令会一直转圈，
            // 用户以为卡死。8 秒收不了尾就按失败返回。
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 8) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// 保证只 resume 一次。
///
/// 不能写成闭包里的局部 class —— Swift 不允许类型嵌套在闭包内；
/// 也不该直接用裸 Bool，PHImageManager 的回调可能来自不同线程。
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
