import SwiftUI
import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct UIKitMap: UIViewRepresentable {
    private static let forecastCacheVersion = "v56"

    struct VisibleTile: Hashable {
        let x: Int
        let y: Int
    }

    struct VisibleTileSnapshot: Equatable {
        let zoom: Int
        let tiles: [VisibleTile]
        let signature: Int
    }

    @Binding var userTracking: Bool
    @Binding var userVisible: Bool
    var isDarkTheme: Bool = true
    var topReservedSpace: CGFloat = 240
    var bottomReservedSpace: CGFloat = 96
    var location: CLLocation?
    var radarFramePath: String?
    var cloudCells: [CloudOverlayService.CloudCell] = []
    var cloudTime: Date? = nil
    var forecastTileTemplate: String?
    var forecastTileMinZoom: Int = 0
    var forecastTileMaxZoom: Int = 6
    var useStaticOverlay: Bool = false
    var staticOverlayAssetName: String? = nil
    var onVisibleTilesChanged: ((VisibleTileSnapshot) -> Void)? = nil

    func makeUIView(context: Context) -> MKMapView {

        let map = MKMapView()

        map.showsUserLocation = true
        map.userTrackingMode = .none
        map.showsCompass = false
        map.delegate = context.coordinator
        ensureAppleBaseMap(map: map, coordinator: context.coordinator)
        context.coordinator.installControls(on: map)
        applyTheme(to: map, coordinator: context.coordinator)

        map.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5072, longitude: -0.1276),
            span: MKCoordinateSpan(latitudeDelta: 0.16, longitudeDelta: 0.16)
        )

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        ensureAppleBaseMap(map: map, coordinator: context.coordinator)
        applyTheme(to: map, coordinator: context.coordinator)

        if useStaticOverlay {
            context.coordinator.logOverlayModeIfChanged(
                mode: "static",
                key: staticOverlayAssetName ?? "nil",
                map: map
            )
            clearRadarOverlay(map: map, coordinator: context.coordinator)
            clearForecastOverlay(map: map, coordinator: context.coordinator)
            clearWeatherOverlay(map: map, coordinator: context.coordinator)
            addStaticOverlay(map: map, coordinator: context.coordinator)
        } else {
            if let old = context.coordinator.staticOverlay {
                map.removeOverlay(old)
                context.coordinator.staticOverlay = nil
            }

            if let template = forecastTileTemplate {
                let key = "\(template)|\(forecastTileMinZoom)|\(forecastTileMaxZoom)"
                context.coordinator.logOverlayModeIfChanged(
                    mode: "forecast",
                    key: key,
                    map: map
                )
                clearRadarOverlay(map: map, coordinator: context.coordinator)
                clearWeatherOverlay(map: map, coordinator: context.coordinator)
                addForecastOverlay(
                    template: template,
                    minZoom: forecastTileMinZoom,
                    maxZoom: forecastTileMaxZoom,
                    map: map,
                    coordinator: context.coordinator
                )
            } else if let path = radarFramePath {
                context.coordinator.logOverlayModeIfChanged(
                    mode: "radar",
                    key: path,
                    map: map
                )
                clearForecastOverlay(map: map, coordinator: context.coordinator)
                clearWeatherOverlay(map: map, coordinator: context.coordinator)
                addRadarOverlay(path: path, map: map, coordinator: context.coordinator)
            } else {
                // Do not drop a valid forecast overlay during transient metadata/template gaps.
                // This prevents visible "empty map" flashes while frame selection updates.
                if context.coordinator.forecastOverlay != nil, cloudCells.isEmpty {
                    context.coordinator.logOverlayModeIfChanged(
                        mode: "forecast-hold",
                        key: "keep-last",
                        map: map
                    )
                    clearRadarOverlay(map: map, coordinator: context.coordinator)
                    return
                }
                context.coordinator.logOverlayModeIfChanged(
                    mode: "weather",
                    key: "cells=\(cloudCells.count)",
                    map: map
                ) 
                clearRadarOverlay(map: map, coordinator: context.coordinator)
                clearForecastOverlay(map: map, coordinator: context.coordinator)
                addWeatherOverlay(
                    cells: cloudCells,
                    map: map,
                    coordinator: context.coordinator
                )
            }
        }

        context.coordinator.updateControlsLayout(for: map)
        context.coordinator.syncControlsState(for: map)
        context.coordinator.scheduleVisibleTileSnapshot(for: map)

        guard let loc = location else { return }

        if context.coordinator.firstLocationFix {
            guard map.bounds.width > 1, map.bounds.height > 1 else { return }
            context.coordinator.firstLocationFix = false
            center(
                map,
                loc,
                animated: false,
                resetZoom: true
            )
            DispatchQueue.main.async {
                userTracking = false
            }
        } else if userTracking {
            center(
                map,
                loc,
                animated: true,
                resetZoom: false
            )
            DispatchQueue.main.async {
                userTracking = false
            }
        }
    }

    private func applyTheme(to map: MKMapView, coordinator: Coordinator) {
        let style: UIUserInterfaceStyle = isDarkTheme ? .dark : .light
        if map.overrideUserInterfaceStyle != style {
            map.overrideUserInterfaceStyle = style
        }
        coordinator.applyControlTheme(isDarkTheme: isDarkTheme)
    }

    fileprivate func center(
        _ map: MKMapView,
        _ loc: CLLocation,
        animated: Bool,
        resetZoom: Bool
    ) {
        if resetZoom {
            let region = MKCoordinateRegion(
                center: loc.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.16, longitudeDelta: 0.16)
            )
            map.setRegion(region, animated: false)
        }

        guard map.bounds.width > 0, map.bounds.height > 0 else {
            map.setCenter(loc.coordinate, animated: animated)
            return
        }

        let focusRect = focusRect(in: map)
        guard focusRect.height > 1 else {
            map.setCenter(loc.coordinate, animated: animated)
            return
        }

        // Shift center so user appears in the center of free area
        // between weather card and timeline, without teleporting first.
        let userPoint = map.convert(loc.coordinate, toPointTo: map)
        let desiredPoint = CGPoint(x: focusRect.midX, y: focusRect.midY)
        let delta = CGPoint(
            x: desiredPoint.x - userPoint.x,
            y: desiredPoint.y - userPoint.y
        )

        if abs(delta.x) < 0.5, abs(delta.y) < 0.5 {
            return
        }

        let mapCenterPoint = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
        let shiftedCenterPoint = CGPoint(
            x: mapCenterPoint.x - delta.x,
            y: mapCenterPoint.y - delta.y
        )
        let shiftedCenterCoordinate = map.convert(
            shiftedCenterPoint,
            toCoordinateFrom: map
        )
        map.setCenter(shiftedCenterCoordinate, animated: animated)
    }

    fileprivate func focusRect(in map: MKMapView) -> CGRect {
        // Keep sane defaults so first location fix works before SwiftUI reports measured heights.
        let effectiveTopReserved = max(topReservedSpace, 220)
        let effectiveBottomReserved = max(bottomReservedSpace, 90)
        let topInset = map.safeAreaInsets.top + max(0, effectiveTopReserved)
        let bottomInset = map.safeAreaInsets.bottom + max(0, effectiveBottomReserved)
        let height = max(1, map.bounds.height - topInset - bottomInset)
        return CGRect(
            x: 0,
            y: topInset,
            width: map.bounds.width,
            height: height
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func ensureAppleBaseMap(
        map: MKMapView,
        coordinator: Coordinator
    ) {
        for overlay in map.overlays where overlay is BaseMapOverlay {
            map.removeOverlay(overlay)
        }
        if let baseOverlay = coordinator.baseMapOverlay {
            map.removeOverlay(baseOverlay)
            coordinator.baseMapOverlay = nil
        }

        map.mapType = .standard
        if #available(iOS 13.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .realistic)
            config.emphasisStyle = .default
            map.preferredConfiguration = config
        }
    }

    // MARK: Radar overlay

    private func clearRadarOverlay(
        map: MKMapView,
        coordinator: Coordinator
    ) {
        guard let overlay = coordinator.overlay else { return }
        map.removeOverlay(overlay)
        coordinator.overlay = nil
        coordinator.lastRadarPath = nil
    }

    private func addRadarOverlay(
        path: String,
        map: MKMapView,
        coordinator: Coordinator
    ) {

        guard coordinator.lastRadarPath != path else { return }
        coordinator.lastRadarPath = path

        if let old = coordinator.overlay {
            map.removeOverlay(old)
        }

        let overlay = RadarOverlay(path: path)
        coordinator.overlay = overlay

        map.addOverlay(overlay, level: .aboveLabels)
        print("🌧 Radar ON:", path)
    }

    // MARK: Forecast tiles overlay (MET Norway / yr-maps)

    private func clearForecastOverlay(
        map: MKMapView,
        coordinator: Coordinator
    ) {
        coordinator.stopForecastFade()
        if let pending = coordinator.pendingForecastPreviousOverlay {
            map.removeOverlay(pending)
            coordinator.pendingForecastPreviousOverlay = nil
            coordinator.pendingForecastPreviousRenderer = nil
        }
        coordinator.clearPendingForecastOverlay(on: map)
        guard let overlay = coordinator.forecastOverlay else { return }
        map.removeOverlay(overlay)
        coordinator.forecastOverlay = nil
        coordinator.forecastRenderer = nil
        coordinator.lastForecastOverlayKey = nil
    }

    private func addForecastOverlay(
        template: String,
        minZoom: Int,
        maxZoom: Int,
        map: MKMapView,
        coordinator: Coordinator
    ) {
        let key = "\(template)|\(minZoom)|\(maxZoom)"
        if coordinator.lastForecastOverlayKey == key { return }
        coordinator.lastForecastOverlayKey = key

        coordinator.stopForecastFade()
        coordinator.clearPendingForecastOverlay(on: map, keeping: coordinator.forecastOverlay)
        coordinator.pendingForecastMotion = .zero

        if let existing = coordinator.forecastOverlay as? ForecastTileOverlay {
            if existing.updateSource(
                urlTemplate: template,
                minSourceZ: minZoom,
                maxSourceZ: maxZoom
            ) {
                if let renderer = coordinator.forecastRenderer {
                    renderer.reloadData()
                }
                print("☁️DBG forecast mode=single-overlay cache=\(Self.forecastCacheVersion)")
                print("☁️ Forecast tiles UPDATE (single overlay):", key)
            }
            return
        }

        let overlay = ForecastTileOverlay(
            urlTemplate: template,
            minSourceZ: minZoom,
            maxSourceZ: maxZoom
        )
        coordinator.forecastOverlay = overlay
        coordinator.forecastRenderer = nil
        map.addOverlay(overlay, level: .aboveLabels)
        print("☁️DBG forecast mode=single-overlay cache=\(Self.forecastCacheVersion)")
        print("☁️ Forecast tiles UPDATE (single overlay):", key)
    }

    // MARK: Static overlay (PNG from Assets)

    private func addStaticOverlay(
        map: MKMapView,
        coordinator: Coordinator
    ) {
        guard coordinator.staticOverlay == nil else { return }
        guard
            let name = staticOverlayAssetName,
            let image = UIImage(named: name)
        else {
            print("🌧 Static overlay image not found:", staticOverlayAssetName ?? "nil")
            return
        }

        let overlay = RadarImageOverlay(image: image)
        coordinator.staticOverlay = overlay
        map.addOverlay(overlay, level: .aboveLabels)
        print("🌧 Static overlay ON:", name)
    }

    // MARK: Open-Meteo precipitation/thunder overlay

    private func clearWeatherOverlay(
        map: MKMapView,
        coordinator: Coordinator
    ) {
        coordinator.stopWeatherFade(on: map)
        if !coordinator.pendingWeatherPreviousOverlays.isEmpty {
            map.removeOverlays(coordinator.pendingWeatherPreviousOverlays)
            coordinator.pendingWeatherPreviousOverlays.removeAll()
        }
        guard !coordinator.weatherOverlays.isEmpty else { return }
        map.removeOverlays(coordinator.weatherOverlays)
        coordinator.weatherOverlays.removeAll()
        coordinator.weatherOverlayAlpha.removeAll()
        coordinator.lastWeatherSignature = nil
    }

    private func addWeatherOverlay(
        cells: [CloudOverlayService.CloudCell],
        map: MKMapView,
        coordinator: Coordinator
    ) {
        var hasher = Hasher()
        hasher.combine(5) // rendering profile version
        hasher.combine(cells.count)
        let hourStamp = Int((cloudTime ?? Date()).timeIntervalSince1970 / 3600)
        hasher.combine(hourStamp)
        for cell in cells {
            hasher.combine(Int((cell.center.latitude * 1000).rounded()))
            hasher.combine(Int((cell.center.longitude * 1000).rounded()))
            hasher.combine(Int((cell.rainIntensity * 100).rounded()))
            hasher.combine(Int((cell.stormRisk * 100).rounded()))
            hasher.combine(cell.row)
            hasher.combine(cell.col)
        }
        let signature = hasher.finalize()
        guard coordinator.lastWeatherSignature != signature else { return }
        coordinator.lastWeatherSignature = signature

        guard !cells.isEmpty else { return }
        let maxRain = cells.map(\.rainIntensity).max() ?? 0
        let maxStorm = cells.map(\.stormRisk).max() ?? 0
        print("☁️ overlay signal maxRain=\(String(format: "%.3f", maxRain)) maxStorm=\(String(format: "%.3f", maxStorm))")
        let incoming = Self.makeWeatherBlobOverlays(from: cells)
        if incoming.isEmpty {
            clearWeatherOverlay(map: map, coordinator: coordinator)
            return
        }

        coordinator.stopWeatherFade(on: map)
        let outgoing = coordinator.weatherOverlays
        if !outgoing.isEmpty {
            coordinator.pendingWeatherPreviousOverlays = outgoing
        }

        map.addOverlays(incoming, level: .aboveLabels)
        coordinator.weatherOverlays = incoming

        for overlay in incoming {
            coordinator.weatherOverlayAlpha[ObjectIdentifier(overlay)] = 1.0
        }

        if outgoing.isEmpty {
            return
        }

        coordinator.startWeatherFade(
            on: map,
            outgoing: outgoing,
            incoming: incoming
        )
    }

    private static func makeWeatherBlobOverlays(
        from cells: [CloudOverlayService.CloudCell]
    ) -> [WeatherBlobOverlay] {
        guard !cells.isEmpty else { return [] }
        let minRain = cells.map(\.rainIntensity).min() ?? 0
        let maxRain = max(0.01, cells.map(\.rainIntensity).max() ?? 0.01)
        let rainRange = max(0.003, maxRain - minRain)
        let maxStorm = max(0.12, cells.map(\.stormRisk).max() ?? 0.12)

        var out: [WeatherBlobOverlay] = []
        out.reserveCapacity(cells.count)

        for cell in cells {
            let baseRainNorm = clamp01((cell.rainIntensity - minRain) / rainRange)
            let texture = cloudTexture(latitude: cell.center.latitude, longitude: cell.center.longitude)
            let rainNorm = clamp01(baseRainNorm * 0.75 + texture * 0.25)
            let stormNorm = clamp01(cell.stormRisk / maxStorm)
            if rainNorm < 0.03 && stormNorm < 0.10 { continue }

            let snowNorm =
                clamp01((0.62 - rainNorm) / 0.62) *
                clamp01(1.0 - stormNorm * 1.25)
            let (red, green, blue, alpha) = weatherPaletteComponents(
                rainNorm: rainNorm,
                stormNorm: stormNorm,
                snowNorm: snowNorm
            )

            let stepMeters = max(
                2_500.0,
                cell.stepDegrees * 111_000.0 * 0.9
            )
            let radiusMeters = stepMeters * (0.55 + 0.35 * rainNorm)
            let fillAlpha = clamp01(alpha * (0.10 + 0.12 * rainNorm))
            if fillAlpha < 0.02 { continue }

            let color = UIColor(
                red: CGFloat(red / 255.0),
                green: CGFloat(green / 255.0),
                blue: CGFloat(blue / 255.0),
                alpha: CGFloat(fillAlpha)
            )
            out.append(
                WeatherBlobOverlay(
                    center: cell.center,
                    radiusMeters: radiusMeters,
                    color: color
                )
            )
        }

        return out
    }

    private static func cloudTexture(latitude: Double, longitude: Double) -> Double {
        let a = sin(latitude * 0.33 + longitude * 0.19)
        let b = sin(latitude * 0.81 - longitude * 0.27)
        let c = cos(latitude * 1.47 + longitude * 0.73)
        return clamp01((a * 0.45 + b * 0.35 + c * 0.20 + 1.0) * 0.5)
    }

    private static func makeWeatherImage(
        rain: [Double],
        storm: [Double],
        gridSize: Int
    ) -> UIImage? {
        let maxRain = rain.max() ?? 0
        let maxStorm = storm.max() ?? 0
        if maxRain < 0.008 && maxStorm < 0.05 { return nil }

        let width = 1024
        let height = 1024
        let bitmapInfo =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setBlendMode(.normal)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        let dx = Double(width - 1) / Double(max(1, gridSize - 1))
        let dy = Double(height - 1) / Double(max(1, gridSize - 1))
        var painted = 0

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let idx = row * gridSize + col
                if idx >= rain.count || idx >= storm.count { continue }

                let rainNorm = clamp01(rain[idx] / max(0.018, maxRain))
                let stormNorm = clamp01(storm[idx] / max(0.12, maxStorm))
                if rainNorm < 0.02 && stormNorm < 0.10 { continue }

                let snowNorm =
                    clamp01((0.62 - rainNorm) / 0.62) *
                    clamp01(1.0 - stormNorm * 1.25)
                let (red, green, blue, alphaBase) = weatherPaletteComponents(
                    rainNorm: rainNorm,
                    stormNorm: stormNorm,
                    snowNorm: snowNorm
                )
                let centerAlpha = clamp01(alphaBase * (0.38 + rainNorm * 0.48))
                if centerAlpha < 0.02 { continue }

                let cx = Double(col) * dx
                // Grid row 0 is south, image y=0 is north.
                let cy = Double(gridSize - 1 - row) * dy
                let radius = min(Double(width), Double(height)) /
                    Double(max(2, gridSize - 1)) *
                    (0.95 + rainNorm * 0.95)

                let colorCenter = UIColor(
                    red: CGFloat(red / 255.0),
                    green: CGFloat(green / 255.0),
                    blue: CGFloat(blue / 255.0),
                    alpha: CGFloat(centerAlpha)
                ).cgColor
                let colorEdge = UIColor(
                    red: CGFloat(red / 255.0),
                    green: CGFloat(green / 255.0),
                    blue: CGFloat(blue / 255.0),
                    alpha: 0
                ).cgColor
                guard let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [colorCenter, colorEdge] as CFArray,
                    locations: [0.0, 1.0]
                ) else { continue }

                context.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(x: cx, y: cy),
                    startRadius: 0,
                    endCenter: CGPoint(x: cx, y: cy),
                    endRadius: CGFloat(radius),
                    options: [.drawsAfterEndLocation]
                )
                painted += 1
            }
        }

        if painted == 0 { return nil }
        guard let cgImage = context.makeImage() else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func smoothedMatrix(
        _ values: [Double],
        gridSize: Int,
        passes: Int
    ) -> [Double] {
        guard gridSize > 1 else { return values }
        guard values.count == gridSize * gridSize else { return values }

        let weights = [
            [1.0, 2.0, 1.0],
            [2.0, 4.0, 2.0],
            [1.0, 2.0, 1.0]
        ]

        var src = values
        var dst = values

        for _ in 0..<passes {
            for row in 0..<gridSize {
                for col in 0..<gridSize {
                    var sum = 0.0
                    var total = 0.0

                    for dy in -1...1 {
                        for dx in -1...1 {
                            let r = row + dy
                            let c = col + dx
                            if r < 0 || r >= gridSize || c < 0 || c >= gridSize {
                                continue
                            }
                            let weight = weights[dy + 1][dx + 1]
                            sum += src[r * gridSize + c] * weight
                            total += weight
                        }
                    }

                    let idx = row * gridSize + col
                    dst[idx] = total > 0 ? sum / total : src[idx]
                }
            }
            swap(&src, &dst)
        }

        return src
    }

    private static func bilinear(
        _ values: [Double],
        gridSize: Int,
        x: Double,
        y: Double
    ) -> Double {
        let x0 = max(0, min(gridSize - 1, Int(floor(x))))
        let y0 = max(0, min(gridSize - 1, Int(floor(y))))
        let x1 = max(0, min(gridSize - 1, x0 + 1))
        let y1 = max(0, min(gridSize - 1, y0 + 1))

        let tx = max(0.0, min(1.0, x - Double(x0)))
        let ty = max(0.0, min(1.0, y - Double(y0)))

        let v00 = values[y0 * gridSize + x0]
        let v10 = values[y0 * gridSize + x1]
        let v01 = values[y1 * gridSize + x0]
        let v11 = values[y1 * gridSize + x1]

        let top = lerp(v00, v10, tx)
        let bottom = lerp(v01, v11, tx)
        return lerp(top, bottom, ty)
    }

    private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private static func weatherPaletteComponents(
        rainNorm: Double,
        stormNorm: Double,
        snowNorm: Double
    ) -> (Double, Double, Double, Double) {
        let rain = clamp01(rainNorm)
        let snow = clamp01(snowNorm)

        // Cloud palette: soft white/gray-blue, no dark storm fill.
        var red = lerp(226.0, 196.0, rain)
        var green = lerp(233.0, 208.0, rain)
        var blue = lerp(241.0, 224.0, rain)
        var alpha = 0.10 + rain * 0.22

        if snow > 0.08 {
            let snowMix = 0.45 + 0.35 * snow
            let snowRed = 245.0
            let snowGreen = 247.0
            let snowBlue = 250.0
            red = mix(red, snowRed, snowMix)
            green = mix(green, snowGreen, snowMix)
            blue = mix(blue, snowBlue, snowMix)
            alpha = max(alpha, 0.14 + rain * 0.18)
        }

        return (red, green, blue, clamp01(alpha))
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        if edge0 == edge1 { return x < edge0 ? 0 : 1 }
        let t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    final class WeatherBlobOverlay: NSObject, MKOverlay {
        let coordinate: CLLocationCoordinate2D
        let boundingMapRect: MKMapRect
        let color: UIColor

        init(center: CLLocationCoordinate2D, radiusMeters: Double, color: UIColor) {
            self.coordinate = center
            self.color = color
            let centerPoint = MKMapPoint(center)
            let pointsPerMeter = MKMapPointsPerMeterAtLatitude(center.latitude)
            let radiusMapPoints = max(1.0, radiusMeters * pointsPerMeter)
            self.boundingMapRect = MKMapRect(
                x: centerPoint.x - radiusMapPoints,
                y: centerPoint.y - radiusMapPoints,
                width: radiusMapPoints * 2,
                height: radiusMapPoints * 2
            )
        }
    }

    final class WeatherBlobRenderer: MKOverlayRenderer {
        override func draw(
            _ mapRect: MKMapRect,
            zoomScale: MKZoomScale,
            in context: CGContext
        ) {
            guard let overlay = overlay as? WeatherBlobOverlay else { return }
            let rect = self.rect(for: overlay.boundingMapRect)
            context.setShouldAntialias(true)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = max(rect.width, rect.height) * 0.5
            let colorCenter = overlay.color.cgColor
            let colorEdge = overlay.color.withAlphaComponent(0).cgColor
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [colorCenter, colorEdge] as CFArray,
                locations: [0.0, 1.0]
            ) else { return }

            context.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: radius,
                options: [.drawsAfterEndLocation]
            )
        }
    }

    final class ForecastTileRenderer: MKTileOverlayRenderer {
        var transitionOffset: CGPoint = .zero
        var toneDarkening: CGFloat = 0.0

        override func draw(
            _ mapRect: MKMapRect,
            zoomScale: MKZoomScale,
            in context: CGContext
        ) {
            context.saveGState()
            // Prevent tile-edge seams from subpixel filtering on transformed quads.
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false)
            if transitionOffset != .zero {
                context.translateBy(x: transitionOffset.x, y: transitionOffset.y)
            }
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            // Disable extra darkening; it crushes the blue gradient.
            context.restoreGState()
        }
    }

    final class BaseMapOverlay: MKTileOverlay {
        private static let userAgent = "RainApp/1.0 (+https://github.com/alex/RainApp)"
        private static let sampleModulo = 64
        private static let placeholderTileData: Data? = {
            let size = 256
            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue

            guard let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.setFillColor(UIColor(red: 0.82, green: 0.84, blue: 0.86, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))

            context.setStrokeColor(UIColor(red: 0.68, green: 0.71, blue: 0.74, alpha: 1).cgColor)
            context.setLineWidth(1.0)
            let step = 32
            for i in stride(from: 0, through: size, by: step) {
                context.move(to: CGPoint(x: i, y: 0))
                context.addLine(to: CGPoint(x: i, y: size))
                context.move(to: CGPoint(x: 0, y: i))
                context.addLine(to: CGPoint(x: size, y: i))
            }
            context.strokePath()

            let output = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                  ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }()

        override init(urlTemplate URLTemplate: String?) {
            super.init(urlTemplate: URLTemplate)
            tileSize = CGSize(width: 256, height: 256)
            minimumZ = 0
            maximumZ = 19
            canReplaceMapContent = false
            isGeometryFlipped = false
        }

        convenience init() {
            self.init(urlTemplate: nil)
        }

        override func loadTile(
            at path: MKTileOverlayPath,
            result: @escaping (Data?, Error?) -> Void
        ) {
            let z = min(max(0, path.z), 19)
            let n = max(1, 1 << z)
            let x = ((path.x % n) + n) % n
            guard path.y >= 0, path.y < n else {
                result(Self.placeholderTileData, nil)
                return
            }
            let urlString = "https://tile.openstreetmap.org/\(z)/\(x)/\(path.y).png"
            guard let url = URL(string: urlString) else {
                result(Self.placeholderTileData, nil)
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 7
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/png,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: request) { data, response, _ in
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let shouldSample = ((path.x + path.y + path.z) & (Self.sampleModulo - 1)) == 0
                if statusCode == 200, let data, !data.isEmpty {
                    if shouldSample {
                        print("🗺 base tile 200 z=\(path.z) x=\(path.x) y=\(path.y) bytes=\(data.count)")
                    }
                    result(data, nil)
                    return
                }

                if shouldSample {
                    print("🗺 base tile fallback z=\(path.z) x=\(path.x) y=\(path.y) status=\(statusCode)")
                }
                result(Self.placeholderTileData, nil)
            }.resume()
        }
    }

    class ForecastTileOverlay: MKTileOverlay {

        // Keep overlay visible at close zoom levels even when source max zoom is limited.
        // Source often ends at z=7, while device can go much closer than z=11.
        private let overzoomLevels = 12
        private let stateQueue = DispatchQueue(
            label: "RainApp.ForecastTileOverlay.state",
            attributes: .concurrent
        )
        private var template: String
        private var fallbackTemplate: String?
        private var fallbackTemplateSetAt: TimeInterval = 0
        private var minSourceZ: Int
        private var maxSourceZ: Int

        private struct RenderedTile {
            let data: Data
            let visiblePixelCount: Int
        }
        private final class DecodedSourceImageBox {
            let image: CGImage

            init(_ image: CGImage) {
                self.image = image
            }
        }
        private static let useRawRendering = true
        private static let debugLoggingEnabled = true
        private static let debugSampleMask = 63
        // Keep fallback permissive so cloud layer does not disappear between frame swaps.
        private static let minVisiblePixelsForGenericFallback = 1
        private static let minVisiblePixelsForGenericStore = 2
        private static let minVisiblePixelsToTrustCurrentTile = 6

        private static let userAgent =
            "RainApp/1.0 (+https://github.com/alex/RainApp)"
        private static let cacheVersion = UIKitMap.forecastCacheVersion
        private static let renderedTileCache: NSCache<NSString, NSData> = {
            let cache = NSCache<NSString, NSData>()
            cache.countLimit = 3000
            cache.totalCostLimit = 72 * 1024 * 1024
            return cache
        }()
        private static let stickyTileCache: NSCache<NSString, NSData> = {
            let cache = NSCache<NSString, NSData>()
            cache.countLimit = 1800
            cache.totalCostLimit = 32 * 1024 * 1024
            return cache
        }()
        private static let stickyStateQueue = DispatchQueue(
            label: "RainApp.ForecastTileOverlay.sticky-state",
            attributes: .concurrent
        )
        private static var stickyTileUpdatedAt: [String: TimeInterval] = [:]
        private static let stickyTileMaxAge: TimeInterval = 600
        private static var fallbackGeneration: Int = 0
        private static let sourceTileCache: NSCache<NSString, NSData> = {
            let cache = NSCache<NSString, NSData>()
            cache.countLimit = 3600
            cache.totalCostLimit = 96 * 1024 * 1024
            return cache
        }()
        private static let decodedSourceImageCache: NSCache<NSString, DecodedSourceImageBox> = {
            let cache = NSCache<NSString, DecodedSourceImageBox>()
            cache.countLimit = 1200
            cache.totalCostLimit = 64 * 1024 * 1024
            return cache
        }()
        private static let sourceTileSignalCache: NSCache<NSString, NSNumber> = {
            let cache = NSCache<NSString, NSNumber>()
            cache.countLimit = 5600
            return cache
        }()
        private typealias SourceTileCompletion = (Data?, Int, Error?) -> Void
        private static let sourceFetchStateQueue = DispatchQueue(
            label: "RainApp.ForecastTileOverlay.source-fetch-state"
        )
        private static var inFlightSourceRequests: [String: [SourceTileCompletion]] = [:]
        private static let renderedVisiblePixelCache: NSCache<NSString, NSNumber> = {
            let cache = NSCache<NSString, NSNumber>()
            cache.countLimit = 3000
            return cache
        }()
        private static let clearTilePNGData: Data = {
            let size = CGSize(width: 256, height: 256)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                UIColor.clear.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            return image.pngData() ?? Data()
        }()
        private static let networkSession: URLSession = {
            let config = URLSessionConfiguration.default
            // Keep parallelism moderate, but high enough for viewport bursts.
            config.httpMaximumConnectionsPerHost = 8
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 25
            config.waitsForConnectivity = false
            return URLSession(configuration: config)
        }()
        private static let renderedPrewarmQueue = DispatchQueue(
            label: "RainApp.ForecastTileOverlay.rendered-prewarm",
            qos: .utility
        )
        private static func shouldSample(_ path: MKTileOverlayPath) -> Bool {
            guard debugLoggingEnabled else { return false }
            return ((path.x & 7) == 0) && ((path.y & 7) == 0)
        }
        private static func shouldSampleStats(_ path: MKTileOverlayPath) -> Bool {
            guard debugLoggingEnabled else { return false }
            return ((path.x + path.y + path.z) & debugSampleMask) == 0
        }
        private static func shouldBypassClientRendering(_ template: String) -> Bool {
            // Do not bypass client rendering for forecast backend tiles.
            // Client-side rendering preserves weak/small precip fragments better.
            _ = template
            return false
        }
        nonisolated private static func templateDebugToken(_ template: String) -> String {
            let parts = template.split(separator: "/")
            if let stamp = parts.first(where: { $0.count == 12 && $0.allSatisfy(\.isNumber) }) {
                return String(stamp)
            }
            return String(parts.suffix(2).joined(separator: "/"))
        }

        init(
            urlTemplate: String,
            minSourceZ: Int,
            maxSourceZ: Int,
            fallbackTemplate: String? = nil
        ) {
            let normalizedMin = max(0, minSourceZ)
            let normalizedMax = max(normalizedMin, maxSourceZ)
            self.template = urlTemplate
            self.fallbackTemplate = fallbackTemplate
            self.fallbackTemplateSetAt = fallbackTemplate == nil ? 0 : Date().timeIntervalSince1970
            self.minSourceZ = normalizedMin
            self.maxSourceZ = normalizedMax
            super.init(urlTemplate: nil)

            tileSize = CGSize(width: 256, height: 256)
            minimumZ = 0
            maximumZ = normalizedMax + overzoomLevels
            canReplaceMapContent = false
            isGeometryFlipped = false
            Self.prewarmGlobalPreview(template: urlTemplate)
        }

        func updateSource(
            urlTemplate: String,
            minSourceZ: Int,
            maxSourceZ: Int
        ) -> Bool {
            let normalizedMin = max(0, minSourceZ)
            let normalizedMax = max(normalizedMin, maxSourceZ)
            var changed = false

            stateQueue.sync(flags: .barrier) {
                if template != urlTemplate ||
                    self.minSourceZ != normalizedMin ||
                    self.maxSourceZ != normalizedMax
                {
                    // Keep only the immediate previous frame as a soft fallback source.
                    // It is used selectively (mainly medium zoom + failed/empty current tile)
                    // to avoid large "holes" during rapid frame switches.
                    fallbackTemplate = template
                    fallbackTemplateSetAt = Date().timeIntervalSince1970
                    template = urlTemplate
                    self.minSourceZ = normalizedMin
                    self.maxSourceZ = normalizedMax
                    changed = true
                }
            }

            if changed {
                // Keep fallback caches across adjacent forecast frames.
                // This avoids full precipitation disappearance when a new frame
                // has sparse/zero-visible tiles on high zoom while data loads.
                maximumZ = normalizedMax + overzoomLevels
                Self.prewarmGlobalPreview(template: urlTemplate)
            }
            return changed
        }

        func currentTemplateIdentifier() -> String {
            sourceSnapshot().template
        }

        func hasCachedCoverage(
            zoom: Int,
            tiles: [UIKitMap.VisibleTile],
            minimumTiles: Int = 2
        ) -> Bool {
            guard zoom >= 0, !tiles.isEmpty else { return false }
            let template = sourceSnapshot().template
            var hits = 0
            let limit = min(96, tiles.count)

            for tile in tiles.prefix(limit) {
                let path = MKTileOverlayPath(
                    x: tile.x,
                    y: tile.y,
                    z: zoom,
                    contentScaleFactor: 1.0
                )
                let key = Self.tileCacheKey(template: template, requested: path)
                guard let cachedData = Self.renderedTileCache.object(forKey: key as NSString) else {
                    continue
                }
                if Self.cachedTileHasVisiblePixels(
                    key: key,
                    data: cachedData as Data
                ) {
                    hits += 1
                    if hits >= minimumTiles { return true }
                }
            }
            return false
        }

        func sourceCoverageDescriptor() -> (
            template: String,
            minSourceZ: Int,
            maxSourceZ: Int
        ) {
            let source = sourceSnapshot()
            return (
                template: source.template,
                minSourceZ: source.minSourceZ,
                maxSourceZ: source.maxSourceZ
            )
        }

        static func hasSourceCacheCoverage(
            template: String,
            minSourceZ: Int,
            maxSourceZ: Int,
            requestedZoom: Int,
            visibleTiles: [UIKitMap.VisibleTile],
            minimumTiles: Int = 1
        ) -> Bool {
            guard requestedZoom >= 0, !visibleTiles.isEmpty else { return false }
            let sourceZ = min(
                max(requestedZoom, max(0, minSourceZ)),
                max(max(0, minSourceZ), maxSourceZ)
            )
            let zoomDelta = max(0, requestedZoom - sourceZ)
            let sourceN = 1 << sourceZ
            guard sourceN > 0 else { return false }

            var hits = 0
            var seen = Set<UIKitMap.VisibleTile>()
            for tile in visibleTiles.prefix(140) {
                let sourceX = ((tile.x >> zoomDelta) % sourceN + sourceN) % sourceN
                let sourceY = tile.y >> zoomDelta
                guard sourceY >= 0, sourceY < sourceN else { continue }
                let sourceTile = UIKitMap.VisibleTile(x: sourceX, y: sourceY)
                if !seen.insert(sourceTile).inserted { continue }

                guard let url = makeURLStatic(
                    template: template,
                    z: sourceZ,
                    x: sourceX,
                    y: sourceY
                ) else {
                    continue
                }
                if sourceTileCache.object(forKey: url.absoluteString as NSString) != nil {
                    hits += 1
                    if hits >= minimumTiles { return true }
                }
            }
            return false
        }

        static func prewarmTile(
            template: String,
            z: Int,
            x: Int,
            y: Int
        ) {
            guard let url = makeURLStatic(template: template, z: z, x: x, y: y) else { return }
            fetchSourceTile(
                url: url,
                timeout: 7,
                z: z,
                x: x,
                y: y
            ) { _, _, _ in }
        }

        static func hasSourceCoverage(
            template: String,
            minSourceZ: Int,
            maxSourceZ: Int,
            requestedZoom: Int,
            visibleTiles: [UIKitMap.VisibleTile],
            minimumTiles: Int = 2
        ) -> Bool {
            guard requestedZoom >= 0, !visibleTiles.isEmpty else { return false }
            let sourceZ = min(max(requestedZoom, max(0, minSourceZ)), max(max(0, minSourceZ), maxSourceZ))
            let zoomDelta = max(0, requestedZoom - sourceZ)
            let sourceN = 1 << sourceZ
            guard sourceN > 0 else { return false }
            var hits = 0
            let scale = 1 << zoomDelta

            for tile in visibleTiles.prefix(120) {
                let sourceX = ((tile.x >> zoomDelta) % sourceN + sourceN) % sourceN
                let sourceY = tile.y >> zoomDelta
                guard sourceY >= 0, sourceY < sourceN else { continue }
                let xOffset = zoomDelta == 0 ? 0 : (tile.x % scale + scale) % scale
                let yOffset = zoomDelta == 0 ? 0 : (tile.y % scale + scale) % scale

                guard let url = makeURLStatic(
                    template: template,
                    z: sourceZ,
                    x: sourceX,
                    y: sourceY
                ) else {
                    continue
                }

                let key = url.absoluteString as NSString
                if let cached = sourceTileCache.object(forKey: key),
                   cachedSourceTileHasSignal(
                    key: "\(url.absoluteString)|\(scale)|\(xOffset)|\(yOffset)",
                    data: cached as Data,
                    scale: scale,
                    xOffset: xOffset,
                    yOffset: yOffset
                   )
                {
                    hits += 1
                    if hits >= minimumTiles { return true }
                }
            }

            return false
        }

        static func hasRenderedCoverage(
            template: String,
            requestedZoom: Int,
            visibleTiles: [UIKitMap.VisibleTile],
            minimumTiles: Int = 2
        ) -> Bool {
            guard requestedZoom >= 0, !visibleTiles.isEmpty else { return false }
            var hits = 0
            let limit = min(120, visibleTiles.count)

            for tile in visibleTiles.prefix(limit) {
                let path = MKTileOverlayPath(
                    x: tile.x,
                    y: tile.y,
                    z: requestedZoom,
                    contentScaleFactor: 1.0
                )
                let key = tileCacheKey(template: template, requested: path)
                guard let cached = renderedTileCache.object(forKey: key as NSString) else {
                    continue
                }
                if cachedTileHasVisiblePixels(key: key, data: cached as Data) {
                    hits += 1
                    if hits >= minimumTiles { return true }
                }
            }

            return false
        }

        static func prewarmRenderedTile(
            template: String,
            minSourceZ: Int,
            maxSourceZ: Int,
            requestedZoom: Int,
            x: Int,
            y: Int
        ) {
            guard requestedZoom >= 0 else { return }
            let path = MKTileOverlayPath(
                x: x,
                y: y,
                z: requestedZoom,
                contentScaleFactor: 1.0
            )
            let key = tileCacheKey(template: template, requested: path)

            if let cached = renderedTileCache.object(forKey: key as NSString),
               cachedTileHasVisiblePixels(key: key, data: cached as Data)
            {
                return
            }

            renderedPrewarmQueue.async {
                if let cached = renderedTileCache.object(forKey: key as NSString),
                   cachedTileHasVisiblePixels(key: key, data: cached as Data)
                {
                    return
                }

                let overlay = ForecastTileOverlay(
                    urlTemplate: template,
                    minSourceZ: minSourceZ,
                    maxSourceZ: maxSourceZ
                )
                overlay.loadTile(at: path) { data, _ in
                    if shouldSample(path) {
                        print(
                            "☁️DBG prewarm rendered",
                            "z=\(path.z)",
                            "x=\(path.x)",
                            "y=\(path.y)",
                            "ok=\(data != nil)"
                        )
                    }
                }
            }
        }

        private func sourceSnapshot() -> (
            template: String,
            fallbackTemplate: String?,
            minSourceZ: Int,
            maxSourceZ: Int
        ) {
            stateQueue.sync {
                (
                    template: template,
                    fallbackTemplate: fallbackTemplate,
                    minSourceZ: minSourceZ,
                    maxSourceZ: maxSourceZ
                )
            }
        }

        override func loadTile(
            at tilePath: MKTileOverlayPath,
            result: @escaping (Data?, Error?) -> Void
        ) {
            let source = sourceSnapshot()
            let sourceZ = min(
                max(tilePath.z, source.minSourceZ),
                source.maxSourceZ
            )
            if Self.shouldSample(tilePath) {
                print(
                    "☁️DBG tile request",
                    "reqZ=\(tilePath.z)",
                    "reqX=\(tilePath.x)",
                    "reqY=\(tilePath.y)",
                    "srcZ=\(sourceZ)",
                    "template=\(Self.templateDebugToken(source.template))",
                    "fallback=\(source.fallbackTemplate.map(Self.templateDebugToken) ?? "nil")"
                )
            }
            loadTileForSourceZ(
                requested: tilePath,
                sourceZ: sourceZ,
                minSourceZ: source.minSourceZ,
                template: source.template,
                fallbackTemplate: source.fallbackTemplate,
                retriesLeft: 1,
                result: result
            )
        }

        private func loadTileDirect(
            requested: MKTileOverlayPath,
            sourceZ: Int,
            template: String,
            fallbackTemplate: String?,
            result: @escaping (Data?, Error?) -> Void
        ) {
            let specificKey = Self.tileCacheKey(template: template, requested: requested)
            let bypass = Self.shouldBypassClientRendering(template)
            let canReuseRenderedCache = !(bypass && sourceZ != requested.z)
            if canReuseRenderedCache,
               let cached = Self.renderedTileCache.object(forKey: specificKey as NSString)
            {
                let cachedData = cached as Data
                if Self.cachedTileHasVisiblePixels(key: specificKey, data: cachedData) {
                    result(cachedData, nil)
                    return
                }
                Self.renderedTileCache.removeObject(forKey: specificKey as NSString)
                Self.renderedVisiblePixelCache.removeObject(forKey: specificKey as NSString)
            }

            let fallbackKey = Self.fallbackTileKey(template: template, requested: requested)
            let genericKey = Self.genericTileKey(template: template, requested: requested)
            let stickyKey = Self.stickyTileKey(template: template, requested: requested)
            let resolveVisibleRenderedCache: (_ key: String, _ reason: String) -> (Data, String)? = { key, reason in
                guard let cached = Self.renderedTileCache.object(forKey: key as NSString) else {
                    return nil
                }
                let data = cached as Data
                guard Self.cachedTileHasVisiblePixels(key: key, data: data) else {
                    return nil
                }
                return (data, reason)
            }
            let isMediumZoom = requested.z >= 4 && requested.z <= 8
            let allowStickyFallback = !isMediumZoom && requested.z <= 7
            let resolveStickyFallback: () -> (Data, String)? = {
                if allowStickyFallback,
                   let sticky = Self.freshStickyTile(key: stickyKey)
                {
                    return (sticky, "sticky")
                }
                return nil
            }
            let allowStickyCompositeFallback = !isMediumZoom && requested.z <= 7
            let resolveCachedFallback: () -> (Data, String)? = {
                if let resolved = resolveVisibleRenderedCache(fallbackKey, "current-fallback") {
                    return resolved
                }
                if let composite = self.childCompositeFallbackTile(
                    template: template,
                    requested: requested
                ) {
                    return (composite.data, "child-composite")
                }
                if allowStickyCompositeFallback,
                   let composite = self.childCompositeStickyFallbackTile(
                    template: template,
                    requested: requested
                   )
                {
                    return (composite.data, "sticky-child-composite")
                }
                if let parent = self.parentFallbackTile(
                    template: template,
                    requested: requested
                ) {
                    return (parent, "parent-fallback")
                }
                if let preview = self.globalPreviewFallbackTile(
                    template: template,
                    requested: requested
                ) {
                    return (preview, "global-preview")
                }
                return resolveStickyFallback()
            }

            let zoomDelta = max(0, requested.z - sourceZ)
            let scale = 1 << zoomDelta
            let sourceN = 1 << sourceZ
            guard sourceN > 0 else {
                if let (cached, _) = resolveCachedFallback() {
                    result(cached, nil)
                    return
                }
                result(Self.clearTilePNGData, nil)
                return
            }

            let sourceX = ((requested.x / scale) % sourceN + sourceN) % sourceN
            let sourceY = requested.y / scale
            guard sourceY >= 0, sourceY < sourceN else {
                if let (cached, _) = resolveCachedFallback() {
                    result(cached, nil)
                    return
                }
                result(Self.clearTilePNGData, nil)
                return
            }

            fetchTile(
                template: template,
                z: sourceZ,
                x: sourceX,
                y: sourceY
            ) { data, statusCode, error in
                guard statusCode == 200, let data, !data.isEmpty else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:http-\(statusCode)")
                        }
                        result(cached, nil)
                        return
                    }
                    result(Self.clearTilePNGData, nil)
                    return
                }

                if bypass {
                    if Self.isSuspiciousBypassSourceTile(data) {
                        if Self.shouldSample(requested) {
                            print("☁️ tile drop suspicious-source", "z=\(requested.z)", "x=\(requested.x)", "y=\(requested.y)", "bytes=\(data.count)")
                        }
                        result(Self.clearTilePNGData, nil)
                        return
                    }
                    if sourceZ == requested.z {
                        // Backend tiles are already styled; do not decode/re-encode or alpha-threshold.
                        // Treat as visible to avoid "empty tile" misclassification at low zoom.
                        Self.storeRenderedTile(
                            data,
                            specificKey: specificKey,
                            fallbackKey: fallbackKey,
                            genericKey: genericKey,
                            stickyKey: stickyKey,
                            visiblePixelCount: Self.minVisiblePixelsForGenericStore,
                            storeAsGeneric: true
                        )
                        result(data, nil)
                        return
                    }
                    let sourceImageKey = Self.sourceImageCacheKey(
                        template: template,
                        z: sourceZ,
                        x: sourceX,
                        y: sourceY
                    )
                    guard let sourceImage = Self.decodeSourceImage(
                        data,
                        cacheKey: sourceImageKey
                    ) else {
                        result(Self.clearTilePNGData, nil)
                        return
                    }
                    let rendered = Self.cropAndScalePassthrough(
                        sourceImage: sourceImage,
                        requested: requested,
                        sourceZ: sourceZ,
                        targetSize: self.tileSize
                    )
                    guard let rendered else {
                        result(Self.clearTilePNGData, nil)
                        return
                    }
                    // Do not persist overzoom-rendered tiles for bypass templates:
                    // stale center fragments can survive quick zoom/time switches.
                    Self.logTileStats(rendered.data, label: "raw-crop", path: requested)
                    result(rendered.data, nil)
                    return
                }

                let sourceImageKey = Self.sourceImageCacheKey(
                    template: template,
                    z: sourceZ,
                    x: sourceX,
                    y: sourceY
                )
                guard let sourceImage = Self.decodeSourceImage(
                    data,
                    cacheKey: sourceImageKey
                ) else {
                    result(Self.clearTilePNGData, nil)
                    return
                }

                let preserveWeakSignal = requested.z <= 8 || sourceZ <= 6 || requested.z >= 9
                let rendered: RenderedTile?
                if preserveWeakSignal {
                    if sourceZ == requested.z {
                        rendered = Self.renderPassthroughTile(
                            image: sourceImage,
                            targetSize: CGSize(width: sourceImage.width, height: sourceImage.height),
                            interpolation: .none
                        )
                    } else {
                        rendered = Self.cropAndScalePassthrough(
                            sourceImage: sourceImage,
                            requested: requested,
                            sourceZ: sourceZ,
                            targetSize: self.tileSize
                        )
                    }
                } else if Self.useRawRendering {
                    if sourceZ == requested.z {
                        rendered = Self.renderRawTile(
                            image: sourceImage,
                            targetSize: CGSize(width: sourceImage.width, height: sourceImage.height),
                            interpolation: .none
                        )
                    } else {
                        rendered = Self.cropAndScaleRaw(
                            sourceImage: sourceImage,
                            requested: requested,
                            sourceZ: sourceZ,
                            targetSize: self.tileSize
                        )
                    }
                } else {
                    if sourceZ == requested.z {
                        rendered = Self.maskAndEncodeForecastTile(
                            image: sourceImage,
                            targetSize: CGSize(width: sourceImage.width, height: sourceImage.height),
                            interpolation: .none,
                            edgeSmoothingPasses: 0,
                            tileEdgeFeatherWidth: 0
                        )
                    } else {
                        rendered = Self.cropAndScale(
                            sourceImage: sourceImage,
                            requested: requested,
                            sourceZ: sourceZ,
                            targetSize: self.tileSize
                        )
                    }
                }

                guard let rendered else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:render-nil")
                        }
                        result(cached, nil)
                        return
                    }
                    result(Self.clearTilePNGData, nil)
                    return
                }

                guard rendered.visiblePixelCount >= Self.minVisiblePixelsForGenericFallback else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:low-visible-drop \(rendered.visiblePixelCount)")
                        }
                        result(cached, nil)
                        return
                    }
                    if allowStickyFallback,
                       let sticky = Self.freshStickyTile(key: stickyKey)
                    {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback: sticky reason:low-visible-drop \(rendered.visiblePixelCount)")
                        }
                        result(sticky, nil)
                        return
                    }
                    if Self.shouldSample(requested) {
                        print("☁️ tile hold reason:low-visible-drop \(rendered.visiblePixelCount)")
                    }
                    // Keep previous map content instead of caching a near-empty tile.
                    result(Self.clearTilePNGData, nil)
                    return
                }

                Self.storeRenderedTile(
                    rendered.data,
                    specificKey: specificKey,
                    fallbackKey: fallbackKey,
                    genericKey: genericKey,
                    stickyKey: stickyKey,
                    visiblePixelCount: rendered.visiblePixelCount,
                    storeAsGeneric: rendered.visiblePixelCount >= Self.minVisiblePixelsForGenericStore
                )
                result(rendered.data, nil)
            }
        }

        private func loadTileForSourceZ(
            requested: MKTileOverlayPath,
            sourceZ: Int,
            minSourceZ: Int,
            template: String,
            fallbackTemplate: String?,
            retriesLeft: Int,
            result: @escaping (Data?, Error?) -> Void
        ) {
            let specificKey = Self.tileCacheKey(template: template, requested: requested)
            let fallbackKey = Self.fallbackTileKey(template: template, requested: requested)
            let genericKey = Self.genericTileKey(template: template, requested: requested)
            let stickyKey = Self.stickyTileKey(template: template, requested: requested)
            let bypass = Self.shouldBypassClientRendering(template)
            let canReuseRenderedCache = !(bypass && sourceZ != requested.z)
            let resolveVisibleRenderedCache: (_ key: String, _ reason: String) -> (Data, String)? = { key, reason in
                guard let cached = Self.renderedTileCache.object(forKey: key as NSString) else {
                    return nil
                }
                let data = cached as Data
                guard bypass || Self.cachedTileHasVisiblePixels(key: key, data: data) else {
                    if Self.shouldSample(requested) {
                        print("☁️DBG fallback reject invisible", reason)
                    }
                    return nil
                }
                return (data, reason)
            }
            let isMediumZoom = requested.z >= 4 && requested.z <= 8
            let allowGenericFallback = !isMediumZoom && requested.z <= 8
            let allowStickyCompositeFallback = !isMediumZoom && requested.z <= 7
            let allowStickyFallback = !isMediumZoom && requested.z <= 7
            let resolveCachedFallback: () -> (Data, String)? = {
                if let resolved = resolveVisibleRenderedCache(fallbackKey, "current-fallback") {
                    return resolved
                }
                if allowGenericFallback,
                   let resolved = resolveVisibleRenderedCache(genericKey, "generic")
                {
                    return resolved
                }
                if let composite = self.childCompositeFallbackTile(
                    template: template,
                    requested: requested
                ) {
                    return (composite.data, "child-composite")
                }
                if allowStickyCompositeFallback,
                   let composite = self.childCompositeStickyFallbackTile(
                    template: template,
                    requested: requested
                   )
                {
                    return (composite.data, "sticky-child-composite")
                }
                if let parent = self.parentFallbackTile(
                    template: template,
                    requested: requested
                ) {
                    return (parent, "parent-fallback")
                }
                if let preview = self.globalPreviewFallbackTile(
                    template: template,
                    requested: requested
                ) {
                    return (preview, "global-preview")
                }
                if allowStickyFallback,
                   let sticky = Self.freshStickyTile(key: stickyKey)
                {
                    return (sticky, "sticky")
                }
                return nil
            }
            if canReuseRenderedCache,
               let cached = Self.renderedTileCache.object(forKey: specificKey as NSString)
            {
                let cachedData = cached as Data
                if bypass {
                    if Self.shouldSample(requested) {
                        print(
                            "☁️ tile cache-hit:",
                            Self.templateDebugToken(template),
                            "z=\(requested.z)",
                            "x=\(requested.x)",
                            "y=\(requested.y)",
                            "bypass=1"
                        )
                    }
                    result(cachedData, nil)
                    return
                }
                if Self.cachedTileHasVisiblePixels(key: specificKey, data: cachedData) {
                    if Self.shouldSample(requested) {
                        print(
                            "☁️ tile cache-hit:",
                            Self.templateDebugToken(template),
                            "z=\(requested.z)",
                            "x=\(requested.x)",
                            "y=\(requested.y)"
                        )
                    }
                    result(cachedData, nil)
                    return
                }
                // Cached tile exists but effectively empty: prefer visible fallback
                // to avoid blink holes during zoom/pan.
                if let (fallback, reason) = resolveCachedFallback() {
                    if Self.shouldSample(requested) {
                        print("☁️ tile fallback:", reason, "reason:empty-cache-hit")
                    }
                    result(fallback, nil)
                    return
                }
                // Empty cached tile must not be emitted, otherwise map briefly flashes blank.
                Self.renderedTileCache.removeObject(forKey: specificKey as NSString)
                Self.renderedVisiblePixelCache.removeObject(forKey: specificKey as NSString)
            }

            let zoomDelta = max(0, requested.z - sourceZ)
            let scale = 1 << zoomDelta
            let sourceN = 1 << sourceZ
            guard sourceN > 0 else {
                if let (cached, reason) = resolveCachedFallback() {
                    if Self.shouldSample(requested) {
                        print("☁️ tile fallback:", reason, "reason:invalid-sourceN")
                    }
                    result(cached, nil)
                } else {
                    result(Self.clearTilePNGData, nil)
                }
                return
            }
            let sourceX = ((requested.x / scale) % sourceN + sourceN) % sourceN
            let sourceY = requested.y / scale
            guard sourceY >= 0, sourceY < sourceN else {
                if let (cached, reason) = resolveCachedFallback() {
                    if Self.shouldSample(requested) {
                        print("☁️ tile fallback:", reason, "reason:out-of-range-y", "z=\(requested.z)", "x=\(requested.x)", "y=\(requested.y)")
                    }
                    result(cached, nil)
                } else {
                    result(Self.clearTilePNGData, nil)
                }
                return
            }

            // Hotfix: 2026-03-03 06:00 frame has recurring corrupted blocks around Birmingham
            // on multiple source zooms. Prefer stable lower source zoom in this bbox.
            if template.contains("/202603030600/"),
               sourceZ > 4,
               Self.isBirminghamBBox(sourceZ: sourceZ, sourceX: sourceX, sourceY: sourceY)
            {
                self.loadTileForSourceZ(
                    requested: requested,
                    sourceZ: sourceZ - 1,
                    minSourceZ: minSourceZ,
                    template: template,
                    fallbackTemplate: fallbackTemplate,
                    retriesLeft: retriesLeft,
                    result: result
                )
                return
            }

            fetchTile(
                template: template,
                z: sourceZ,
                x: sourceX,
                y: sourceY
            ) { data, statusCode, error in
                if statusCode != 200 || data == nil || data?.isEmpty == true {
                    // Retry once on transient network errors to reduce tile-edge holes.
                    if statusCode == -1, retriesLeft > 0 {
                        self.loadTileForSourceZ(
                            requested: requested,
                            sourceZ: sourceZ,
                            minSourceZ: minSourceZ,
                            template: template,
                            fallbackTemplate: fallbackTemplate,
                            retriesLeft: retriesLeft - 1,
                            result: result
                        )
                        return
                    }

                    // Avoid deep fallback cascades on generic backend errors/timeouts.
                    // Step down only for explicit not-found responses.
                    let canFallback = (statusCode == 404) && (sourceZ > minSourceZ)
                    if canFallback {
                        self.loadTileForSourceZ(
                            requested: requested,
                            sourceZ: sourceZ - 1,
                            minSourceZ: minSourceZ,
                            template: template,
                            fallbackTemplate: fallbackTemplate,
                            retriesLeft: retriesLeft,
                            result: result
                        )
                        return
                    }
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print(
                                "☁️ tile fallback:",
                                reason,
                                "reason:http-\(statusCode)",
                                "req-z=\(requested.z)",
                                "req-x=\(requested.x)",
                                "req-y=\(requested.y)",
                                "src-z=\(sourceZ)",
                                "src-x=\(sourceX)",
                                "src-y=\(sourceY)"
                            )
                        }
                        result(cached, nil)
                        return
                    }
                    result(Self.clearTilePNGData, nil)
                    return
                }

                guard let data else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:nil-data")
                        }
                        result(cached, nil)
                        return
                    }
                    result(Self.clearTilePNGData, nil)
                    return
                }

                if Self.shouldBypassClientRendering(template) {
                    if Self.shouldAvoidKnownStuckSourceTile(
                        template: template,
                        z: sourceZ,
                        x: sourceX,
                        y: sourceY,
                        data: data
                    ) {
                        if sourceZ > minSourceZ {
                            if Self.shouldSample(requested) {
                                print(
                                    "☁️ tile downgrade known-stuck-source",
                                    "req-z=\(requested.z)",
                                    "req-x=\(requested.x)",
                                    "req-y=\(requested.y)",
                                    "src-z=\(sourceZ)",
                                    "src-x=\(sourceX)",
                                    "src-y=\(sourceY)"
                                )
                            }
                            self.loadTileForSourceZ(
                                requested: requested,
                                sourceZ: sourceZ - 1,
                                minSourceZ: minSourceZ,
                                template: template,
                                fallbackTemplate: fallbackTemplate,
                                retriesLeft: retriesLeft,
                                result: result
                            )
                            return
                        }
                        result(Self.clearTilePNGData, nil)
                        return
                    }
                    if Self.isSuspiciousBypassSourceTile(data) {
                        if Self.shouldSample(requested) {
                            print("☁️ tile drop suspicious-source", "z=\(requested.z)", "x=\(requested.x)", "y=\(requested.y)", "bytes=\(data.count)")
                        }
                        result(Self.clearTilePNGData, nil)
                        return
                    }
                    if sourceZ == requested.z {
                        // Backend tiles are already styled; do not decode/re-encode or alpha-threshold.
                        // Treat as visible to avoid "empty tile" misclassification at low zoom.
                        Self.storeRenderedTile(
                            data,
                            specificKey: specificKey,
                            fallbackKey: fallbackKey,
                            genericKey: genericKey,
                            stickyKey: stickyKey,
                            visiblePixelCount: Self.minVisiblePixelsForGenericStore,
                            storeAsGeneric: true
                        )
                        result(data, nil)
                        return
                    }
                    let sourceImageKey = Self.sourceImageCacheKey(
                        template: template,
                        z: sourceZ,
                        x: sourceX,
                        y: sourceY
                    )
                    guard let sourceImage = Self.decodeSourceImage(
                        data,
                        cacheKey: sourceImageKey
                    ) else {
                        if let (cached, reason) = resolveCachedFallback() {
                            if Self.shouldSample(requested) {
                                print("☁️ tile fallback:", reason, "reason:decode-failed")
                            }
                            result(cached, nil)
                            return
                        }
                        result(Self.clearTilePNGData, nil)
                        return
                    }
                    let rendered = Self.cropAndScalePassthrough(
                        sourceImage: sourceImage,
                        requested: requested,
                        sourceZ: sourceZ,
                        targetSize: self.tileSize
                    )
                    guard let rendered else {
                        if let (cached, reason) = resolveCachedFallback() {
                            if Self.shouldSample(requested) {
                                print("☁️ tile fallback:", reason, "reason:render-nil")
                            }
                            result(cached, nil)
                            return
                        }
                        result(Self.clearTilePNGData, nil)
                        return
                    }
                    // For bypass templates, even a fully transparent tile is a valid/stable result.
                    // Mark it as visible so it can be reused as fallback and does not cause refetch churn.
                    // Do not cache overzoom-rendered bypass tiles. Keep source-tile cache only.
                    Self.logTileStats(rendered.data, label: "raw-crop", path: requested)
                    result(rendered.data, nil)
                    return
                }

                let sourceImageKey = Self.sourceImageCacheKey(
                    template: template,
                    z: sourceZ,
                    x: sourceX,
                    y: sourceY
                )
                guard let sourceImage = Self.decodeSourceImage(
                    data,
                    cacheKey: sourceImageKey
                ) else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:decode-failed")
                        }
                        result(cached, nil)
                        return
                    }
                    result(Self.clearTilePNGData, nil)
                    return
                }

                let preserveWeakSignal = requested.z <= 8 || sourceZ <= 6 || requested.z >= 9
                if sourceZ == requested.z {
                    let rendered: RenderedTile?
                    if preserveWeakSignal {
                        rendered = Self.renderPassthroughTile(
                            image: sourceImage,
                            targetSize: CGSize(
                                width: sourceImage.width,
                                height: sourceImage.height
                            ),
                            interpolation: .none
                        )
                    } else if Self.useRawRendering {
                        rendered = Self.renderRawTile(
                            image: sourceImage,
                            targetSize: CGSize(
                                width: sourceImage.width,
                                height: sourceImage.height
                            ),
                            interpolation: .none
                        )
                    } else {
                        rendered = Self.maskAndEncodeForecastTile(
                            image: sourceImage,
                            targetSize: CGSize(
                                width: sourceImage.width,
                                height: sourceImage.height
                            ),
                            interpolation: .none,
                            edgeSmoothingPasses: 0,
                            tileEdgeFeatherWidth: 0
                        )
                    }
                    guard let rendered else {
                        if let (cached, reason) = resolveCachedFallback() {
                            if Self.shouldSample(requested) {
                                print("☁️ tile fallback:", reason, "reason:render-nil")
                            }
                            result(cached, nil)
                            return
                        }
                        result(Self.clearTilePNGData, nil)
                        return
                    }

                    if rendered.visiblePixelCount < Self.minVisiblePixelsForGenericFallback {
                        self.resolveLowVisibleTile(
                            rendered: rendered,
                            requested: requested,
                            sourceZ: sourceZ,
                            sourceX: sourceX,
                            sourceY: sourceY,
                            template: template,
                            fallbackTemplate: fallbackTemplate,
                            specificKey: specificKey,
                            fallbackKey: fallbackKey,
                            genericKey: genericKey,
                            stickyKey: stickyKey,
                            resolveCachedFallback: resolveCachedFallback,
                            result: result
                        )
                        return
                    }

                    Self.storeRenderedTile(
                        rendered.data,
                        specificKey: specificKey,
                        fallbackKey: fallbackKey,
                        genericKey: genericKey,
                        stickyKey: stickyKey,
                        visiblePixelCount: rendered.visiblePixelCount,
                        storeAsGeneric: rendered.visiblePixelCount >= Self.minVisiblePixelsForGenericStore
                    )
                    if Self.shouldSample(requested) {
                        print(
                            "☁️ tile render:",
                            Self.templateDebugToken(template),
                            "z=\(requested.z)",
                            "x=\(requested.x)",
                            "y=\(requested.y)",
                            "visible=\(rendered.visiblePixelCount)"
                        )
                    }
                    result(rendered.data, nil)
                    return
                }

                let rendered: RenderedTile?
                if preserveWeakSignal {
                    rendered = Self.cropAndScalePassthrough(
                        sourceImage: sourceImage,
                        requested: requested,
                        sourceZ: sourceZ,
                        targetSize: self.tileSize
                    )
                } else if Self.useRawRendering {
                    rendered = Self.cropAndScaleRaw(
                        sourceImage: sourceImage,
                        requested: requested,
                        sourceZ: sourceZ,
                        targetSize: self.tileSize
                    )
                } else {
                    rendered = Self.cropAndScale(
                        sourceImage: sourceImage,
                        requested: requested,
                        sourceZ: sourceZ,
                        targetSize: self.tileSize
                    )
                }
                guard let rendered else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:crop-scale-nil")
                        }
                        result(cached, nil)
                        return
                    }
                    result(Self.clearTilePNGData, nil)
                    return
                }

                if rendered.visiblePixelCount < Self.minVisiblePixelsForGenericFallback {
                    self.resolveLowVisibleTile(
                        rendered: rendered,
                        requested: requested,
                        sourceZ: sourceZ,
                        sourceX: sourceX,
                        sourceY: sourceY,
                        template: template,
                        fallbackTemplate: fallbackTemplate,
                        specificKey: specificKey,
                        fallbackKey: fallbackKey,
                        genericKey: genericKey,
                        stickyKey: stickyKey,
                        resolveCachedFallback: resolveCachedFallback,
                        result: result
                    )
                    return
                }

                Self.storeRenderedTile(
                    rendered.data,
                    specificKey: specificKey,
                    fallbackKey: fallbackKey,
                    genericKey: genericKey,
                    stickyKey: stickyKey,
                    visiblePixelCount: rendered.visiblePixelCount,
                    storeAsGeneric: rendered.visiblePixelCount >= Self.minVisiblePixelsForGenericStore
                )
                if Self.shouldSample(requested) {
                    print(
                        "☁️ tile render-overzoom:",
                        Self.templateDebugToken(template),
                        "z=\(requested.z)",
                        "x=\(requested.x)",
                        "y=\(requested.y)",
                        "visible=\(rendered.visiblePixelCount)",
                        "srcZ=\(sourceZ)"
                    )
                }
                result(rendered.data, nil)
            }
        }

        private func resolveLowVisibleTile(
            rendered: RenderedTile,
            requested: MKTileOverlayPath,
            sourceZ: Int,
            sourceX: Int,
            sourceY: Int,
            template: String,
            fallbackTemplate: String?,
            specificKey: String,
            fallbackKey: String,
            genericKey: String,
            stickyKey: String,
            resolveCachedFallback: @escaping () -> (Data, String)?,
            result: @escaping (Data?, Error?) -> Void
        ) {
            _ = sourceZ
            _ = sourceX
            _ = sourceY
            _ = template
            _ = fallbackTemplate

            // Do not cache low-visible tiles into current fallback keys; this causes
            // persistent "holes" on overzoom when a sparse tile overwrites good cache.

            // Important: do not "hold" old cached tile for low-visible results.
            // Holding old content causes persistent frozen cloud fragments.

            if rendered.visiblePixelCount == 0 {
                if let (cached, reason) = resolveCachedFallback() {
                    if Self.shouldSample(requested) {
                        print("☁️ tile zero-visible: fallback \(reason)")
                    }
                    result(cached, nil)
                    return
                }
                if Self.shouldSample(requested) {
                    print("☁️ tile zero-visible: clear-current")
                }
                // Do not overwrite cache with transparent tile: it causes long "disappear"
                // periods on watch/iPhone until another successful tile arrives.
                result(Self.clearTilePNGData, nil)
                return
            }

            // Only now store the tile, when we decided it is acceptable to display.
            Self.storeRenderedTile(
                rendered.data,
                specificKey: specificKey,
                fallbackKey: fallbackKey,
                genericKey: genericKey,
                stickyKey: stickyKey,
                visiblePixelCount: rendered.visiblePixelCount,
                storeAsGeneric: false
            )

            if Self.shouldSample(requested) {
                print("☁️ tile keep current low-visible:", rendered.visiblePixelCount)
            }
            result(rendered.data, nil)
        }

        private func fetchTile(
            template: String,
            z: Int,
            x: Int,
            y: Int,
            completion: @escaping (Data?, Int, Error?) -> Void
        ) {
            guard let url = makeURL(template: template, z: z, x: x, y: y) else {
                completion(nil, -1, nil)
                return
            }
            Self.fetchSourceTile(
                url: url,
                timeout: 6,
                z: z,
                x: x,
                y: y,
                completion: completion
            )
        }

        private static func prewarmGlobalPreview(template: String) {
            guard let url = makeURLStatic(template: template, z: 0, x: 0, y: 0) else { return }
            fetchSourceTile(
                url: url,
                timeout: 8,
                z: 0,
                x: 0,
                y: 0
            ) { _, _, _ in }
        }

        private func globalPreviewFallbackTile(
            template: String,
            requested: MKTileOverlayPath
        ) -> Data? {
            guard let url = Self.makeURLStatic(template: template, z: 0, x: 0, y: 0) else {
                return nil
            }
            let sourceKey = url.absoluteString as NSString
            guard let source = Self.sourceTileCache.object(forKey: sourceKey) else {
                return nil
            }
            let sourceData = source as Data
            let sourceImageKey = Self.sourceImageCacheKey(template: template, z: 0, x: 0, y: 0)
            guard let sourceImage = Self.decodeSourceImage(sourceData, cacheKey: sourceImageKey) else {
                return nil
            }
            return Self.cropAndScalePassthrough(
                sourceImage: sourceImage,
                requested: requested,
                sourceZ: 0,
                targetSize: self.tileSize
            )?.data
        }

        private func parentFallbackTile(
            template: String,
            requested: MKTileOverlayPath,
            maxDepth: Int = 2
        ) -> Data? {
            guard requested.z > 0 else { return nil }
            for depth in 1...maxDepth {
                let parentZ = requested.z - depth
                if parentZ < 0 { break }
                let scale = 1 << depth
                let parentX = requested.x / scale
                let parentY = requested.y / scale

                if let url = Self.makeURLStatic(
                    template: template,
                    z: parentZ,
                    x: parentX,
                    y: parentY
                ) {
                    let key = url.absoluteString as NSString
                    if let cached = Self.sourceTileCache.object(forKey: key) {
                        let data = cached as Data
                        if let sourceImage = Self.decodeSourceImage(
                            data,
                            cacheKey: "\(key)|decoded"
                        ) {
                            if let rendered = Self.cropAndScalePassthrough(
                                sourceImage: sourceImage,
                                requested: requested,
                                sourceZ: parentZ,
                                targetSize: self.tileSize
                            ) {
                                return rendered.data
                            }
                        }
                    }
                }
            }
            return nil
        }

        private func childCompositeFallbackTile(
            template: String,
            requested: MKTileOverlayPath,
            maxDepth: Int = 2
        ) -> RenderedTile? {
            // Zoom-out fallback: synthesize a low-zoom tile from cached higher-zoom rendered children.
            // This avoids "blink holes" while waiting for network/source render on zoom-out.
            guard requested.z >= 0, requested.z < 19 else { return nil }

            let allowEmpty = Self.shouldBypassClientRendering(template)
            for depth in 1...maxDepth {
                let childZ = requested.z + depth
                if childZ > 20 { break }
                let scale = 1 << depth
                let childTileSide = 256 / scale
                if childTileSide <= 0 { break }

                // On zoom-out, require only one visible child tile to synthesize a parent fallback.
                // This avoids empty/flickering sectors when cloud coverage is sparse.
                let requiredChildren = 1
                var childImages: [(image: CGImage, dx: Int, dy: Int)] = []
                childImages.reserveCapacity(scale * scale)

                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let childPath = MKTileOverlayPath(
                            x: requested.x * scale + dx,
                            y: requested.y * scale + dy,
                            z: childZ,
                            contentScaleFactor: 1.0
                        )
                        let childKey = Self.tileCacheKey(template: template, requested: childPath)
                        guard let cached = Self.renderedTileCache.object(forKey: childKey as NSString) else {
                            continue
                        }
                        let data = cached as Data
                        guard allowEmpty || Self.cachedTileHasVisiblePixels(key: childKey, data: data) else {
                            continue
                        }
                        guard let image = Self.decodeImage(data) else { continue }
                        childImages.append((image: image, dx: dx, dy: dy))
                    }
                }

                guard childImages.count >= requiredChildren else { continue }

                let width = 256
                let height = 256
                let bitmapInfo =
                    CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                ) else {
                    return nil
                }

                context.interpolationQuality = .high
                context.setShouldAntialias(false)
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))

                for child in childImages {
                    let rect = CGRect(
                        x: child.dx * childTileSide,
                        y: child.dy * childTileSide,
                        width: childTileSide,
                        height: childTileSide
                    )
                    context.draw(child.image, in: rect)
                }

                guard let bytes = context.data else { return nil }
                let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
                let count = width * height
                var visible = 0
                // Fast-ish scan: stop once we know it's non-empty enough.
                for i in stride(from: 0, to: count, by: 29) {
                    if ptr[i * 4 + 3] >= 3 {
                        visible += 1
                        if visible >= Self.minVisiblePixelsForGenericStore { break }
                    }
                }
                guard visible >= Self.minVisiblePixelsForGenericFallback else { continue }
                guard let outputImage = context.makeImage() else { return nil }

                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                ) else {
                    return nil
                }
                CGImageDestinationAddImage(destination, outputImage, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }

                return RenderedTile(
                    data: output as Data,
                    visiblePixelCount: max(visible, Self.minVisiblePixelsForGenericStore)
                )
            }

            return nil
        }

        private func childCompositeStickyFallbackTile(
            template: String,
            requested: MKTileOverlayPath,
            maxDepth: Int = 2
        ) -> RenderedTile? {
            // Template-agnostic zoom-out hold:
            // if current template has no fallback chain yet, synthesize a parent
            // tile from recent sticky children at higher zoom.
            guard requested.z >= 0, requested.z < 19 else { return nil }

            for depth in 1...maxDepth {
                let childZ = requested.z + depth
                if childZ > 20 { break }
                let scale = 1 << depth
                let childTileSide = 256 / scale
                if childTileSide <= 0 { break }

                let requiredChildren = 1
                var childImages: [(image: CGImage, dx: Int, dy: Int)] = []
                childImages.reserveCapacity(scale * scale)

                for dy in 0..<scale {
                    for dx in 0..<scale {
                        let childPath = MKTileOverlayPath(
                            x: requested.x * scale + dx,
                            y: requested.y * scale + dy,
                            z: childZ,
                            contentScaleFactor: 1.0
                        )
                        let childStickyKey = Self.stickyTileKey(template: template, requested: childPath)
                        guard let data = Self.freshStickyTile(key: childStickyKey) else {
                            continue
                        }
                        guard let image = Self.decodeImage(data) else { continue }
                        childImages.append((image: image, dx: dx, dy: dy))
                    }
                }

                guard childImages.count >= requiredChildren else { continue }

                let width = 256
                let height = 256
                let bitmapInfo =
                    CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue
                guard let context = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                ) else {
                    return nil
                }

                context.interpolationQuality = .high
                context.setShouldAntialias(false)
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))

                for child in childImages {
                    let rect = CGRect(
                        x: child.dx * childTileSide,
                        y: child.dy * childTileSide,
                        width: childTileSide,
                        height: childTileSide
                    )
                    context.draw(child.image, in: rect)
                }

                guard let bytes = context.data else { return nil }
                let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
                let count = width * height
                var visible = 0
                for i in stride(from: 0, to: count, by: 29) {
                    if ptr[i * 4 + 3] >= 3 {
                        visible += 1
                        if visible >= Self.minVisiblePixelsForGenericStore { break }
                    }
                }
                guard visible >= Self.minVisiblePixelsForGenericFallback else { continue }
                guard let outputImage = context.makeImage() else { return nil }

                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output,
                    UTType.png.identifier as CFString,
                    1,
                    nil
                ) else {
                    return nil
                }
                CGImageDestinationAddImage(destination, outputImage, nil)
                guard CGImageDestinationFinalize(destination) else { return nil }

                return RenderedTile(
                    data: output as Data,
                    visiblePixelCount: max(visible, Self.minVisiblePixelsForGenericStore)
                )
            }

            return nil
        }

        private static func fetchSourceTile(
            url: URL,
            timeout: TimeInterval,
            z: Int,
            x: Int,
            y: Int,
            completion: @escaping SourceTileCompletion
        ) {
            let isForecastBackendTile = url.absoluteString.contains("/v1/tiles/")
            let sourceCacheKey = url.absoluteString as NSString
            if !isForecastBackendTile, let cached = sourceTileCache.object(forKey: sourceCacheKey) {
                if debugLoggingEnabled && ((x + y + z) & 31) == 0 {
                    print("☁️DBG source cache-hit z=\(z) x=\(x) y=\(y)")
                }
                completion(cached as Data, 200, nil)
                return
            }

            let requestKey = url.absoluteString
            var shouldStartRequest = false
            sourceFetchStateQueue.sync {
                if inFlightSourceRequests[requestKey] != nil {
                    inFlightSourceRequests[requestKey]?.append(completion)
                    if debugLoggingEnabled && ((x + y + z) & 31) == 0 {
                        print("☁️DBG source join in-flight z=\(z) x=\(x) y=\(y)")
                    }
                } else {
                    inFlightSourceRequests[requestKey] = [completion]
                    shouldStartRequest = true
                }
            }
            if !shouldStartRequest { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/png,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
            if isForecastBackendTile {
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("no-cache, no-store, must-revalidate", forHTTPHeaderField: "Cache-Control")
                request.setValue("no-cache", forHTTPHeaderField: "Pragma")
                request.setValue("0", forHTTPHeaderField: "Expires")
            }

            networkSession.dataTask(with: request) { data, response, error in
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if debugLoggingEnabled {
                    if statusCode != 200 {
                        print("☁️ forecast tile z=\(z) x=\(x) y=\(y) status=\(statusCode) bytes=\(data?.count ?? 0)")
                    } else if ((x + y + z) & 31) == 0 {
                        print("☁️ forecast tile 200 z=\(z) x=\(x) y=\(y) bytes=\(data?.count ?? 0)")
                    }
                }
                if !isForecastBackendTile, statusCode == 200, let data, !data.isEmpty {
                    sourceTileCache.setObject(
                        data as NSData,
                        forKey: sourceCacheKey,
                        cost: data.count
                    )
                }
                let callbacks: [SourceTileCompletion] = sourceFetchStateQueue.sync {
                    let pending = inFlightSourceRequests[requestKey] ?? []
                    inFlightSourceRequests.removeValue(forKey: requestKey)
                    return pending
                }
                for callback in callbacks {
                    callback(data, statusCode, error)
                }
            }.resume()
        }

        static func flushSourceCaches() {
            sourceTileCache.removeAllObjects()
            decodedSourceImageCache.removeAllObjects()
            sourceTileSignalCache.removeAllObjects()
            sourceFetchStateQueue.sync {
                inFlightSourceRequests.removeAll(keepingCapacity: false)
            }
        }

        private func makeURL(
            template: String,
            z: Int,
            x: Int,
            y: Int
        ) -> URL? {
            Self.makeURLStatic(template: template, z: z, x: x, y: y)
        }

        private static func makeURLStatic(
            template: String,
            z: Int,
            x: Int,
            y: Int
        ) -> URL? {
            let normalizedTemplate = template
                .replacingOccurrences(of: "%7Bz%7D", with: "{z}", options: .caseInsensitive)
                .replacingOccurrences(of: "%7Bx%7D", with: "{x}", options: .caseInsensitive)
                .replacingOccurrences(of: "%7By%7D", with: "{y}", options: .caseInsensitive)

            let urlString = normalizedTemplate
                .replacingOccurrences(of: "{z}", with: "\(z)")
                .replacingOccurrences(of: "{x}", with: "\(x)")
                .replacingOccurrences(of: "{y}", with: "\(y)")
            return URL(string: urlString)
        }

        static func estimateMotionPixels(
            fromTemplate: String,
            toTemplate: String,
            zoom: Int,
            tiles: [UIKitMap.VisibleTile]
        ) -> CGPoint? {
            guard fromTemplate != toTemplate else { return .zero }
            guard zoom >= 0, !tiles.isEmpty else { return nil }

            let sampledTiles = sampleTiles(tiles, limit: 28)
            var fromCentroid = WeightedCentroid()
            var toCentroid = WeightedCentroid()

            for tile in sampledTiles {
                let path = MKTileOverlayPath(
                    x: tile.x,
                    y: tile.y,
                    z: zoom,
                    contentScaleFactor: 1.0
                )

                if let rendered = renderedTileCache.object(
                    forKey: tileCacheKey(
                        template: fromTemplate,
                        requested: path
                    ) as NSString
                ) {
                    accumulateCentroid(
                        data: rendered as Data,
                        tile: tile,
                        treatAsSourceTile: false,
                        into: &fromCentroid
                    )
                } else if let source = sourceTileData(
                    template: fromTemplate,
                    z: zoom,
                    x: tile.x,
                    y: tile.y
                ) {
                    accumulateCentroid(
                        data: source,
                        tile: tile,
                        treatAsSourceTile: true,
                        into: &fromCentroid
                    )
                }

                if let rendered = renderedTileCache.object(
                    forKey: tileCacheKey(
                        template: toTemplate,
                        requested: path
                    ) as NSString
                ) {
                    accumulateCentroid(
                        data: rendered as Data,
                        tile: tile,
                        treatAsSourceTile: false,
                        into: &toCentroid
                    )
                } else if let source = sourceTileData(
                    template: toTemplate,
                    z: zoom,
                    x: tile.x,
                    y: tile.y
                ) {
                    accumulateCentroid(
                        data: source,
                        tile: tile,
                        treatAsSourceTile: true,
                        into: &toCentroid
                    )
                }
            }

            guard fromCentroid.mass > 14, toCentroid.mass > 14 else {
                return nil
            }

            let fromX = fromCentroid.sumX / fromCentroid.mass
            let fromY = fromCentroid.sumY / fromCentroid.mass
            let toX = toCentroid.sumX / toCentroid.mass
            let toY = toCentroid.sumY / toCentroid.mass
            let rawDx = toX - fromX
            let rawDy = toY - fromY

            let dx = max(-220.0, min(220.0, rawDx))
            let dy = max(-220.0, min(220.0, rawDy))
            if abs(dx) + abs(dy) < 2.0 {
                return .zero
            }
            return CGPoint(x: dx, y: dy)
        }

        private struct WeightedCentroid {
            var sumX: Double = 0
            var sumY: Double = 0
            var mass: Double = 0
        }

        private static func sampleTiles(
            _ tiles: [UIKitMap.VisibleTile],
            limit: Int
        ) -> [UIKitMap.VisibleTile] {
            guard tiles.count > limit else { return tiles }
            let stride = max(1, tiles.count / limit)
            var sampled: [UIKitMap.VisibleTile] = []
            sampled.reserveCapacity(limit)
            for idx in Swift.stride(from: 0, to: tiles.count, by: stride) {
                sampled.append(tiles[idx])
                if sampled.count >= limit { break }
            }
            return sampled
        }

        private static func sourceTileData(
            template: String,
            z: Int,
            x: Int,
            y: Int
        ) -> Data? {
            guard let url = makeURLStatic(template: template, z: z, x: x, y: y) else {
                return nil
            }
            let key = url.absoluteString as NSString
            guard let cached = sourceTileCache.object(forKey: key) else { return nil }
            return cached as Data
        }

        private static func accumulateCentroid(
            data: Data,
            tile: UIKitMap.VisibleTile,
            treatAsSourceTile: Bool,
            into centroid: inout WeightedCentroid
        ) {
            guard let image = decodeImage(data) else { return }
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return }

            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return
            }

            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let bytes = context.data else { return }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)

            let step = max(3, min(width, height) / 36)
            let scaleX = 256.0 / Double(width)
            let scaleY = 256.0 / Double(height)
            let tileBaseX = Double(tile.x * 256)
            let tileBaseY = Double(tile.y * 256)

            for y in Swift.stride(from: 0, to: height, by: step) {
                for x in Swift.stride(from: 0, to: width, by: step) {
                    let idx = (y * width + x) * 4
                    let alpha = Int(ptr[idx + 3])
                    if alpha < 3 { continue }

                    let weight: Double
                    if treatAsSourceTile {
                        let r = Double(ptr[idx])
                        let g = Double(ptr[idx + 1])
                        let b = Double(ptr[idx + 2])
                        if r <= 8.0 && g <= 8.0 && b <= 8.0 {
                            continue
                        }
                        let unpremulScale = 255.0 / max(1.0, Double(alpha))
                        let ur = min(255.0, r * unpremulScale)
                        let ug = min(255.0, g * unpremulScale)
                        let ub = min(255.0, b * unpremulScale)
                        let brightness = max(ur, max(ug, ub)) / 255.0
                        weight = max(0.05, (Double(alpha) / 255.0) * brightness)
                    } else {
                        weight = Double(alpha) / 255.0
                    }

                    let gx = tileBaseX + (Double(x) + 0.5) * scaleX
                    let gy = tileBaseY + (Double(y) + 0.5) * scaleY
                    centroid.sumX += gx * weight
                    centroid.sumY += gy * weight
                    centroid.mass += weight
                }
            }
        }

        private static func tileCacheKey(
            template: String,
            requested: MKTileOverlayPath
        ) -> String {
            "\(cacheVersion)|\(template)|\(requested.z)|\(requested.x)|\(requested.y)"
        }

        private static func fallbackTileKey(
            template: String,
            requested: MKTileOverlayPath
        ) -> String {
            "\(cacheVersion)|\(template)|fallback|\(requested.z)|\(requested.x)|\(requested.y)"
        }

        private static func genericTileKey(
            template: String,
            requested: MKTileOverlayPath
        ) -> String {
            "\(cacheVersion)|g\(currentFallbackGeneration())|\(template)|generic|\(requested.z)|\(requested.x)|\(requested.y)"
        }

        private static func stickyTileKey(
            template: String,
            requested: MKTileOverlayPath
        ) -> String {
            "\(cacheVersion)|g\(currentFallbackGeneration())|\(template)|sticky|\(requested.z)|\(requested.x)|\(requested.y)"
        }

        private static func currentFallbackGeneration() -> Int {
            stickyStateQueue.sync { fallbackGeneration }
        }

        private static func bumpFallbackGeneration() {
            stickyStateQueue.sync(flags: .barrier) {
                fallbackGeneration &+= 1
                stickyTileUpdatedAt.removeAll(keepingCapacity: true)
            }
            stickyTileCache.removeAllObjects()
        }

        private static func storeRenderedTile(
            _ data: Data,
            specificKey: String,
            fallbackKey: String,
            genericKey: String,
            stickyKey: String,
            visiblePixelCount: Int,
            storeAsGeneric: Bool
        ) {
            let boxed = data as NSData
            renderedTileCache.setObject(
                boxed,
                forKey: specificKey as NSString,
                cost: data.count
            )
            renderedVisiblePixelCache.setObject(
                NSNumber(value: visiblePixelCount),
                forKey: specificKey as NSString
            )
            renderedTileCache.setObject(
                boxed,
                forKey: fallbackKey as NSString,
                cost: data.count
            )
            renderedVisiblePixelCache.setObject(
                NSNumber(value: visiblePixelCount),
                forKey: fallbackKey as NSString
            )
            if storeAsGeneric {
                renderedTileCache.setObject(
                    boxed,
                    forKey: genericKey as NSString,
                    cost: data.count
                )
                renderedVisiblePixelCache.setObject(
                    NSNumber(value: visiblePixelCount),
                    forKey: genericKey as NSString
                )
            }

            guard visiblePixelCount >= minVisiblePixelsForGenericFallback else { return }
            stickyTileCache.setObject(
                boxed,
                forKey: stickyKey as NSString,
                cost: data.count
            )
            let now = Date().timeIntervalSince1970
            stickyStateQueue.sync(flags: .barrier) {
                stickyTileUpdatedAt[stickyKey] = now
                if stickyTileUpdatedAt.count > 2600 {
                    let cutoff = now - stickyTileMaxAge * 1.7
                    stickyTileUpdatedAt = stickyTileUpdatedAt.filter { $0.value >= cutoff }
                }
            }
        }

        private static func freshStickyTile(
            key: String
        ) -> Data? {
            guard let cached = stickyTileCache.object(forKey: key as NSString) else {
                return nil
            }
            let now = Date().timeIntervalSince1970
            let isFresh = stickyStateQueue.sync {
                guard let updatedAt = stickyTileUpdatedAt[key] else { return false }
                return now - updatedAt <= stickyTileMaxAge
            }
            guard isFresh else {
                stickyTileCache.removeObject(forKey: key as NSString)
                _ = stickyStateQueue.sync(flags: .barrier) {
                    stickyTileUpdatedAt.removeValue(forKey: key)
                }
                return nil
            }
            return cached as Data
        }

        private static func cachedTileHasVisiblePixels(
            key: String,
            data: Data
        ) -> Bool {
            if let cached = renderedVisiblePixelCache.object(forKey: key as NSString) {
                return cached.intValue >= minVisiblePixelsForGenericFallback
            }

            let visible = countVisiblePixels(in: data)
            renderedVisiblePixelCache.setObject(
                NSNumber(value: visible),
                forKey: key as NSString
            )
            return visible >= minVisiblePixelsForGenericFallback
        }

        private static func cachedSourceTileHasSignal(
            key: String,
            data: Data,
            scale: Int,
            xOffset: Int,
            yOffset: Int
        ) -> Bool {
            if let cached = sourceTileSignalCache.object(forKey: key as NSString) {
                return cached.boolValue
            }

            let hasSignal = countSourceSignalPixels(
                in: data,
                scale: scale,
                xOffset: xOffset,
                yOffset: yOffset
            ) >= 4
            sourceTileSignalCache.setObject(
                NSNumber(value: hasSignal),
                forKey: key as NSString
            )
            return hasSignal
        }

        private static func countSourceSignalPixels(
            in data: Data,
            scale: Int,
            xOffset: Int,
            yOffset: Int
        ) -> Int {
            guard let image = decodeImage(data) else { return 0 }
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return 0 }

            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return 0
            }

            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let bytes = context.data else { return 0 }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)

            let regionX0: Int
            let regionY0: Int
            let regionX1: Int
            let regionY1: Int
            if scale > 1 {
                let x0 = Int(floor(Double(xOffset) * Double(width) / Double(scale)))
                let y0 = Int(floor(Double(yOffset) * Double(height) / Double(scale)))
                let x1 = Int(floor(Double(xOffset + 1) * Double(width) / Double(scale)))
                let y1 = Int(floor(Double(yOffset + 1) * Double(height) / Double(scale)))
                regionX0 = max(0, min(width - 1, x0))
                regionY0 = max(0, min(height - 1, y0))
                regionX1 = max(regionX0 + 1, min(width, x1))
                regionY1 = max(regionY0 + 1, min(height, y1))
            } else {
                regionX0 = 0
                regionY0 = 0
                regionX1 = width
                regionY1 = height
            }

            let regionWidth = max(1, regionX1 - regionX0)
            let regionHeight = max(1, regionY1 - regionY0)
            let step = max(1, min(regionWidth, regionHeight) / 18)
            var hits = 0
            for y in stride(from: regionY0, to: regionY1, by: step) {
                for x in stride(from: regionX0, to: regionX1, by: step) {
                    let idx = (y * width + x) * 4
                    let alpha = Int(ptr[idx + 3])
                    if alpha < 4 { continue }

                    let unpremulScale = 255.0 / max(1.0, Double(alpha))
                    let r = min(255.0, Double(ptr[idx]) * unpremulScale)
                    let g = min(255.0, Double(ptr[idx + 1]) * unpremulScale)
                    let b = min(255.0, Double(ptr[idx + 2]) * unpremulScale)

                    if r <= 8.0 && g <= 8.0 && b <= 8.0 { continue }
                    let brightness = max(r, max(g, b))
                    if brightness < 26.0 { continue }

                    hits += 1
                    if hits >= 4 { return hits }
                }
            }
            return hits
        }

        private static func countVisiblePixels(in data: Data) -> Int {
            guard let image = decodeImage(data) else { return 0 }
            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else { return 0 }

            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return 0
            }

            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let bytes = context.data else { return 0 }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)

            let step = max(1, min(width, height) / 24)
            var visible = 0
            for y in stride(from: 0, to: height, by: step) {
                for x in stride(from: 0, to: width, by: step) {
                    let idx = (y * width + x) * 4
                    if ptr[idx + 3] >= 3 {
                        visible += 1
                        if visible >= minVisiblePixelsForGenericFallback { return visible }
                    }
                }
            }
            return visible
        }

        private static func decodeImage(_ data: Data) -> CGImage? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        private static func logTileStats(
            _ data: Data,
            label: String,
            path: MKTileOverlayPath
        ) {
            guard shouldSampleStats(path) else { return }
            guard let image = decodeImage(data) else {
                print("☁️DBG tile stats decode-failed", label, "z=\(path.z)", "x=\(path.x)", "y=\(path.y)")
                return
            }
            guard
                let context = CGContext(
                    data: nil,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                        CGBitmapInfo.byteOrder32Big.rawValue
                )
            else {
                return
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let bytes = context.data else { return }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
            let count = image.width * image.height
            var minA: UInt8 = 255
            var maxA: UInt8 = 0
            var sumA: Double = 0
            var minR: UInt8 = 255
            var maxR: UInt8 = 0
            var minG: UInt8 = 255
            var maxG: UInt8 = 0
            var minB: UInt8 = 255
            var maxB: UInt8 = 0
            var nonzero = 0
            for i in 0..<count {
                let idx = i * 4
                let r = ptr[idx]
                let g = ptr[idx + 1]
                let b = ptr[idx + 2]
                let a = ptr[idx + 3]
                if a > 0 { nonzero += 1 }
                minA = min(minA, a)
                maxA = max(maxA, a)
                sumA += Double(a)
                minR = min(minR, r); maxR = max(maxR, r)
                minG = min(minG, g); maxG = max(maxG, g)
                minB = min(minB, b); maxB = max(maxB, b)
            }
            let meanA = sumA / Double(count)
            print(
                "☁️DBG tile stats",
                label,
                "z=\(path.z)",
                "x=\(path.x)",
                "y=\(path.y)",
                "a[min,max,mean]=\(minA),\(maxA),\(String(format: "%.1f", meanA))",
                "rgb[min]=\(minR),\(minG),\(minB)",
                "rgb[max]=\(maxR),\(maxG),\(maxB)",
                "nz=\(nonzero)"
            )
        }

        private static func sourceImageCacheKey(
            template: String,
            z: Int,
            x: Int,
            y: Int
        ) -> String {
            if let url = makeURLStatic(template: template, z: z, x: x, y: y) {
                return "\(cacheVersion)|source-image|\(url.absoluteString)"
            }
            return "\(cacheVersion)|source-image|\(template)|\(z)|\(x)|\(y)"
        }

        private static func isSuspiciousBypassSourceTile(_ data: Data) -> Bool {
            // Disabled for now: aggressive filtering can hide real rain over London.
            _ = data
            return false
        }

        private static func shouldAvoidKnownStuckSourceTile(
            template: String,
            z: Int,
            x: Int,
            y: Int,
            data: Data
        ) -> Bool {
            // Backend occasionally serves one stale static tile for this coordinate.
            // Match by coordinate + payload fingerprint to avoid dropping valid rain.
            if z == 7, x == 63, y == 42, data.count == 14_225 {
                return fnv1a64(data) == 0x0498_0ffe_80fd_d5ff
            }

            // March 3rd 06:00 frame occasionally contains a stuck/blocked patch near Birmingham
            // on source z=6 tiles. Keep this guard narrow by timestamp + tile neighborhood.
            if template.contains("/202603030600/"),
               z == 6,
               (30...32).contains(x),
               (20...22).contains(y)
            {
                return true
            }

            return false
        }

        private static func isBirminghamBBox(
            sourceZ: Int,
            sourceX: Int,
            sourceY: Int
        ) -> Bool {
            switch sourceZ {
            case 7:
                return (60...64).contains(sourceX) && (40...44).contains(sourceY)
            case 6:
                return (30...32).contains(sourceX) && (20...22).contains(sourceY)
            case 5:
                return (15...16).contains(sourceX) && (10...11).contains(sourceY)
            default:
                return false
            }
        }

        private static func fnv1a64(_ data: Data) -> UInt64 {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            return hash
        }

        private static func decodeSourceImage(
            _ data: Data,
            cacheKey: String
        ) -> CGImage? {
            if let cached = decodedSourceImageCache.object(forKey: cacheKey as NSString) {
                return cached.image
            }
            guard let decoded = decodeImage(data) else { return nil }
            decodedSourceImageCache.setObject(
                DecodedSourceImageBox(decoded),
                forKey: cacheKey as NSString,
                cost: data.count
            )
            return decoded
        }

        private static func cropAndScale(
            sourceImage: CGImage,
            requested: MKTileOverlayPath,
            sourceZ: Int,
            targetSize: CGSize
        ) -> RenderedTile? {
            let zoomDelta = requested.z - sourceZ
            guard zoomDelta > 0 else { return nil }

            let scale = 1 << zoomDelta
            let xOffset = requested.x % scale
            let yOffset = requested.y % scale

            let srcW = sourceImage.width
            let srcH = sourceImage.height

            let x0 = Int(floor(Double(xOffset) * Double(srcW) / Double(scale)))
            let y0 = Int(floor(Double(yOffset) * Double(srcH) / Double(scale)))
            let x1 = Int(floor(Double(xOffset + 1) * Double(srcW) / Double(scale)))
            let y1 = Int(floor(Double(yOffset + 1) * Double(srcH) / Double(scale)))

            let cropX = max(0, min(srcW - 1, x0))
            let cropY = max(0, min(srcH - 1, y0))
            let cropW = max(1, min(srcW - cropX, x1 - x0))
            let cropH = max(1, min(srcH - cropY, y1 - y0))

            let cropRect = CGRect(
                x: cropX,
                y: cropY,
                width: cropW,
                height: cropH
            )

            guard let cropped = sourceImage.cropping(to: cropRect) else { return nil }

            return maskAndEncodeForecastTile(
                image: cropped,
                targetSize: targetSize,
                interpolation: .high,
                edgeSmoothingPasses: 0,
                tileEdgeFeatherWidth: 0
            )
        }

        private static func cropAndScaleRaw(
            sourceImage: CGImage,
            requested: MKTileOverlayPath,
            sourceZ: Int,
            targetSize: CGSize
        ) -> RenderedTile? {
            let zoomDelta = requested.z - sourceZ
            guard zoomDelta > 0 else {
                return renderRawTile(
                    image: sourceImage,
                    targetSize: targetSize,
                    interpolation: .none
                )
            }

            let scale = 1 << zoomDelta
            let xOffset = requested.x % scale
            let yOffset = requested.y % scale

            let srcW = sourceImage.width
            let srcH = sourceImage.height

            let x0 = Int(floor(Double(xOffset) * Double(srcW) / Double(scale)))
            let y0 = Int(floor(Double(yOffset) * Double(srcH) / Double(scale)))
            let x1 = Int(floor(Double(xOffset + 1) * Double(srcW) / Double(scale)))
            let y1 = Int(floor(Double(yOffset + 1) * Double(srcH) / Double(scale)))

            let baseCropX = max(0, min(srcW - 1, x0))
            let baseCropY = max(0, min(srcH - 1, y0))
            let baseCropW = max(1, min(srcW - baseCropX, x1 - x0))
            let baseCropH = max(1, min(srcH - baseCropY, y1 - y0))

            let cropRect = stabilizedRawCropRect(
                srcW: srcW,
                srcH: srcH,
                cropX: baseCropX,
                cropY: baseCropY,
                cropW: baseCropW,
                cropH: baseCropH,
                zoomDelta: zoomDelta
            )

            guard let cropped = sourceImage.cropping(to: cropRect) else {
                return nil
            }
            let interpolation: CGInterpolationQuality = .high
            return renderRawTile(
                image: cropped,
                targetSize: targetSize,
                interpolation: interpolation
            )
        }

        private static func cropAndScalePassthrough(
            sourceImage: CGImage,
            requested: MKTileOverlayPath,
            sourceZ: Int,
            targetSize: CGSize
        ) -> RenderedTile? {
            let zoomDelta = requested.z - sourceZ
            guard zoomDelta > 0 else {
                return renderPassthroughTile(
                    image: sourceImage,
                    targetSize: targetSize,
                    interpolation: .none
                )
            }

            let scale = 1 << zoomDelta
            let xOffset = requested.x % scale
            let yOffset = requested.y % scale

            let srcW = sourceImage.width
            let srcH = sourceImage.height

            let x0 = Int(floor(Double(xOffset) * Double(srcW) / Double(scale)))
            let y0 = Int(floor(Double(yOffset) * Double(srcH) / Double(scale)))
            let x1 = Int(floor(Double(xOffset + 1) * Double(srcW) / Double(scale)))
            let y1 = Int(floor(Double(yOffset + 1) * Double(srcH) / Double(scale)))

            let baseCropX = max(0, min(srcW - 1, x0))
            let baseCropY = max(0, min(srcH - 1, y0))
            let baseCropW = max(1, min(srcW - baseCropX, x1 - x0))
            let baseCropH = max(1, min(srcH - baseCropY, y1 - y0))

            // Use stabilized crop for deep overzoom to avoid 1px "on/off" flicker.
            let cropRect = stabilizedRawCropRect(
                srcW: srcW,
                srcH: srcH,
                cropX: baseCropX,
                cropY: baseCropY,
                cropW: baseCropW,
                cropH: baseCropH,
                zoomDelta: zoomDelta
            )

            guard let cropped = sourceImage.cropping(to: cropRect) else {
                return nil
            }
            // Preserve weak/small precip fragments during overzoom.
            // Smoothing can dilute alpha and make tiny clouds disappear.
            let interpolation: CGInterpolationQuality = .none
            return renderPassthroughTile(
                image: cropped,
                targetSize: targetSize,
                interpolation: interpolation
            )
        }

        private static func stabilizedRawCropRect(
            srcW: Int,
            srcH: Int,
            cropX: Int,
            cropY: Int,
            cropW: Int,
            cropH: Int,
            zoomDelta: Int
        ) -> CGRect {
            // Deep overzoom (z12..z15 from z5 source) can map to 1-2 source pixels.
            // Expand sampling window a bit to reduce "tile present/absent" flicker.
            let minSample: Int
            switch zoomDelta {
            case ..<4:
                minSample = 1
            case 4:
                minSample = 2
            case 5:
                minSample = 3
            default:
                minSample = 4
            }

            let sampleW = min(srcW, max(cropW, minSample))
            let sampleH = min(srcH, max(cropH, minSample))

            if sampleW == cropW && sampleH == cropH {
                return CGRect(
                    x: cropX,
                    y: cropY,
                    width: cropW,
                    height: cropH
                )
            }

            let centerX = cropX + cropW / 2
            let centerY = cropY + cropH / 2
            var sampleX = centerX - sampleW / 2
            var sampleY = centerY - sampleH / 2
            sampleX = max(0, min(srcW - sampleW, sampleX))
            sampleY = max(0, min(srcH - sampleH, sampleY))

            return CGRect(
                x: sampleX,
                y: sampleY,
                width: sampleW,
                height: sampleH
            )
        }

        private static func renderRawTile(
            image: CGImage,
            targetSize: CGSize,
            interpolation: CGInterpolationQuality
        ) -> RenderedTile? {
            let width = Int(targetSize.width)
            let height = Int(targetSize.height)
            guard width > 0, height > 0 else { return nil }

            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.interpolationQuality = interpolation
            context.setShouldAntialias(true)
            context.clear(CGRect(origin: .zero, size: targetSize))
            context.draw(image, in: CGRect(origin: .zero, size: targetSize))

            guard let bytes = context.data else { return nil }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
            let count = width * height
            var visiblePixelCount = 0

            for i in 0..<count {
                let idx = i * 4
                let alpha = ptr[idx + 3]
                if alpha < 2 {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    continue
                }

                let unpremulScale = 255.0 / max(1.0, Double(alpha))
                let ur = min(255.0, Double(ptr[idx]) * unpremulScale)
                let ug = min(255.0, Double(ptr[idx + 1]) * unpremulScale)
                let ub = min(255.0, Double(ptr[idx + 2]) * unpremulScale)

                // Remove opaque background and dark seam pixels from provider tiles.
                let isNoRainBlack = ur <= 10.0 && ug <= 10.0 && ub <= 14.0
                let isDarkSeam = ur < 32.0 && ug < 40.0 && ub < 60.0
                if isNoRainBlack || isDarkSeam {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    continue
                }

                let sourceA = Double(alpha) / 255.0
                let warmScore = Self.clamp01(((ur - ub) * 0.95 + (ug - ub) * 0.35) / 255.0)
                let coldScore = Self.clamp01(((ub - ug) * 1.05 + (ub - ur) * 0.65) / 255.0)
                let density = Self.clamp01((sourceA - 0.06) / 0.90)
                let intensity = Self.clamp01(max(density * 0.86, density * 0.74 + warmScore * 0.26))
                let stormScore = Self.clamp01(
                    0.58 * Self.clamp01((sourceA - 0.83) / 0.17) +
                    0.42 * warmScore
                )

                let color = Self.precipitationPalette(
                    intensity: intensity,
                    stormScore: stormScore,
                    coldScore: coldScore,
                    sourceAlpha: sourceA
                )
                if color.alpha < 0.03 {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    continue
                }

                ptr[idx] = UInt8(max(0.0, min(255.0, color.red * color.alpha)).rounded())
                ptr[idx + 1] = UInt8(max(0.0, min(255.0, color.green * color.alpha)).rounded())
                ptr[idx + 2] = UInt8(max(0.0, min(255.0, color.blue * color.alpha)).rounded())
                ptr[idx + 3] = UInt8(max(0.0, min(255.0, 255.0 * color.alpha)).rounded())

                visiblePixelCount += 1
            }

            removeDarkEdgeHalos(
                ptr: ptr,
                width: width,
                height: height
            )
            visiblePixelCount = 0
            for i in 0..<count {
                if ptr[i * 4 + 3] >= 2 {
                    visiblePixelCount += 1
                }
            }

            guard let outputImage = context.makeImage() else { return nil }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, outputImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }

            return RenderedTile(
                data: output as Data,
                visiblePixelCount: visiblePixelCount
            )
        }

        private static func renderPassthroughTile(
            image: CGImage,
            targetSize: CGSize,
            interpolation: CGInterpolationQuality
        ) -> RenderedTile? {
            let width = Int(targetSize.width)
            let height = Int(targetSize.height)
            guard width > 0, height > 0 else { return nil }

            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.interpolationQuality = interpolation
            context.setShouldAntialias(false)
            context.clear(CGRect(origin: .zero, size: targetSize))
            context.draw(image, in: CGRect(origin: .zero, size: targetSize))

            guard let bytes = context.data else { return nil }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
            let count = width * height
            var visiblePixelCount = 0

            for i in 0..<count {
                let idx = i * 4
                let alpha = ptr[idx + 3]
                if alpha == 0 {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    continue
                }
                ptr[idx + 3] = alpha
                visiblePixelCount += 1
            }

            guard let outputImage = context.makeImage() else { return nil }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, outputImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }

            return RenderedTile(
                data: output as Data,
                visiblePixelCount: visiblePixelCount
            )
        }

        private static func removeDarkEdgeHalos(
            ptr: UnsafeMutablePointer<UInt8>,
            width: Int,
            height: Int
        ) {
            guard width > 2, height > 2 else { return }

            let count = width * height
            var alpha = Array(repeating: UInt8(0), count: count)
            for i in 0..<count {
                alpha[i] = ptr[i * 4 + 3]
            }

            var clearMask = Array(repeating: false, count: count)

            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    let a = alpha[i]
                    if a < 2 { continue }

                    let idx = i * 4
                    let unpremulScale = 255.0 / max(1.0, Double(a))
                    let ur = min(255.0, Double(ptr[idx]) * unpremulScale)
                    let ug = min(255.0, Double(ptr[idx + 1]) * unpremulScale)
                    let ub = min(255.0, Double(ptr[idx + 2]) * unpremulScale)
                    let looksLikeHalo = ur < 126.0 && ug < 168.0 && ub < 230.0
                    if !looksLikeHalo { continue }

                    var touchesTransparent = false
                    for ny in max(0, y - 1)...min(height - 1, y + 1) {
                        for nx in max(0, x - 1)...min(width - 1, x + 1) {
                            if alpha[ny * width + nx] < 2 {
                                touchesTransparent = true
                                break
                            }
                        }
                        if touchesTransparent { break }
                    }

                    if touchesTransparent {
                        clearMask[i] = true
                    }
                }
            }

            for i in 0..<count where clearMask[i] {
                let idx = i * 4
                ptr[idx] = 0
                ptr[idx + 1] = 0
                ptr[idx + 2] = 0
                ptr[idx + 3] = 0
            }
        }

        private static func maskAndEncodeForecastTile(
            image: CGImage,
            targetSize: CGSize,
            interpolation: CGInterpolationQuality,
            edgeSmoothingPasses: Int = 0,
            tileEdgeFeatherWidth: Int = 0
        ) -> RenderedTile? {
            let width = Int(targetSize.width)
            let height = Int(targetSize.height)
            guard width > 0, height > 0 else { return nil }

            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.interpolationQuality = interpolation
            context.setShouldAntialias(true)
            context.clear(CGRect(origin: .zero, size: targetSize))
            context.draw(image, in: CGRect(origin: .zero, size: targetSize))

            guard let bytes = context.data else { return nil }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
            let count = width * height
            var visiblePixelCount = 0
            var nonTransparentSourcePixels = 0

            for i in 0..<count {
                let idx = i * 4
                let alpha = ptr[idx + 3]
                if alpha == 0 { continue }
                nonTransparentSourcePixels += 1

                let sourceR = Double(ptr[idx])
                let sourceG = Double(ptr[idx + 1])
                let sourceB = Double(ptr[idx + 2])
                let unpremulScale = 255.0 / max(1.0, Double(alpha))
                let ur = min(255.0, sourceR * unpremulScale)
                let ug = min(255.0, sourceG * unpremulScale)
                let ub = min(255.0, sourceB * unpremulScale)

                // Drop near-black/neutral backdrop fragments that create dark seams.
                let isNoRainBlack = ur <= 10.0 && ug <= 10.0 && ub <= 12.0
                let isDarkSeam = ur < 32.0 && ug < 40.0 && ub < 60.0
                if isNoRainBlack || isDarkSeam {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    continue
                }

                visiblePixelCount += 1

                let sourceA = Double(alpha) / 255.0
                let luminance = (0.299 * ur + 0.587 * ug + 0.114 * ub) / 255.0
                let warmScore = Self.clamp01(((ur - ub) * 0.95 + (ug - ub) * 0.35) / 255.0)
                let coldScore = Self.clamp01(((ub - ug) * 1.05 + (ub - ur) * 0.65) / 255.0)
                let intensity = Self.clamp01(
                    max(
                        (1.0 - luminance - 0.18) / 0.62,
                        (sourceA - 0.08) / 0.86
                    )
                )
                let stormScore = Self.clamp01(
                    0.56 * Self.clamp01((intensity - 0.72) / 0.28) +
                    0.44 * warmScore
                )
                let color = Self.precipitationPalette(
                    intensity: intensity,
                    stormScore: stormScore,
                    coldScore: coldScore,
                    sourceAlpha: sourceA
                )
                if color.alpha < 0.03 {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    visiblePixelCount -= 1
                    continue
                }

                ptr[idx] = UInt8(max(0.0, min(255.0, color.red * color.alpha)).rounded())
                ptr[idx + 1] = UInt8(max(0.0, min(255.0, color.green * color.alpha)).rounded())
                ptr[idx + 2] = UInt8(max(0.0, min(255.0, color.blue * color.alpha)).rounded())
                ptr[idx + 3] = UInt8(max(0.0, min(255.0, 255.0 * color.alpha)).rounded())
            }

            // If processing removed all visible pixels while source had alpha,
            // return a direct (very light) source pass-through to avoid "disappearing clouds".
            if visiblePixelCount == 0 && nonTransparentSourcePixels > 0 {
                context.clear(CGRect(origin: .zero, size: targetSize))
                context.draw(image, in: CGRect(origin: .zero, size: targetSize))
                guard let rawBytes = context.data else { return nil }
                let rawPtr = rawBytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
                for i in 0..<count {
                    let idx = i * 4
                    let a = rawPtr[idx + 3]
                    if a == 0 { continue }
                    let r = Double(rawPtr[idx])
                    let g = Double(rawPtr[idx + 1])
                    let b = Double(rawPtr[idx + 2])
                    let unpremulScale = 255.0 / max(1.0, Double(a))
                    let ur = min(255.0, r * unpremulScale)
                    let ug = min(255.0, g * unpremulScale)
                    let ub = min(255.0, b * unpremulScale)
                    let isNoRainBlack = ur <= 10.0 && ug <= 10.0 && ub <= 12.0
                    let isDarkSeam = ur < 32.0 && ug < 40.0 && ub < 60.0
                    if isNoRainBlack || isDarkSeam {
                        rawPtr[idx] = 0
                        rawPtr[idx + 1] = 0
                        rawPtr[idx + 2] = 0
                        rawPtr[idx + 3] = 0
                        continue
                    }
                    let sourceA = Double(a) / 255.0
                    let warmScore = Self.clamp01(((ur - ub) * 0.95 + (ug - ub) * 0.35) / 255.0)
                    let coldScore = Self.clamp01(((ub - ug) * 1.05 + (ub - ur) * 0.65) / 255.0)
                    let intensity = Self.clamp01((sourceA - 0.05) / 0.90)
                    let stormScore = Self.clamp01(
                        0.58 * Self.clamp01((sourceA - 0.83) / 0.17) +
                        0.42 * warmScore
                    )
                    let color = Self.precipitationPalette(
                        intensity: intensity,
                        stormScore: stormScore,
                        coldScore: coldScore,
                        sourceAlpha: min(sourceA, 0.42)
                    )
                    if color.alpha < 0.03 {
                        rawPtr[idx] = 0
                        rawPtr[idx + 1] = 0
                        rawPtr[idx + 2] = 0
                        rawPtr[idx + 3] = 0
                        continue
                    }
                    rawPtr[idx] = UInt8(max(0.0, min(255.0, color.red * color.alpha)).rounded())
                    rawPtr[idx + 1] = UInt8(max(0.0, min(255.0, color.green * color.alpha)).rounded())
                    rawPtr[idx + 2] = UInt8(max(0.0, min(255.0, color.blue * color.alpha)).rounded())
                    rawPtr[idx + 3] = UInt8(max(0.0, min(255.0, 255.0 * color.alpha)).rounded())
                    visiblePixelCount += 1
                }
            }

            if visiblePixelCount > 0 && (edgeSmoothingPasses > 0 || tileEdgeFeatherWidth > 0) {
                softenPrecipitationEdges(
                    ptr: ptr,
                    width: width,
                    height: height,
                    passes: edgeSmoothingPasses,
                    tileEdgeFeatherWidth: tileEdgeFeatherWidth
                )
            }

            guard let outputImage = context.makeImage() else { return nil }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, outputImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return RenderedTile(
                data: output as Data,
                visiblePixelCount: visiblePixelCount
            )
        }

        private static func softenPrecipitationEdges(
            ptr: UnsafeMutablePointer<UInt8>,
            width: Int,
            height: Int,
            passes: Int,
            tileEdgeFeatherWidth: Int
        ) {
            guard width > 2, height > 2 else { return }
            let count = width * height * 4
            var src = Array(UnsafeBufferPointer(start: ptr, count: count))
            var dst = src

            let kernel = [
                1, 4, 6, 4, 1,
                4, 16, 24, 16, 4,
                6, 24, 36, 24, 6,
                4, 16, 24, 16, 4,
                1, 4, 6, 4, 1
            ]
            let kSum = 256.0
            let passCount = max(1, passes)

            // Multiple short passes produce rounded contours without blurring interiors too much.
            for _ in 0..<passCount {
                dst = src

                for y in 0..<height {
                    for x in 0..<width {
                        let idx = (y * width + x) * 4
                        let currentA = Int(src[idx + 3])

                        var hasZero = false
                        var hasSolid = false
                        var accA = 0.0
                        var accUR = 0.0
                        var accUG = 0.0
                        var accUB = 0.0
                        var colorW = 0.0
                        var k = 0

                        for oy in -2...2 {
                            for ox in -2...2 {
                                let nx = max(0, min(width - 1, x + ox))
                                let ny = max(0, min(height - 1, y + oy))
                                let nIdx = (ny * width + nx) * 4
                                let w = Double(kernel[k])
                                k += 1

                                let na = Int(src[nIdx + 3])
                                if na == 0 {
                                    hasZero = true
                                } else {
                                    hasSolid = true
                                }
                                accA += Double(na) * w

                                guard na > 0 else { continue }
                                // Convert neighboring premultiplied color back to straight color.
                                let unpremulScale = 255.0 / max(1.0, Double(na))
                                let ur = min(255.0, Double(src[nIdx]) * unpremulScale)
                                let ug = min(255.0, Double(src[nIdx + 1]) * unpremulScale)
                                let ub = min(255.0, Double(src[nIdx + 2]) * unpremulScale)
                                accUR += ur * w
                                accUG += ug * w
                                accUB += ub * w
                                colorW += w
                            }
                        }

                        // Process only edge transition zones; keep interiors crisp.
                        guard hasZero && hasSolid else { continue }

                        let smoothedA = Int((accA / kSum).rounded())
                        let boostedA = max(currentA, Int((Double(smoothedA) * 1.10).rounded()))
                        let outA = max(0, min(255, boostedA))
                        guard outA > 1, colorW > 0 else {
                            dst[idx] = 0
                            dst[idx + 1] = 0
                            dst[idx + 2] = 0
                            dst[idx + 3] = 0
                            continue
                        }

                        let ur = accUR / colorW
                        let ug = accUG / colorW
                        let ub = accUB / colorW
                        let aScale = Double(outA) / 255.0

                        dst[idx] = UInt8(max(0.0, min(255.0, (ur * aScale).rounded())))
                        dst[idx + 1] = UInt8(max(0.0, min(255.0, (ug * aScale).rounded())))
                        dst[idx + 2] = UInt8(max(0.0, min(255.0, (ub * aScale).rounded())))
                        dst[idx + 3] = UInt8(outA)
                    }
                }

                src = dst
            }

            sealTileBorders(
                ptr: &src,
                width: width,
                height: height,
                featherWidth: tileEdgeFeatherWidth
            )

            for i in 0..<count {
                ptr[i] = src[i]
            }
        }

        private static func sealTileBorders(
            ptr: inout [UInt8],
            width: Int,
            height: Int,
            featherWidth: Int
        ) {
            guard width > 2, height > 2 else { return }
            let edge = max(0, featherWidth)
            guard edge > 0 else { return }

            for y in 0..<height {
                for x in 0..<width {
                    let borderDistance = min(
                        min(x, width - 1 - x),
                        min(y, height - 1 - y)
                    )
                    if borderDistance >= edge { continue }

                    let idx = (y * width + x) * 4
                    let alpha = Int(ptr[idx + 3])
                    guard alpha > 0 else { continue }

                    let t = Double(borderDistance + 1) / Double(edge + 1)
                    let eased = t * t * (3.0 - 2.0 * t)
                    let factor = 0.64 + 0.36 * eased
                    let outA = max(0, min(255, Int((Double(alpha) * factor).rounded())))

                    if outA < 2 {
                        ptr[idx] = 0
                        ptr[idx + 1] = 0
                        ptr[idx + 2] = 0
                        ptr[idx + 3] = 0
                        continue
                    }

                    let scale = Double(outA) / Double(alpha)
                    ptr[idx] = UInt8(max(0, min(255, Int((Double(ptr[idx]) * scale).rounded()))))
                    ptr[idx + 1] = UInt8(max(0, min(255, Int((Double(ptr[idx + 1]) * scale).rounded()))))
                    ptr[idx + 2] = UInt8(max(0, min(255, Int((Double(ptr[idx + 2]) * scale).rounded()))))
                    ptr[idx + 3] = UInt8(outA)
                }
            }
        }

        private static func clamp01(_ value: Double) -> Double {
            max(0.0, min(1.0, value))
        }

        private static func precipitationPalette(
            intensity: Double,
            stormScore: Double,
            coldScore: Double,
            sourceAlpha: Double
        ) -> (red: Double, green: Double, blue: Double, alpha: Double) {
            let rain = clamp01(intensity)
            let storm = clamp01(stormScore)
            let cold = clamp01(coldScore)
            let snow = clamp01(cold * (1.0 - storm * 0.90))

            var red = lerp(170.0, 24.0, rain)
            var green = lerp(222.0, 56.0, rain)
            var blue = lerp(255.0, 138.0, rain)
            var alpha = 0.18 + 0.66 * rain

            if snow > 0.08 {
                let snowMix = 0.42 + 0.42 * snow
                let snowRed = lerp(255.0, 232.0, rain)
                let snowGreen = lerp(255.0, 238.0, rain)
                let snowBlue = lerp(255.0, 246.0, rain)
                red = mix(red, snowRed, snowMix)
                green = mix(green, snowGreen, snowMix)
                blue = mix(blue, snowBlue, snowMix)
                alpha = max(alpha * 0.84, 0.20 + rain * 0.48)
            }

            if storm > 0.04 {
                let s = clamp01(storm * 1.20)
                red = mix(red, 4.0, s)
                green = mix(green, 4.0, s)
                blue = mix(blue, 8.0, s)
                alpha = max(alpha, 0.44 + 0.48 * s)
            }

            return (red, green, blue, clamp01(alpha * sourceAlpha))
        }

        private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
            a + (b - a) * t
        }

        private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
            a + (b - a) * t
        }

        private static func smoothstep(
            _ edge0: Double,
            _ edge1: Double,
            _ x: Double
        ) -> Double {
            if edge0 == edge1 { return x < edge0 ? 0 : 1 }
            let t = clamp01((x - edge0) / (edge1 - edge0))
            return t * t * (3.0 - 2.0 * t)
        }

    }

    class RadarOverlay: MKTileOverlay {

        var path: String
        // RainViewer tiles return 403 at high zooms; use source zoom fallback with crop/upscale.
        private let maxSourceZ = 7
        private let overzoomLevels = 20

        init(path: String) {
            self.path = path
            super.init(urlTemplate: nil)

            tileSize = CGSize(width: 256, height: 256)
            minimumZ = 0
            maximumZ = maxSourceZ + overzoomLevels
            canReplaceMapContent = false
            isGeometryFlipped = false
        }

        override func url(forTilePath p: MKTileOverlayPath) -> URL {
            return URL(string:
                "https://tilecache.rainviewer.com\(path)/256/\(p.z)/\(p.x)/\(p.y)/2/1_1.png"
            )!
        }

        override func loadTile(
            at tilePath: MKTileOverlayPath,
            result: @escaping (Data?, Error?) -> Void
        ) {
            let initialSourceZ = min(tilePath.z, maxSourceZ)
            loadTileForSourceZ(
                requested: tilePath,
                sourceZ: initialSourceZ,
                result: result
            )
        }

        private func loadTileForSourceZ(
            requested: MKTileOverlayPath,
            sourceZ: Int,
            result: @escaping (Data?, Error?) -> Void
        ) {
            let zoomDelta = max(0, requested.z - sourceZ)
            let scale = 1 << zoomDelta
            let sourceX = requested.x / scale
            let sourceY = requested.y / scale

            fetchTile(z: sourceZ, x: sourceX, y: sourceY) { data, statusCode, error in
                if statusCode != 200 || data == nil || data?.isEmpty == true {
                    if sourceZ > 0 {
                        self.loadTileForSourceZ(
                            requested: requested,
                            sourceZ: sourceZ - 1,
                            result: result
                        )
                        return
                    }
                    result(nil, error)
                    return
                }

                guard let data else {
                    result(nil, error)
                    return
                }

                guard let sourceImage = Self.decodeImage(data) else {
                    result(nil, error)
                    return
                }

                if sourceZ == requested.z {
                    guard let output = Self.recolorAndEncode(
                        image: sourceImage,
                        targetSize: CGSize(
                            width: sourceImage.width,
                            height: sourceImage.height
                        ),
                        interpolation: .none
                    ) else {
                        result(data, nil)
                        return
                    }
                    result(output, nil)
                    return
                }

                guard
                    let output = Self.cropAndScale(
                        sourceImage: sourceImage,
                        requested: requested,
                        sourceZ: sourceZ,
                        targetSize: self.tileSize
                    )
                else {
                    result(nil, error)
                    return
                }

                result(output, nil)
            }
        }

        private func fetchTile(
            z: Int,
            x: Int,
            y: Int,
            completion: @escaping (Data?, Int, Error?) -> Void
        ) {
            let url = URL(string:
                "https://tilecache.rainviewer.com\(path)/256/\(z)/\(x)/\(y)/2/1_1.png"
            )!

            URLSession.shared.dataTask(with: url) { data, response, error in
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                completion(data, statusCode, error)
            }.resume()
        }

        private static func decodeImage(_ data: Data) -> CGImage? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }

        private static func cropAndScale(
            sourceImage: CGImage,
            requested: MKTileOverlayPath,
            sourceZ: Int,
            targetSize: CGSize
        ) -> Data? {
            let zoomDelta = requested.z - sourceZ
            guard zoomDelta > 0 else { return nil }

            let scale = 1 << zoomDelta
            let xOffset = requested.x % scale
            let yOffset = requested.y % scale

            let srcW = sourceImage.width
            let srcH = sourceImage.height

            // Keep geometric mapping exact to avoid tile duplication artifacts.
            let x0 = Int(floor(Double(xOffset) * Double(srcW) / Double(scale)))
            let y0 = Int(floor(Double(yOffset) * Double(srcH) / Double(scale)))
            let x1 = Int(floor(Double(xOffset + 1) * Double(srcW) / Double(scale)))
            let y1 = Int(floor(Double(yOffset + 1) * Double(srcH) / Double(scale)))

            let cropX = max(0, min(srcW - 1, x0))
            let cropY = max(0, min(srcH - 1, y0))
            let cropW = max(1, min(srcW - cropX, x1 - x0))
            let cropH = max(1, min(srcH - cropY, y1 - y0))

            let cropRect = CGRect(
                x: cropX,
                y: cropY,
                width: cropW,
                height: cropH
            )

            guard let cropped = sourceImage.cropping(to: cropRect) else { return nil }

            let interpolation: CGInterpolationQuality
            if cropW <= 2 || cropH <= 2 {
                interpolation = .high
            } else {
                interpolation = .medium
            }

            return recolorAndEncode(
                image: cropped,
                targetSize: targetSize,
                interpolation: interpolation
            )
        }

        private static func recolorAndEncode(
            image: CGImage,
            targetSize: CGSize,
            interpolation: CGInterpolationQuality
        ) -> Data? {
            let width = Int(targetSize.width)
            let height = Int(targetSize.height)
            guard width > 0, height > 0 else { return nil }

            let bitmapInfo =
                CGImageAlphaInfo.premultipliedLast.rawValue |
                CGBitmapInfo.byteOrder32Big.rawValue

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }

            context.interpolationQuality = interpolation
            context.setShouldAntialias(true)
            context.draw(image, in: CGRect(origin: .zero, size: targetSize))

            guard let bytes = context.data else { return nil }
            let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
            let count = width * height

            for i in 0..<count {
                let idx = i * 4
                let alpha = ptr[idx + 3]
                if alpha == 0 { continue }

                let a = Double(alpha) / 255.0

                // Unpremultiply source color before intensity classification.
                let r = min(1.0, Double(ptr[idx]) / max(1.0, Double(alpha)))
                let g = min(1.0, Double(ptr[idx + 1]) / max(1.0, Double(alpha)))
                let b = min(1.0, Double(ptr[idx + 2]) / max(1.0, Double(alpha)))

                // Convert warm/high-intensity cells to darker tones.
                let warm = max(0.0, r - b) + max(0.0, g - b)
                let brightness = 0.299 * r + 0.587 * g + 0.114 * b
                let strength = min(1.0, max(0.0, 0.65 * warm + 0.35 * brightness))

                let outR: Double
                let outG: Double
                let outB: Double

                if strength < 0.7 {
                    let t = strength / 0.7
                    outR = lerp(40.0, 5.0, t)
                    outG = lerp(170.0, 55.0, t)
                    outB = lerp(255.0, 150.0, t)
                } else {
                    let t = (strength - 0.7) / 0.3
                    outR = lerp(5.0, 0.0, t)
                    outG = lerp(55.0, 0.0, t)
                    outB = lerp(150.0, 0.0, t)
                }

                ptr[idx] = UInt8(max(0.0, min(255.0, outR * a)).rounded())
                ptr[idx + 1] = UInt8(max(0.0, min(255.0, outG * a)).rounded())
                ptr[idx + 2] = UInt8(max(0.0, min(255.0, outB * a)).rounded())
            }

            guard let scaledImage = context.makeImage() else { return nil }

            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            ) else {
                return nil
            }
            CGImageDestinationAddImage(destination, scaledImage, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return output as Data
        }

        private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
            a + (b - a) * t
        }
    }

    class Coordinator: NSObject, MKMapViewDelegate {

        static let forecastTargetAlphaDark: CGFloat = 0.66
        static let forecastTargetAlphaLight: CGFloat = 0.62

        var currentForecastTargetAlpha: CGFloat {
            parent.isDarkTheme ? Self.forecastTargetAlphaDark : Self.forecastTargetAlphaLight
        }

        var currentForecastToneDarkening: CGFloat {
            0.0
        }

        var parent: UIKitMap
        var firstLocationFix = true
        var lastRadarPath: String?
        var overlay: MKTileOverlay?
        var baseMapOverlay: MKTileOverlay?
        var forecastOverlay: MKTileOverlay?
        var forecastRenderer: ForecastTileRenderer?
        var lastForecastOverlayKey: String?
        var forecastFadeTimer: Timer?
        var pendingForecastPreviousOverlay: MKTileOverlay?
        var pendingForecastPreviousRenderer: ForecastTileRenderer?
        var forecastTransitionToken: Int = 0
        var pendingForecastTransitionRetry: DispatchWorkItem?
        var pendingForecastRetryAttempts: Int = 0
        let maxPendingForecastRetryAttempts: Int = 10
        var forecastTransitionArmed: Bool = false
        var pendingForecastMotion: CGPoint = .zero
        var isViewportChanging = false
        var viewportSettledWorkItem: DispatchWorkItem?
        var lastForecastZoomLevel: Int?
        var lastZoomFadeAt: Date = .distantPast
        var staticOverlay: RadarImageOverlay?
        var weatherOverlays: [WeatherBlobOverlay] = []
        var pendingWeatherPreviousOverlays: [WeatherBlobOverlay] = []
        var weatherOverlayAlpha: [ObjectIdentifier: CGFloat] = [:]
        var weatherFadeTimer: Timer?
        var weatherTransitionToken: Int = 0
        var lastWeatherSignature: Int?
        var lastUserVisible: Bool = true
        var lastLocatorVisible: Bool = false
        weak var mapView: MKMapView?
        var locatorButton: MKUserTrackingButton?
        var compassButton: MKCompassButton?
        var locatorBottomConstraint: NSLayoutConstraint?
        var locatorTrailingConstraint: NSLayoutConstraint?
        var locatorWidthConstraint: NSLayoutConstraint?
        var locatorHeightConstraint: NSLayoutConstraint?
        var compassBottomConstraint: NSLayoutConstraint?
        var compassTrailingConstraint: NSLayoutConstraint?
        var compassWidthConstraint: NSLayoutConstraint?
        var compassHeightConstraint: NSLayoutConstraint?
        var lastControlThemeIsDark: Bool?
        var lastVisibleTileSignature: Int?
        var visibleTileWorkItem: DispatchWorkItem?
        var lastOverlayDebugSignature: String?

        init(_ parent: UIKitMap) {
            self.parent = parent
        }

        func stopForecastFade() {
            normalizeForecastRenderers()
            forecastFadeTimer?.invalidate()
            forecastFadeTimer = nil
            pendingForecastTransitionRetry?.cancel()
            pendingForecastTransitionRetry = nil
            pendingForecastRetryAttempts = 0
            forecastTransitionToken += 1
        }

        func stopWeatherFade(on mapView: MKMapView?) {
            weatherFadeTimer?.invalidate()
            weatherFadeTimer = nil
            weatherTransitionToken += 1

            if let mapView {
                for overlay in weatherOverlays {
                    if let renderer = mapView.renderer(for: overlay) {
                        renderer.alpha = 1.0
                        renderer.setNeedsDisplay()
                    }
                }
            }
        }

        func startWeatherFade(
            on mapView: MKMapView,
            outgoing: [WeatherBlobOverlay],
            incoming: [WeatherBlobOverlay]
        ) {
            stopWeatherFade(on: mapView)

            let token = weatherTransitionToken
            let duration: TimeInterval = 0.42
            let steps = max(1, Int(duration / (1.0 / 30.0)))
            var step = 0

            for overlay in outgoing {
                weatherOverlayAlpha[ObjectIdentifier(overlay)] = 1.0
                if let renderer = mapView.renderer(for: overlay) {
                    renderer.alpha = 1.0
                    renderer.setNeedsDisplay()
                }
            }

            for overlay in incoming {
                weatherOverlayAlpha[ObjectIdentifier(overlay)] = 0.0
                if let renderer = mapView.renderer(for: overlay) {
                    renderer.alpha = 0.0
                    renderer.setNeedsDisplay()
                }
            }

            weatherFadeTimer = Timer.scheduledTimer(
                withTimeInterval: duration / Double(steps),
                repeats: true
            ) { [weak self, weak mapView] timer in
                guard let self, let mapView else {
                    timer.invalidate()
                    return
                }
                guard self.weatherTransitionToken == token else {
                    timer.invalidate()
                    return
                }

                step += 1
                let t = min(1.0, Double(step) / Double(steps))
                let eased = CGFloat(t * t * (3.0 - 2.0 * t))
                let incomingAlpha = eased
                let outgoingAlpha = 1.0 - eased

                for overlay in incoming {
                    self.weatherOverlayAlpha[ObjectIdentifier(overlay)] = incomingAlpha
                    if let renderer = mapView.renderer(for: overlay) {
                        renderer.alpha = incomingAlpha
                        renderer.setNeedsDisplay()
                    }
                }

                for overlay in outgoing {
                    self.weatherOverlayAlpha[ObjectIdentifier(overlay)] = outgoingAlpha
                    if let renderer = mapView.renderer(for: overlay) {
                        renderer.alpha = outgoingAlpha
                        renderer.setNeedsDisplay()
                    }
                }

                if step >= steps {
                    timer.invalidate()
                    self.weatherFadeTimer = nil

                    mapView.removeOverlays(outgoing)
                    self.pendingWeatherPreviousOverlays.removeAll()
                    for overlay in outgoing {
                        self.weatherOverlayAlpha.removeValue(forKey: ObjectIdentifier(overlay))
                    }
                    for overlay in incoming {
                        self.weatherOverlayAlpha[ObjectIdentifier(overlay)] = 1.0
                        if let renderer = mapView.renderer(for: overlay) {
                            renderer.alpha = 1.0
                            renderer.setNeedsDisplay()
                        }
                    }
                }
            }

            if let timer = weatherFadeTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        private func normalizeForecastRenderers() {
            let targetAlpha = currentForecastTargetAlpha
            let toneDarkening = currentForecastToneDarkening
            if let renderer = forecastRenderer {
                renderer.alpha = targetAlpha
                renderer.toneDarkening = toneDarkening
                renderer.transitionOffset = .zero
                renderer.setNeedsDisplay()
            }
            if let renderer = pendingForecastPreviousRenderer {
                renderer.alpha = targetAlpha
                renderer.toneDarkening = toneDarkening
                renderer.transitionOffset = .zero
                renderer.setNeedsDisplay()
            }
        }

        func clearPendingForecastOverlay(
            on mapView: MKMapView,
            keeping keepOverlay: MKTileOverlay? = nil
        ) {
            pendingForecastTransitionRetry?.cancel()
            pendingForecastTransitionRetry = nil
            pendingForecastRetryAttempts = 0
            if let overlay = pendingForecastPreviousOverlay,
               !(keepOverlay.map { $0 === overlay } ?? false)
            {
                mapView.removeOverlay(overlay)
            }
            pendingForecastPreviousOverlay = nil
            pendingForecastPreviousRenderer = nil
            forecastTransitionArmed = false
        }

        func setPendingForecastTransition(
            fromOverlay: MKTileOverlay?,
            fromRenderer: ForecastTileRenderer?
        ) {
            pendingForecastPreviousOverlay = fromOverlay
            pendingForecastPreviousRenderer = fromRenderer
            pendingForecastRetryAttempts = 0
            forecastTransitionArmed = (fromOverlay != nil)
        }

        func isIncomingForecastReady(on mapView: MKMapView) -> Bool {
            guard let incomingOverlay = forecastOverlay as? ForecastTileOverlay else {
                return true
            }
            guard let snapshot = Self.makeVisibleTileSnapshot(for: mapView) else {
                return true
            }
            let minTiles = max(2, min(8, snapshot.tiles.count))
            if incomingOverlay.hasCachedCoverage(
                zoom: snapshot.zoom,
                tiles: snapshot.tiles,
                minimumTiles: minTiles
            ) {
                return true
            }
            let descriptor = incomingOverlay.sourceCoverageDescriptor()
            let minSourceTiles = max(2, min(6, snapshot.tiles.count))
            return ForecastTileOverlay.hasSourceCacheCoverage(
                template: descriptor.template,
                minSourceZ: descriptor.minSourceZ,
                maxSourceZ: descriptor.maxSourceZ,
                requestedZoom: snapshot.zoom,
                visibleTiles: snapshot.tiles,
                minimumTiles: minSourceTiles
            )
        }

        private func schedulePendingTransitionRetry(
            on mapView: MKMapView,
            token: Int
        ) {
            pendingForecastTransitionRetry?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                guard self.forecastTransitionToken == token else { return }
                self.startPendingForecastTransitionIfPossible(on: mapView)
            }
            pendingForecastTransitionRetry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func startPendingForecastTransitionIfPossible(on mapView: MKMapView) {
            guard let incomingRenderer = forecastRenderer else { return }
            let targetAlpha = currentForecastTargetAlpha
            let toneDarkening = currentForecastToneDarkening
            pendingForecastTransitionRetry?.cancel()
            pendingForecastTransitionRetry = nil

            if let pending = pendingForecastPreviousOverlay,
               !mapView.overlays.contains(where: { $0 === pending })
            {
                pendingForecastPreviousOverlay = nil
                pendingForecastPreviousRenderer = nil
                pendingForecastRetryAttempts = 0
            }

            guard let outgoingOverlay = pendingForecastPreviousOverlay else {
                pendingForecastRetryAttempts = 0
                guard forecastTransitionArmed else {
                    incomingRenderer.alpha = targetAlpha
                    incomingRenderer.toneDarkening = toneDarkening
                    incomingRenderer.transitionOffset = .zero
                    incomingRenderer.setNeedsDisplay()
                    return
                }
                forecastTransitionArmed = false
                let startAlpha = min(targetAlpha, max(0.20, targetAlpha * 0.26))
                incomingRenderer.alpha = startAlpha
                incomingRenderer.toneDarkening = toneDarkening
                incomingRenderer.transitionOffset = .zero
                incomingRenderer.setNeedsDisplay()
                let simpleFadeDuration: TimeInterval = isViewportChanging ? 0.20 : 0.28
                startForecastFade(from: startAlpha, to: targetAlpha, duration: simpleFadeDuration)
                return
            }

            let outgoingRenderer: ForecastTileRenderer? = {
                if let renderer = pendingForecastPreviousRenderer {
                    return renderer
                }
                return mapView.renderer(for: outgoingOverlay) as? ForecastTileRenderer
            }()

            let token = forecastTransitionToken
            if isViewportChanging {
                pendingForecastRetryAttempts += 1
                incomingRenderer.alpha = 0
                incomingRenderer.toneDarkening = toneDarkening
                incomingRenderer.transitionOffset = .zero
                incomingRenderer.setNeedsDisplay()

                if let outgoingRenderer {
                    outgoingRenderer.alpha = targetAlpha
                    outgoingRenderer.toneDarkening = toneDarkening
                    outgoingRenderer.transitionOffset = .zero
                    outgoingRenderer.setNeedsDisplay()
                    pendingForecastPreviousRenderer = outgoingRenderer
                }

                schedulePendingTransitionRetry(on: mapView, token: token)
                return
            }
            if !isIncomingForecastReady(on: mapView) {
                pendingForecastRetryAttempts += 1
                incomingRenderer.alpha = 0
                incomingRenderer.toneDarkening = toneDarkening
                incomingRenderer.transitionOffset = .zero
                incomingRenderer.setNeedsDisplay()

                if let outgoingRenderer {
                    outgoingRenderer.alpha = targetAlpha
                    outgoingRenderer.toneDarkening = toneDarkening
                    outgoingRenderer.transitionOffset = .zero
                    outgoingRenderer.setNeedsDisplay()
                    pendingForecastPreviousRenderer = outgoingRenderer
                }
                if pendingForecastRetryAttempts >= maxPendingForecastRetryAttempts {
                    pendingForecastRetryAttempts = maxPendingForecastRetryAttempts
                }
                schedulePendingTransitionRetry(on: mapView, token: token)
                return
            }
            pendingForecastRetryAttempts = 0
            // Old renderer can be temporarily unavailable during rapid overlay churn.
            // In that case keep old layer until new one is ready, then swap without fade.
            guard let outgoingRenderer else {
                mapView.removeOverlay(outgoingOverlay)
                pendingForecastPreviousOverlay = nil
                pendingForecastPreviousRenderer = nil
                forecastTransitionArmed = false
                pendingForecastMotion = .zero
                let startAlpha = min(targetAlpha, max(0.20, targetAlpha * 0.26))
                incomingRenderer.alpha = startAlpha
                incomingRenderer.toneDarkening = toneDarkening
                incomingRenderer.transitionOffset = .zero
                incomingRenderer.setNeedsDisplay()
                let simpleFadeDuration: TimeInterval = isViewportChanging ? 0.20 : 0.28
                startForecastFade(from: startAlpha, to: targetAlpha, duration: simpleFadeDuration)
                return
            }

            pendingForecastPreviousRenderer = outgoingRenderer
            let duration: TimeInterval = isViewportChanging ? 0.34 : 0.66
            let steps = max(1, Int(duration / (1.0 / 60.0)))
            var step = 0
            let motion = isViewportChanging ? .zero : pendingForecastMotion
            let incomingStartOffset = CGPoint(
                x: -motion.x * 0.35,
                y: -motion.y * 0.35
            )

            incomingRenderer.alpha = 0
            incomingRenderer.toneDarkening = toneDarkening
            incomingRenderer.transitionOffset = incomingStartOffset
            incomingRenderer.setNeedsDisplay()
            outgoingRenderer.alpha = targetAlpha
            outgoingRenderer.toneDarkening = toneDarkening
            outgoingRenderer.transitionOffset = .zero
            outgoingRenderer.setNeedsDisplay()

            forecastFadeTimer = Timer.scheduledTimer(
                withTimeInterval: duration / Double(steps),
                repeats: true
            ) { [weak self, weak mapView, weak incomingRenderer, weak outgoingRenderer] timer in
                guard
                    let self,
                    let mapView,
                    let incomingRenderer,
                    let outgoingRenderer
                else {
                    timer.invalidate()
                    return
                }

                if self.forecastTransitionToken != token {
                    timer.invalidate()
                    return
                }

                step += 1
                let t = min(1.0, Double(step) / Double(steps))

                // "Slider-like" blending:
                // incoming rises faster, outgoing holds longer then fades slowly.
                let inPhase = min(1.0, t / 0.58)
                let incomingEased = inPhase * inPhase * (3.0 - 2.0 * inPhase)

                let outDelay = 0.20
                let outProgressRaw = max(0.0, (t - outDelay) / (1.0 - outDelay))
                let outProgress = outProgressRaw * outProgressRaw * (3.0 - 2.0 * outProgressRaw)
                let outgoingEased = 1.0 - outProgress

                incomingRenderer.alpha = targetAlpha * CGFloat(incomingEased)
                outgoingRenderer.alpha = targetAlpha * CGFloat(outgoingEased)
                incomingRenderer.toneDarkening = toneDarkening
                outgoingRenderer.toneDarkening = toneDarkening
                let effectiveMotion = self.isViewportChanging ? .zero : motion
                incomingRenderer.transitionOffset = CGPoint(
                    x: -effectiveMotion.x * CGFloat(0.28 * (1.0 - incomingEased)),
                    y: -effectiveMotion.y * CGFloat(0.28 * (1.0 - incomingEased))
                )
                outgoingRenderer.transitionOffset = CGPoint(
                    x: effectiveMotion.x * CGFloat(0.20 * (1.0 - outgoingEased)),
                    y: effectiveMotion.y * CGFloat(0.20 * (1.0 - outgoingEased))
                )
                incomingRenderer.setNeedsDisplay()
                outgoingRenderer.setNeedsDisplay()

                if step >= steps {
                    timer.invalidate()
                    self.forecastFadeTimer = nil
                    self.pendingForecastTransitionRetry?.cancel()
                    self.pendingForecastTransitionRetry = nil
                    self.pendingForecastRetryAttempts = 0
                    incomingRenderer.alpha = targetAlpha
                    incomingRenderer.toneDarkening = toneDarkening
                    incomingRenderer.transitionOffset = .zero
                    outgoingRenderer.transitionOffset = .zero
                    incomingRenderer.setNeedsDisplay()
                    mapView.removeOverlay(outgoingOverlay)
                    self.pendingForecastPreviousOverlay = nil
                    self.pendingForecastPreviousRenderer = nil
                    self.forecastTransitionArmed = false
                    self.pendingForecastMotion = .zero
                }
            }

            if let timer = forecastFadeTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        func installControls(on mapView: MKMapView) {
            self.mapView = mapView
            let controlSide = controlButtonSide(for: mapView)

            if locatorButton == nil {
                let locator = MKUserTrackingButton(mapView: mapView)
                locator.translatesAutoresizingMaskIntoConstraints = false
                locator.layer.cornerRadius = 11
                locator.clipsToBounds = true
                locator.alpha = 0
                locator.isHidden = true
                mapView.addSubview(locator)
                locatorButton = locator

                locatorTrailingConstraint = locator.trailingAnchor.constraint(
                    equalTo: mapView.safeAreaLayoutGuide.trailingAnchor,
                    constant: -20
                )
                locatorBottomConstraint = locator.bottomAnchor.constraint(
                    equalTo: mapView.bottomAnchor,
                    constant: -96
                )
                locatorWidthConstraint = locator.widthAnchor.constraint(equalToConstant: controlSide)
                locatorHeightConstraint = locator.heightAnchor.constraint(equalToConstant: controlSide)
                NSLayoutConstraint.activate([
                    locatorTrailingConstraint,
                    locatorBottomConstraint,
                    locatorWidthConstraint,
                    locatorHeightConstraint
                ].compactMap { $0 })
            }

            if compassButton == nil {
                guard let locatorButton else { return }
                let compass = MKCompassButton(mapView: mapView)
                compass.translatesAutoresizingMaskIntoConstraints = false
                compass.compassVisibility = .adaptive
                compass.layer.cornerRadius = 11
                compass.clipsToBounds = true
                mapView.addSubview(compass)
                compassButton = compass

                compassTrailingConstraint = compass.trailingAnchor.constraint(
                    equalTo: mapView.safeAreaLayoutGuide.trailingAnchor,
                    constant: -20
                )
                compassBottomConstraint = compass.bottomAnchor.constraint(
                    equalTo: locatorButton.topAnchor,
                    constant: -12
                )
                NSLayoutConstraint.activate([
                    compassTrailingConstraint,
                    compassBottomConstraint
                ].compactMap { $0 })
                compassWidthConstraint = compass.widthAnchor.constraint(equalToConstant: controlSide)
                compassHeightConstraint = compass.heightAnchor.constraint(equalToConstant: controlSide)
                NSLayoutConstraint.activate([
                    compassWidthConstraint,
                    compassHeightConstraint
                ].compactMap { $0 })
            }

            applyControlTheme(isDarkTheme: parent.isDarkTheme)
            updateControlsLayout(for: mapView)
        }

        func applyControlTheme(isDarkTheme: Bool) {
            guard lastControlThemeIsDark != isDarkTheme else { return }
            lastControlThemeIsDark = isDarkTheme

            let tintColor = isDarkTheme ? UIColor.white : UIColor.black
            let compassPlateColor = isDarkTheme
                ? UIColor.black.withAlphaComponent(0.16)
                : UIColor.white.withAlphaComponent(0.18)
            let locatorPlateColor = compassPlateColor

            if let locatorButton {
                locatorButton.tintColor = tintColor
                styleCircularLocator(
                    locatorButton,
                    plateColor: locatorPlateColor
                )
            }

            if let compassButton {
                compassButton.tintColor = tintColor
                styleCircularCompass(
                    compassButton,
                    plateColor: compassPlateColor
                )
            }
        }

        private func styleCircularLocator(
            _ control: UIView,
            plateColor: UIColor
        ) {
            control.layoutIfNeeded()
            let side = min(control.bounds.width, control.bounds.height)
            control.layer.cornerRadius = side > 0 ? side / 2 : 999
            control.layer.cornerCurve = .continuous
            control.clipsToBounds = true
            control.layer.borderWidth = 1
            control.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
            control.backgroundColor = plateColor
            control.layer.shadowColor = UIColor.black.withAlphaComponent(0.10).cgColor
            control.layer.shadowOpacity = 1
            control.layer.shadowOffset = CGSize(width: 0, height: 6)
            control.layer.shadowRadius = 12
        }

        private func styleCircularCompass(
            _ control: UIView,
            plateColor: UIColor
        ) {
            control.layoutIfNeeded()
            let side = min(control.bounds.width, control.bounds.height)
            control.layer.cornerRadius = side > 0 ? side / 2 : 999
            control.layer.cornerCurve = .continuous
            control.clipsToBounds = true
            control.layer.borderWidth = 1
            control.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
            control.backgroundColor = plateColor
            control.layer.shadowColor = UIColor.black.withAlphaComponent(0.10).cgColor
            control.layer.shadowOpacity = 1
            control.layer.shadowOffset = CGSize(width: 0, height: 6)
            control.layer.shadowRadius = 12
        }

        func logOverlayModeIfChanged(
            mode: String,
            key: String,
            map: MKMapView
        ) {
            let signature = "\(mode)|\(key)"
            guard signature != lastOverlayDebugSignature else { return }
            lastOverlayDebugSignature = signature
            let token = Self.debugTemplateToken(key)
            print(
                "☁️DBG map mode=\(mode)",
                "key=\(token)",
                "overlays=\(map.overlays.count)",
                "bounds=\(Int(map.bounds.width))x\(Int(map.bounds.height))"
            )
        }

        private static func debugTemplateToken(_ value: String) -> String {
            let parts = value.split(separator: "/")
            if let stamp = parts.first(where: { $0.count == 12 && $0.allSatisfy(\.isNumber) }) {
                return String(stamp)
            }
            return String(value.prefix(44))
        }

        func updateControlsLayout(for mapView: MKMapView) {
            let controlBottomInset = mapView.safeAreaInsets.bottom + max(36, parent.bottomReservedSpace + 44)
            locatorBottomConstraint?.constant = -controlBottomInset
            let controlSide = controlButtonSide(for: mapView)
            locatorWidthConstraint?.constant = controlSide
            locatorHeightConstraint?.constant = controlSide
            compassWidthConstraint?.constant = controlSide
            compassHeightConstraint?.constant = controlSide
            if let locatorButton {
                styleCircularLocator(locatorButton, plateColor: locatorButton.backgroundColor ?? .clear)
            }
            if let compassButton {
                styleCircularCompass(compassButton, plateColor: compassButton.backgroundColor ?? .clear)
            }
        }

        private func controlButtonSide(for mapView: MKMapView) -> CGFloat {
            let minSide = min(mapView.bounds.width, mapView.bounds.height)
            if minSide >= 820 { return 60 }
            if minSide >= 620 { return 54 }
            return 48
        }

        func syncControlsState(for mapView: MKMapView) {
            var userInFocusArea = true
            if mapView.bounds.width > 1, mapView.bounds.height > 1 {
                if let coordinate = userCoordinate(for: mapView) {
                    let focusRect = parent.focusRect(in: mapView).insetBy(dx: 10, dy: 10)
                    let point = mapView.convert(coordinate, toPointTo: mapView)
                    userInFocusArea = focusRect.contains(point)
                }
            }

            if userInFocusArea != lastUserVisible {
                lastUserVisible = userInFocusArea
                DispatchQueue.main.async {
                    self.parent.userVisible = userInFocusArea
                }
            }

            let shouldShowLocator = !userInFocusArea
            if shouldShowLocator != lastLocatorVisible {
                lastLocatorVisible = shouldShowLocator
                let alpha: CGFloat = shouldShowLocator ? 1 : 0
                if shouldShowLocator {
                    locatorButton?.isHidden = false
                }
                UIView.animate(withDuration: 0.2, animations: {
                    self.locatorButton?.alpha = alpha
                }, completion: { _ in
                    if let locatorButton = self.locatorButton {
                        self.styleCircularLocator(
                            locatorButton,
                            plateColor: locatorButton.backgroundColor ?? .clear
                        )
                    }
                    if let compassButton = self.compassButton {
                        self.styleCircularCompass(
                            compassButton,
                            plateColor: compassButton.backgroundColor ?? .clear
                        )
                    }
                    self.locatorButton?.isHidden = !shouldShowLocator
                })
            }
        }

        func publishVisibleTileSnapshot(for mapView: MKMapView) {
            if isViewportChanging {
                scheduleVisibleTileSnapshot(for: mapView)
                return
            }
            guard let snapshot = Self.makeVisibleTileSnapshot(for: mapView) else { return }
            maybeStartZoomForecastFadeIfNeeded(snapshot: snapshot)
            guard snapshot.signature != lastVisibleTileSignature else { return }
            lastVisibleTileSignature = snapshot.signature
            DispatchQueue.main.async { [weak self] in
                self?.parent.onVisibleTilesChanged?(snapshot)
            }
        }

        private func maybeStartZoomForecastFadeIfNeeded(snapshot: VisibleTileSnapshot) {
            defer { lastForecastZoomLevel = snapshot.zoom }
            // Dedicated zoom fade is disabled: it adds extra churn and can stutter on device.
            return

            guard let previousZoom = lastForecastZoomLevel else { return }
            guard previousZoom != snapshot.zoom else { return }
            guard pendingForecastPreviousOverlay == nil else { return }
            guard let renderer = forecastRenderer else { return }
            guard let overlay = forecastOverlay as? ForecastTileOverlay else { return }
            guard Date().timeIntervalSince(lastZoomFadeAt) >= 0.24 else { return }

            // Avoid blink: run zoom fade only when current zoom tiles are already cached.
            let minimumCoverage = max(2, min(8, snapshot.tiles.count / 2))
            guard overlay.hasCachedCoverage(
                zoom: snapshot.zoom,
                tiles: snapshot.tiles,
                minimumTiles: minimumCoverage
            ) else {
                return
            }

            let targetAlpha = currentForecastTargetAlpha
            let isZoomIn = snapshot.zoom > previousZoom
            guard isZoomIn else {
                renderer.transitionOffset = .zero
                renderer.toneDarkening = currentForecastToneDarkening
                renderer.alpha = targetAlpha
                renderer.setNeedsDisplay()
                print("☁️DBG zoom fade disabled dir=out")
                return
            }
            let startAlpha = min(targetAlpha, max(0.52, targetAlpha * 0.90))
            let duration: TimeInterval = 0.16
            renderer.transitionOffset = .zero
            renderer.toneDarkening = currentForecastToneDarkening
            renderer.alpha = startAlpha
            renderer.setNeedsDisplay()
            print("☁️DBG zoom fade from=\(previousZoom) to=\(snapshot.zoom) dir=in")
            startForecastFade(from: startAlpha, to: targetAlpha, duration: duration)
            lastZoomFadeAt = Date()
        }

        func scheduleVisibleTileSnapshot(for mapView: MKMapView) {
            visibleTileWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.publishVisibleTileSnapshot(for: mapView)
            }
            visibleTileWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
        }

        private static func makeVisibleTileSnapshot(
            for mapView: MKMapView
        ) -> VisibleTileSnapshot? {
            guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return nil }
            let zoom = zoomLevel(for: mapView)
            let n = 1 << zoom
            guard n > 0 else { return nil }

            let topLeftCoord = mapView.convert(
                CGPoint(x: mapView.bounds.minX, y: mapView.bounds.minY),
                toCoordinateFrom: mapView
            )
            let bottomRightCoord = mapView.convert(
                CGPoint(x: mapView.bounds.maxX, y: mapView.bounds.maxY),
                toCoordinateFrom: mapView
            )

            guard let topLeft = tileXY(for: topLeftCoord, zoom: zoom),
                  let bottomRight = tileXY(for: bottomRightCoord, zoom: zoom)
            else {
                return nil
            }

            let minY = max(0, min(topLeft.y, bottomRight.y))
            let maxY = min(n - 1, max(topLeft.y, bottomRight.y))

            let xRange: [Int]
            if topLeft.x <= bottomRight.x {
                xRange = Array(topLeft.x...bottomRight.x)
            } else {
                // Dateline crossing.
                xRange = Array(topLeft.x..<n) + Array(0...bottomRight.x)
            }

            var tiles: [VisibleTile] = []
            tiles.reserveCapacity(min(196, xRange.count * max(1, maxY - minY + 1)))
            for x in xRange {
                for y in minY...maxY {
                    tiles.append(VisibleTile(x: x, y: y))
                    if tiles.count >= 196 { break }
                }
                if tiles.count >= 196 { break }
            }

            if tiles.isEmpty { return nil }
            var hasher = Hasher()
            hasher.combine(zoom)
            hasher.combine(tiles.count)
            for tile in tiles {
                hasher.combine(tile.x)
                hasher.combine(tile.y)
            }

            return VisibleTileSnapshot(
                zoom: zoom,
                tiles: tiles,
                signature: hasher.finalize()
            )
        }

        private static func zoomLevel(for mapView: MKMapView) -> Int {
            let worldWidth = MKMapSize.world.width
            let visibleWidth = max(1.0, mapView.visibleMapRect.size.width)
            let raw = log2(worldWidth / visibleWidth)
            return max(0, min(20, Int(raw.rounded())))
        }

        private static func tileXY(
            for coordinate: CLLocationCoordinate2D,
            zoom: Int
        ) -> (x: Int, y: Int)? {
            guard zoom >= 0 else { return nil }
            let lat = max(-85.05112878, min(85.05112878, coordinate.latitude))
            let lon = coordinate.longitude
            let scale = pow(2.0, Double(zoom))

            let xFloat = (lon + 180.0) / 360.0 * scale
            let latRad = lat * .pi / 180.0
            let mercN = log(tan(.pi / 4.0 + latRad / 2.0))
            let yFloat = (1.0 - mercN / .pi) / 2.0 * scale

            let n = Int(scale)
            guard n > 0 else { return nil }
            let x = ((Int(floor(xFloat)) % n) + n) % n
            let y = max(0, min(n - 1, Int(floor(yFloat))))
            return (x: x, y: y)
        }

        private func userCoordinate(for mapView: MKMapView) -> CLLocationCoordinate2D? {
            if let userLocation = mapView.userLocation.location {
                return userLocation.coordinate
            }
            return parent.location?.coordinate
        }

        private func recenterToUser(on mapView: MKMapView, resetZoom: Bool) {
            guard let coordinate = userCoordinate(for: mapView) else { return }
            let loc = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            parent.center(mapView, loc, animated: true, resetZoom: resetZoom)
        }

        func estimateForecastMotion(
            on mapView: MKMapView,
            fromTemplate: String,
            toTemplate: String
        ) -> CGPoint {
            if isViewportChanging {
                return .zero
            }
            guard let snapshot = Self.makeVisibleTileSnapshot(for: mapView) else {
                return .zero
            }

            guard let tileMotion = ForecastTileOverlay.estimateMotionPixels(
                fromTemplate: fromTemplate,
                toTemplate: toTemplate,
                zoom: snapshot.zoom,
                tiles: snapshot.tiles
            ) else {
                return .zero
            }

            let worldPixels = 256.0 * pow(2.0, Double(snapshot.zoom))
            guard worldPixels > 0 else { return .zero }
            guard mapView.visibleMapRect.width > 1, mapView.visibleMapRect.height > 1 else {
                return .zero
            }

            let dxMapPoints = (Double(tileMotion.x) / worldPixels) * MKMapSize.world.width
            let dyMapPoints = (Double(tileMotion.y) / worldPixels) * MKMapSize.world.width

            let dxScreen = CGFloat(
                dxMapPoints * Double(mapView.bounds.width) / mapView.visibleMapRect.width
            )
            let dyScreen = CGFloat(
                dyMapPoints * Double(mapView.bounds.height) / mapView.visibleMapRect.height
            )

            let clamped = CGPoint(
                x: max(-56, min(56, dxScreen)),
                y: max(-56, min(56, dyScreen))
            )
            if abs(clamped.x) + abs(clamped.y) < 1.5 {
                return .zero
            }
            return clamped
        }

        private func markViewportChanging() {
            isViewportChanging = true
            viewportSettledWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.isViewportChanging = false
            }
            viewportSettledWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
        }

        private func suspendForecastCrossfade(on mapView: MKMapView) {
            guard pendingForecastPreviousOverlay != nil || forecastFadeTimer != nil else { return }
            stopForecastFade()
            clearPendingForecastOverlay(on: mapView, keeping: forecastOverlay)
            let targetAlpha = currentForecastTargetAlpha
            let toneDarkening = currentForecastToneDarkening
            forecastRenderer?.alpha = targetAlpha
            forecastRenderer?.toneDarkening = toneDarkening
            forecastRenderer?.transitionOffset = .zero
            forecastRenderer?.setNeedsDisplay()
            print("☁️DBG crossfade suspended (zoom)")
        }

        func startForecastFade(
            from: CGFloat,
            to: CGFloat,
            duration: TimeInterval
        ) {
            stopForecastFade()
            guard let renderer = forecastRenderer else { return }
            renderer.alpha = from
            renderer.setNeedsDisplay()

            let steps = max(1, Int(duration / (1.0 / 30.0)))
            var step = 0

            forecastFadeTimer = Timer.scheduledTimer(
                withTimeInterval: duration / Double(steps),
                repeats: true
            ) { [weak self, weak renderer] timer in
                guard let self, let renderer else {
                    timer.invalidate()
                    return
                }

                step += 1
                let t = min(1.0, Double(step) / Double(steps))
                let eased = t * t * (3.0 - 2.0 * t)
                renderer.alpha = from + CGFloat(eased) * (to - from)
                renderer.setNeedsDisplay()

                if step >= steps {
                    timer.invalidate()
                    self.forecastFadeTimer = nil
                    renderer.alpha = to
                    renderer.setNeedsDisplay()
                }
            }

            if let timer = forecastFadeTimer {
                RunLoop.main.add(timer, forMode: .common)
            }
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: MKOverlay
        ) -> MKOverlayRenderer {

            if let weatherOverlay = overlay as? WeatherBlobOverlay {
                let renderer = WeatherBlobRenderer(overlay: weatherOverlay)
                let alpha = weatherOverlayAlpha[ObjectIdentifier(weatherOverlay)] ?? 1.0
                renderer.alpha = alpha
                return renderer
            }

            if let tile = overlay as? ForecastTileOverlay {
                let renderer = ForecastTileRenderer(tileOverlay: tile)
                let targetAlpha = currentForecastTargetAlpha
                let toneDarkening = currentForecastToneDarkening
                if let activeOverlay = forecastOverlay, activeOverlay === tile {
                    forecastRenderer = renderer
                    renderer.alpha = targetAlpha
                    renderer.toneDarkening = toneDarkening
                    renderer.transitionOffset = .zero
                    print("☁️ renderer attach active")
                    if pendingForecastPreviousOverlay != nil || forecastTransitionArmed {
                        startPendingForecastTransitionIfPossible(on: mapView)
                    }
                    return renderer
                }

                renderer.alpha = targetAlpha
                renderer.toneDarkening = toneDarkening
                renderer.transitionOffset = .zero
                return renderer
            }

            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                if let base = baseMapOverlay, base === tile {
                    renderer.alpha = 1.0
                } else {
                    renderer.alpha = 0.65
                }
                return renderer
            }

            if let imageOverlay = overlay as? RadarImageOverlay {
                let renderer = RadarImageRenderer(overlay: imageOverlay)
                return renderer
            }

            return MKOverlayRenderer()
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            markViewportChanging()
            suspendForecastCrossfade(on: mapView)
            syncControlsState(for: mapView)
        }

        func mapView(
            _ mapView: MKMapView,
            regionDidChangeAnimated animated: Bool
        ) {
            markViewportChanging()
            syncControlsState(for: mapView)
            scheduleVisibleTileSnapshot(for: mapView)
        }

        func mapView(
            _ mapView: MKMapView,
            didChange mode: MKUserTrackingMode,
            animated: Bool
        ) {
            guard mode != .none else { return }
            recenterToUser(on: mapView, resetZoom: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                mapView.setUserTrackingMode(.none, animated: false)
            }
        }
    }
}
