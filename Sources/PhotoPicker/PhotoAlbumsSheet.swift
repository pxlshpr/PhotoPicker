import SwiftUI
import Photos
import RemoteLogger

/// "All Albums" sheet shown from the photo picker's source menu.
///
/// Lists smart albums (Recents, Favorites, Videos when filter allows, plus
/// Screenshots / Selfies / etc.) followed by user-created albums. Reads from
/// `PhotoLibraryPrewarmer`'s album cache so the sheet appears instantly when
/// the prewarm has run; falls back to a fresh background fetch otherwise.
///
/// Tapping an album row pushes a `PhotoSourceGrid` onto the sheet's navigation
/// stack, so the user can swipe-back to return to the album list. Tapping a
/// photo in the pushed grid runs the picker's normal selection flow.
struct PhotoAlbumsSheet: View {
    let filter: PhotoLibraryPicker.Filter
    @ObservedObject var model: PhotoLibraryModel
    let isMultiSelect: Bool
    let onTapAsset: (PHAsset) -> Void
    let onFinishMultiSelect: () -> Void

    @ObservedObject private var prewarmer = PhotoLibraryPrewarmer.shared
    @State private var fallbackSmart: [PhotoAlbum] = []
    @State private var fallbackUser: [PhotoAlbum] = []
    @State private var isLoadingFallback = false
    @State private var didAttemptFallback = false
    @State private var sortOrder: AlbumSortOrder = .recent
    @State private var searchText: String = ""
    @Environment(\.dismiss) private var dismiss

    private let cachingManager = PhotoLibraryPrewarmer.shared.cachingManager

    private var smartAlbums: [PhotoAlbum] {
        prewarmer.smartAlbumsByFilter[filter] ?? fallbackSmart
    }

    private var userAlbums: [PhotoAlbum] {
        prewarmer.userAlbumsByFilter[filter] ?? fallbackUser
    }

