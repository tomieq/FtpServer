//
//  Socket.swift
//  ftpServer
//
//  Created by Tomasz on 19/08/2025.
//

import Foundation

public enum SocketError: Error {
    case socketCreationFailed(String)
    case socketSettingReUseAddrFailed(String)
    case bindFailed(String)
    case listenFailed(String)
    case writeFailed(String)
    case getPeerNameFailed(String)
    case convertingPeerNameFailed
    case getNameInfoFailed(String)
    case acceptFailed(String)
    case recvFailed(String)
    case getSockNameFailed(String)
}

// swiftlint: disable identifier_name
open class Socket: Hashable, Equatable, @unchecked Sendable {

    let id = UUID()
    let socketFileDescriptor: Int32
    private var shutdown = false
    private let shutdownLock = NSLock()

    public init(socketFileDescriptor: Int32) {
        self.socketFileDescriptor = socketFileDescriptor
    }

    deinit {
        close()
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.socketFileDescriptor)
    }

    public func close() {
        shutdownLock.lock()
        defer { shutdownLock.unlock() }

        if shutdown {
            return
        }

        shutdown = true
        Socket.close(self.socketFileDescriptor)
    }

    public var port: in_port_t {
        get throws {
            let address = try socketAddress(using: getsockname)
            switch Int32(address.ss_family) {
            case AF_INET:
                let ipv4 = withUnsafePointer(to: address) {
                    $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee
                    }
                }
                return in_port_t(bigEndian: ipv4.sin_port)
            case AF_INET6:
                let ipv6 = withUnsafePointer(to: address) {
                    $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        $0.pointee
                    }
                }
                return in_port_t(bigEndian: ipv6.sin6_port)
            default:
                throw SocketError.getSockNameFailed("Unsupported address family")
            }
        }
    }

    public func isIPv4() throws -> Bool {
        try Int32(socketAddress(using: getsockname).ss_family) == AF_INET
    }

    public var localIPAddress: String? {
        try? ipAddress(using: getsockname)
    }

    public func writeUTF8(_ string: String) throws {
        try writeUInt8(ArraySlice(string.utf8))
    }

    public func writeUInt8(_ data: [UInt8]) throws {
        try writeUInt8(ArraySlice(data))
    }

    public func writeUInt8(_ data: ArraySlice<UInt8>) throws {
        try data.withUnsafeBufferPointer {
            try writeBuffer($0.baseAddress!, length: data.count)
        }
    }

    public func writeData(_ data: Data) throws {
        #if compiler(>=5.0)
        try data.withUnsafeBytes { (body: UnsafeRawBufferPointer) -> Void in
            if let baseAddress = body.baseAddress, body.count > 0 {
                let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
                try self.writeBuffer(pointer, length: data.count)
            }
        }
        #else
        try data.withUnsafeBytes { (pointer: UnsafePointer<UInt8>) -> Void in
            try self.writeBuffer(pointer, length: data.count)
        }
        #endif
    }

    private func writeBuffer(_ pointer: UnsafeRawPointer, length: Int) throws {
        var sent = 0
        while sent < length {
            #if os(Linux)
                let result = send(self.socketFileDescriptor, pointer + sent, Int(length - sent), Int32(MSG_NOSIGNAL))
            #else
                let result = write(self.socketFileDescriptor, pointer + sent, Int(length - sent))
            #endif
            if result <= 0 {
                throw SocketError.writeFailed(Errno.description())
            }
            sent += result
        }
    }

    /// Read a single byte off the socket. This method is optimized for reading
    /// a single byte. For reading multiple bytes, use read(length:), which will
    /// pre-allocate heap space and read directly into it.
    ///
    /// - Returns: A single byte
    /// - Throws: SocketError.recvFailed if unable to read from the socket
    open func read() throws -> UInt8 {
        var byte: UInt8 = 0

        #if os(Linux)
        let count = Glibc.read(self.socketFileDescriptor as Int32, &byte, 1)
        #else
        let count = Darwin.read(self.socketFileDescriptor as Int32, &byte, 1)
        #endif

        guard count > 0 else {
            throw SocketError.recvFailed(Errno.description())
        }
        return byte
    }

    static let kBufferLength = 1024

    
    func consumeAvailable(maxChunkSize: Int = Socket.kBufferLength) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: maxChunkSize)
        
        #if os(Linux)
        let bytesRead = Glibc.read(self.socketFileDescriptor, &buffer, maxChunkSize)
        #else
        let bytesRead = Darwin.read(self.socketFileDescriptor, &buffer, maxChunkSize)
        #endif

        if bytesRead > 0 {
            return Data(buffer.prefix(bytesRead))
        } else if bytesRead == 0 {
            return nil
        } else {
            throw SocketError.recvFailed(Errno.description())
        }
    }

    private static let CR: UInt8 = 13
    private static let NL: UInt8 = 10

    public func readLine() throws -> String {
        var characters: String = ""
        var index: UInt8 = 0
        repeat {
            index = try self.read()
            if index > Socket.CR { characters.append(Character(UnicodeScalar(index))) }
        } while index != Socket.NL
        return characters
    }
    
    public var peerIP: String? {
        try? ipAddress(using: getpeername)
    }

    private func socketAddress(using provider: (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32) throws -> sockaddr_storage {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                provider(self.socketFileDescriptor, $0, &length)
            }
        }
        guard result == 0 else {
            throw SocketError.getSockNameFailed(Errno.description())
        }
        return address
    }

    private func ipAddress(using provider: (Int32, UnsafeMutablePointer<sockaddr>?, UnsafeMutablePointer<socklen_t>?) -> Int32) throws -> String {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let providerResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                provider(self.socketFileDescriptor, $0, &length)
            }
        }
        guard providerResult == 0 else {
            throw SocketError.getSockNameFailed(Errno.description())
        }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let nameInfoResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            }
        }

        guard nameInfoResult == 0 else {
            throw SocketError.getNameInfoFailed(Errno.description())
        }

        let hostBytes = hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: hostBytes, as: UTF8.self)
    }

    public class func setNoSigPipe(_ socket: Int32) {
        #if os(Linux)
        #else
            var no_sig_pipe: Int32 = 1
            setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &no_sig_pipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    public class func close(_ socket: Int32) {
        #if os(Linux)
            _ = Glibc.close(socket)
        #else
            _ = Darwin.close(socket)
        #endif
    }
}

public func == (socket1: Socket, socket2: Socket) -> Bool {
    return socket1.socketFileDescriptor == socket2.socketFileDescriptor
}
