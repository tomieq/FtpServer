import Foundation

struct FTPPathResolver {
    let rootDirectory: URL

    func resolveDirectory(_ requestedPath: String, currentDirectory: String) -> String? {
        let components = normalizedComponents(for: requestedPath, currentDirectory: currentDirectory)
        return "/" + components.joined(separator: "/")
    }

    func resolveFile(_ requestedPath: String, currentDirectory: String) -> URL? {
        let components = normalizedComponents(for: requestedPath, currentDirectory: currentDirectory)
        guard !components.isEmpty else {
            return nil
        }

        return components.reduce(rootDirectory) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: false)
        }
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
}