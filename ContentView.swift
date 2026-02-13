import SwiftUI
import MapKit

struct ContentView: View {

    @Environment(\.colorScheme) private var colorScheme
    @StateObject var locationManager = LocationManager()

    @State private var userTracking = true
    @State private var userVisible = true
    @State private var weatherHeaderHeight: CGFloat = 0
    @State private var timeWheelHeight: CGFloat = 64
    @State private var forecastTileTemplate: String?
    @State private var forecastTileMinZoom = 0
    @State private var forecastTileMaxZoom = 6
    @State private var forecastFrameCache: [Int: CloudOverlayService.ForecastFrame] = [:]
    @State private var latestForecastRequestHour: Int?
    @State private var forecastFrameRequestsInFlight: Set<Int> = []
    @State private var forecastRefreshWorkItem: DispatchWorkItem?
    @State private var forecastPrefetchWorkItem: DispatchWorkItem?
    @State private var forecastBackgroundPrefetchWorkItem: DispatchWorkItem?
    @State private var visibleTileSnapshot: UIKitMap.VisibleTileSnapshot?
    @State private var prefetchedOverlayKeys: Set<String> = []
    @State private var lastWeatherRequestKey: String?
    @State private var lastWeatherRequestAt: Date = .distantPast
    @State private var weatherRequestInFlight = false
    @State private var overlayApplyWorkItem: DispatchWorkItem?
    @State private var lastOverlayAppliedAt: Date = .distantPast
    @State private var pendingOverlayHourStamp: Int?

    @State private var selectedHour =
        Calendar.current.component(.hour, from: Date())

    @State private var temperature = "--"
    @State private var wind = "--"
    @State private var humidity = "--"
    @State private var feelsLike = "--"
    @State private var weatherIcon = "cloud"
    @State private var weatherText = "--"
    @State private var hourlyWeather: WeatherData.Hourly?
    @State private var radarFallbackPath: String?
    private let forecastOverlayDebounce: TimeInterval = 0.08
    private let minOverlaySwitchInterval: TimeInterval = 0.0
    private let overlayDebugPrefix = "☁️DBG"

