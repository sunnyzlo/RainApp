import Foundation
import CoreLocation
import MapKit
import Combine

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastGeocodedLocation: CLLocation?
    private var lastGeocodeAt: Date = .distantPast

    @Published var location: CLLocation?
    @Published var city: String = "Locating..."

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 150
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let loc = locations.last else { return }

        location = loc

        let shouldGeocode: Bool
        if let last = lastGeocodedLocation {
            let movedEnough = loc.distance(from: last) > 120
            let enoughTimePassed = Date().timeIntervalSince(lastGeocodeAt) > 60
            shouldGeocode = movedEnough || enoughTimePassed
        } else {
            shouldGeocode = true
        }
        guard shouldGeocode else { return }

        if geocoder.isGeocoding {
            geocoder.cancelGeocode()
        }

        geocoder.reverseGeocodeLocation(loc) { placemarks, _ in
            guard let place = placemarks?.first else { return }

            let district = place.subLocality ?? place.locality
            let city = place.locality ?? place.administrativeArea ?? place.country ?? ""
            let areaText: String
            if let district, !district.isEmpty, !city.isEmpty, district != city {
                areaText = "\(district), \(city)"
            } else if let district, !district.isEmpty {
                areaText = district
            } else if !city.isEmpty {
                areaText = city
            } else {
                areaText = "Locating..."
            }

            DispatchQueue.main.async {
                self.city = areaText
            }
        }

        lastGeocodedLocation = loc
        lastGeocodeAt = Date()
    }
}
