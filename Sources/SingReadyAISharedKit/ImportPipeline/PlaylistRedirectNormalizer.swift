import Foundation

struct PlaylistRedirectNormalizer: Sendable {
    func normalize(
        proposedRequest: URLRequest,
        currentRequest: URLRequest?
    ) -> URLRequest {
        guard let originalURL = currentRequest?.url,
              let proposedURL = proposedRequest.url,
              MusicShareHostRegistry.canonicalHost(for: originalURL) == "music.apple.com",
              MusicShareHostRegistry.canonicalHost(for: proposedURL) == "music.apple.com",
              var originalComponents = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            return proposedRequest
        }

        var originalPath = originalComponents.percentEncodedPath
            .split(separator: "/")
            .map(String.init)
        let proposedPath = proposedURL.path
            .split(separator: "/")
            .map(String.init)
        guard originalPath.count >= 3,
              originalPath[1] == "playlist",
              let storefront = proposedPath.first?.lowercased(),
              storefront.count == 2,
              storefront.allSatisfy(\.isLetter),
              proposedPath.count == 1 || (proposedPath.count == 2 && proposedPath[1] == "new") else {
            return proposedRequest
        }

        originalPath[0] = storefront
        originalComponents.percentEncodedPath = "/" + originalPath.joined(separator: "/")
        guard let normalizedURL = originalComponents.url else {
            return proposedRequest
        }
        var normalizedRequest = proposedRequest
        normalizedRequest.url = normalizedURL
        return normalizedRequest
    }
}
