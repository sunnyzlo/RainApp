import MapKit

class RadarImageOverlay: NSObject, MKOverlay {

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 0, longitude: 0)
    }

    var boundingMapRect: MKMapRect {
        MKMapRect.world
    }

    let image: UIImage

    init(image: UIImage) {
        self.image = image
    }
}//
//  RadarImageOverlay.swift
//  RainApp
//
//  Created by Alexander Savchenko on 2/8/26.
//

