import MapKit

class RadarImageRenderer: MKOverlayRenderer {

    override func draw(
        _ mapRect: MKMapRect,
        zoomScale: MKZoomScale,
        in context: CGContext
    ) {

        guard
            let overlay = overlay as? RadarImageOverlay
        else { return }

        let rect = self.rect(for: overlay.boundingMapRect)

        context.setAlpha(0.6)
        context.draw(
            overlay.image.cgImage!,
            in: rect
        )
    }
}//
//  RadarImageRenderer.swift
//  RainApp
//
//  Created by Alexander Savchenko on 2/8/26.
//

