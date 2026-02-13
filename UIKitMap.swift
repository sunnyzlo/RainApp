import SwiftUI
import MapKit
import UIKit
import ImageIO
import UniformTypeIdentifiers

struct UIKitMap: UIViewRepresentable {

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
        context.coordinator.publishVisibleTileSnapshot(for: map)

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
        if coordinator.lastForecastOverlayKey == key {
            print("☁️DBG forecast overlay skip (same key)")
            return
        }
        coordinator.lastForecastOverlayKey = key

        if let existing = coordinator.forecastOverlay as? ForecastTileOverlay {
            let fromTemplate = existing.currentTemplateIdentifier()

            // Same frame template (e.g. only zoom bounds changed): update in place.
            if fromTemplate == template {
                if existing.updateSource(
                    urlTemplate: template,
                    minSourceZ: minZoom,
                    maxSourceZ: maxZoom
                ) {
                    coordinator.pendingForecastMotion = .zero
                    coordinator.stopForecastFade()
                    coordinator.clearPendingForecastOverlay(on: map)
                    coordinator.forecastRenderer?.alpha = coordinator.currentForecastTargetAlpha
                    coordinator.forecastRenderer?.toneDarkening = coordinator.currentForecastToneDarkening
                    coordinator.forecastRenderer?.transitionOffset = .zero
                    coordinator.forecastRenderer?.reloadData()
                    print("☁️ Forecast tiles UPDATE (reuse overlay):", key)
                } else {
                    print("☁️DBG forecast overlay reuse called, but source unchanged")
                }
                return
            }

            // New frame template: update same overlay instance.
            // This avoids renderer churn that can leave the layer transparent
            // during rapid slider scrubbing.
            if existing.updateSource(
                urlTemplate: template,
                minSourceZ: minZoom,
                maxSourceZ: maxZoom
            ) {
                coordinator.pendingForecastMotion = .zero
                coordinator.stopForecastFade()
                coordinator.clearPendingForecastOverlay(on: map)
                coordinator.forecastRenderer?.alpha = coordinator.currentForecastTargetAlpha
                coordinator.forecastRenderer?.toneDarkening = coordinator.currentForecastToneDarkening
                coordinator.forecastRenderer?.transitionOffset = .zero
                coordinator.forecastRenderer?.reloadData()
                print("☁️ Forecast tiles UPDATE (reuse overlay frame):", key)
            } else {
                print("☁️DBG forecast overlay frame update called, but source unchanged")
            }
            return
        }

        coordinator.stopForecastFade()
        coordinator.clearPendingForecastOverlay(on: map)
        coordinator.pendingForecastMotion = .zero
        if let oldOverlay = coordinator.forecastOverlay {
            map.removeOverlay(oldOverlay)
        }

