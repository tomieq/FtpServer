import Foundation

public struct FtpServerConfiguration: Sendable {
    public var rootDirectory: URL
    public var username: String?
    public var password: String?
    public var bindAddressIPv4: String?
    public var bindAddressIPv6: String?
    public var passiveAddressIPv4: String?
    public var passivePortRange: ClosedRange<UInt16>?
    public let onFileStored: (@Sendable (URL, Int) -> Void)?

    public init(
        rootDirectory: URL,
        username: String? = nil,
        password: String? = nil,
        bindAddressIPv4: String? = nil,
        bindAddressIPv6: String? = nil,
        passiveAddressIPv4: String? = nil,
        passivePortRange: ClosedRange<UInt16>? = nil,
        onFileStored: (@Sendable (URL, Int) -> Void)? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.username = username
        self.password = password
        self.bindAddressIPv4 = bindAddressIPv4
        self.bindAddressIPv6 = bindAddressIPv6
        self.passiveAddressIPv4 = passiveAddressIPv4
        self.passivePortRange = passivePortRange
        self.onFileStored = onFileStored
    }

    var requiresAuthentication: Bool {
        username != nil
    }

    func accepts(user: String, password: String?) -> Bool {
        guard let configuredUsername = username else {
            return true
        }

        guard user == configuredUsername else {
            return false
        }

        guard let configuredPassword = self.password else {
            return true
        }

        return configuredPassword == password
    }
}
