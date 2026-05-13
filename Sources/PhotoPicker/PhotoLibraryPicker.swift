import SwiftUI
import Photos
import PhotosUI
import UniformTypeIdentifiers
import RemoteLogger

/// Identifies which slice of the photo library the picker grid is currently showing.
///
/// `.recents` is the default and reads from the prewarmer's cache. The other cases
/// fetch on demand when first selected.
public enum PhotoLibrarySource: Hashable, Sendable {
    case recents
    case favorites
    case videos
    case screenshots
    case album(localIdentifier: String, title: String)

    public var title: String {
        switch self {
        case .recents: "Recents"
        case .favorites: "Favorites"
        case .videos: "Videos"
        case .screenshots: "Screenshots"
        case .album(_, let title): title
        }
    }

    public var systemImage: String {
        switch self {
        case .recents: "clock"
        case .favorites: "heart"
        case .videos: "play.rectangle"
        case .screenshots: "camera.viewfinder"
        case .album: "rectangle.stack"
        }
    }
}

/// A custom PhotoKit-backed photo/video picker that replaces `PHPickerViewController`.
///
/// Built on top of `PHAsset` + `PHCachingImageManager` so the grid scrolls smoothly the
/// instant it appears (the remote-extension scroll-reset bug in `PHPickerViewController`
/// can't be worked around from the host process).
public struct PhotoLibraryPicker: View {

    public enum Filter: Equatable, Sendable {
        case images
        case videos
        case any
    }

    let filter: Filter
    let selectionLimit: Int
    let defaultSource: PhotoLibrarySource
    let onImageSelected: ((UIImage) -> Void)?
    let onImagesSelected: (([UIImage]) -> Void)?
    let onVideoSelected: ((URL) -> Void)?

    @StateObject private var model: PhotoLibraryModel
    @ObservedObject private var prewarmer = PhotoLibraryPrewarmer.shared
    @State private var isProcessing = false
    @State private var showingAlbumsSheet = false
    @Environment(\.dismiss) private var dismiss

    public init(
        filter: Filter = .images,
        selectionLimit: Int = 1,
        defaultSource: PhotoLibrarySource = .recents,
        onImageSelected: ((UIImage) -> Void)? = nil,
        onImagesSelected: (([UIImage]) -> Void)? = nil,
        onVideoSelected: ((URL) -> Void)? = nil
    ) {
        self.filter = filter
        self.selectionLimit = selectionLimit
        self.defaultSource = defaultSource
        self.onImageSelected = onImageSelected
        self.onImagesSelected = onImagesSelected
        self.onVideoSelected = onVideoSelected
        _model = StateObject(wrappedValue: PhotoLibraryModel(filter: filter, initialSource: defaultSource))
    }

