import LensSDK

/// The development-backend product (LensSDKDev). The staging ingest URL lives
/// only here: a build that never links this product cannot ship it. Internal
/// consumers opt in explicitly; release builds link only the core.
public enum LensDev {
    public static let developmentIngestUrl =
        "https://data-ingest-api.staging.dolbyio.com/api/v1/cmcd/events"

    /// Registers the development ingest and locks the backend to it.
    public static func enableDevelopmentBackend() throws {
        try Lens.useDevelopmentBackend(url: developmentIngestUrl)
    }
}
