// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "vad_plus",
    platforms: [
        .iOS("15.1"),
        .macOS("14.0")
    ],
    products: [
        // Dynamic on purpose. Dart finds the @_cdecl functions by name through
        // DynamicLibrary.process() and no native code calls them, so a static
        // product would have them stripped from the app. Only the host app's
        // build settings could prevent that, and a package can't change those.
        .library(name: "vad-plus", type: .dynamic, targets: ["vad_plus"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            .upToNextMinor(from: "1.24.1")
        )
    ],
    targets: [
        .target(
            name: "vad_plus",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager")
            ],
            resources: [
                .copy("Resources/silero_vad_v6.onnx")
            ]
        )
    ]
)
