import Dispatch
import Foundation

public final class FTPServer {
    public enum State {
        case starting
        case running
        case stopping
        case stopped
    }

    public let configuration: FTPServerConfiguration

    private let clientQueue = DispatchQueue(label: "FTPServer.client-sockets")
    private let stateLock = NSLock()

    private var listener: Socket?
    private var clientSockets = Set<Socket>()
    private var stateValue: State = .stopped

    public init(configuration: FTPServerConfiguration) {
        self.configuration = configuration
    }

    deinit {
        stop()
    }

    public var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stateValue
    }

    public var isRunning: Bool {
        state == .running
    }

    public var port: Int {
        get throws {
            guard let listener else {
                throw SocketError.getSockNameFailed("Server is not listening")
            }
            return Int(try listener.port)
        }
    }

    public func start(
        port: in_port_t = 21,
        forceIPv4: Bool = true,
        priority: DispatchQoS.QoSClass = .background
    ) throws {
        guard !isRunning else {
            return
        }

        setState(.starting)
        let listenAddress = forceIPv4 ? configuration.bindAddressIPv4 : configuration.bindAddressIPv6
        let listener = try Socket.tcpSocketForListen(port, forceIPv4, SOMAXCONN, listenAddress)
        self.listener = listener
        setState(.running)

        DispatchQueue.global(qos: priority).async { [weak self] in
            self?.acceptLoop(listener: listener, forceIPv4: forceIPv4, priority: priority)
        }
    }

    public func stop() {
        guard state != .stopped else {
            return
        }

        setState(.stopping)
        listener?.close()
        listener = nil

        clientQueue.sync {
            for socket in clientSockets {
                socket.close()
            }
            clientSockets.removeAll(keepingCapacity: false)
        }

        setState(.stopped)
    }

    private func acceptLoop(listener: Socket, forceIPv4: Bool, priority: DispatchQoS.QoSClass) {
        while isRunning {
            do {
                let client = try listener.acceptClientSocket()
                _ = clientQueue.sync {
                    clientSockets.insert(client)
                }

                DispatchQueue.global(qos: priority).async { [weak self] in
                    guard let self else {
                        client.close()
                        return
                    }

                    defer {
                        client.close()
                        _ = self.clientQueue.sync {
                            self.clientSockets.remove(client)
                        }
                    }

                    let session = FTPSession(
                        controlSocket: client,
                        configuration: self.configuration,
                        forceIPv4: forceIPv4
                    )
                    session.run()
                }
            } catch {
                if isRunning {
                    stop()
                }
                break
            }
        }
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        stateValue = newState
        stateLock.unlock()
    }
}