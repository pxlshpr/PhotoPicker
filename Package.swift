// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PhotoPicker",
    platforms: [
        .iOS("26.0"),
        .macOS("26.0")
    ],
    products: [
        .library(
            name: "PhotoPicker",
            targets: ["PhotoPicker"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/pxlshpr/RemoteLogger", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "PhotoPicker",
            dependencies: [
                .product(name: "RemoteLogger", package: "RemoteLogger"),
            ]
        ),
    ]
)
