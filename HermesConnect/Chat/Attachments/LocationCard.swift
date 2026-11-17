import CoreLocation
import HermesKit
import MapKit
import UIKit

/// One location fix for the "Send Location" card (issue #8). Its own manager, so the #13 background
/// sharing does not change. "While Using" access is enough. Never log the fix.
@MainActor
final class OneTimeLocation: NSObject, CLLocationManagerDelegate {
    enum Result {
        case fix(LocationFix)
        case denied
        case failed
    }

    private let manager = CLLocationManager()
    private var completion: ((Result) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func request(_ completion: @escaping (Result) -> Void) {
        self.completion = completion
        switch manager.authorizationStatus {
        case .notDetermined:
            // `locationManagerDidChangeAuthorization` asks for the fix after the owner answers.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(.denied)
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result) {
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    private func authorizationChanged() {
        guard completion != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: finish(.denied)
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        MainActor.assumeIsolated { authorizationChanged() }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last.flatMap(LocationFix.init(location:))
        MainActor.assumeIsolated {
            guard completion != nil else { return }
            finish(fix.map(Result.fix) ?? .failed)
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError _: any Error) {
        MainActor.assumeIsolated {
            guard completion != nil else { return }
            finish(.failed)
        }
    }
}

/// The map picture of the location card: 240 x 160 pt, about 600 m across, a red pin in the center.
enum LocationCardSnapshot {
    static let size = CGSize(width: 240, height: 160)

    @MainActor
    static func make(_ fix: LocationFix, traits: UITraitCollection?) async -> UIImage? {
        let center = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, latitudinalMeters: 600, longitudinalMeters: 600)
        options.size = size
        if let traits { options.traitCollection = traits }
        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return pinOnly(traits: traits) }
        return draw(base: snapshot.image, pinAt: snapshot.point(for: center))
    }

    /// No map tiles (offline, Simulator): a plain card with the pin.
    @MainActor
    static func pinOnly(traits: UITraitCollection?) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        let base = renderer.image { context in
            (traits.map { UIColor.secondarySystemBackground.resolvedColor(with: $0) } ?? .systemGray5).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return draw(base: base, pinAt: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    private static func draw(base: UIImage, pinAt point: CGPoint) -> UIImage {
        let pin = UIImage(systemName: "mappin.circle.fill",
                          withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold))?
            .withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        let renderer = UIGraphicsImageRenderer(size: base.size)
        return renderer.image { _ in
            base.draw(at: .zero)
            if let pin {
                let rect = CGRect(x: point.x - pin.size.width / 2, y: point.y - pin.size.height / 2,
                                  width: pin.size.width, height: pin.size.height)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
                pin.draw(in: rect)
            }
        }
    }
}
