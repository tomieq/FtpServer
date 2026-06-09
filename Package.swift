// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "FTPServer",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "FTPServer",
            targets: ["FTPServer"])
    ],
    targets: [
        .target(
            name: "FTPServer",
            path: "Sources"),
        .testTarget(
            name: "FTPServerTests",
            dependencies: ["FTPServer"])
    ]
)