    private var isMultiSelect: Bool { onImagesSelected != nil && selectionLimit != 1 }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.currentSource.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .overlay { processingOverlay }
                .sheet(isPresented: $showingAlbumsSheet) {
                    PhotoAlbumsSheet(
                        filter: filter,
                        model: model,
                        isMultiSelect: isMultiSelect,
                        onTapAsset: handleTap,
                        onFinishMultiSelect: finishMultiSelection
                    )
                }
        }
        .task { await model.requestAuthorizationIfNeeded() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
        }
        ToolbarItem(placement: .principal) {
            sourceMenu
        }
        if isMultiSelect {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { finishMultiSelection() }
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(.label))
                    .disabled(model.selectedAssetIDs.isEmpty || isProcessing)
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Picker("Source", selection: sourceBinding) {
                if case .album = model.currentSource {
                    Label(model.currentSource.title, systemImage: model.currentSource.systemImage)
                        .tag(model.currentSource)
                }
                Label("Recents", systemImage: PhotoLibrarySource.recents.systemImage)
                    .tag(PhotoLibrarySource.recents)
                if filter == .any {
                    Label("Videos", systemImage: PhotoLibrarySource.videos.systemImage)
                        .tag(PhotoLibrarySource.videos)
                }
                Label("Favorites", systemImage: PhotoLibrarySource.favorites.systemImage)
                    .tag(PhotoLibrarySource.favorites)
                Label("Screenshots", systemImage: PhotoLibrarySource.screenshots.systemImage)
                    .tag(PhotoLibrarySource.screenshots)
            }
            Divider()
            Button {
                showingAlbumsSheet = true
            } label: {
                Label("All Albums", systemImage: "rectangle.stack")
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.currentSource.title)
                    .font(.body.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(Color(.label))
        }
    }

    private var sourceBinding: Binding<PhotoLibrarySource> {
        Binding(
            get: { model.currentSource },
            set: { model.switchSource($0) }
        )
    }

    @ViewBuilder
    private var processingOverlay: some View {
        if isProcessing {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .overlay {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.4)
                }
                .allowsHitTesting(true)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.authStatus {
        case .authorized, .limited:
            PhotoSourceGrid(
                model: model,
                source: model.currentSource,
                isMultiSelect: isMultiSelect,
                onTapAsset: handleTap
            )
        case .denied, .restricted:
            DeniedAccessView()
        case .notDetermined:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        @unknown default:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func handleTap(_ asset: PHAsset) {
        guard !isProcessing else { return }
        if isMultiSelect {
            model.toggleSelection(of: asset, limit: selectionLimit)
        } else {
            selectSingle(asset)
        }
    }

    private func selectSingle(_ asset: PHAsset) {
        // Dismiss the All Albums sheet (if open) so the picker's processing
        // overlay is visible while we fetch the full-quality image.
        showingAlbumsSheet = false
        isProcessing = true
        Task {
            if asset.mediaType == .video, let onVideoSelected {
                let url = await model.exportVideo(for: asset)
                await MainActor.run {
                    if let url { onVideoSelected(url) }
                    isProcessing = false
                    dismiss()
                }
            } else if onImageSelected != nil || onImagesSelected != nil {
                let image = await model.fullImage(for: asset)
                await MainActor.run {
                    if let image {
                        onImageSelected?(image)
                        onImagesSelected?([image])
                    }
                    isProcessing = false
                    dismiss()
                }
            } else {
                await MainActor.run {
                    isProcessing = false
                    dismiss()
                }
            }
        }
    }

    private func finishMultiSelection() {
        showingAlbumsSheet = false
        isProcessing = true
        Task {
            let assets = model.selectedAssets
            let images = await model.fullImages(for: assets)
            await MainActor.run {
                onImagesSelected?(images)
                isProcessing = false
                dismiss()
            }
        }
    }
}

// MARK: - Photo Source Grid

/// Renders a 3-column grid of `PHAsset`s for `source`. Used by
/// `PhotoLibraryPicker` for its main grid and by `PhotoAlbumsSheet` as the
/// destination pushed onto the sheet's navigation stack when a user taps an
/// album row. Self-loads via `ensureLoaded` on appear.
struct PhotoSourceGrid: View {
    @ObservedObject var model: PhotoLibraryModel
    let source: PhotoLibrarySource
    let isMultiSelect: Bool
    let onTapAsset: (PHAsset) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                if model.authStatus == .limited {
                    LimitedAccessBanner()
                }
                if let fetchResult = model.fetchResult(for: source) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 3),
                        spacing: 1
                    ) {
                        ForEach(0..<fetchResult.count, id: \.self) { index in
                            let asset = fetchResult.object(at: index)
                            AssetThumbnailCell(
                                asset: asset,
                                cachingManager: model.cachingManager,
                                selectionIndex: isMultiSelect ? model.selectionIndex(for: asset) : nil,
                                showsSelectionUI: isMultiSelect
                            )
                            .onTapGesture { onTapAsset(asset) }
                        }
                    }
                } else if model.isLoading(source) {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
            }
        }
        .task(id: source) { model.ensureLoaded(source) }
    }
}

// MARK: - Limited Access Banner

private struct LimitedAccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Limited Photo Access")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Select more photos to make them available here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Manage") { presentLimitedPicker() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private func presentLimitedPicker() {
        guard let vc = topPresentedViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc)
    }
}

