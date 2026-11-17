import Foundation

/// One location fix from the device (issue #13). It holds the raw values from Core Location.
/// `LocationPayload` makes the gate JSON from it. Never log a fix: it is private data.
public struct LocationFix: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public var latitude: Double
    public var longitude: Double
    /// The radius of uncertainty in meters (0 or more).
    public var horizontalAccuracy: Double
    public var timestamp: Date
    /// Meters per second, or nil if not known.
    public var speed: Double?
    /// Degrees from true north (0...360), or nil if not known.
    public var course: Double?

    /// Returns nil if the values are not a usable fix (the same rules as the gate `location` command).
    /// A negative speed or course from Core Location means "not known" and becomes nil.
    public init?(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date,
                 speed: Double? = nil, course: Double? = nil) {
        guard latitude.isFinite, (-90...90).contains(latitude),
              longitude.isFinite, (-180...180).contains(longitude),
              horizontalAccuracy.isFinite, horizontalAccuracy >= 0,
              timestamp.timeIntervalSince1970.isFinite else { return nil }
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.speed = speed.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.course = course.flatMap { $0.isFinite && (0...360).contains($0) ? $0 : nil }
    }

    /// A fix from a Core Location visit. `arrival` is `distantPast` if not known.
    /// `departure` is `distantFuture` while the owner is still at the place.
    /// The timestamp is the departure, else the arrival, else `now`. It is never later than `now`.
    public init?(visitLatitude latitude: Double, longitude: Double, horizontalAccuracy: Double,
                 arrival: Date, departure: Date, now: Date) {
        let timestamp: Date
        if departure != .distantFuture, departure <= now {
            timestamp = departure
        } else if arrival != .distantPast, arrival <= now {
            timestamp = arrival
        } else {
            timestamp = now
        }
        self.init(latitude: latitude, longitude: longitude, horizontalAccuracy: horizontalAccuracy,
                  timestamp: timestamp)
    }

    /// The great-circle distance to `other` in meters.
    public func distance(to other: LocationFix) -> Double {
        let radius = 6_371_000.0
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Hides the coordinates, so a print or a log line cannot leak them.
    public var description: String { "LocationFix(<redacted>)" }
    public var debugDescription: String { description }
}

/// How much detail the server gets. Settings > Location > Accuracy.
public enum LocationPrecision: String, Sendable, Codable, CaseIterable {
    /// The fix as Core Location gives it.
    case precise
    /// Coordinates rounded to 0.01 degree (about 1 km), accuracy 1000 m or more, no speed or course.
    case approximate
}

/// The JSON that the gate `location` command reads on stdin (`server/README.md`, `validate_location`).
public enum LocationPayload {
    /// The gate refuses a larger input.
    public static let maxBytes = 4096
    /// Approximate mode: coordinates rounded to this step in degrees (0.01 degree of latitude is about 1.1 km).
    public static let approximateStep = 0.01
    /// Approximate mode: the smallest accuracy that the server gets.
    public static let approximateAccuracy = 1000.0

    private struct Body: Encodable {
        var lat: Double
        var lon: Double
        var accuracy_m: Double
        var timestamp: String
        var speed: Double?
        var course: Double?
    }

    /// One JSON object with `lat`, `lon`, `accuracy_m`, `timestamp` (ISO 8601 UTC) and optional `speed`, `course`.
    public static func encode(_ fix: LocationFix, precision: LocationPrecision) -> Data {
        var body = Body(lat: fix.latitude, lon: fix.longitude, accuracy_m: fix.horizontalAccuracy,
                        timestamp: timestampText(fix.timestamp), speed: fix.speed, course: fix.course)
        if precision == .approximate {
            body.lat = rounded(fix.latitude, limit: 90)
            body.lon = rounded(fix.longitude, limit: 180)
            body.accuracy_m = max(fix.horizontalAccuracy, approximateAccuracy)
            body.speed = nil
            body.course = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // The values are finite (`LocationFix` checks them), so the encoder cannot fail.
        return (try? encoder.encode(body)) ?? Data("{}".utf8)
    }

    /// `2026-11-16T12:00:00.123Z`. The gate accepts ISO 8601 with a time zone.
    public static func timestampText(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
    }

    private static func rounded(_ value: Double, limit: Double) -> Double {
        let steps = (value / approximateStep).rounded()
        return min(max(steps * approximateStep, -limit), limit)
    }
}

/// At most one upload per `minimumInterval`, unless the owner moved more than `overrideDistance`.
public struct LocationRateLimit: Sendable, Equatable {
    public var minimumInterval: TimeInterval
    public var overrideDistance: Double

    public init(minimumInterval: TimeInterval = 120, overrideDistance: Double = 500) {
        self.minimumInterval = minimumInterval
        self.overrideDistance = overrideDistance
    }

    /// `lastSent` is the last fix that the gate accepted and the time of that upload.
    public func allows(_ fix: LocationFix, lastSent: LocationFix?, lastSentAt: Date?, now: Date) -> Bool {
        guard let lastSent, let lastSentAt else { return true }
        if now.timeIntervalSince(lastSentAt) >= minimumInterval { return true }
        if now < lastSentAt { return true }  // The clock went back. Do not block uploads.
        return fix.distance(to: lastSent) > overrideDistance
    }
}
