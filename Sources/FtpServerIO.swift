//
//  FtpServerIO.swift
//  ftpServer
//
//  Created by Tomasz on 19/08/2025.
//

import Foundation
import Dispatch
import SwiftExtensions

public protocol HttpServerIODelegate: AnyObject {
    func socketConnectionReceived(_ socket: Socket)
}

open class FtpServerIO {

    public weak var delegate: HttpServerIODelegate?

    private var socket = Socket(socketFileDescriptor: -1)
    private var sockets = Set<Socket>()

    public enum FtpServerIOState: Int32 {
        case starting
        case running
        case stopping
        case stopped
    }

    private var stateValue: Int32 = FtpServerIOState.stopped.rawValue

    public private(set) var state: FtpServerIOState {
        get {
            return FtpServerIOState(rawValue: stateValue)!
        }
        set(state) {
            #if !os(Linux)
            OSAtomicCompareAndSwapInt(self.state.rawValue, state.rawValue, &stateValue)
            #else
            self.stateValue = state.rawValue
            #endif
        }
    }

    public var operating: Bool { return self.state == .running }

    /// String representation of the IPv4 address to receive requests from.
    /// It's only used when the server is started with `forceIPv4` option set to true.
    /// Otherwise, `listenAddressIPv6` will be used.
    public var listenAddressIPv4: String?

    /// String representation of the IPv6 address to receive requests from.
    /// It's only used when the server is started with `forceIPv4` option set to false.
    /// Otherwise, `listenAddressIPv4` will be used.
    public var listenAddressIPv6: String?

    private let queue = DispatchQueue(label: "swifter.httpserverio.clientsockets")

    public var port: Int {
        get throws {
            return Int(try socket.port)
        }
    }

    public func isIPv4() throws -> Bool {
        return try socket.isIPv4()
    }
    
    public func close(socketID: UUID) {
        sockets.first { $0.id == socketID }?.close()
    }

    deinit {
        stop()
    }

    @available(macOS 10.10, *)
    public func start(_ port: in_port_t = 8080, forceIPv4: Bool = true, priority: DispatchQoS.QoSClass = DispatchQoS.QoSClass.background) throws {
        guard !self.operating else { return }
        stop()
        self.state = .starting
        let address = forceIPv4 ? listenAddressIPv4 : listenAddressIPv6
        self.socket = try Socket.tcpSocketForListen(port, forceIPv4, SOMAXCONN, address)
        self.state = .running
        DispatchQueue.global(qos: priority).async { [weak self] in
            guard let strongSelf = self else { return }
            guard strongSelf.operating else { return }
            while let socket = try? strongSelf.socket.acceptClientSocket() {
                DispatchQueue.global(qos: priority).async { [weak self] in
                    guard let strongSelf = self else { return }
                    guard strongSelf.operating else { return }
                    strongSelf.queue.async {
                        strongSelf.sockets.insert(socket)
                    }
                    strongSelf.handleConnection(socket)
                    strongSelf.queue.async {
                        strongSelf.sockets.remove(socket)
                    }
                }
            }
            strongSelf.stop()
        }
    }

    public func stop() {
        guard self.operating else { return }
        self.state = .stopping
        self.queue.sync {
            // Shutdown connected peers because they can live in 'keep-alive' or 'websocket' loops.
            for socket in self.sockets {
                socket.close()
            }
            self.sockets.removeAll(keepingCapacity: true)
        }
        socket.close()
        self.state = .stopped
    }

    private func handleConnection(_ socket: Socket) {
        print("New ftp from \(socket.peerIP.readable)")
        func sendResponse(_ code: Int, _ message: String) {
            let text = "\(code) \(message)\r\n"
            print("Sending response: \(text)")
            try? socket.writeUTF8(text)
        }
        
        sendResponse(220, "Welcome to Swift FTP")
        
        var passiveSocket: Socket? = nil
        
        while true {
            let commandData = try? socket.readLine() // musisz dodać metodę readLine() do Socket
            guard let commandLine = commandData else { break }
            print("Received command: \(commandLine)")
            
            let parts = commandLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let cmd = parts[0].uppercased()
            let arg = parts.count > 1 ? String(parts[1]) : nil
            
            switch cmd {
            case "USER":
                sendResponse(331, "User name okay, need password.")
            case "PASS":
                sendResponse(230, "User logged in, proceed.")
            case "SYST":
                sendResponse(215, "UNIX Type: L8")
            case "TYPE":
                if arg?.uppercased() == "I" {
                    sendResponse(200, "Switching to Binary mode.")
                } else {
                    sendResponse(200, "Type set to \(arg ?? "")")
                }
            case "PWD":
                sendResponse(257, "\"/\" is current directory")
            case "CWD":
                print("Client changed working directory to \(arg.readable)")
                sendResponse(250, "Requested file action okay, completed.")
            case "PASV":
                // otwieramy port danych
                do {
                    let serverIP = "127.0.0.1"
                    passiveSocket = try Socket.tcpSocketForListen(4000, true, SOMAXCONN, nil)
                    
                    let port = try! passiveSocket!.port
                    let p1 = port / 256
                    let p2 = port % 256
                    let ipParts = serverIP.split(separator: ".").map { String($0) }
                    sendResponse(227, "Entering Passive Mode (\(ipParts.joined(separator: ",")),\(p1),\(p2))")
                } catch {
                    sendResponse(425, "Can't open data connection.")
                }
            case "STOR":
                guard let filename = arg?.split("/").last, let pasv = passiveSocket else {
                    sendResponse(425, "Use PASV first.")
                    continue
                }
                if let transferSocket = try? pasv.acceptClientSocket() {
                    print("New transfer connection from \(transferSocket.peerIP.readable)")
                    sendResponse(150, "Opening data connection for \(filename)")
                    let fileURL = URL(filePath: "/Users/tomaskuc/tmp/ftp/").appending(components: filename, directoryHint: .notDirectory)
                    
                    do {
                        if FileManager.default.createFile(atPath: fileURL.path, contents: nil) {

                            var byteCounter = 0
                            let handle = try FileHandle(forWritingTo: fileURL)
                            while let content = try? transferSocket.consumeAvailable() {
                                byteCounter += content.count
                                handle.write(content)
                            }
                            handle.closeFile()
                            print("Content size: \(byteCounter) bytes")
                        } else {
                            print("Problem creating file")
                        }
                    } catch {
                        print(error)
                    }
                    sendResponse(226, "Transfer complete.")
                    transferSocket.close()
                    passiveSocket?.close()
                } else {
                    sendResponse(425, "Data connection failed.")
                }
            case "QUIT":
                sendResponse(221, "Goodbye.")
                return
            default:
                sendResponse(502, "Command not implemented.")
            }
        }
    
        
        socket.close()
    }



}
