import Foundation

struct FtpPathResolver {
    let rootDirectory: URL

    func resolveDirectory(_ requestedPath: String, currentDirectory: String) -> String? {
        let components = normalizedComponents(for: requestedPath, currentDirectory: currentDirectory)
        return virtualPath(for: components)
    }

    func resolveFile(_ requestedPath: String, currentDirectory: String) -> URL? {
        let components = normalizedComponents(for: requestedPath, currentDirectory: currentDirectory)
        guard !components.isEmpty else {
            return nil
        }

        return fileURL(for: components)
    }

    func resolveItem(_ requestedPath: String?, currentDirectory: String) -> URL {
        let path = requestedPath?.isEmpty == false ? requestedPath! : currentDirectory
        let components = normalizedComponents(for: path, currentDirectory: currentDirectory)
        return fileURL(for: components)
    }

    func resolveVirtualPath(_ requestedPath: String, currentDirectory: String) -> String {
        let components = normalizedComponents(for: requestedPath, currentDirectory: currentDirectory)
        return virtualPath(for: components)
    }

    private func normalizedComponents(for requestedPath: String, currentDirectory: String) -> [String] {
        var components = requestedPath.hasPrefix("/") ? [] : split(path: currentDirectory)

        for rawComponent in requestedPath.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent)
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }

        return components
    }

    private func split(path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private func virtualPath(for components: [String]) -> String {
        "/" + components.joined(separator: "/")
    }

    private func fileURL(for components: [String]) -> URL {
        components.reduce(rootDirectory) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: false)
        }
    }
}
