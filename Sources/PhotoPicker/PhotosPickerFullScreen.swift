import SwiftUI

/// A photo picker presented as a sheet.
///
/// Thin wrapper around `PhotoLibraryPicker` for the most common use case
/// (single image, presented full-screen).
///
/// Usage:
/// ```swift
/// .sheet(isPresented: $showingPicker) {
///     PhotosPickerFullScreen(onImageSelected: { image in
///         // handle image
///     })
/// }
/// ```
public struct PhotosPickerFullScreen: View {
    public var selectionLimit: Int
    public var defaultSource: PhotoLibrarySource
    public var onImageSelected: (UIImage) -> Void
    public var onImagesSelected: (([UIImage]) -> Void)?

    public init(
        selectionLimit: Int = 1,
        defaultSource: PhotoLibrarySource = .recents,
        onImageSelected: @escaping (UIImage) -> Void = { _ in },
        onImagesSelected: (([UIImage]) -> Void)? = nil
    ) {
        self.selectionLimit = selectionLimit
        self.defaultSource = defaultSource
        self.onImageSelected = onImageSelected
        self.onImagesSelected = onImagesSelected
    }

    public var body: some View {
        PhotoLibraryPicker(
            filter: .images,
            selectionLimit: selectionLimit,
            defaultSource: defaultSource,
            onImageSelected: onImageSelected,
            onImagesSelected: onImagesSelected
        )
    }
}
