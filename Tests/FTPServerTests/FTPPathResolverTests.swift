import Foundation
import Testing
@testable import FtpServer

@Test func resolvesRelativeFileInsideRoot() {
    let resolver = FtpPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveFile("incoming/cam001.jpg", currentDirectory: "/")

    #expect(result?.path == "/tmp/ftp-root/incoming/cam001.jpg")
}

@Test func keepsDirectoryTraversalInsideRoot() {
    let resolver = FtpPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveFile("../../escape.jpg", currentDirectory: "/incoming")

    #expect(result?.path == "/tmp/ftp-root/escape.jpg")
}

@Test func resolvesAbsoluteDirectoryFromRoot() {
    let resolver = FtpPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveDirectory("/nested/day-01", currentDirectory: "/incoming")

    #expect(result == "/nested/day-01")
}

@Test func resolvesCurrentDirectoryWhenListPathIsMissing() {
    let resolver = FtpPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveItem(nil, currentDirectory: "/incoming")

    #expect(result.path == "/tmp/ftp-root/incoming")
}

@Test func resolvesVirtualPathForCreatedDirectory() {
    let resolver = FtpPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveVirtualPath("./batch-01", currentDirectory: "/incoming")

    #expect(result == "/incoming/batch-01")
}

@Test func resolvesDeleteTargetInsideCurrentDirectory() {
    let resolver = FtpPathResolver(rootDirectory: URL(fileURLWithPath: "/tmp/ftp-root", isDirectory: true))

    let result = resolver.resolveItem("frame.jpg", currentDirectory: "/incoming")

    #expect(result.path == "/tmp/ftp-root/incoming/frame.jpg")
}
