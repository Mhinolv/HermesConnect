import Foundation

/// The one-time "Send Location" card (issue #8, research.md D4): one text line that Hermes can read.
/// It has the coordinates, the accuracy, the time and an Apple Maps link. Never log it.
public enum LocationShareText {
    public static func make(_ fix: LocationFix) -> String {
        let lat = coordinate(fix.latitude)
        let lon = coordinate(fix.longitude)
        let accuracy = Int(fix.horizontalAccuracy.rounded())
        let time = LocationPayload.timestampText(fix.timestamp)
        return "My location: \(lat), \(lon) (accuracy \(accuracy) m, \(time)). \(mapsURL(fix).absoluteString)"
    }

    /// `https://maps.apple.com/?ll=<lat>,<lon>&q=My%20Location`.
    public static func mapsURL(_ fix: LocationFix) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "maps.apple.com"
        parts.path = "/"
        parts.queryItems = [URLQueryItem(name: "ll", value: "\(coordinate(fix.latitude)),\(coordinate(fix.longitude))"),
                            URLQueryItem(name: "q", value: "My Location")]
        return parts.url ?? URL(string: "https://maps.apple.com/")!
    }

    /// Five decimals: about 1 m.
    static func coordinate(_ value: Double) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
