// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FtpServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FtpServer",
            targets: ["FtpServer"])
    ],
    targets: [
        .target(
            name: "FtpServer",
            path: "Sources"),
        .testTarget(
            name: "FtpServerTests",
            dependencies: ["FtpServer"])
    ]
)