// MARK: - Denied Access View

private struct DeniedAccessView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Photos Access Required")
                .font(.headline)
            Text("To pick photos, allow Photos access for this app in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Asset Thumbnail Cell

private struct AssetThumbnailCell: View {
    let asset: PHAsset
    let cachingManager: PHCachingImageManager
    let selectionIndex: Int?
    let showsSelectionUI: Bool

    @State private var image: UIImage?

    private var isSelected: Bool { selectionIndex != nil }

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
            if asset.mediaType == .video {
                videoOverlay
            }
            if isSelected {
                Rectangle().fill(Color.accentColor.opacity(0.25))
            }
            if showsSelectionUI {
                selectionBadge
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .task(id: asset.localIdentifier) {
            await loadThumbnail()
        }
    }

    private var selectionBadge: some View {
        VStack {
            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .strokeBorder(.white, lineWidth: 2)
                        .background(
                            Circle().fill(isSelected ? Color.accentColor : Color.black.opacity(0.25))
                        )
                        .frame(width: 26, height: 26)
                    if let selectionIndex {
                        Text("\(selectionIndex)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 1)
                .padding(6)
            }
            Spacer()
        }
    }

    private var videoOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if asset.duration > 0 {
                    Text(formatDuration(asset.duration))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.55), .clear],
                    startPoint: .bottom,
                    endPoint: .top
                )
            )
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func loadThumbnail() async {
        let cm = cachingManager
        let asset = self.asset

        let stream = AsyncStream<UIImage> { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            let id = cm.requestImage(
                for: asset,
                targetSize: PhotoLibraryPrewarmer.thumbnailTargetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let image {
                    continuation.yield(image)
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if !isDegraded {
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                cm.cancelImageRequest(id)
            }
        }

        for await img in stream {
            image = img
        }
    }
}

// MARK: - Prewarmer

/// Process-wide cache of `PHFetchResult`s and a shared `PHCachingImageManager`.
///
/// The first time a `PhotoLibraryPicker` is presented in a session, fetching the
/// asset list and decoding the first batch of thumbnails is what makes the grid
/// feel slow. Calling `prewarm()` from the app entry warms both up while the user
/// is doing something else, so the picker reads a hot cache when it eventually
/// appears.
///
/// Subsequent picker presentations always read from this same instance — both the
/// fetch result and the thumbnail cache survive across pickers in the session.
@MainActor
public final class PhotoLibraryPrewarmer: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    public static let shared = PhotoLibraryPrewarmer()

    static let thumbnailTargetSize = CGSize(width: 480, height: 480)
    static let initialPrefetchCount = 60

    @Published public private(set) var fetchResults: [PhotoLibraryPicker.Filter: PHFetchResult<PHAsset>] = [:]
    @Published var smartAlbumsByFilter: [PhotoLibraryPicker.Filter: [PhotoAlbum]] = [:]
    @Published var userAlbumsByFilter: [PhotoLibraryPicker.Filter: [PhotoAlbum]] = [:]
    public let cachingManager = PHCachingImageManager()

    private var observerRegistered = false
    private var lifecycleObserverRegistered = false
    private var isLoadingAlbums = false

    private override init() { super.init() }

    deinit {
        if observerRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    /// Idempotent. Safe to call from app launch and from picker presentation.
    /// Only does work if photo access is already granted; otherwise no-op until
    /// the picker requests authorization.
    ///
    /// The `PHAsset` query + thumbnail prefetch run on the main actor (this type
    /// is `@MainActor`-isolated), so callers on the launch-critical path should
    /// defer this until after the first frame.
    public func prewarm() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        registerObserver()
        registerLifecycleObserver()
        // Pre-warm the two filters most pickers use.
        // `.images` covers single-image flows; `.any` covers picker flows that
        // accept both photos and videos. `.videos` is rare and fetched on demand.
        ensureFetched(.images)
        ensureFetched(.any)
        prefetchInitialThumbnails()
        prewarmAlbums()
    }

    private func prewarmAlbums() {
        guard !isLoadingAlbums else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        isLoadingAlbums = true
        Task.detached(priority: .utility) {
            async let imagesSmart = Task.detached(priority: .utility) {
                PhotoLibraryFetcher.loadSmartAlbums(filter: .images)
            }.value
            async let imagesUser = Task.detached(priority: .utility) {
                PhotoLibraryFetcher.loadUserAlbums(filter: .images)
            }.value
            async let anySmart = Task.detached(priority: .utility) {
                PhotoLibraryFetcher.loadSmartAlbums(filter: .any)
            }.value
            async let anyUser = Task.detached(priority: .utility) {
                PhotoLibraryFetcher.loadUserAlbums(filter: .any)
            }.value
            let (iSmart, iUser, aSmart, aUser) = await (imagesSmart, imagesUser, anySmart, anyUser)
            await MainActor.run {
                let p = PhotoLibraryPrewarmer.shared
                p.smartAlbumsByFilter[.images] = iSmart
                p.userAlbumsByFilter[.images] = iUser
                p.smartAlbumsByFilter[.any] = aSmart
                p.userAlbumsByFilter[.any] = aUser
                p.isLoadingAlbums = false
            }
        }
    }

    private func registerLifecycleObserver() {
        guard !lifecycleObserverRegistered else { return }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                PhotoLibraryPrewarmer.shared.prewarmAlbums()
            }
        }
        lifecycleObserverRegistered = true
    }

    /// Returns the cached fetch result for `filter`, performing a synchronous
    /// fetch if it isn't cached yet. Returns nil if photo access isn't granted.
    @discardableResult
    public func ensureFetched(_ filter: PhotoLibraryPicker.Filter) -> PHFetchResult<PHAsset>? {
        if let existing = fetchResults[filter] { return existing }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        registerObserver()
        let result = Self.fetch(filter: filter)
        fetchResults[filter] = result
        return result
    }

    private func registerObserver() {
        guard !observerRegistered else { return }
        PHPhotoLibrary.shared().register(self)
        observerRegistered = true
    }

    private static func fetch(filter: PhotoLibraryPicker.Filter) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(with: PhotoLibraryFetcher.defaultOptions(for: filter))
    }

    private func prefetchInitialThumbnails() {
        cachingManager.stopCachingImagesForAllAssets()
        // Prefer `.images` for prefetch (most common picker flow).
        let result = fetchResults[.images] ?? fetchResults[.any]
        guard let result, result.count > 0 else { return }
        let count = min(Self.initialPrefetchCount, result.count)
        var toPrefetch: [PHAsset] = []
        toPrefetch.reserveCapacity(count)
        for i in 0..<count {
            toPrefetch.append(result.object(at: i))
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        cachingManager.startCachingImages(
            for: toPrefetch,
            targetSize: Self.thumbnailTargetSize,
            contentMode: .aspectFill,
            options: options
        )
    }

    public nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            // Re-fetch every filter we'd already cached.
            for filter in self.fetchResults.keys {
                self.fetchResults[filter] = Self.fetch(filter: filter)
            }
            self.prefetchInitialThumbnails()
            self.prewarmAlbums()
        }
    }
}

