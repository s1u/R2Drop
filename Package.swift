// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "R2Drop",
    platforms: [
        .macOS(.v14),  // Sonoma+ for SwiftUI drag improvements
        .iOS(.v17)     // future iOS target
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift", from: "1.0.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", from: "1.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "R2Drop",
            dependencies: [
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .product(name: "AWSClientRuntime", package: "aws-sdk-swift"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