        let overlay = ForecastTileOverlay(
            urlTemplate: template,
            minSourceZ: minZoom,
            maxSourceZ: maxZoom
        )
        coordinator.forecastOverlay = overlay
        coordinator.forecastRenderer = nil
        map.addOverlay(overlay, level: .aboveLabels)
        print("☁️ Forecast tiles UPDATE (new overlay):", key)
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
        guard let overlay = coordinator.weatherOverlay else { return }
        map.removeOverlay(overlay)
        coordinator.weatherOverlay = nil
        coordinator.lastWeatherSignature = nil
    }

    private func addWeatherOverlay(
        cells: [CloudOverlayService.CloudCell],
        map: MKMapView,
        coordinator: Coordinator
    ) {
        var hasher = Hasher()
        hasher.combine(4) // rendering profile version
        hasher.combine(cells.count)
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

        if let old = coordinator.weatherOverlay {
            map.removeOverlay(old)
            coordinator.weatherOverlay = nil
        }

        guard !cells.isEmpty else { return }
        let maxRain = cells.map(\.rainIntensity).max() ?? 0
        let maxStorm = cells.map(\.stormRisk).max() ?? 0
        print("☁️ overlay signal maxRain=\(String(format: "%.3f", maxRain)) maxStorm=\(String(format: "%.3f", maxStorm))")
        guard let overlay = Self.makeWeatherFieldOverlay(from: cells) else { return }

        coordinator.weatherOverlay = overlay
        map.addOverlay(overlay, level: .aboveLabels)
    }

    private static func makeWeatherFieldOverlay(
        from cells: [CloudOverlayService.CloudCell]
    ) -> WeatherFieldOverlay? {
        guard let first = cells.first else { return nil }
        let gridSize = first.gridSize
        guard gridSize > 1 else { return nil }

        var rain = Array(repeating: 0.0, count: gridSize * gridSize)
        var storm = Array(repeating: 0.0, count: gridSize * gridSize)

        for cell in cells {
            guard cell.gridSize == gridSize else { continue }
            guard cell.row >= 0, cell.row < gridSize else { continue }
            guard cell.col >= 0, cell.col < gridSize else { continue }
            let idx = cell.row * gridSize + cell.col
            rain[idx] = cell.rainIntensity
            storm[idx] = cell.stormRisk
        }

        let rainSmooth = smoothedMatrix(rain, gridSize: gridSize, passes: 2)
        let stormSmooth = smoothedMatrix(storm, gridSize: gridSize, passes: 1)

        guard
            let image = makeWeatherImage(
                rain: rainSmooth,
                storm: stormSmooth,
                gridSize: gridSize
            )
        else {
            return nil
        }

        let minLat = cells.map { $0.center.latitude }.min() ?? 0
        let maxLat = cells.map { $0.center.latitude }.max() ?? 0
        let minLon = cells.map { $0.center.longitude }.min() ?? 0
        let maxLon = cells.map { $0.center.longitude }.max() ?? 0
        let pad = first.stepDegrees * 0.5

        return WeatherFieldOverlay(
            image: image,
            minLatitude: minLat - pad,
            maxLatitude: maxLat + pad,
            minLongitude: minLon - pad,
            maxLongitude: maxLon + pad
        )
    }

    private static func makeWeatherImage(
        rain: [Double],
        storm: [Double],
        gridSize: Int
    ) -> UIImage? {
        let maxRain = rain.max() ?? 0
        let maxStorm = storm.max() ?? 0
        if maxRain < 0.008 && maxStorm < 0.05 { return nil }

        let sortedRain = rain.sorted()
        let baselineIndex = min(
            max(0, Int(Double(sortedRain.count - 1) * 0.20)),
            max(0, sortedRain.count - 1)
        )
        let rainBaselineRaw = sortedRain.isEmpty ? 0 : sortedRain[baselineIndex]
        let rainBaseline = rainBaselineRaw * 0.70
        var rainSpread = max(0, maxRain - rainBaseline)
        if rainSpread < 0.004 {
            rainSpread = max(0.03, maxRain * 0.65)
        }
        if rainSpread < 0.004 && maxStorm < 0.08 { return nil }

        let stormBaseline = max(0.0, min(maxStorm * 0.35, 0.16))

        let width = 900
        let height = 900
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

        guard let bytes = context.data else { return nil }
        let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))

        for y in 0..<height {
            // Matrix row 0 is south; image y=0 is north, so flip vertically.
            let gy = Double(height - 1 - y) * Double(gridSize - 1) / Double(height - 1)
            for x in 0..<width {
                let gx = Double(x) * Double(gridSize - 1) / Double(width - 1)

                let rainValue = bilinear(rain, gridSize: gridSize, x: gx, y: gy)
                let stormValue = bilinear(storm, gridSize: gridSize, x: gx, y: gy)

                let effectiveRain = max(0, rainValue - rainBaseline)
                let rainNorm = max(0.0, min(1.0, effectiveRain / max(0.08, rainSpread)))
                let stormNorm = max(
                    0.0,
                    min(1.0, (stormValue - stormBaseline) / max(0.08, maxStorm - stormBaseline))
                )
                if rainNorm < 0.01 && stormNorm < 0.03 { continue }

                var red = lerp(32.0, 8.0, rainNorm)
                var green = lerp(150.0, 52.0, rainNorm)
                var blue = lerp(255.0, 175.0, rainNorm)
                var alpha = 0.18 + rainNorm * 0.58

                if stormNorm > 0.04 {
                    let s = max(0.0, min(1.0, stormNorm * 1.2))
                    red = mix(red, 4.0, s)
                    green = mix(green, 4.0, s)
                    blue = mix(blue, 10.0, s)
                    alpha = max(alpha, 0.26 + s * 0.54)
                }

                let u = Double(x) / Double(width - 1)
                let v = Double(y) / Double(height - 1)
                let edge = min(min(u, 1.0 - u), min(v, 1.0 - v))
                let feather = smoothstep(0.02, 0.16, edge)
                alpha *= feather

                let a = max(0.0, min(1.0, alpha))
                let idx = (y * width + x) * 4
                ptr[idx] = UInt8(max(0.0, min(255.0, red * a)).rounded())
                ptr[idx + 1] = UInt8(max(0.0, min(255.0, green * a)).rounded())
                ptr[idx + 2] = UInt8(max(0.0, min(255.0, blue * a)).rounded())
                ptr[idx + 3] = UInt8((255.0 * a).rounded())
            }
        }

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

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        if edge0 == edge1 { return x < edge0 ? 0 : 1 }
        let t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    final class WeatherFieldOverlay: NSObject, MKOverlay {
        let image: UIImage
        let coordinate: CLLocationCoordinate2D
        let boundingMapRect: MKMapRect

        init(
            image: UIImage,
            minLatitude: Double,
            maxLatitude: Double,
            minLongitude: Double,
            maxLongitude: Double
        ) {
            self.image = image

            let centerLat = (minLatitude + maxLatitude) * 0.5
            let centerLon = (minLongitude + maxLongitude) * 0.5
            self.coordinate = CLLocationCoordinate2D(
                latitude: centerLat,
                longitude: centerLon
            )

            let topLeft = MKMapPoint(
                CLLocationCoordinate2D(
                    latitude: maxLatitude,
                    longitude: minLongitude
                )
            )
            let bottomRight = MKMapPoint(
                CLLocationCoordinate2D(
                    latitude: minLatitude,
                    longitude: maxLongitude
                )
            )

            let x = min(topLeft.x, bottomRight.x)
            let y = min(topLeft.y, bottomRight.y)
            let width = abs(bottomRight.x - topLeft.x)
            let height = abs(bottomRight.y - topLeft.y)
            self.boundingMapRect = MKMapRect(x: x, y: y, width: width, height: height)
        }
    }

    final class WeatherFieldRenderer: MKOverlayRenderer {
        override func draw(
            _ mapRect: MKMapRect,
            zoomScale: MKZoomScale,
            in context: CGContext
        ) {
            guard let overlay = overlay as? WeatherFieldOverlay else { return }
            guard let cgImage = overlay.image.cgImage else { return }

            let rect = self.rect(for: overlay.boundingMapRect)
            context.interpolationQuality = .high
            context.setShouldAntialias(true)
            context.draw(cgImage, in: rect)
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
            if transitionOffset != .zero {
                context.translateBy(x: transitionOffset.x, y: transitionOffset.y)
            }
            super.draw(mapRect, zoomScale: zoomScale, in: context)
            if toneDarkening > 0 {
                context.setBlendMode(.sourceAtop)
                context.setFillColor(
                    UIColor(white: 0.0, alpha: toneDarkening).cgColor
                )
                context.fill(rect(for: mapRect))
            }
            context.restoreGState()
        }
    }

    class ForecastTileOverlay: MKTileOverlay {

        private let overzoomLevels = 20
        private let stateQueue = DispatchQueue(
            label: "RainApp.ForecastTileOverlay.state",
            attributes: .concurrent
        )
        private var template: String
        private var fallbackTemplate: String?
        private var minSourceZ: Int
        private var maxSourceZ: Int

        private struct RenderedTile {
            let data: Data
            let visiblePixelCount: Int
        }
        private static let useRawRendering = true
        // Keep fallback permissive so cloud layer does not disappear between frame swaps.
        private static let minVisiblePixelsForGenericFallback = 1

        private static let userAgent =
            "RainApp/1.0 (+https://github.com/alex/RainApp)"
        private static let cacheVersion = "v19"
        private static let renderedTileCache: NSCache<NSString, NSData> = {
            let cache = NSCache<NSString, NSData>()
            cache.countLimit = 2200
            cache.totalCostLimit = 48 * 1024 * 1024
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
        private static let stickyTileMaxAge: TimeInterval = 110
        private static let sourceTileCache: NSCache<NSString, NSData> = {
            let cache = NSCache<NSString, NSData>()
            cache.countLimit = 2600
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
        private static let networkSession: URLSession = {
            let config = URLSessionConfiguration.default
            config.httpMaximumConnectionsPerHost = 3
            config.timeoutIntervalForRequest = 8
            config.timeoutIntervalForResource = 12
            config.waitsForConnectivity = false
            return URLSession(configuration: config)
        }()
        private static let renderedPrewarmQueue = DispatchQueue(
            label: "RainApp.ForecastTileOverlay.rendered-prewarm",
            qos: .utility
        )
        private static func shouldSample(_ path: MKTileOverlayPath) -> Bool {
            ((path.x & 3) == 0) && ((path.y & 3) == 0)
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
            self.minSourceZ = normalizedMin
            self.maxSourceZ = normalizedMax
            super.init(urlTemplate: nil)

            tileSize = CGSize(width: 256, height: 256)
            minimumZ = 0
            maximumZ = normalizedMax + overzoomLevels
            canReplaceMapContent = false
            isGeometryFlipped = false
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
                    fallbackTemplate = template
                    template = urlTemplate
                    self.minSourceZ = normalizedMin
                    self.maxSourceZ = normalizedMax
                    changed = true
                }
            }

            if changed {
                maximumZ = normalizedMax + overzoomLevels
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

        static func prewarmTile(
            template: String,
            z: Int,
            x: Int,
            y: Int
        ) {
            guard let url = makeURLStatic(template: template, z: z, x: x, y: y) else { return }
            let cacheKey = url.absoluteString as NSString
            if sourceTileCache.object(forKey: cacheKey) != nil { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 7
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/png,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

            networkSession.dataTask(with: request) { data, response, _ in
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard statusCode == 200, let data, !data.isEmpty else { return }
                sourceTileCache.setObject(
                    data as NSData,
                    forKey: cacheKey,
                    cost: data.count
                )
            }.resume()
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
            loadTileDirect(
                requested: tilePath,
                sourceZ: sourceZ,
                template: source.template,
                fallbackTemplate: source.fallbackTemplate,
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
            if let cached = Self.renderedTileCache.object(forKey: specificKey as NSString) {
                let cachedData = cached as Data
                if Self.cachedTileHasVisiblePixels(key: specificKey, data: cachedData) {
                    result(cachedData, nil)
                    return
                }
                Self.renderedTileCache.removeObject(forKey: specificKey as NSString)
                Self.renderedVisiblePixelCache.removeObject(forKey: specificKey as NSString)
            }

            let fallbackKey = Self.fallbackTileKey(template: template, requested: requested)
            let genericKey = Self.genericTileKey(requested: requested)
            let stickyKey = Self.stickyTileKey(requested: requested)
            let previousSpecificKey = fallbackTemplate.map {
                Self.tileCacheKey(template: $0, requested: requested)
            }
            let previousFallbackKey = fallbackTemplate.map {
                Self.fallbackTileKey(template: $0, requested: requested)
            }
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
            let resolveCachedFallback: () -> (Data, String)? = {
                if let resolved = resolveVisibleRenderedCache(fallbackKey, "current-fallback") {
                    return resolved
                }
                if let resolved = resolveVisibleRenderedCache(genericKey, "generic") {
                    return resolved
                }
                if let previousSpecificKey,
                   let resolved = resolveVisibleRenderedCache(previousSpecificKey, "previous-specific")
                {
                    return resolved
                }
                if let previousFallbackKey,
                   let resolved = resolveVisibleRenderedCache(previousFallbackKey, "previous-fallback")
                {
                    return resolved
                }
                if let sticky = Self.freshStickyTile(key: stickyKey) {
                    return (sticky, "sticky")
                }
                return nil
            }

            let zoomDelta = max(0, requested.z - sourceZ)
            let scale = 1 << zoomDelta
            let sourceN = 1 << sourceZ
            guard sourceN > 0 else {
                if let (cached, _) = resolveCachedFallback() {
                    result(cached, nil)
                    return
                }
                result(nil, nil)
                return
            }

            let sourceX = ((requested.x / scale) % sourceN + sourceN) % sourceN
            let sourceY = requested.y / scale
            guard sourceY >= 0, sourceY < sourceN else {
                if let (cached, _) = resolveCachedFallback() {
                    result(cached, nil)
                    return
                }
                result(nil, nil)
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
                    result(nil, error)
                    return
                }

                guard let sourceImage = Self.decodeImage(data) else {
                    result(nil, nil)
                    return
                }

                let rendered: RenderedTile?
                if Self.useRawRendering {
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
                    result(nil, nil)
                    return
                }

                guard rendered.visiblePixelCount >= Self.minVisiblePixelsForGenericFallback else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:low-visible")
                        }
                        result(cached, nil)
                        return
                    }
                    result(nil, nil)
                    return
                }

                Self.storeRenderedTile(
                    rendered.data,
                    specificKey: specificKey,
                    fallbackKey: fallbackKey,
                    genericKey: genericKey,
                    stickyKey: stickyKey,
                    visiblePixelCount: rendered.visiblePixelCount,
                    storeAsGeneric: true
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
            let genericKey = Self.genericTileKey(requested: requested)
            let stickyKey = Self.stickyTileKey(requested: requested)
            let previousSpecificKey = fallbackTemplate.map {
                Self.tileCacheKey(template: $0, requested: requested)
            }
            let previousFallbackKey = fallbackTemplate.map {
                Self.fallbackTileKey(template: $0, requested: requested)
            }
            let resolveVisibleRenderedCache: (_ key: String, _ reason: String) -> (Data, String)? = { key, reason in
                guard let cached = Self.renderedTileCache.object(forKey: key as NSString) else {
                    return nil
                }
                let data = cached as Data
                guard Self.cachedTileHasVisiblePixels(key: key, data: data) else {
                    if Self.shouldSample(requested) {
                        print("☁️DBG fallback reject invisible", reason)
                    }
                    return nil
                }
                return (data, reason)
            }
            let resolveCachedFallback: () -> (Data, String)? = {
                if let resolved = resolveVisibleRenderedCache(fallbackKey, "current-fallback") {
                    return resolved
                }
                if let resolved = resolveVisibleRenderedCache(genericKey, "generic") {
                    return resolved
                }
                if let previousSpecificKey,
                   let resolved = resolveVisibleRenderedCache(previousSpecificKey, "previous-specific")
                {
                    return resolved
                }
                if let previousFallbackKey,
                   let resolved = resolveVisibleRenderedCache(previousFallbackKey, "previous-fallback")
                {
                    return resolved
                }
                if let sticky = Self.freshStickyTile(key: stickyKey) {
                    return (sticky, "sticky")
                }
                return nil
            }
            if let cached = Self.renderedTileCache.object(forKey: specificKey as NSString) {
                if Self.shouldSample(requested) {
                    print(
                        "☁️ tile cache-hit:",
                        Self.templateDebugToken(template),
                        "z=\(requested.z)",
                        "x=\(requested.x)",
                        "y=\(requested.y)"
                    )
                }
                result(cached as Data, nil)
                return
            }

            let zoomDelta = max(0, requested.z - sourceZ)
            let scale = 1 << zoomDelta
            let sourceN = 1 << sourceZ
            guard sourceN > 0 else {
                if let (cached, reason) = resolveCachedFallback() {
                    print("☁️ tile fallback:", reason, "reason:invalid-sourceN")
                    result(cached, nil)
                } else {
                    result(nil, nil)
                }
                return
            }
            let sourceX = ((requested.x / scale) % sourceN + sourceN) % sourceN
            let sourceY = requested.y / scale
            guard sourceY >= 0, sourceY < sourceN else {
                if let (cached, reason) = resolveCachedFallback() {
                    print("☁️ tile fallback:", reason, "reason:out-of-range-y", "z=\(requested.z)", "x=\(requested.x)", "y=\(requested.y)")
                    result(cached, nil)
                } else {
                    result(nil, nil)
                }
                return
            }

            // Critical path for scrubbing: if the incoming frame source tile is not yet cached,
            // render immediately from previous frame's cached source tile (same z/x/y),
            // then warm current source in background.
            if let fallbackTemplate,
               let currentURL = Self.makeURLStatic(template: template, z: sourceZ, x: sourceX, y: sourceY),
               Self.sourceTileCache.object(forKey: currentURL.absoluteString as NSString) == nil,
               let previousURL = Self.makeURLStatic(template: fallbackTemplate, z: sourceZ, x: sourceX, y: sourceY),
               let previousSourceData = Self.sourceTileCache.object(forKey: previousURL.absoluteString as NSString) as Data?,
               let previousImage = Self.decodeImage(previousSourceData)
            {
                let immediateRendered: RenderedTile?
                if sourceZ == requested.z {
                    immediateRendered = Self.maskAndEncodeForecastTile(
                        image: previousImage,
                        targetSize: CGSize(
                            width: previousImage.width,
                            height: previousImage.height
                        ),
                        interpolation: .none,
                        edgeSmoothingPasses: 0,
                        tileEdgeFeatherWidth: 0
                    )
                } else {
                    immediateRendered = Self.cropAndScale(
                        sourceImage: previousImage,
                        requested: requested,
                        sourceZ: sourceZ,
                        targetSize: self.tileSize
                    )
                }

                if let immediateRendered,
                   immediateRendered.visiblePixelCount >= Self.minVisiblePixelsForGenericFallback
                {
                    Self.storeRenderedTile(
                        immediateRendered.data,
                        specificKey: specificKey,
                        fallbackKey: fallbackKey,
                        genericKey: genericKey,
                        stickyKey: stickyKey,
                        visiblePixelCount: immediateRendered.visiblePixelCount,
                        storeAsGeneric: false
                    )
                    if Self.shouldSample(requested) {
                        print(
                            "☁️ tile immediate previous-source:",
                            "z=\(requested.z)",
                            "x=\(requested.x)",
                            "y=\(requested.y)",
                            "from=\(Self.templateDebugToken(fallbackTemplate))",
                            "to=\(Self.templateDebugToken(template))"
                        )
                    }

                    fetchTile(
                        template: template,
                        z: sourceZ,
                        x: sourceX,
                        y: sourceY
                    ) { _, _, _ in }

                    result(immediateRendered.data, nil)
                    return
                }
            }
            if Self.shouldSample(requested),
               let fallbackTemplate,
               let currentURL = Self.makeURLStatic(template: template, z: sourceZ, x: sourceX, y: sourceY)
            {
                let currentCached = Self.sourceTileCache.object(forKey: currentURL.absoluteString as NSString) != nil
                if !currentCached {
                    let previousCached: Bool = {
                        guard let previousURL = Self.makeURLStatic(template: fallbackTemplate, z: sourceZ, x: sourceX, y: sourceY) else {
                            return false
                        }
                        return Self.sourceTileCache.object(forKey: previousURL.absoluteString as NSString) != nil
                    }()
                    if !previousCached {
                        print(
                            "☁️DBG immediate-fallback miss prev-source",
                            "reqZ=\(requested.z)",
                            "reqX=\(requested.x)",
                            "reqY=\(requested.y)",
                            "srcZ=\(sourceZ)",
                            "srcX=\(sourceX)",
                            "srcY=\(sourceY)",
                            "template=\(Self.templateDebugToken(template))",
                            "fallback=\(Self.templateDebugToken(fallbackTemplate))"
                        )
                    }
                }
            }

            fetchTile(
                template: template,
                z: sourceZ,
                x: sourceX,
                y: sourceY
            ) { data, statusCode, error in
                if statusCode != 200 || data == nil || data?.isEmpty == true {
                    // Overzoom fallback only for explicit tile-unavailable statuses.
                    let canFallback = (statusCode == 403 || statusCode == 404 || statusCode == 410)
                    if canFallback && sourceZ > minSourceZ {
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
                    result(nil, error)
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
                    result(nil, error)
                    return
                }

                guard let sourceImage = Self.decodeImage(data) else {
                    if let (cached, reason) = resolveCachedFallback() {
                        if Self.shouldSample(requested) {
                            print("☁️ tile fallback:", reason, "reason:decode-failed")
                        }
                        result(cached, nil)
                        return
                    }
                    result(nil, error)
                    return
                }

                if sourceZ == requested.z {
                    let rendered: RenderedTile?
                    if Self.useRawRendering {
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
                        result(nil, error)
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
                        storeAsGeneric: rendered.visiblePixelCount >= Self.minVisiblePixelsForGenericFallback
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
                if Self.useRawRendering {
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
                    result(nil, error)
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
                    storeAsGeneric: rendered.visiblePixelCount >= Self.minVisiblePixelsForGenericFallback
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
            if let cached = Self.renderedTileCache.object(forKey: genericKey as NSString) {
                if Self.shouldSample(requested) {
                    print("☁️ tile fallback: generic reason:low-visible", rendered.visiblePixelCount)
                }
                result(cached as Data, nil)
                return
            }
            if let (cached, reason) = resolveCachedFallback() {
                if Self.shouldSample(requested) {
                    print("☁️ tile fallback:", reason, "reason:low-visible", rendered.visiblePixelCount)
                }
                result(cached, nil)
                return
            }
            guard let fallbackTemplate else {
                result(rendered.data, nil)
                return
            }

            fetchTile(
                template: fallbackTemplate,
                z: sourceZ,
                x: sourceX,
                y: sourceY
            ) { fallbackData, fallbackStatus, _ in
                guard fallbackStatus == 200,
                      let fallbackData,
                      let fallbackImage = Self.decodeImage(fallbackData)
                else {
                    result(rendered.data, nil)
                    return
                }

                let fallbackRendered: RenderedTile?
                if sourceZ == requested.z {
                    if Self.useRawRendering {
                        fallbackRendered = Self.renderRawTile(
                            image: fallbackImage,
                            targetSize: CGSize(
                                width: fallbackImage.width,
                                height: fallbackImage.height
                            ),
                            interpolation: .none
                        )
                    } else {
                        fallbackRendered = Self.maskAndEncodeForecastTile(
                            image: fallbackImage,
                            targetSize: CGSize(
                                width: fallbackImage.width,
                                height: fallbackImage.height
                            ),
                            interpolation: .none,
                            edgeSmoothingPasses: 0,
                            tileEdgeFeatherWidth: 0
                        )
                    }
                } else {
                    if Self.useRawRendering {
                        fallbackRendered = Self.cropAndScaleRaw(
                            sourceImage: fallbackImage,
                            requested: requested,
                            sourceZ: sourceZ,
                            targetSize: self.tileSize
                        )
                    } else {
                        fallbackRendered = Self.cropAndScale(
                            sourceImage: fallbackImage,
                            requested: requested,
                            sourceZ: sourceZ,
                            targetSize: self.tileSize
                        )
                    }
                }

                guard
                    let fallbackRendered,
                    fallbackRendered.visiblePixelCount >= Self.minVisiblePixelsForGenericFallback
                else {
                    result(rendered.data, nil)
                    return
                }

                Self.storeRenderedTile(
                    fallbackRendered.data,
                    specificKey: specificKey,
                    fallbackKey: fallbackKey,
                    genericKey: genericKey,
                    stickyKey: stickyKey,
                    visiblePixelCount: fallbackRendered.visiblePixelCount,
                    storeAsGeneric: true
                )

                if Self.shouldSample(requested) {
                    print(
                        "☁️ tile fallback: previous-source",
                        "req-z=\(requested.z)",
                        "req-x=\(requested.x)",
                        "req-y=\(requested.y)",
                        "from=\(Self.templateDebugToken(template))",
                        "prev=\(Self.templateDebugToken(fallbackTemplate))"
                    )
                }
                result(fallbackRendered.data, nil)
            }
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
            let sourceCacheKey = url.absoluteString as NSString
            if let cached = Self.sourceTileCache.object(forKey: sourceCacheKey) {
                if ((x + y + z) & 31) == 0 {
                    print("☁️DBG source cache-hit z=\(z) x=\(x) y=\(y)")
                }
                completion(cached as Data, 200, nil)
                return
            }

            let requestKey = url.absoluteString
            var shouldStartRequest = false
            Self.sourceFetchStateQueue.sync {
                if Self.inFlightSourceRequests[requestKey] != nil {
                    Self.inFlightSourceRequests[requestKey]?.append(completion)
                    if ((x + y + z) & 31) == 0 {
                        print("☁️DBG source join in-flight z=\(z) x=\(x) y=\(y)")
                    }
                } else {
                    Self.inFlightSourceRequests[requestKey] = [completion]
                    shouldStartRequest = true
                }
            }
            if !shouldStartRequest { return }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/png,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

            Self.networkSession.dataTask(with: request) { data, response, error in
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                if statusCode != 200 {
                    print("☁️ forecast tile z=\(z) x=\(x) y=\(y) status=\(statusCode) bytes=\(data?.count ?? 0)")
                } else if ((x + y + z) & 31) == 0 {
                    print("☁️ forecast tile 200 z=\(z) x=\(x) y=\(y) bytes=\(data?.count ?? 0)")
                }
                if statusCode == 200, let data, !data.isEmpty {
                    Self.sourceTileCache.setObject(
                        data as NSData,
                        forKey: sourceCacheKey,
                        cost: data.count
                    )
                }
                let callbacks: [SourceTileCompletion] = Self.sourceFetchStateQueue.sync {
                    let pending = Self.inFlightSourceRequests[requestKey] ?? []
                    Self.inFlightSourceRequests.removeValue(forKey: requestKey)
                    return pending
                }
                for callback in callbacks {
                    callback(data, statusCode, error)
                }
            }.resume()
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
            let urlString = template
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

            let sampledTiles = sampleTiles(tiles, limit: 52)
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
            requested: MKTileOverlayPath
        ) -> String {
            "\(cacheVersion)|generic|\(requested.z)|\(requested.x)|\(requested.y)"
        }

        private static func stickyTileKey(
            requested: MKTileOverlayPath
        ) -> String {
            "\(cacheVersion)|sticky|\(requested.z)|\(requested.x)|\(requested.y)"
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
                stickyStateQueue.sync(flags: .barrier) {
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
                    if ptr[idx + 3] >= 6 {
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
                edgeSmoothingPasses: 5,
                tileEdgeFeatherWidth: 2
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
            return renderRawTile(
                image: cropped,
                targetSize: targetSize,
                interpolation: .none
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
                let isNoRainBlack = ur <= 14.0 && ug <= 14.0 && ub <= 18.0
                let isDarkSeam = ur < 70.0 && ug < 95.0 && ub < 140.0
                if isNoRainBlack || isDarkSeam {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    continue
                }

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
                    let looksLikeHalo = ur < 110.0 && ug < 145.0 && ub < 200.0
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
                if ur <= 10.0 && ug <= 10.0 && ub <= 12.0 {
                    ptr[idx] = 0
                    ptr[idx + 1] = 0
                    ptr[idx + 2] = 0
                    ptr[idx + 3] = 0
                    continue
                }

                visiblePixelCount += 1

                // Keep source shape and encode in readable rain palette.
                let intensity = max(ur, max(ug, ub)) / 255.0
                let warm = max(0.0, ur - ub) + max(0.0, ug - ub)
                let stormScore = max(
                    0.0,
                    min(1.0, 0.58 * (warm / 255.0) + 0.42 * intensity)
                )

                var outUR = max(16.0, min(110.0, ur * 0.42 + 8.0))
                var outUG = max(70.0, min(190.0, ug * 0.55 + 44.0))
                var outUB = max(130.0, min(255.0, ub * 0.72 + 90.0))
                if stormScore > 0.62 {
                    let t = (stormScore - 0.62) / 0.38
                    // Darker storm tint while preserving rain geometry.
                    outUR = outUR * (1.0 - 0.88 * t)
                    outUG = outUG * (1.0 - 0.84 * t)
                    outUB = outUB * (1.0 - 0.78 * t)
                }
                let sourceA = Double(alpha) / 255.0
                let outA = max(0.14, min(0.78, sourceA * (0.62 + 0.40 * intensity)))

                ptr[idx] = UInt8(max(0.0, min(255.0, outUR * outA)).rounded())
                ptr[idx + 1] = UInt8(max(0.0, min(255.0, outUG * outA)).rounded())
                ptr[idx + 2] = UInt8(max(0.0, min(255.0, outUB * outA)).rounded())
                ptr[idx + 3] = UInt8(max(0.0, min(255.0, 255.0 * outA)).rounded())
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
                    if ur <= 10.0 && ug <= 10.0 && ub <= 12.0 {
                        rawPtr[idx] = 0
                        rawPtr[idx + 1] = 0
                        rawPtr[idx + 2] = 0
                        rawPtr[idx + 3] = 0
                        continue
                    }
                    let outA = max(0.10, min(0.42, Double(a) / 255.0 * 0.78))
                    let intensity = max(ur, max(ug, ub)) / 255.0
                    let warm = max(0.0, ur - ub) + max(0.0, ug - ub)
                    let stormScore = max(
                        0.0,
                        min(1.0, 0.58 * (warm / 255.0) + 0.42 * intensity)
                    )

                    var outUR = max(14.0, min(96.0, ur * 0.35 + 12.0))
                    var outUG = max(62.0, min(172.0, ug * 0.46 + 40.0))
                    var outUB = max(120.0, min(255.0, ub * 0.62 + 92.0))
                    if stormScore > 0.62 {
                        let t = (stormScore - 0.62) / 0.38
                        outUR = outUR * (1.0 - 0.86 * t)
                        outUG = outUG * (1.0 - 0.82 * t)
                        outUB = outUB * (1.0 - 0.76 * t)
                    }
                    rawPtr[idx] = UInt8(max(0.0, min(255.0, outUR * outA)).rounded())
                    rawPtr[idx + 1] = UInt8(max(0.0, min(255.0, outUG * outA)).rounded())
                    rawPtr[idx + 2] = UInt8(max(0.0, min(255.0, outUB * outA)).rounded())
                    rawPtr[idx + 3] = UInt8(max(0.0, min(255.0, 255.0 * outA)).rounded())
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

        static let forecastTargetAlphaDark: CGFloat = 0.92
        static let forecastTargetAlphaLight: CGFloat = 0.90

        var currentForecastTargetAlpha: CGFloat {
            parent.isDarkTheme ? Self.forecastTargetAlphaDark : Self.forecastTargetAlphaLight
        }

        var currentForecastToneDarkening: CGFloat {
            parent.isDarkTheme ? 0.46 : 0.0
        }

        var parent: UIKitMap
        var firstLocationFix = true
        var lastRadarPath: String?
        var overlay: MKTileOverlay?
        var forecastOverlay: MKTileOverlay?
        var forecastRenderer: ForecastTileRenderer?
        var lastForecastOverlayKey: String?
        var forecastFadeTimer: Timer?
        var pendingForecastPreviousOverlay: MKTileOverlay?
        var pendingForecastPreviousRenderer: ForecastTileRenderer?
        var forecastTransitionToken: Int = 0
        var pendingForecastTransitionRetry: DispatchWorkItem?
        var pendingForecastRetryAttempts: Int = 0
        var pendingForecastMotion: CGPoint = .zero
        var isViewportChanging = false
        var viewportSettledWorkItem: DispatchWorkItem?
        var staticOverlay: RadarImageOverlay?
        var weatherOverlay: WeatherFieldOverlay?
        var lastWeatherSignature: Int?
        var lastUserVisible: Bool = true
        var lastLocatorVisible: Bool = false
        weak var mapView: MKMapView?
        var locatorButton: UIButton?
        var compassButton: MKCompassButton?
        var locatorBottomConstraint: NSLayoutConstraint?
        var locatorTrailingConstraint: NSLayoutConstraint?
        var locatorWidthConstraint: NSLayoutConstraint?
        var locatorHeightConstraint: NSLayoutConstraint?
        var locatorGlyphWidthConstraint: NSLayoutConstraint?
        var locatorGlyphHeightConstraint: NSLayoutConstraint?
        var compassBottomConstraint: NSLayoutConstraint?
        var compassTrailingConstraint: NSLayoutConstraint?
        var compassWidthConstraint: NSLayoutConstraint?
        var compassHeightConstraint: NSLayoutConstraint?
        var locatorGlyphView: UIImageView?
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

        func clearPendingForecastOverlay(on mapView: MKMapView) {
            pendingForecastTransitionRetry?.cancel()
            pendingForecastTransitionRetry = nil
            pendingForecastRetryAttempts = 0
            if let overlay = pendingForecastPreviousOverlay {
                mapView.removeOverlay(overlay)
            }
            pendingForecastPreviousOverlay = nil
            pendingForecastPreviousRenderer = nil
        }

        func setPendingForecastTransition(
            fromOverlay: MKTileOverlay?,
            fromRenderer: ForecastTileRenderer?
        ) {
            pendingForecastPreviousOverlay = fromOverlay
            pendingForecastPreviousRenderer = fromRenderer
            pendingForecastRetryAttempts = 0
        }

        func isIncomingForecastReady(on mapView: MKMapView) -> Bool {
            guard let incomingOverlay = forecastOverlay as? ForecastTileOverlay else {
                return true
            }
            guard let snapshot = Self.makeVisibleTileSnapshot(for: mapView) else {
                return true
            }
            return incomingOverlay.hasCachedCoverage(
                zoom: snapshot.zoom,
                tiles: snapshot.tiles,
                minimumTiles: 2
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
                incomingRenderer.alpha = targetAlpha
                incomingRenderer.toneDarkening = toneDarkening
                incomingRenderer.transitionOffset = .zero
                incomingRenderer.setNeedsDisplay()
                return
            }

            let outgoingRenderer: ForecastTileRenderer? = {
                if let renderer = pendingForecastPreviousRenderer {
                    return renderer
                }
                return mapView.renderer(for: outgoingOverlay) as? ForecastTileRenderer
            }()

            let token = forecastTransitionToken
            pendingForecastRetryAttempts = 0
            // Old renderer can be temporarily unavailable during rapid overlay churn.
            // In that case keep old layer until new one is ready, then swap without fade.
            guard let outgoingRenderer else {
                mapView.removeOverlay(outgoingOverlay)
                pendingForecastPreviousOverlay = nil
                pendingForecastPreviousRenderer = nil
                pendingForecastMotion = .zero
                incomingRenderer.alpha = targetAlpha
                incomingRenderer.toneDarkening = toneDarkening
                incomingRenderer.transitionOffset = .zero
                incomingRenderer.setNeedsDisplay()
                return
            }

            pendingForecastPreviousRenderer = outgoingRenderer
            let duration: TimeInterval = 0.55
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
                let eased = t * t * (3.0 - 2.0 * t)
                incomingRenderer.alpha = targetAlpha * CGFloat(eased)
                outgoingRenderer.alpha = targetAlpha * CGFloat(1.0 - eased)
                incomingRenderer.toneDarkening = toneDarkening
                outgoingRenderer.toneDarkening = toneDarkening
                let effectiveMotion = self.isViewportChanging ? .zero : motion
                incomingRenderer.transitionOffset = CGPoint(
                    x: -effectiveMotion.x * CGFloat(0.35 * (1.0 - eased)),
                    y: -effectiveMotion.y * CGFloat(0.35 * (1.0 - eased))
                )
                outgoingRenderer.transitionOffset = CGPoint(
                    x: effectiveMotion.x * CGFloat(0.35 * eased),
                    y: effectiveMotion.y * CGFloat(0.35 * eased)
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
                let locator = UIButton(type: .system)
                if #available(iOS 15.0, *) {
                    locator.configuration = .plain()
                }
                locator.translatesAutoresizingMaskIntoConstraints = false
                locator.layer.cornerRadius = 11
                locator.clipsToBounds = true
                locator.alpha = 0
                locator.isHidden = true
                locator.addTarget(self, action: #selector(locatorTapped), for: .touchUpInside)
                mapView.addSubview(locator)
                locatorButton = locator

                locatorTrailingConstraint = locator.trailingAnchor.constraint(
                    equalTo: mapView.trailingAnchor,
                    constant: -16
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

                let glyph = UIImageView(
                    image: UIImage(systemName: "location.fill")
                )
                glyph.translatesAutoresizingMaskIntoConstraints = false
                glyph.contentMode = .scaleAspectFit
                glyph.isUserInteractionEnabled = false
                locator.addSubview(glyph)
                locatorGlyphWidthConstraint = glyph.widthAnchor.constraint(equalToConstant: max(20, controlSide * 0.38))
                locatorGlyphHeightConstraint = glyph.heightAnchor.constraint(equalToConstant: max(20, controlSide * 0.38))
                NSLayoutConstraint.activate([
                    glyph.centerXAnchor.constraint(equalTo: locator.centerXAnchor),
                    glyph.centerYAnchor.constraint(equalTo: locator.centerYAnchor),
                    locatorGlyphWidthConstraint,
                    locatorGlyphHeightConstraint
                ].compactMap { $0 })
                locatorGlyphView = glyph
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
                    equalTo: mapView.trailingAnchor,
                    constant: -16
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
            let plateColor = isDarkTheme
                ? UIColor.black.withAlphaComponent(0.28)
                : UIColor.white.withAlphaComponent(0.60)

            if let locatorButton {
                // Hide default glyph and draw a filled locator icon on top.
                locatorButton.tintColor = .clear
                styleCircularLocator(
                    locatorButton,
                    plateColor: plateColor
                )
                locatorGlyphView?.tintColor = tintColor
            }

            if let compassButton {
                compassButton.tintColor = tintColor
                styleCircularCompass(
                    compassButton,
                    plateColor: plateColor
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
            control.layer.borderWidth = 0
            control.layer.borderColor = UIColor.clear.cgColor
            control.backgroundColor = plateColor
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
            control.layer.borderWidth = 0
            control.layer.borderColor = UIColor.clear.cgColor
            control.backgroundColor = plateColor
        }

        @objc
        private func locatorTapped() {
            guard let mapView else { return }
            recenterToUser(on: mapView, resetZoom: false)
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
            let controlBottomInset = mapView.safeAreaInsets.bottom + max(16, parent.bottomReservedSpace - 10)
            locatorBottomConstraint?.constant = -controlBottomInset
            let controlSide = controlButtonSide(for: mapView)
            locatorWidthConstraint?.constant = controlSide
            locatorHeightConstraint?.constant = controlSide
            compassWidthConstraint?.constant = controlSide
            compassHeightConstraint?.constant = controlSide
            let glyphSide = max(20, controlSide * 0.38)
            locatorGlyphWidthConstraint?.constant = glyphSide
            locatorGlyphHeightConstraint?.constant = glyphSide
            if let locatorButton {
                styleCircularLocator(locatorButton, plateColor: locatorButton.backgroundColor ?? .clear)
            }
            if let compassButton {
                styleCircularCompass(compassButton, plateColor: compassButton.backgroundColor ?? .clear)
            }
        }

        private func controlButtonSide(for mapView: MKMapView) -> CGFloat {
            let minSide = min(mapView.bounds.width, mapView.bounds.height)
            if minSide >= 820 { return 82 }
            if minSide >= 620 { return 76 }
            return 68
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
            guard let snapshot = Self.makeVisibleTileSnapshot(for: mapView) else { return }
            guard snapshot.signature != lastVisibleTileSignature else { return }
            lastVisibleTileSignature = snapshot.signature
            DispatchQueue.main.async { [weak self] in
                self?.parent.onVisibleTilesChanged?(snapshot)
            }
        }

        func scheduleVisibleTileSnapshot(for mapView: MKMapView) {
            visibleTileWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.publishVisibleTileSnapshot(for: mapView)
            }
            visibleTileWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
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

            if let weatherOverlay = overlay as? WeatherFieldOverlay {
                return WeatherFieldRenderer(overlay: weatherOverlay)
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
                    startPendingForecastTransitionIfPossible(on: mapView)
                    return renderer
                }

                renderer.alpha = targetAlpha
                renderer.toneDarkening = toneDarkening
                renderer.transitionOffset = .zero
                return renderer
            }

            if let tile = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tile)
                renderer.alpha = 0.65
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
            syncControlsState(for: mapView)
            scheduleVisibleTileSnapshot(for: mapView)
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
