import Foundation

/// URL of a bundled test fixture under `Tests/HyperCoreTests/Fixtures`.
func fixture(_ name: String) -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        fatalError("Missing test fixture: \(name)")
    }
    return url
}
