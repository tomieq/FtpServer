import Foundation

struct FtpListEntryFormatter {
    private let formatter: DateFormatter
    private let fileManager = FileManager.default

    init(locale: Locale = Locale(identifier: "en_US_POSIX"), timeZone: TimeZone = .gmt) {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM dd yyyy"
        self.formatter = formatter
    }

    func line(for itemURL: URL) throws -> String {
        let attributes = try fileManager.attributesOfItem(atPath: itemURL.path)
        let resourceValues = try itemURL.resourceValues(forKeys: [.isDirectoryKey])
        return line(
            name: itemURL.lastPathComponent,
            isDirectory: resourceValues.isDirectory ?? false,
            attributes: attributes
        )
    }

    func line(name: String, isDirectory: Bool, attributes: [FileAttributeKey: Any]) -> String {
        let permissions = isDirectory ? "drwxr-xr-x" : "-rw-r--r--"
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let modifiedAt = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let timestamp = formatter.string(from: modifiedAt)
        return "\(permissions) 1 owner group \(size) \(timestamp) \(name)"
    }
}