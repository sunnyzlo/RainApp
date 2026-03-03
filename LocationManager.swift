import Foundation
import CoreLocation
import Combine

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var location: CLLocation?
    @Published var city: String = "Locating..."

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocodedCoordinate: CLLocationCoordinate2D?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.city = "Location denied"
            }
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        DispatchQueue.main.async {
            self.location = latest
        }
        reverseGeocodeIfNeeded(for: latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        _ = error
    }

    private func reverseGeocodeIfNeeded(for location: CLLocation) {
        let coordinate = location.coordinate
        if let last = lastGeocodedCoordinate {
            let latDelta = abs(last.latitude - coordinate.latitude)
            let lonDelta = abs(last.longitude - coordinate.longitude)
            if latDelta < 0.01 && lonDelta < 0.01 {
                return
            }
        }
        lastGeocodedCoordinate = coordinate

        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self else { return }
            let placemark = placemarks?.first
            let cityName =
                placemark?.locality ??
                placemark?.subAdministrativeArea ??
                placemark?.administrativeArea ??
                "Unknown"
            let districtName =
                placemark?.subLocality ??
                placemark?.subAdministrativeArea
            let displayName: String = {
                guard let districtName, !districtName.isEmpty, districtName != cityName else {
                    return cityName
                }
                return "\(cityName), \(districtName)"
            }()
            DispatchQueue.main.async {
                self.city = displayName
            }
        }
    }
}
