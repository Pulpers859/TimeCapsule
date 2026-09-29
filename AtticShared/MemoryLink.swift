import Foundation

/// The link a widget photo opens: `attic://memory?id=<photo identifier>`.
///
/// Tapping the widget used to open the app to the gallery and leave the
/// photo that was tapped for the user to find again. The widget now links to
/// the photo it is showing, and the app opens it in the viewer.
///
/// The identifier goes in a query item rather than the path because a
/// Photos identifier contains slashes (`<UUID>/L0/001`), and `URLComponents`
/// escapes and unescapes it for us. Framework-free, so the round trip is
/// tested on every platform the package builds on.
nonisolated enum MemoryLink {
    static let scheme = "attic"
    static let host = "memory"
    private static let identifierName = "id"

    static func url(forAssetID identifier: String) -> URL? {
        guard !identifier.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        // Encoded by hand: `queryItems` leaves `&`, `=` and `+` alone, since
        // they are legal in a query, and an identifier holding one would
        // read back cut short. Photos identifiers do not, but nothing
        // promises they never will.
        guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: valueAllowed) else {
            return nil
        }
        components.percentEncodedQuery = "\(identifierName)=\(encoded)"
        return components.url
    }

    private static let valueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")
        return allowed
    }()

    /// The photo identifier in a memory link, or `nil` for any other URL.
    static func assetID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              let identifier = components.queryItems?
                .first(where: { $0.name == identifierName })?
                .value,
              !identifier.isEmpty else {
            return nil
        }
        return identifier
    }
}
