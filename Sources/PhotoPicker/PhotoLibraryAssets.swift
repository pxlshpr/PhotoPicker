import AVFoundation
import Photos
import UIKit

/// A picked image together with the library asset it came from, so a caller
/// can fetch the same asset again later (`PhotoLibraryAssets.image(localIdentifier:)`).
public struct PickedImage {
    public let image: UIImage
    /// `PHAsset.localIdentifier` of the picked asset.
    public let assetIdentifier: String

    public init(image: UIImage, assetIdentifier: String) {
        self.image = image
        self.assetIdentifier = assetIdentifier
    }
}

/// A picked video, exported to a temp file, together with the library asset
/// it came from, so a caller can export the same asset again later
/// (`PhotoLibraryAssets.exportVideo(localIdentifier:)`).
public struct PickedVideo: Hashable, Sendable {
    public let url: URL
    /// `PHAsset.localIdentifier` of the picked asset.
    public let assetIdentifier: String

    public init(url: URL, assetIdentifier: String) {
        self.url = url
        self.assetIdentifier = assetIdentifier
    }
}

/// Fetches library assets by identifier — what a picked asset's identifier
/// is for. The picker's own deliveries run through the same calls, so a
/// re-fetch yields exactly what the original pick did (current edits
/// applied, iCloud originals downloaded).
public enum PhotoLibraryAssets {
    /// True when every identifier still names an asset in the library the
    /// app can see — false once one has been deleted, or access revoked.
    public static func contains(_ identifiers: [String]) -> Bool {
        guard !identifiers.isEmpty else { return false }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return false }
        let unique = Set(identifiers)
        let result = PHAsset.fetchAssets(withLocalIdentifiers: Array(unique), options: nil)
        return result.count == unique.count
    }

    /// Exports the video asset `localIdentifier` names to a temp file. Nil
    /// when the asset is gone or the export fails.
    public static func exportVideo(localIdentifier: String) async -> URL? {
        guard let asset = asset(localIdentifier) else { return nil }
        return await exportVideo(for: asset)
    }

    /// The full-resolution image of the asset `localIdentifier` names. Nil
    /// when the asset is gone or can't be loaded.
    public static func image(localIdentifier: String) async -> UIImage? {
        guard let asset = asset(localIdentifier) else { return nil }
        return await fullImage(for: asset)
    }

    private static func asset(_ localIdentifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject
    }

    static func fullImage(for asset: PHAsset) async -> UIImage? {
        let resumer = ResumeOnce<UIImage?>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                let image = data.flatMap { UIImage(data: $0) }
                resumer.tryResume(continuation, with: image)
            }
        }
    }

    static func exportVideo(for asset: PHAsset) async -> URL? {
        // Ask PhotoKit to compose the asset with its *current* adjustments
        // applied (trims, etc). Picking the `.video` PHAssetResource and
        // writing its raw bytes would always return the unedited original,
        // since edits in Photos are stored as a separate adjustment layer.
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopicker-\(UUID().uuidString).mov")
        try? FileManager.default.removeItem(at: dest)

        let resumer = ResumeOnce<AVAssetExportSession?>()
        let session = await withCheckedContinuation { (continuation: CheckedContinuation<AVAssetExportSession?, Never>) in
            PHImageManager.default().requestExportSession(
                forVideo: asset,
                options: options,
                exportPreset: AVAssetExportPresetPassthrough
            ) { session, _ in
                resumer.tryResume(continuation, with: session)
            }
        }
        guard let session else { return nil }

        do {
            try await session.export(to: dest, as: .mov)
            return dest
        } catch {
            return nil
        }
    }
}