// MARK: - Model

@MainActor
final class PhotoLibraryModel: ObservableObject {
    @Published var authStatus: PHAuthorizationStatus = .notDetermined
    @Published var selectedAssetIDs: [String] = []
    @Published var currentSource: PhotoLibrarySource
    @Published var sourceFetchResults: [PhotoLibrarySource: PHFetchResult<PHAsset>] = [:]
    @Published private(set) var pendingSources: Set<PhotoLibrarySource> = []

    let filter: PhotoLibraryPicker.Filter
    let prewarmer = PhotoLibraryPrewarmer.shared

    init(filter: PhotoLibraryPicker.Filter, initialSource: PhotoLibrarySource = .recents) {
        self.filter = filter
        self.currentSource = initialSource
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        self.authStatus = status
        if status == .authorized || status == .limited {
            // Idempotent: hits the prewarmed cache instantly if app pre-warmed.
            prewarmer.ensureFetched(filter)
            // Kick off the load for the initial source if it's not Recents.
            if initialSource != .recents {
                ensureLoaded(initialSource)
            }
        }
    }

    var cachingManager: PHCachingImageManager {
        prewarmer.cachingManager
    }

    /// Returns the cached fetch result for `source`. Recents reads from the
    /// prewarmer; everything else from `sourceFetchResults`. Returns nil while
    /// a fetch for `source` is still in flight.
    func fetchResult(for source: PhotoLibrarySource) -> PHFetchResult<PHAsset>? {
        switch source {
        case .recents:
            return prewarmer.fetchResults[filter]
        default:
            return sourceFetchResults[source]
        }
    }

