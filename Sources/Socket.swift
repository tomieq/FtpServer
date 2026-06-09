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
open class Socket: Hashable, Equatable {

    let id = UUID()
    let socketFileDescriptor: Int32
    private var shutdown = false

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
        if shutdown {
            return
        }
        shutdown = true
        Socket.close(self.socketFileDescriptor)
    }

    public var port: in_port_t {
        get throws {
            var addr = sockaddr_in()
            return try withUnsafePointer(to: &addr) { pointer in
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                if getsockname(socketFileDescriptor, UnsafeMutablePointer(OpaquePointer(pointer)), &len) != 0 {
                    throw SocketError.getSockNameFailed(Errno.description())
                }
                let sin_port = pointer.pointee.sin_port
                #if os(Linux)
                return ntohs(sin_port)
                #else
                return Int(OSHostByteOrder()) != OSLittleEndian ? sin_port.littleEndian : sin_port.bigEndian
                #endif
            }
        }
    }

    public func isIPv4() throws -> Bool {
        var addr = sockaddr_in()
        return try withUnsafePointer(to: &addr) { pointer in
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            if getsockname(socketFileDescriptor, UnsafeMutablePointer(OpaquePointer(pointer)), &len) != 0 {
                throw SocketError.getSockNameFailed(Errno.description())
            }
            return Int32(pointer.pointee.sin_family) == AF_INET
        }
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
            // EOF: klient zamknął połączenie
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
    
    lazy var peerIP: String? = {
        var addr = sockaddr_storage()
        var addrLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        
        if getpeername(socketFileDescriptor, withUnsafeMutablePointer(to: &addr) {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: sockaddr.self)
        }, &addrLen) != 0 {
            return nil
        }
        
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, addrLen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return result == 0 ? String(cString: hostBuffer) : nil
    }()

    public class func setNoSigPipe(_ socket: Int32) {
        #if os(Linux)
            // There is no SO_NOSIGPIPE in Linux (nor some other systems). You can instead use the MSG_NOSIGNAL flag when calling send(),
            // or use signal(SIGPIPE, SIG_IGN) to make your entire application ignore SIGPIPE.
        #else
            // Prevents crashes when blocking calls are pending and the app is paused ( via Home button ).
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
