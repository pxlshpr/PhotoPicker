# PhotoPicker

A custom PhotoKit-backed photo/video picker for SwiftUI that replaces `PHPickerViewController`. Built on `PHAsset` + `PHCachingImageManager` so the grid scrolls smoothly the instant it appears.

## Why

`PHPickerViewController` runs in a remote extension and has a long-standing scroll-reset bug that can't be worked around from the host process. `PhotoPicker` runs in-process, with a process-wide prewarmer that hides asset-list and thumbnail decode latency behind app launch.

## Features

- Custom 3-column grid with thumbnail caching
- Source switcher: Recents, Favorites, Videos, Screenshots, plus an "All Albums" sheet
- Single or multi-select
- Image and video output (full-quality fetch via `PHImageManager` for stills, `PHAssetResourceManager` export for video)
- Process-wide prewarmer for instant first presentation
- Limited Photos access banner with system "Manage" picker hook
- Denied access fallback view

## Requirements

- iOS 26+
- Swift 5.10+

## Install

```swift
.package(url: "https://github.com/pxlshpr/PhotoPicker", from: "1.0.0")
```

Add `Privacy - Photo Library Usage Description` (`NSPhotoLibraryUsageDescription`) to your app's `Info.plist`.

## Usage

### Basic single-image picker

```swift
import PhotoPicker

.sheet(isPresented: $showingPicker) {
    PhotosPickerFullScreen { image in
        // handle UIImage
    }
}
```

### Open straight to the Screenshots album

```swift
PhotosPickerFullScreen(defaultSource: .screenshots) { image in
    // ...
}
```

### Multi-select images

```swift
PhotoLibraryPicker(
    filter: .images,
    selectionLimit: 10,
    onImagesSelected: { images in
        // handle [UIImage]
    }
)
```

### Photos + videos

```swift
PhotoLibraryPicker(
    filter: .any,
    onImageSelected: { image in /* ... */ },
    onVideoSelected: { url in /* ... */ }
)
```

### Prewarm at app launch

The grid feels significantly faster if you call the prewarmer ~1.5s after launch (off the main thread's critical path):

```swift
import PhotoPicker

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    try? await Task.sleep(for: .seconds(1.5))
                    PhotoLibraryPrewarmer.shared.prewarm()
                }
        }
    }
}
```

`prewarm()` is idempotent and a no-op if photo access hasn't been granted yet.

## License

MIT.
