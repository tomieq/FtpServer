import Foundation

final class FtpSession {
    private let controlSocket: Socket
    private let configuration: FtpServerConfiguration
    private let forceIPv4: Bool
    private let pathResolver: FtpPathResolver
    private let listEntryFormatter = FtpListEntryFormatter()

    private var currentDirectory = "/"
    private var pendingUsername: String?
    private var isAuthenticated: Bool
    private var passiveListener: Socket?

    init(controlSocket: Socket, configuration: FtpServerConfiguration, forceIPv4: Bool) {
        self.controlSocket = controlSocket
        self.configuration = configuration
        self.forceIPv4 = forceIPv4
        self.pathResolver = FtpPathResolver(rootDirectory: configuration.rootDirectory)
        self.isAuthenticated = !configuration.requiresAuthentication
    }

    deinit {
        passiveListener?.close()
    }

    func run() {
        sendResponse(220, "Swift FTP server ready")

        while let commandLine = try? controlSocket.readLine() {
            let sanitizedLine = commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sanitizedLine.isEmpty else {
                continue
            }

            let parts = sanitizedLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let command = parts[0].uppercased()
            let argument = parts.count > 1 ? String(parts[1]) : nil

            switch command {
            case "USER":
                handleUser(argument)
            case "PASS":
                handlePass(argument)
            case "SYST":
                sendResponse(215, "UNIX Type: L8")
            case "TYPE":
                sendResponse(200, "Type set")
            case "FEAT":
                sendMultilineResponse([
                    "211-Extensions supported",
                    " PASV",
                    " EPSV",
                    "211 End"
                ])
            case "PWD":
                sendResponse(257, "\"\(currentDirectory)\"")
            case "CWD":
                handleCwd(argument)
            case "CDUP":
                handleCwd("..")
            case "PASV":
                handlePasv()
            case "EPSV":
                handleEpsv()
            case "STOR":
                handleStor(argument)
            case "LIST":
                handleList(argument)
            case "MKD":
                handleMkd(argument)
            case "DELE":
                handleDele(argument)
            case "RMD":
                handleRmd(argument)
            case "NOOP":
                sendResponse(200, "NOOP ok")
            case "PORT", "EPRT":
                sendResponse(502, "Active mode is not supported")
            case "QUIT":
                sendResponse(221, "Goodbye")
                return
            default:
                sendResponse(502, "Command not implemented")
            }
        }
    }

    private func handleUser(_ argument: String?) {
        guard let argument, !argument.isEmpty else {
            sendResponse(501, "Missing username")
            return
        }

        pendingUsername = argument
        if configuration.requiresAuthentication {
            sendResponse(331, "User name okay, need password")
        } else {
            isAuthenticated = true
            sendResponse(230, "User logged in")
        }
    }

    private func handlePass(_ argument: String?) {
        guard configuration.requiresAuthentication else {
            isAuthenticated = true
            sendResponse(230, "User logged in")
            return
        }

        guard let pendingUsername else {
            sendResponse(503, "Send USER first")
            return
        }

        if configuration.accepts(user: pendingUsername, password: argument) {
            isAuthenticated = true
            sendResponse(230, "User logged in")
        } else {
            isAuthenticated = false
            sendResponse(530, "Authentication failed")
        }
    }

    private func handleCwd(_ argument: String?) {
        guard requireAuthentication() else {
            return
        }

        guard let argument, !argument.isEmpty else {
            sendResponse(501, "Missing directory")
            return
        }

        guard let resolvedDirectory = pathResolver.resolveDirectory(argument, currentDirectory: currentDirectory) else {
            sendResponse(550, "Invalid directory")
            return
        }

        currentDirectory = resolvedDirectory
        sendResponse(250, "Directory changed")
    }

    private func handlePasv() {
        guard requireAuthentication() else {
            return
        }

        guard forceIPv4 else {
            sendResponse(522, "Use EPSV for IPv6 connections")
            return
        }

        do {
            let passiveListener = try openPassiveListener(forceIPv4: true)
            guard let address = configuration.passiveAddressIPv4 ?? controlSocket.localIPAddress else {
                passiveListener.close()
                self.passiveListener = nil
                sendResponse(425, "Configure passiveAddressIPv4 for passive mode")
                return
            }

            let port = Int(try passiveListener.port)
            let p1 = port / 256
            let p2 = port % 256
            let octets = address.split(separator: ".")

            guard octets.count == 4 else {
                passiveListener.close()
                self.passiveListener = nil
                sendResponse(425, "Passive mode requires an IPv4 address")
                return
            }

            sendResponse(227, "Entering Passive Mode (\(octets.joined(separator: ",")),\(p1),\(p2))")
        } catch {
            sendResponse(425, "Can't open passive data connection")
        }
    }

    private func handleEpsv() {
        guard requireAuthentication() else {
            return
        }

        do {
            let passiveListener = try openPassiveListener(forceIPv4: forceIPv4)
            let port = try passiveListener.port
            sendResponse(229, "Entering Extended Passive Mode (|||\(port)|)")
        } catch {
            sendResponse(425, "Can't open passive data connection")
        }
    }

