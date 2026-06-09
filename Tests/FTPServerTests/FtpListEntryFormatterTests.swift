import Foundation
import Testing
@testable import FtpServer

@Test func formatsDirectoryEntryUsingUnixLikePrefix() {
    let formatter = FtpListEntryFormatter()
    let modifiedAt = Date(timeIntervalSince1970: 0)

    let line = formatter.line(
        name: "captures",
        isDirectory: true,
        attributes: [
            .size: NSNumber(value: 0),
            .modificationDate: modifiedAt
        ]
    )

    #expect(line.hasPrefix("drwxr-xr-x 1 owner group 0 Jan 01 1970 captures"))
}

@Test func formatsFileEntryUsingRegularFilePrefix() {
    let formatter = FtpListEntryFormatter()
    let modifiedAt = Date(timeIntervalSince1970: 86_400)

    let line = formatter.line(
        name: "frame.jpg",
        isDirectory: false,
        attributes: [
            .size: NSNumber(value: 512),
            .modificationDate: modifiedAt
        ]
    )

    #expect(line.hasPrefix("-rw-r--r-- 1 owner group 512 Jan 02 1970 frame.jpg"))
}