    /// True while an asset-list fetch for `source` is in flight. The grid uses
    /// this to show a loading indicator instead of an empty view.
    func isLoading(_ source: PhotoLibrarySource) -> Bool {
        pendingSources.contains(source)
    }

    /// Switches the picker's main grid to `source`. Used by the source menu's
    /// quick-switch (Recents/Favorites/Videos). Tapping an album in the All
    /// Albums sheet does NOT call this — those taps push a new grid onto the
    /// sheet's navigation stack via `ensureLoaded`.
    func switchSource(_ source: PhotoLibrarySource) {
        currentSource = source
        ensureLoaded(source)
    }

    /// Kicks off a background fetch for `source` if one isn't already cached
    /// or in flight. Idempotent. Recents is served from the prewarmer's cache
    /// and needs no per-source fetch.
    func ensureLoaded(_ source: PhotoLibrarySource) {
        guard source != .recents else { return }
        guard sourceFetchResults[source] == nil, !pendingSources.contains(source) else { return }
        pendingSources.insert(source)
        let f = filter
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = PhotoLibraryFetcher.fetchAssets(for: source, filter: f)
            await MainActor.run {
                guard let self else { return }
                self.sourceFetchResults[source] = result
                self.pendingSources.remove(source)
            }
        }
    }

    var selectedAssets: [PHAsset] {
        guard !selectedAssetIDs.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: selectedAssetIDs, options: nil)
        var byID: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        return selectedAssetIDs.compactMap { byID[$0] }
    }

    func selectionIndex(for asset: PHAsset) -> Int? {
        selectedAssetIDs.firstIndex(of: asset.localIdentifier).map { $0 + 1 }
    }

    func toggleSelection(of asset: PHAsset, limit: Int) {
        if let i = selectedAssetIDs.firstIndex(of: asset.localIdentifier) {
            selectedAssetIDs.remove(at: i)
        } else if limit == 0 || selectedAssetIDs.count < limit {
            selectedAssetIDs.append(asset.localIdentifier)
        }
    }

    func requestAuthorizationIfNeeded() async {
        guard authStatus == .notDetermined else { return }
        let status = await Self.requestAuthorization()
        authStatus = status
        if status == .authorized || status == .limited {
            prewarmer.ensureFetched(filter)
            if currentSource != .recents {
                ensureLoaded(currentSource)
            }
        }
    }

    private static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fullImage(for asset: PHAsset) async -> UIImage? {
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

    func fullImages(for assets: [PHAsset]) async -> [UIImage] {
        var images: [UIImage] = []
        images.reserveCapacity(assets.count)
        for asset in assets {
            if let image = await fullImage(for: asset) {
                images.append(image)
            }
        }
        return images
    }

    func exportVideo(for asset: PHAsset) async -> URL? {
        let resources = PHAssetResource.assetResources(for: asset)
        let videoResource = resources.first { $0.type == .video }
            ?? resources.first { $0.type == .fullSizeVideo }
            ?? resources.first { $0.type == .pairedVideo }
        guard let resource = videoResource else { return nil }

        let ext = (resource.originalFilename as NSString).pathExtension
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("photopicker-\(UUID().uuidString)\(suffix)")
        try? FileManager.default.removeItem(at: dest)

        let resumer = ResumeOnce<URL?>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let opts = PHAssetResourceRequestOptions()
            opts.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: dest,
                options: opts
            ) { error in
                resumer.tryResume(continuation, with: error == nil ? dest : nil)
            }
        }
    }
}