    private func handleStor(_ argument: String?) {
        guard requireAuthentication() else {
            return
        }

        guard let argument, !argument.isEmpty else {
            sendResponse(501, "Missing file name")
            return
        }

        guard let passiveListener else {
            sendResponse(425, "Use PASV or EPSV first")
            return
        }

        guard let destinationURL = pathResolver.resolveFile(argument, currentDirectory: currentDirectory) else {
            closePassiveListener()
            sendResponse(553, "Invalid file name")
            return
        }

        sendResponse(150, "Opening data connection")

        do {
            let transferSocket = try passiveListener.acceptClientSocket()
            defer {
                transferSocket.close()
                closePassiveListener()
            }

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            try Data().write(to: destinationURL)
            let handle = try FileHandle(forWritingTo: destinationURL)
            defer {
                try? handle.close()
            }

            var totalBytes = 0
            while let chunk = try transferSocket.consumeAvailable() {
                totalBytes += chunk.count
                handle.write(chunk)
            }

            configuration.onFileStored?(destinationURL, totalBytes)
            sendResponse(226, "Transfer complete")
        } catch {
            closePassiveListener()
            sendResponse(451, "Transfer aborted")
        }
    }

    private func handleList(_ argument: String?) {
        guard requireAuthentication() else {
            return
        }

        guard let passiveListener else {
            sendResponse(425, "Use PASV or EPSV first")
            return
        }

        let requestedPath = listPath(from: argument)
        let targetURL = pathResolver.resolveItem(requestedPath, currentDirectory: currentDirectory)
        sendResponse(150, "Opening data connection")

        do {
            let transferSocket = try passiveListener.acceptClientSocket()
            defer {
                transferSocket.close()
                closePassiveListener()
            }

            let listing = try directoryListing(for: targetURL)
            try transferSocket.writeUTF8(listing)
            sendResponse(226, "Transfer complete")
        } catch {
            closePassiveListener()
            sendResponse(451, "Transfer aborted")
        }
    }

    private func handleMkd(_ argument: String?) {
        guard requireAuthentication() else {
            return
        }

        guard let argument, !argument.isEmpty else {
            sendResponse(501, "Missing directory name")
            return
        }

        let directoryURL = pathResolver.resolveItem(argument, currentDirectory: currentDirectory)
        let virtualPath = pathResolver.resolveVirtualPath(argument, currentDirectory: currentDirectory)

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            sendResponse(257, "\"\(virtualPath)\" created")
        } catch {
            sendResponse(550, "Failed to create directory")
        }
    }

    private func handleDele(_ argument: String?) {
        guard requireAuthentication() else {
            return
        }

        guard let argument, !argument.isEmpty else {
            sendResponse(501, "Missing file name")
            return
        }

        let targetURL = pathResolver.resolveItem(argument, currentDirectory: currentDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            sendResponse(550, "File not found")
            return
        }

        guard !isDirectory.boolValue else {
            sendResponse(550, "Requested path is a directory")
            return
        }

        do {
            try FileManager.default.removeItem(at: targetURL)
            sendResponse(250, "File deleted")
        } catch {
            sendResponse(550, "Failed to delete file")
        }
    }

    private func handleRmd(_ argument: String?) {
        guard requireAuthentication() else {
            return
        }

        guard let argument, !argument.isEmpty else {
            sendResponse(501, "Missing directory name")
            return
        }

        let targetURL = pathResolver.resolveItem(argument, currentDirectory: currentDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            sendResponse(550, "Directory not found")
            return
        }

        guard isDirectory.boolValue else {
            sendResponse(550, "Requested path is not a directory")
            return
        }

        do {
            try FileManager.default.removeItem(at: targetURL)
            sendResponse(250, "Directory removed")
        } catch {
            sendResponse(550, "Failed to remove directory")
        }
    }

    private func openPassiveListener(forceIPv4: Bool) throws -> Socket {
        closePassiveListener()

        if let passivePortRange = configuration.passivePortRange {
            for port in passivePortRange {
                if let listener = try? Socket.tcpSocketForListen(
                    in_port_t(port),
                    forceIPv4,
                    SOMAXCONN,
                    forceIPv4 ? configuration.bindAddressIPv4 : configuration.bindAddressIPv6
                ) {
                    passiveListener = listener
                    return listener
                }
            }
            throw SocketError.listenFailed("No passive port available in configured range")
        }

        let listener = try Socket.tcpSocketForListen(
            0,
            forceIPv4,
            SOMAXCONN,
            forceIPv4 ? configuration.bindAddressIPv4 : configuration.bindAddressIPv6
        )
        passiveListener = listener
        return listener
    }

    private func closePassiveListener() {
        passiveListener?.close()
        passiveListener = nil
    }

    private func listPath(from argument: String?) -> String? {
        guard let argument else {
            return nil
        }

        let tokens = argument.split(separator: " ", omittingEmptySubsequences: true)
        guard let pathToken = tokens.last(where: { !$0.hasPrefix("-") }) else {
            return nil
        }

        return String(pathToken)
    }

    private func directoryListing(for targetURL: URL) throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let lines: [String]
        if isDirectory.boolValue {
            let contents = try FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            lines = try contents
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map(listEntryFormatter.line(for:))
        } else {
            lines = [try listEntryFormatter.line(for: targetURL)]
        }

        return lines.joined(separator: "\r\n") + "\r\n"
    }

    @discardableResult
    private func requireAuthentication() -> Bool {
        guard isAuthenticated else {
            sendResponse(530, "Please log in")
            return false
        }
        return true
    }

    private func sendResponse(_ code: Int, _ message: String) {
        try? controlSocket.writeUTF8("\(code) \(message)\r\n")
    }

    private func sendMultilineResponse(_ lines: [String]) {
        let payload = lines.joined(separator: "\r\n") + "\r\n"
        try? controlSocket.writeUTF8(payload)
    }
}
