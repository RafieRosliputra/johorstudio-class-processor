// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClassProcessor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClassProcessor", targets: ["ClassProcessor"]),
    ],
    dependencies: [
        // libwebp compiled from source and linked statically into the app (WebP for the phone).
        .package(url: "https://github.com/SDWebImage/libwebp-Xcode.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClassProcessor",
            dependencies: [
                .product(name: "libwebp", package: "libwebp-Xcode"),
            ],
            path: "Sources/ClassProcessor"
        ),
    ]
)