// MARK: - Album / Source Fetching

struct PhotoAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let count: Int
    let coverAsset: PHAsset?
    let source: PhotoLibrarySource
    /// Modification date of the most recently touched asset — drives the
    /// "Recently Added" sort in `PhotoAlbumsSheet`. Nil if the album is empty.
    let lastAssetDate: Date?
    let kind: PhotoAlbumKind
}

enum PhotoAlbumKind: Hashable {
    /// Always shown at the top, regardless of sort. Recents + Favorites.
    case pinned
    /// User-created albums in Photos.app (best-effort heuristic: the current
    /// app can add/remove/delete content on the collection).
    case userCreated
    /// Apple smart albums — Screenshots, Selfies, Panoramas, etc.
    case system
    /// Albums created by other apps via PhotoKit. Heuristic: a regular
    /// album that doesn't grant the current app the full edit rights of a
    /// user-managed album.
    case app
}

enum PhotoLibraryFetcher {
    static func mediaPredicate(for filter: PhotoLibraryPicker.Filter) -> NSPredicate {
        switch filter {
        case .images:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        case .videos:
            return NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        case .any:
            return NSPredicate(
                format: "mediaType == %d || mediaType == %d",
                PHAssetMediaType.image.rawValue,
                PHAssetMediaType.video.rawValue
            )
        }
    }