    private var hasContent: Bool {
        !smartAlbums.isEmpty || !userAlbums.isEmpty
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Albums")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom) {
                    if hasContent {
                        searchBar
                    }
                }
                .navigationDestination(for: PhotoLibrarySource.self) { source in
                    PhotoSourceGrid(
                        model: model,
                        source: source,
                        isMultiSelect: isMultiSelect,
                        onTapAsset: onTapAsset
                    )
                    .navigationTitle(source.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if isMultiSelect {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { onFinishMultiSelect() }
                                    .fontWeight(.semibold)
                                    .disabled(model.selectedAssetIDs.isEmpty)
                            }
                        }
                    }
                }
        }
        .task { await loadIfNeeded() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            sortMenu
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(.label))
            }
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(AlbumSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.systemImage).tag(order)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color(.label))
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasContent {
            if isLoadingFallback || (!didAttemptFallback && smartAlbums.isEmpty) {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Albums",
                    systemImage: "photo.on.rectangle",
                    description: Text("Your photo library doesn't contain any matching albums.")
                )
            }
        } else {
            albumList
        }
    }

    @ViewBuilder
    private var albumList: some View {
        switch sortOrder {
        case .recent:
            recentList
        case .name, .count:
            groupedList
        }
    }

    /// Recently-added view: Recents + Favorites pinned at the top, then three
    /// groups in order — My Albums, System Albums, App Albums — each sorted
    /// internally by most recent asset modification.
    @ViewBuilder
    private var recentList: some View {
        let all = smartAlbums + userAlbums
        let pinned = applySearch(sortPinned(all.filter { $0.kind == .pinned }))
        let user = applySearch(sortByRecent(all.filter { $0.kind == .userCreated }))
        let system = applySearch(sortByRecent(all.filter { $0.kind == .system }))
        let app = applySearch(sortByRecent(all.filter { $0.kind == .app }))

        if pinned.isEmpty && user.isEmpty && system.isEmpty && app.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                section(title: nil, albums: pinned)
                section(title: "My Albums", albums: user)
                section(title: "System Albums", albums: system)
                section(title: "App Albums", albums: app)
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func section(title: String?, albums: [PhotoAlbum]) -> some View {
        if !albums.isEmpty {
            if let title {
                Section(title) {
                    ForEach(albums) { album in
                        albumRow(album)
                    }
                }
            } else {
                Section {
                    ForEach(albums) { album in
                        albumRow(album)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var groupedList: some View {
        let smart = filtered(smartAlbums)
        let user = filtered(userAlbums)

        if smart.isEmpty && user.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                if !smart.isEmpty {
                    Section {
                        ForEach(smart) { album in
                            albumRow(album)
                        }
                    }
                }
                if !user.isEmpty {
                    Section("My Albums") {
                        ForEach(user) { album in
                            albumRow(album)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search albums", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func albumRow(_ album: PhotoAlbum) -> some View {
        NavigationLink(value: album.source) {
            HStack(spacing: 12) {
                AlbumCoverThumbnail(
                    asset: album.coverAsset,
                    cachingManager: cachingManager
                )
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text("\(album.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if album.source == model.currentSource {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private func filtered(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        applySearch(sort(albums))
    }

    private func applySearch(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        guard !searchText.isEmpty else { return albums }
        return albums.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private func sort(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        switch sortOrder {
        case .recent:
            return sortByRecent(albums)
        case .name:
            return albums.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .count:
            return albums.sorted { $0.count > $1.count }
        }
    }

    /// Pinned section has a fixed order: Recents first, Favorites second.
    private func sortPinned(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        func rank(_ album: PhotoAlbum) -> Int {
            switch album.source {
            case .recents: return 0
            case .favorites: return 1
            default: return 2
            }
        }
        return albums.sorted { rank($0) < rank($1) }
    }

    private func sortByRecent(_ albums: [PhotoAlbum]) -> [PhotoAlbum] {
        // #1690 — pure sort. This is called 3× per `recentList` body evaluation, and
        // SwiftUI re-runs the body on every search keystroke, sort-order change, and
        // prewarmer `@Published` album publish. The previous per-call `ISO8601DateFormatter`
        // allocation + `RemoteLogger.shared.info` ("album-sort") network POST therefore ran
        // dozens of times on the main actor while the All-Albums sheet was open — the source
        // of the in-session 170–500 ms main-thread blocks. Per-album metadata is still logged
        // (off-main) by `logAlbumMetadata` during enumeration if that telemetry is needed.
        albums.sorted { lhs, rhs in
            switch (lhs.lastAssetDate, rhs.lastAssetDate) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
    }

    private func loadIfNeeded() async {
        if prewarmer.smartAlbumsByFilter[filter] != nil { return }
        guard !isLoadingFallback else { return }
        isLoadingFallback = true
        let f = filter
        async let smart = Task.detached(priority: .userInitiated) {
            PhotoLibraryFetcher.loadSmartAlbums(filter: f)
        }.value
        async let user = Task.detached(priority: .userInitiated) {
            PhotoLibraryFetcher.loadUserAlbums(filter: f)
        }.value
        let (s, u) = await (smart, user)
        fallbackSmart = s
        fallbackUser = u
        isLoadingFallback = false
        didAttemptFallback = true
    }
}

// MARK: - Sort Order

enum AlbumSortOrder: String, CaseIterable, Identifiable {
    case recent
    case name
    case count

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .name: "Name"
        case .count: "Number of Items"
        }
    }

    var systemImage: String {
        switch self {
        case .recent: "clock"
        case .name: "textformat"
        case .count: "number"
        }
    }
}

// MARK: - Album Cover Thumbnail

private struct AlbumCoverThumbnail: View {
    let asset: PHAsset?
    let cachingManager: PHCachingImageManager

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: asset?.localIdentifier) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard let asset else {
            image = nil
            return
        }
        let cm = cachingManager
        let stream = AsyncStream<UIImage> { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true

            let id = cm.requestImage(
                for: asset,
                targetSize: CGSize(width: 168, height: 168),
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
