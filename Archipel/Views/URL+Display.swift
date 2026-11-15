import Foundation

extension URL {
    /// The path with the home directory shortened to `~`, for showing to people.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