    static func defaultOptions(for filter: PhotoLibraryPicker.Filter) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = mediaPredicate(for: filter)
        return options
    }

    /// Album-metadata options used when summarising a collection for the
    /// album list. Sorts by `modificationDate` descending so `firstObject`
    /// reflects the asset most recently *added/touched* in the album — which
    /// matches a user's mental model of "recently added" much better than
    /// `creationDate` (which is when the photo was taken, possibly years
    /// before it was saved/added).
    static func albumSummaryOptions(for filter: PhotoLibraryPicker.Filter) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: false)]
        options.predicate = mediaPredicate(for: filter)
        return options
    }

    static func fetchAssets(
        for source: PhotoLibrarySource,
        filter: PhotoLibraryPicker.Filter
    ) -> PHFetchResult<PHAsset> {
        let options = defaultOptions(for: filter)
        switch source {
        case .recents:
            return PHAsset.fetchAssets(with: options)
        case .favorites:
            return fetchFromSmartAlbum(.smartAlbumFavorites, options: options)
        case .videos:
            return fetchFromSmartAlbum(.smartAlbumVideos, options: options)
        case .screenshots:
            return fetchFromSmartAlbum(.smartAlbumScreenshots, options: options)
        case .album(let localID, _):
            let collections = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [localID],
                options: nil
            )
            guard let collection = collections.firstObject else {
                return PHAsset.fetchAssets(with: options)
            }
            return PHAsset.fetchAssets(in: collection, options: options)
        }
    }

    private static func fetchFromSmartAlbum(
        _ subtype: PHAssetCollectionSubtype,
        options: PHFetchOptions
    ) -> PHFetchResult<PHAsset> {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: subtype,
            options: nil
        )
        guard let collection = collections.firstObject else {
            return PHAsset.fetchAssets(with: options)
        }
        return PHAsset.fetchAssets(in: collection, options: options)
    }

    /// Smart albums to surface in the All Albums sheet — Recents/Favorites/Videos
    /// are added by `loadSmartAlbums` directly so they always lead the list.
    private static let extraSmartTypes: [(PHAssetCollectionSubtype, String)] = [
        (.smartAlbumScreenshots, "Screenshots"),
        (.smartAlbumSelfPortraits, "Selfies"),
        (.smartAlbumPanoramas, "Panoramas"),
        (.smartAlbumLivePhotos, "Live Photos"),
        (.smartAlbumBursts, "Bursts"),
        (.smartAlbumSlomoVideos, "Slo-mo"),
        (.smartAlbumTimelapses, "Time-lapse"),
        (.smartAlbumDepthEffect, "Portrait"),
        (.smartAlbumLongExposures, "Long Exposure"),
        (.smartAlbumAnimated, "Animated"),
        (.smartAlbumScreenRecordings, "Screen Recordings"),
    ]

    static func loadSmartAlbums(filter: PhotoLibraryPicker.Filter) -> [PhotoAlbum] {
        var albums: [PhotoAlbum] = []
        let options = defaultOptions(for: filter)

        let recents = PHAsset.fetchAssets(with: options)
        if recents.count > 0 {
            let first = recents.firstObject
            logAlbumMetadata(
                title: PhotoLibrarySource.recents.title,
                count: recents.count,
                firstAssetCreationDate: first?.creationDate,
                firstAssetModificationDate: first?.modificationDate,
                collectionStartDate: nil,
                collectionEndDate: nil,
                estimatedCount: nil,
                subtypeRaw: nil,
                canDelete: nil,
                canRemoveContent: nil,
                canAddContent: nil
            )
            albums.append(PhotoAlbum(
                id: "source.recents",
                title: PhotoLibrarySource.recents.title,
                count: recents.count,
                coverAsset: first,
                source: .recents,
                lastAssetDate: first?.creationDate,
                kind: .pinned
            ))
        }

        if let favorites = makeBuiltInAlbum(
            subtype: .smartAlbumFavorites,
            source: .favorites,
            filter: filter,
            kind: .pinned
        ) {
            albums.append(favorites)
        }

        if filter == .any, let videos = makeBuiltInAlbum(
            subtype: .smartAlbumVideos,
            source: .videos,
            filter: filter,
            kind: .system
        ) {
            albums.append(videos)
        }

        for (subtype, fallbackTitle) in extraSmartTypes {
            guard let collection = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: subtype,
                options: nil
            ).firstObject else { continue }
            guard let album = makeAlbum(
                from: collection,
                fallbackTitle: fallbackTitle,
                filter: filter,
                kindOverride: .system
            ) else { continue }
            albums.append(album)
        }

        return albums
    }

    static func loadUserAlbums(filter: PhotoLibraryPicker.Filter) -> [PhotoAlbum] {
        let userResult = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var albums: [PhotoAlbum] = []
        userResult.enumerateObjects { collection, _, _ in
            if let album = makeAlbum(
                from: collection,
                fallbackTitle: "Untitled",
                filter: filter,
                kindOverride: nil
            ) {
                albums.append(album)
            }
        }
        return albums
    }

    private static func makeBuiltInAlbum(
        subtype: PHAssetCollectionSubtype,
        source: PhotoLibrarySource,
        filter: PhotoLibraryPicker.Filter,
        kind: PhotoAlbumKind
    ) -> PhotoAlbum? {
        guard let collection = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: subtype,
            options: nil
        ).firstObject else { return nil }
        let result = PHAsset.fetchAssets(in: collection, options: albumSummaryOptions(for: filter))
        guard result.count > 0 else { return nil }
        let first = result.firstObject
        logAlbumMetadata(
            title: source.title,
            count: result.count,
            firstAssetCreationDate: first?.creationDate,
            firstAssetModificationDate: first?.modificationDate,
            collectionStartDate: collection.startDate,
            collectionEndDate: collection.endDate,
            estimatedCount: collection.estimatedAssetCount,
            subtypeRaw: collection.assetCollectionSubtype.rawValue,
            canDelete: collection.canPerform(.delete),
            canRemoveContent: collection.canPerform(.removeContent),
            canAddContent: collection.canPerform(.addContent)
        )
        return PhotoAlbum(
            id: "source.\(source.title.lowercased())",
            title: source.title,
            count: result.count,
            coverAsset: first,
            source: source,
            lastAssetDate: first?.modificationDate ?? first?.creationDate,
            kind: kind
        )
    }

    /// `kindOverride` is supplied for smart albums (always `.system`); for
    /// user/app albums we infer it from collection edit permissions.
    private static func makeAlbum(
        from collection: PHAssetCollection,
        fallbackTitle: String,
        filter: PhotoLibraryPicker.Filter,
        kindOverride: PhotoAlbumKind?
    ) -> PhotoAlbum? {
        let result = PHAsset.fetchAssets(in: collection, options: albumSummaryOptions(for: filter))
        guard result.count > 0 else { return nil }
        let title = collection.localizedTitle ?? fallbackTitle
        let first = result.firstObject
        let canDelete = collection.canPerform(.delete)
        let canRemove = collection.canPerform(.removeContent)
        let canAdd = collection.canPerform(.addContent)
        logAlbumMetadata(
            title: title,
            count: result.count,
            firstAssetCreationDate: first?.creationDate,
            firstAssetModificationDate: first?.modificationDate,
            collectionStartDate: collection.startDate,
            collectionEndDate: collection.endDate,
            estimatedCount: collection.estimatedAssetCount,
            subtypeRaw: collection.assetCollectionSubtype.rawValue,
            canDelete: canDelete,
            canRemoveContent: canRemove,
            canAddContent: canAdd
        )
        // Heuristic: a fully-editable .albumRegular collection is a
        // user-created album from Photos.app. Anything that doesn't grant
        // the current app full edit rights is treated as an app-created
        // album. This is best-effort — PhotoKit doesn't expose the album
        // creator's bundle id.
        let inferredKind: PhotoAlbumKind = {
            if let kindOverride { return kindOverride }
            return (canDelete && canRemove && canAdd) ? .userCreated : .app
        }()
        return PhotoAlbum(
            id: collection.localIdentifier,
            title: title,
            count: result.count,
            coverAsset: first,
            source: .album(localIdentifier: collection.localIdentifier, title: title),
            lastAssetDate: first?.modificationDate ?? first?.creationDate,
            kind: inferredKind
        )
    }

    private static let albumLogFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func logAlbumMetadata(
        title: String,
        count: Int,
        firstAssetCreationDate: Date?,
        firstAssetModificationDate: Date?,
        collectionStartDate: Date?,
        collectionEndDate: Date?,
        estimatedCount: Int?,
        subtypeRaw: Int?,
        canDelete: Bool?,
        canRemoveContent: Bool?,
        canAddContent: Bool?
    ) {
        func fmt(_ d: Date?) -> String {
            guard let d else { return "nil" }
            return albumLogFormatter.string(from: d)
        }
        func fmtBool(_ b: Bool?) -> String {
            b.map { $0 ? "Y" : "N" } ?? "n/a"
        }
        let estCount = estimatedCount.map { $0 == NSNotFound ? "NSNotFound" : "\($0)" } ?? "n/a"
        let subtype = subtypeRaw.map(String.init) ?? "n/a"
        RemoteLogger.shared.info(
            "album=\"\(title)\" count=\(count) estCount=\(estCount) subtype=\(subtype) canDelete=\(fmtBool(canDelete)) canRemove=\(fmtBool(canRemoveContent)) canAdd=\(fmtBool(canAddContent)) firstAsset.creationDate=\(fmt(firstAssetCreationDate)) firstAsset.modificationDate=\(fmt(firstAssetModificationDate)) collection.startDate=\(fmt(collectionStartDate)) collection.endDate=\(fmt(collectionEndDate))",
            category: "album-sort"
        )
    }
}

// MARK: - Helpers

/// Resumes a continuation at most once. PhotoKit callbacks may fire multiple
/// times (degraded → high-quality), and `withCheckedContinuation` traps on
/// double-resume.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func tryResume(_ continuation: CheckedContinuation<T, Never>, with value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: value)
    }
}

@MainActor
private func topPresentedViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    let activeScene = scenes.first { ($0 as? UIWindowScene)?.activationState == .foregroundActive }
        ?? scenes.first
    guard let windowScene = activeScene as? UIWindowScene else { return nil }
    let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
        top = presented
    }
    return top
}