    var body: some View {
        ZStack {

            UIKitMap(
                userTracking: $userTracking,
                userVisible: $userVisible,
                isDarkTheme: isDarkTheme,
                topReservedSpace: weatherHeaderHeight + 16,
                bottomReservedSpace: timeWheelHeight + 20,
                location: locationManager.location,
                radarFramePath: (forecastTileTemplate == nil ? radarFallbackPath : nil),
                cloudCells: [],
                forecastTileTemplate: forecastTileTemplate,
                forecastTileMinZoom: forecastTileMinZoom,
                forecastTileMaxZoom: forecastTileMaxZoom,
                useStaticOverlay: false,
                staticOverlayAssetName: "Image",
                onVisibleTilesChanged: { snapshot in
                    visibleTileSnapshot = snapshot
                    scheduleForecastTilePrefetch(delay: 0.02)
                }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {

                weatherHeader
                    .padding(.top, 20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: WeatherHeaderHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )

                Spacer()

                TimeWheel(
                    selectedHour: $selectedHour,
                    isDarkTheme: isDarkTheme,
                    rainIntensityByHour: wheelRainIntensityByHour(reference: Date())
                )
                    .frame(height: 64)
                    .padding(.horizontal, 20)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TimeWheelHeightKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
            }
        }
        .onPreferenceChange(WeatherHeaderHeightKey.self) { value in
            weatherHeaderHeight = value
        }
        .onPreferenceChange(TimeWheelHeightKey.self) { value in
            timeWheelHeight = value
        }

        .onAppear {
            print("☁️DBG build=edge-cleanup-v32")
            scheduleForecastOverlayRefresh(delay: 0)
            scheduleForecastTilePrefetch(delay: 0.05)
            RadarService.fetchLatestRadarPath { path in
                radarFallbackPath = path
            }
        }

        // MARK: Weather update
        .onChange(of: locationManager.location) { _, loc in
            guard let loc else { return }
            refreshWeather(for: loc)
            scheduleForecastOverlayRefresh(delay: 0.10)
            scheduleForecastTilePrefetch(delay: 0.05)
        }
        .onChange(of: selectedHour) { _, _ in
            applySelectedHourForecast()
            scheduleForecastOverlayRefresh(delay: forecastOverlayDebounce)
            scheduleForecastTilePrefetch(delay: 0.0)
        }

        .animation(.easeInOut(duration: 0.25), value: userVisible)
    }

    private var isDarkTheme: Bool {
        colorScheme == .dark
    }

    // MARK: Weather Header UI
    var weatherHeader: some View {
        let cardShape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let primaryText = isDarkTheme ? Color.white : Color.black
        let heroWidth: CGFloat = 118

        return VStack(alignment: .leading, spacing: 18) {

            Text(locationManager.city)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryText.opacity(0.9))

            HStack(spacing: 16) {

                HStack(spacing: 10) {
                    Text(temperature)
                        .font(.system(size: 76, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(primaryText)
                        .frame(width: heroWidth, alignment: .trailing)

                    Image(systemName: weatherIcon)
                        .font(.system(size: 70, weight: .regular))
                        .foregroundStyle(primaryText)
                        .frame(width: heroWidth, alignment: .leading)
                }

                Spacer()

                Text(twoLineWeatherText(weatherText))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(width: 140, alignment: .leading)
            }

            HStack {
                weatherMetric("Feels like", feelsLike, "thermometer")
                Spacer()
                weatherMetric("Wind", wind, "wind")
                Spacer()
                weatherMetric("Humidity", humidity, "drop")
            }
        }
        .padding(20)
        .background(
            ZStack {
                cardShape
                    .fill(.ultraThinMaterial)

                cardShape
                    .fill(
                        LinearGradient(
                            colors: isDarkTheme
                                ? [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.05),
                                    Color.white.opacity(0.12)
                                ]
                                : [
                                    Color.white.opacity(0.36),
                                    Color.white.opacity(0.14),
                                    Color.white.opacity(0.26)
                                ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                cardShape
                    .strokeBorder(
                        LinearGradient(
                            colors: isDarkTheme
                                ? [
                                    Color.white.opacity(0.36),
                                    Color.white.opacity(0.10)
                                ]
                                : [
                                    Color.black.opacity(0.20),
                                    Color.black.opacity(0.06)
                                ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
        )
        .clipShape(cardShape)
        .allowsHitTesting(false)
        .padding(.horizontal, 20)
    }

    func weatherMetric(_ title: String,
                       _ value: String,
                       _ icon: String) -> some View {
        let primaryText = isDarkTheme ? Color.white : Color.black
        let secondaryText = isDarkTheme ? Color.white.opacity(0.7) : Color.black.opacity(0.68)

        return HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(secondaryText)
                .frame(width: 24, height: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(secondaryText)

                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
            }
        }
    }

    private func twoLineWeatherText(_ text: String) -> String {
        let words = text.split(separator: " ")
        guard words.count > 1 else { return text }
        return "\(words[0])\n\(words.dropFirst().joined(separator: " "))"
    }

    func weatherInfo(from code: Int) -> (String, String) {
        switch code {
        case 0: return ("sun.max", "Clear")
        case 1, 2: return ("cloud.sun", "Partly Cloudy")
        case 3: return ("cloud", "Cloudy")
        case 45, 48: return ("cloud.fog", "Fog")
        case 51...67: return ("cloud.drizzle", "Drizzle")
        case 71...77: return ("snow", "Snow")
        case 80...82: return ("cloud.rain", "Rain")
        case 95...99: return ("cloud.bolt.rain", "Storm")
        default: return ("cloud", "Cloudy")
        }
    }

    private func applySelectedHourForecast() {
        guard let hourly = hourlyWeather else { return }
        guard !hourly.temperature_2m.isEmpty else { return }

        let now = Date()
        guard let offset = wheelHourOffset(for: selectedHour, reference: now) else { return }
        guard let targetDate = targetDateForSelectedHour(reference: now) else { return }

        let parsedTimes = hourly.time.compactMap { Self.hourlyDateFormatter.date(from: $0) }
        let timeBasedIndex = parsedTimes.firstIndex(where: { $0 >= targetDate })

        let idx = min(max(0, timeBasedIndex ?? offset), hourly.temperature_2m.count - 1)
        guard idx < hourly.apparent_temperature.count else { return }
        guard idx < hourly.wind_speed_10m.count else { return }
        guard idx < hourly.relative_humidity_2m.count else { return }
        guard idx < hourly.weather_code.count else { return }

        temperature = "\(Int(hourly.temperature_2m[idx]))°"
        feelsLike = "\(Int(hourly.apparent_temperature[idx]))°"
        wind = "\(Int(hourly.wind_speed_10m[idx])) km/h"
        humidity = "\(hourly.relative_humidity_2m[idx])%"

        let info = weatherInfo(from: hourly.weather_code[idx])
        weatherIcon = info.0
        weatherText = info.1
    }

    private func wheelHourOffset(for hour: Int, reference: Date) -> Int? {
        let nowHour = Calendar.current.component(.hour, from: reference)
        let wheelHours = (0..<7).map { (nowHour + $0) % 24 }
        return wheelHours.firstIndex(of: hour)
    }

    private func refreshForecastOverlay() {
        guard let targetDate = targetDateForSelectedHour(reference: Date()) else { return }
        let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)
        latestForecastRequestHour = hourStamp

        print(
            overlayDebugPrefix,
            "refresh start",
            "selectedHour=\(selectedHour)",
            "hourStamp=\(hourStamp)",
            "hasCache=\(forecastFrameCache[hourStamp] != nil)",
            "inFlight=\(forecastFrameRequestsInFlight.contains(hourStamp))"
        )

        if let cached = forecastFrameCache[hourStamp] {
            print(overlayDebugPrefix, "use cached frame", hourStamp)
            applyForecastFrame(cached, hourStamp: hourStamp)
            scheduleForecastTilePrefetch(delay: 0.0)
            return
        }

        if forecastFrameRequestsInFlight.contains(hourStamp) {
            print(overlayDebugPrefix, "skip fetch (already in-flight)", hourStamp)
            if forecastFrameCache[hourStamp] == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    guard latestForecastRequestHour == hourStamp else { return }
                    if let cached = forecastFrameCache[hourStamp] {
                        print(overlayDebugPrefix, "late apply from in-flight cache", hourStamp)
                        applyForecastFrame(cached, hourStamp: hourStamp)
                        scheduleForecastTilePrefetch(delay: 0.0)
                    } else if !forecastFrameRequestsInFlight.contains(hourStamp) {
                        print(overlayDebugPrefix, "in-flight finished without cache, retry", hourStamp)
                        refreshForecastOverlay()
                    }
                }
            }
            return
        }
        forecastFrameRequestsInFlight.insert(hourStamp)
        print(overlayDebugPrefix, "fetch start", hourStamp)

        CloudOverlayService.fetchForecastFrame(
            targetDate: targetDate,
            near: locationManager.location?.coordinate
        ) { result in
            forecastFrameRequestsInFlight.remove(hourStamp)

            switch result {
            case .success(let frame):
                let frameHour = Int(frame.time.timeIntervalSince1970 / 3600)
                print(
                    overlayDebugPrefix,
                    "fetch success",
                    "requested=\(hourStamp)",
                    "frameHour=\(frameHour)",
                    "signal=\(frame.hasLikelySignal)"
                )
                forecastFrameCache[hourStamp] = frame
                if latestForecastRequestHour == hourStamp {
                    applyForecastFrame(frame, hourStamp: hourStamp)
                }
                scheduleForecastTilePrefetch(delay: 0.0)
            case .failure(let reason):
                print(overlayDebugPrefix, "fetch failed", hourStamp, reason)
                print("☁️ Forecast tiles failed:", reason)
            }
        }
    }

    private func scheduleForecastOverlayRefresh(delay: TimeInterval) {
        forecastRefreshWorkItem?.cancel()

        let work = DispatchWorkItem {
            refreshForecastOverlay()
        }
        forecastRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleForecastTilePrefetch(delay: TimeInterval) {
        forecastPrefetchWorkItem?.cancel()
        forecastBackgroundPrefetchWorkItem?.cancel()
        let work = DispatchWorkItem {
            prefetchForecastTilesAroundCurrentView()
        }
        forecastPrefetchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func prefetchForecastTilesAroundCurrentView() {
        guard let snapshot = visibleTileSnapshot else { return }
        guard !snapshot.tiles.isEmpty else { return }

        let now = Date()
        guard let selectedDate = targetDateForSelectedHour(reference: now) else { return }
        let selectedHourStamp = Int(selectedDate.timeIntervalSince1970 / 3600)
        var prefetchDates = wheelHourDates(reference: now)
        if !prefetchDates.contains(where: { Int($0.timeIntervalSince1970 / 3600) == selectedHourStamp }) {
            prefetchDates.append(selectedDate)
        }
        // Phase 1: first warm the currently selected hour under the user.
        prefetchHour(
            selectedDate,
            snapshot: snapshot,
            requestedZooms: [snapshot.zoom],
            renderedTileBudget: 8,
            visibleTileLimit: 48,
            sourceTileLimit: 10,
            fetchIfMissing: true,
            applyIfLatest: true
        )

        // Phase 2: then (with delay) warm nearby hours in background.
        let backgroundDates = prefetchDates.filter {
            Int($0.timeIntervalSince1970 / 3600) != selectedHourStamp
        }
        let work = DispatchWorkItem {
            for targetDate in backgroundDates {
                let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)
                let distance = abs(hourStamp - selectedHourStamp)
                guard distance <= 2 else { continue }

                prefetchHour(
                    targetDate,
                    snapshot: snapshot,
                    requestedZooms: [snapshot.zoom],
                    renderedTileBudget: distance <= 1 ? 4 : 2,
                    visibleTileLimit: distance <= 1 ? 24 : 12,
                    sourceTileLimit: distance <= 1 ? 6 : 4,
                    fetchIfMissing: distance <= 1,
                    applyIfLatest: false
                )
            }
        }
        forecastBackgroundPrefetchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func prefetchHour(
        _ targetDate: Date,
        snapshot: UIKitMap.VisibleTileSnapshot,
        requestedZooms: [Int],
        renderedTileBudget: Int,
        visibleTileLimit: Int,
        sourceTileLimit: Int,
        fetchIfMissing: Bool,
        applyIfLatest: Bool
    ) {
        let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)

        if let frame = forecastFrameCache[hourStamp] {
            prefetchTiles(
                for: frame,
                hourStamp: hourStamp,
                snapshot: snapshot,
                requestedZooms: requestedZooms,
                renderedTileBudget: renderedTileBudget,
                visibleTileLimit: visibleTileLimit,
                sourceTileLimit: sourceTileLimit
            )
            return
        }

        guard fetchIfMissing else { return }
        if forecastFrameRequestsInFlight.contains(hourStamp) { return }
        forecastFrameRequestsInFlight.insert(hourStamp)

        CloudOverlayService.fetchForecastFrame(
            targetDate: targetDate,
            near: locationManager.location?.coordinate
        ) { result in
            forecastFrameRequestsInFlight.remove(hourStamp)
            guard case .success(let frame) = result else { return }
            forecastFrameCache[hourStamp] = frame
            if applyIfLatest, latestForecastRequestHour == hourStamp {
                print(overlayDebugPrefix, "prefetch apply latest hour", hourStamp)
                applyForecastFrame(frame, hourStamp: hourStamp)
            }
            prefetchTiles(
                for: frame,
                hourStamp: hourStamp,
                snapshot: snapshot,
                requestedZooms: requestedZooms,
                renderedTileBudget: renderedTileBudget,
                visibleTileLimit: visibleTileLimit,
                sourceTileLimit: sourceTileLimit
            )
        }
    }

    private func prefetchTiles(
        for frame: CloudOverlayService.ForecastFrame,
        hourStamp: Int,
        snapshot: UIKitMap.VisibleTileSnapshot,
        requestedZooms: [Int],
        renderedTileBudget: Int,
        visibleTileLimit: Int,
        sourceTileLimit: Int
    ) {
        for requestedZoom in requestedZooms {
            let projectedTiles = projectVisibleTiles(
                snapshot.tiles,
                fromZoom: snapshot.zoom,
                toZoom: requestedZoom,
                limit: max(visibleTileLimit, sourceTileLimit * 2)
            )
            guard !projectedTiles.isEmpty else { continue }
            let prioritizedTiles = prioritizeVisibleTiles(projectedTiles, zoom: requestedZoom)
            let visibleTiles = Array(prioritizedTiles.prefix(visibleTileLimit))
            guard !visibleTiles.isEmpty else { continue }

            let sourceZ = min(max(requestedZoom, frame.minZoom), frame.maxZoom)
            let zoomDelta = max(0, requestedZoom - sourceZ)
            let sourceN = 1 << sourceZ
            guard sourceN > 0 else { continue }

            var sourceTiles = Set<UIKitMap.VisibleTile>()
            for tile in visibleTiles {
                let sourceX = ((tile.x >> zoomDelta) % sourceN + sourceN) % sourceN
                let sourceY = tile.y >> zoomDelta
                guard sourceY >= 0 && sourceY < sourceN else { continue }
                sourceTiles.insert(UIKitMap.VisibleTile(x: sourceX, y: sourceY))
                if sourceTiles.count >= sourceTileLimit { break }
            }
            guard !sourceTiles.isEmpty else { continue }

            let signature = visibleTilesSignature(zoom: requestedZoom, tiles: visibleTiles)
            let key = "\(hourStamp)|rqz\(requestedZoom)|src\(sourceZ)|sig\(signature)"
            if prefetchedOverlayKeys.contains(key) { continue }
            prefetchedOverlayKeys.insert(key)
            if prefetchedOverlayKeys.count > 1400 {
                prefetchedOverlayKeys.removeAll(keepingCapacity: true)
            }

            for tile in sourceTiles {
                UIKitMap.ForecastTileOverlay.prewarmTile(
                    template: frame.tileTemplate,
                    z: sourceZ,
                    x: tile.x,
                    y: tile.y
                )
            }

            let perZoomBudget = (requestedZoom == snapshot.zoom)
                ? renderedTileBudget
                : max(4, renderedTileBudget / 2)

            for tile in visibleTiles.prefix(perZoomBudget) {
                UIKitMap.ForecastTileOverlay.prewarmRenderedTile(
                    template: frame.tileTemplate,
                    minSourceZ: frame.minZoom,
                    maxSourceZ: frame.maxZoom,
                    requestedZoom: requestedZoom,
                    x: tile.x,
                    y: tile.y
                )
            }
        }
    }

    private func prioritizeVisibleTiles(
        _ tiles: [UIKitMap.VisibleTile],
        zoom: Int
    ) -> [UIKitMap.VisibleTile] {
        guard !tiles.isEmpty else { return [] }

        let anchor: (x: Double, y: Double)
        if let coordinate = locationManager.location?.coordinate,
           let userTile = tileForCoordinate(coordinate, zoom: zoom)
        {
            anchor = (Double(userTile.x), Double(userTile.y))
        } else {
            let centerX = Double(tiles.reduce(0) { $0 + $1.x }) / Double(tiles.count)
            let centerY = Double(tiles.reduce(0) { $0 + $1.y }) / Double(tiles.count)
            anchor = (centerX, centerY)
        }

        return tiles.sorted { lhs, rhs in
            let ldx = Double(lhs.x) - anchor.x
            let ldy = Double(lhs.y) - anchor.y
            let rdx = Double(rhs.x) - anchor.x
            let rdy = Double(rhs.y) - anchor.y
            return (ldx * ldx + ldy * ldy) < (rdx * rdx + rdy * rdy)
        }
    }

    private func tileForCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        zoom: Int
    ) -> UIKitMap.VisibleTile? {
        guard zoom >= 0 else { return nil }
        let lat = max(-85.05112878, min(85.05112878, coordinate.latitude))
        let lon = coordinate.longitude
        let scale = pow(2.0, Double(zoom))
        let n = Int(scale)
        guard n > 0 else { return nil }

        let xFloat = (lon + 180.0) / 360.0 * scale
        let latRad = lat * .pi / 180.0
        let mercN = log(tan(.pi / 4.0 + latRad / 2.0))
        let yFloat = (1.0 - mercN / .pi) / 2.0 * scale

        let x = ((Int(floor(xFloat)) % n) + n) % n
        let y = max(0, min(n - 1, Int(floor(yFloat))))
        return UIKitMap.VisibleTile(x: x, y: y)
    }

    private func wheelHourDates(reference: Date) -> [Date] {
        let calendar = Calendar.current
        let nowHour = calendar.component(.hour, from: reference)
        let base = calendar.date(
            bySettingHour: nowHour,
            minute: 0,
            second: 0,
            of: reference
        ) ?? reference
        return (0..<7).compactMap { calendar.date(byAdding: .hour, value: $0, to: base) }
    }

    private func wheelRainIntensityByHour(reference: Date) -> [Int: Double] {
        guard let hourly = hourlyWeather else { return [:] }
        guard !hourly.time.isEmpty else { return [:] }

        let parsedTimes = hourly.time.compactMap { Self.hourlyDateFormatter.date(from: $0) }
        guard !parsedTimes.isEmpty else { return [:] }

        let calendar = Calendar.current
        var result: [Int: Double] = [:]
        let precipitation = hourly.precipitation ?? []

        for slotDate in wheelHourDates(reference: reference) {
            let targetIndex = parsedTimes.firstIndex(where: { $0 >= slotDate })
                ?? parsedTimes.indices.last
            guard let targetIndex else { continue }

            let slotHour = calendar.component(.hour, from: slotDate)
            let slotHourStamp = Int(slotDate.timeIntervalSince1970 / 3600)
            let hasLocalCloudSignal = forecastFrameCache[slotHourStamp]?.hasLikelySignal == true
            guard hasLocalCloudSignal else {
                result[slotHour] = 0
                continue
            }
            let amount = targetIndex < precipitation.count
                ? max(0, precipitation[targetIndex])
                : 0
            result[slotHour] = min(3.2, max(0.35, amount * 1.05))
        }

        return result
    }

    private func visibleTilesSignature(
        zoom: Int,
        tiles: [UIKitMap.VisibleTile]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(zoom)
        hasher.combine(tiles.count)
        for tile in tiles.prefix(96) {
            hasher.combine(tile.x)
            hasher.combine(tile.y)
        }
        return hasher.finalize()
    }

    private func projectVisibleTiles(
        _ tiles: [UIKitMap.VisibleTile],
        fromZoom: Int,
        toZoom: Int,
        limit: Int
    ) -> [UIKitMap.VisibleTile] {
        guard !tiles.isEmpty, limit > 0 else { return [] }
        if fromZoom == toZoom {
            return Array(tiles.prefix(limit))
        }

        if toZoom < fromZoom {
            let shift = fromZoom - toZoom
            var seen = Set<UIKitMap.VisibleTile>()
            var out: [UIKitMap.VisibleTile] = []
            out.reserveCapacity(min(limit, tiles.count))
            for tile in tiles {
                let projected = UIKitMap.VisibleTile(
                    x: tile.x >> shift,
                    y: tile.y >> shift
                )
                if seen.insert(projected).inserted {
                    out.append(projected)
                    if out.count >= limit { break }
                }
            }
            return out
        }

        let scale = 1 << (toZoom - fromZoom)
        var seen = Set<UIKitMap.VisibleTile>()
        var out: [UIKitMap.VisibleTile] = []
        out.reserveCapacity(limit)
        for tile in tiles {
            let baseX = tile.x * scale
            let baseY = tile.y * scale
            for dy in 0..<scale {
                for dx in 0..<scale {
                    let projected = UIKitMap.VisibleTile(
                        x: baseX + dx,
                        y: baseY + dy
                    )
                    if seen.insert(projected).inserted {
                        out.append(projected)
                        if out.count >= limit { return out }
                    }
                }
            }
        }
        return out
    }

    private func refreshWeather(for location: CLLocation) {
        let roundedLat = (location.coordinate.latitude * 10).rounded() / 10
        let roundedLon = (location.coordinate.longitude * 10).rounded() / 10
        let requestKey = "\(roundedLat)_\(roundedLon)"

        if weatherRequestInFlight { return }

        let minInterval: TimeInterval = 30
        if requestKey == lastWeatherRequestKey &&
            Date().timeIntervalSince(lastWeatherRequestAt) < minInterval
        {
            return
        }

        weatherRequestInFlight = true
        lastWeatherRequestKey = requestKey
        lastWeatherRequestAt = Date()

        WeatherService.fetchWeather(location: location) { weather in
            weatherRequestInFlight = false
            guard let w = weather else { return }

            DispatchQueue.main.async {
                temperature = "\(Int(w.current.temperature_2m))°"
                feelsLike = "\(Int(w.current.apparent_temperature))°"
                wind = "\(Int(w.current.wind_speed_10m)) km/h"
                humidity = "\(w.current.relative_humidity_2m)%"
                hourlyWeather = w.hourly

                let info = weatherInfo(from: w.current.weather_code)
                weatherIcon = info.0
                weatherText = info.1

                applySelectedHourForecast()
            }
        }
    }

    private func applyForecastFrame(
        _ frame: CloudOverlayService.ForecastFrame,
        hourStamp: Int
    ) {
        let frameHour = Int(frame.time.timeIntervalSince1970 / 3600)
        print("☁️ Forecast frame:", frameHour, "for:", hourStamp)

        // Keep the last working overlay if local signal is absent for this hour.
        if !frame.hasLikelySignal, forecastTileTemplate != nil {
            print("☁️ Forecast frame skipped (no local signal):", frameHour)
            return
        }

        scheduleOverlayApply(frame)
    }

    private func scheduleOverlayApply(
        _ frame: CloudOverlayService.ForecastFrame
    ) {
        overlayApplyWorkItem?.cancel()

        let currentKey = "\(forecastTileTemplate ?? "")|\(forecastTileMinZoom)|\(forecastTileMaxZoom)"
        let incomingKey = "\(frame.tileTemplate)|\(frame.minZoom)|\(frame.maxZoom)"
        let hourStamp = Int(frame.time.timeIntervalSince1970 / 3600)
        if currentKey == incomingKey {
            print(overlayDebugPrefix, "schedule skip same key", "hour=\(hourStamp)")
            return
        }

        print(
            overlayDebugPrefix,
            "schedule apply",
            "hour=\(hourStamp)",
            "current=\(overlayTemplateToken(from: currentKey))",
            "incoming=\(overlayTemplateToken(from: incomingKey))"
        )
        pendingOverlayHourStamp = hourStamp

        let work = DispatchWorkItem {
            applyForecastFrameWhenReady(
                frame,
                hourStamp: hourStamp,
                attempt: 0
            )
        }
        overlayApplyWorkItem = work
        if minOverlaySwitchInterval <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            let elapsed = Date().timeIntervalSince(lastOverlayAppliedAt)
            let neededGap = forecastTileTemplate == nil ? 0 : minOverlaySwitchInterval
            let delay = max(0, neededGap - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func applyForecastFrameWhenReady(
        _ frame: CloudOverlayService.ForecastFrame,
        hourStamp: Int,
        attempt: Int
    ) {
        guard pendingOverlayHourStamp == hourStamp else {
            print("☁️ Overlay skip pending-mismatch:", hourStamp, "pending:", pendingOverlayHourStamp ?? -1)
            return
        }

        let currentKey = "\(forecastTileTemplate ?? "")|\(forecastTileMinZoom)|\(forecastTileMaxZoom)"
        let incomingKey = "\(frame.tileTemplate)|\(frame.minZoom)|\(frame.maxZoom)"
        if currentKey == incomingKey {
            print("☁️ Overlay skip same-key:", hourStamp)
            print(overlayDebugPrefix, "apply skip same key", "hour=\(hourStamp)")
            return
        }

        print("☁️ Overlay APPLY:", hourStamp, "key:", incomingKey)
        print(overlayDebugPrefix, "apply success", "hour=\(hourStamp)")
        forecastTileTemplate = frame.tileTemplate
        forecastTileMinZoom = frame.minZoom
        forecastTileMaxZoom = frame.maxZoom
        lastOverlayAppliedAt = Date()
        pendingOverlayHourStamp = nil
    }

    private func targetDateForSelectedHour(reference: Date) -> Date? {
        let calendar = Calendar.current
        let nowHour = calendar.component(.hour, from: reference)
        guard let offset = wheelHourOffset(for: selectedHour, reference: reference) else {
            return nil
        }

        let startOfHour = calendar.date(
            bySettingHour: nowHour,
            minute: 0,
            second: 0,
            of: reference
        ) ?? reference

        return calendar.date(byAdding: .hour, value: offset, to: startOfHour)
    }

    private static let hourlyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private func overlayTemplateToken(from key: String) -> String {
        if let stamp = key.split(separator: "/").first(where: { $0.count == 12 && $0.allSatisfy(\.isNumber) }) {
            return String(stamp)
        }
        return String(key.prefix(36))
    }
}

private struct WeatherHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TimeWheelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 64

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
