import Foundation
import Testing
@testable import FTPServer

@Test func resolvesRelativeFileInsideRoot() {
    let resolver = FTPPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveFile("incoming/cam001.jpg", currentDirectory: "/")

    #expect(result?.path == "/tmp/ftp-root/incoming/cam001.jpg")
}

@Test func keepsDirectoryTraversalInsideRoot() {
    let resolver = FTPPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveFile("../../escape.jpg", currentDirectory: "/incoming")

    #expect(result?.path == "/tmp/ftp-root/escape.jpg")
}

@Test func resolvesAbsoluteDirectoryFromRoot() {
    let resolver = FTPPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveDirectory("/nested/day-01", currentDirectory: "/incoming")

    #expect(result == "/nested/day-01")
}