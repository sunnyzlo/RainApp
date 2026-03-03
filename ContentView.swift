import SwiftUI
import MapKit

struct ContentView: View {

    @Environment(\.colorScheme) private var colorScheme
    @StateObject var locationManager = LocationManager()
    @Binding var selectedHour: Int
    var showsTimeWheel: Bool = true

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
    @State private var lastPrefetchZoom: Int?
    @State private var isViewportZooming = false
    @State private var zoomSettleWorkItem: DispatchWorkItem?
    @State private var prefetchedOverlayKeys: Set<String> = []
    @State private var lastWeatherRequestKey: String?
    @State private var lastWeatherRequestAt: Date = .distantPast
    @State private var weatherRequestInFlight = false
    @State private var overlayApplyWorkItem: DispatchWorkItem?
    @State private var lastOverlayAppliedAt: Date = .distantPast
    @State private var pendingOverlayHourStamp: Int?
    @State private var lastAppliedOverlayHourStamp: Int?
    @State private var showStartupSplash = true
    @State private var startupSplashInitialized = false
    @State private var startupMinDelayPassed = false
    @State private var hasAppliedFirstForecastOverlay = false

    @State private var temperature = "--"
    @State private var wind = "--"
    @State private var humidity = "--"
    @State private var feelsLike = "--"
    @State private var temperatureCelsius: Double?
    @State private var feelsLikeCelsius: Double?
    @State private var useFahrenheit = false
    @State private var weatherIcon = "cloud"
    @State private var weatherText = "--"
    @State private var selectedHourIsDay = true
    @State private var hourlyWeather: WeatherData.Hourly?
    @State private var cloudCoverTotal: Double = 0
    @State private var cloudCoverLow: Double = 0
    @State private var cloudCoverMid: Double = 0
    @State private var cloudCoverHigh: Double = 0
    @State private var cloudCells: [CloudOverlayService.CloudCell] = []
    @State private var cloudFieldRefreshWorkItem: DispatchWorkItem?
    @State private var cloudFieldRequestNonce: Int = 0
    @State private var cloudFieldLastRequestAt: Date = .distantPast
    @State private var cloudFieldLastQueryKey: String?
    @State private var cloudFieldBackoffUntil: Date = .distantPast
    @State private var cloudField429Streak: Int = 0
    @State private var cloudFieldLastNonEmptyCells: [CloudOverlayService.CloudCell] = []
    @State private var cloudFieldResultCache: [String: [CloudOverlayService.CloudCell]] = [:]
    @State private var selectedCloudModel: CloudFieldService.Model = .icon
    @State private var radarFallbackPath: String?
    @State private var lastKnownProbeCoordinate: CLLocationCoordinate2D?
    @State private var isWheelScrubbing = false
    @State private var wheelScrubRefreshWorkItem: DispatchWorkItem?
    @State private var wheelDotColorsByHour: [Int: Color] = [:]
    @State private var wheelDotColorByHourStamp: [Int: Color?] = [:]
    @State private var wheelDotRequestsInFlight: Set<Int> = []
    private let forecastOverlayDebounce: TimeInterval = 0.22
    private let minOverlaySwitchInterval: TimeInterval = 0.20
    private let maxConcurrentFrameFetches = 1
    // Aggressive prefetch can overload local backend and break smooth hour switching.
    private let forecastPrefetchEnabled = false
    private let overlayDebugPrefix = "☁️DBG"
    private let startupSplashMinDuration: TimeInterval = 2.0
    private let startupSplashMaxDuration: TimeInterval = 8.0
    private let timeWheelSlotCount = 12 // must match TimeWheel.slotCount

    var body: some View {
        GeometryReader { proxy in
            let topOverlayPadding: CGFloat = 10

            ZStack(alignment: .top) {
                UIKitMap(
                    userTracking: $userTracking,
                    userVisible: $userVisible,
                    isDarkTheme: isDarkTheme,
                    topReservedSpace: showStartupSplash ? 0 : (weatherHeaderHeight + topOverlayPadding),
                    bottomReservedSpace: showStartupSplash ? 0 : (timeWheelHeight + 16),
                    location: locationManager.location,
                    radarFramePath: nil,
                    cloudCells: cloudCells,
                    cloudTime: targetDateForSelectedHour(reference: Date()),
                    forecastTileTemplate: forecastTileTemplate,
                    forecastTileMinZoom: forecastTileMinZoom,
                    forecastTileMaxZoom: forecastTileMaxZoom,
                    useStaticOverlay: false,
                    staticOverlayAssetName: "Image",
                    onVisibleTilesChanged: { snapshot in
                        visibleTileSnapshot = snapshot
                        let previousZoom = lastPrefetchZoom
                        lastPrefetchZoom = snapshot.zoom
                        if forecastTileTemplate != nil {
                            if let previousZoom, snapshot.zoom != previousZoom {
                                isViewportZooming = true
                                zoomSettleWorkItem?.cancel()
                                let settle = DispatchWorkItem {
                                    isViewportZooming = false
                                }
                                zoomSettleWorkItem = settle
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: settle)
                                // Skip prefetch during zoom gestures; it causes stutter on device.
                                return
                            }
                            scheduleForecastTilePrefetch(delay: 0.08)
                        }
                    }
                )
                .ignoresSafeArea()

                if !showStartupSplash {
                    weatherHeader
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .background(
                            GeometryReader { headerProxy in
                                Color.clear.preference(
                                    key: WeatherHeaderHeightKey.self,
                                    value: headerProxy.size.height
                                )
                            }
                        )
                        .padding(.top, topOverlayPadding)
                }

                // Cloud model picker is hidden in backend tile mode.

                if showStartupSplash {
                    startupSplashView
                        .transition(.opacity)
                        .zIndex(1000)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showStartupSplash {
                let bubbleInfo = twelveHourBubbleInfo(reference: Date())
                let wheelWidth = max(200, UIScreen.main.bounds.width - 40)
                let notificationShape = Capsule(style: .continuous)
                VStack(spacing: showsTimeWheel ? 10 : 0) {
                    HStack(spacing: 8) {
                        Image(systemName: bubbleInfo.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(bubbleInfo.text)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isDarkTheme ? Color.white : Color.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background {
                        Group {
                            if #available(iOS 26.0, *) {
                                notificationShape
                                    .fill(isDarkTheme ? .clear : Color.black.opacity(0.08))
                                    .glassEffect(.regular)
                                    .overlay(
                                        notificationShape
                                            .stroke(.white.opacity(isDarkTheme ? 0.22 : 0.12), lineWidth: 1)
                                    )
                            } else {
                                notificationShape
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        notificationShape
                                            .stroke(.white.opacity(isDarkTheme ? 0.22 : 0.12), lineWidth: 1)
                                    )
                            }
                        }
                    }

                    if showsTimeWheel {
                        TimeWheel(
                            selectedHour: $selectedHour,
                            isDarkTheme: isDarkTheme,
                            cloudDotColorByHour: wheelDotColorsByHour,
                            isScrubbing: $isWheelScrubbing,
                            embeddedInContainer: false
                        )
                        .frame(width: wheelWidth, height: 54)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .center)
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
            configureStartupSplashIfNeeded()
            print("☁️DBG build=open-meteo-cloud-overlay-v24")
            if let location = locationManager.location {
                refreshWeather(for: location)
                PushNotificationService.shared.registerDeviceIfPossible(location: location)
            }
            scheduleForecastOverlayRefresh(delay: 0.05)
            scheduleWheelDotRefresh(delay: 0.15)
        }

        // MARK: Weather update
        .onChange(of: locationManager.location) { _, loc in
            guard let loc else { return }
            lastKnownProbeCoordinate = loc.coordinate
            refreshWeather(for: loc)
            PushNotificationService.shared.registerDeviceIfPossible(location: loc)
            scheduleForecastOverlayRefresh(delay: 0.12)
            scheduleWheelDotRefresh(delay: 0.08)
        }
        .onChange(of: selectedHour) { _, _ in
            applySelectedHourForecast()
            if isWheelScrubbing {
                wheelScrubRefreshWorkItem?.cancel()
                let work = DispatchWorkItem {
                    scheduleForecastOverlayRefresh(delay: 0.0)
                }
                wheelScrubRefreshWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            } else {
                scheduleForecastOverlayRefresh(delay: 0.06)
            }
            scheduleWheelDotRefresh(delay: 0.08)
        }
        .onChange(of: isWheelScrubbing) { _, scrubbing in
            if !scrubbing {
                wheelScrubRefreshWorkItem?.cancel()
                scheduleForecastOverlayRefresh(delay: 0.02)
            }
        }
        .onChange(of: selectedCloudModel) { _, _ in
            cloudFieldLastQueryKey = nil
            cloudFieldBackoffUntil = .distantPast
            rebuildCloudCells()
        }

        .animation(.easeInOut(duration: 0.25), value: userVisible)
        .animation(.easeInOut(duration: 0.25), value: showStartupSplash)
        .preferredColorScheme(isDarkTheme ? .dark : .light)
    }

    private var startupSplashView: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            Image("LaunchIconRounded")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 116, height: 116)
        }
        .ignoresSafeArea()
    }

    private var cloudModelControl: some View {
        Picker("Model", selection: $selectedCloudModel) {
            Text("AUTO").tag(CloudFieldService.Model.auto)
            Text("ICON").tag(CloudFieldService.Model.icon)
            Text("GFS").tag(CloudFieldService.Model.gfs)
            Text("ECMWF").tag(CloudFieldService.Model.ecmwf)
        }
        .pickerStyle(.segmented)
        .frame(width: 264)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func configureStartupSplashIfNeeded() {
        guard !startupSplashInitialized else { return }
        startupSplashInitialized = true
        startupMinDelayPassed = false
        hasAppliedFirstForecastOverlay = true
        showStartupSplash = true

        DispatchQueue.main.asyncAfter(deadline: .now() + startupSplashMinDuration) {
            startupMinDelayPassed = true
            dismissStartupSplashIfReady()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + startupSplashMaxDuration) {
            guard showStartupSplash else { return }
            withAnimation {
                showStartupSplash = false
            }
        }
    }

    private func dismissStartupSplashIfReady() {
        guard showStartupSplash else { return }
        guard startupMinDelayPassed else { return }
        guard hasAppliedFirstForecastOverlay else { return }
        withAnimation {
            showStartupSplash = false
        }
    }

    private var isDarkTheme: Bool {
        if hourlyWeather != nil {
            return !selectedHourIsDay
        }
        return colorScheme == .dark
    }

    // MARK: Weather Header UI
    var weatherHeader: some View {
        let cardShape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        let primaryText = isDarkTheme ? Color.white : Color.black

        return VStack(alignment: .leading, spacing: 18) {

            Text(locationManager.city)
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(primaryText.opacity(0.9))
                .frame(height: 26, alignment: .leading)
                .padding(.top, -4)

            HStack(alignment: .center, spacing: 16) {

                HStack(spacing: 4) {
                    Text(temperature)
                        .font(.system(size: 76, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .fixedSize(horizontal: true, vertical: false)

                    Image(systemName: weatherIcon)
                        .font(.system(size: 70, weight: .regular))
                        .foregroundStyle(primaryText)
                        .frame(width: 70, height: 70, alignment: .center)
                }

                Text(twoLineWeatherText(weatherText))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(primaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 100, maxWidth: 140, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 108, alignment: .center)

            HStack {
                weatherMetric("Feels like", feelsLike, "thermometer")
                    .frame(maxWidth: .infinity, alignment: .leading)
                weatherMetric("Wind", wind, "wind")
                    .frame(maxWidth: .infinity, alignment: .leading)
                weatherMetric("Humidity", humidity, "drop")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 56, alignment: .center)
            .padding(.top, -4)
        }
        .padding(20)
        .frame(height: 248, alignment: .topLeading)
        .background(
            cardShape
                .fill(.ultraThinMaterial)
                .overlay(
                    cardShape
                        .stroke(.white.opacity(isDarkTheme ? 0.22 : 0.12), lineWidth: 1)
                )
        )
        .clipShape(cardShape)
        .contentShape(cardShape)
        .onTapGesture {
            useFahrenheit.toggle()
            applyDisplayedTemperatureUnit()
        }
        .allowsHitTesting(true)
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

    private func formattedTemperature(from celsius: Double?) -> String {
        guard let celsius else { return "--" }
        let value = useFahrenheit ? (celsius * 9.0 / 5.0 + 32.0) : celsius
        return "\(Int(value.rounded()))°"
    }

    private func applyDisplayedTemperatureUnit() {
        temperature = formattedTemperature(from: temperatureCelsius)
        feelsLike = formattedTemperature(from: feelsLikeCelsius)
    }

    func weatherInfo(from code: Int, isDay: Bool) -> (String, String) {
        switch code {
        case 0: return (isDay ? "sun.max" : "moon.stars", "Clear")
        case 1, 2: return (isDay ? "cloud.sun" : "cloud.moon", "Partly Cloudy")
        case 3: return ("cloud", "Cloudy")
        case 45, 48: return ("cloud.fog", "Fog")
        case 51...67: return (isDay ? "cloud.drizzle" : "cloud.moon.rain", "Drizzle")
        case 71...77, 85...86: return ("snow", "Snow")
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

        temperatureCelsius = hourly.temperature_2m[idx]
        feelsLikeCelsius = hourly.apparent_temperature[idx]
        applyDisplayedTemperatureUnit()
        wind = "\(Int(hourly.wind_speed_10m[idx])) km/h"
        humidity = "\(hourly.relative_humidity_2m[idx])%"

        let selectedWeatherCode = hourly.weather_code[idx]
        let selectedIsDay = (idx < (hourly.is_day?.count ?? 0) ? hourly.is_day?[idx] : 1) == 1
        withAnimation(.easeInOut(duration: 0.45)) {
            selectedHourIsDay = selectedIsDay
        }
        let info = weatherInfo(from: selectedWeatherCode, isDay: selectedIsDay)
        weatherIcon = info.0
        weatherText = info.1
        applyCloudCover(
            from: hourly,
            index: idx,
            fallbackFromWeatherCode: selectedWeatherCode
        )
    }

    private func applyCloudCover(
        from hourly: WeatherData.Hourly,
        index: Int,
        fallbackFromWeatherCode: Int?
    ) {
        let fallbackCover = fallbackFromWeatherCode.map(fallbackCloudCover(from:)) ?? 0
        let total = resolvedCloudCover(from: hourly, index: index) ?? fallbackCover
        let fallbackLayer = total / 3.0

        cloudCoverTotal = total
        cloudCoverLow = seriesValue(hourly.cloud_cover_low, index: index) ?? fallbackLayer
        cloudCoverMid = seriesValue(hourly.cloud_cover_mid, index: index) ?? fallbackLayer
        cloudCoverHigh = seriesValue(hourly.cloud_cover_high, index: index) ?? fallbackLayer
#if DEBUG
        print(
            "☁️DBG cloud",
            "total=\(Int(cloudCoverTotal.rounded()))",
            "low=\(Int(cloudCoverLow.rounded()))",
            "mid=\(Int(cloudCoverMid.rounded()))",
            "high=\(Int(cloudCoverHigh.rounded()))",
            "fallbackCode=\(fallbackFromWeatherCode ?? -1)"
        )
#endif
    }

    private func wheelHourOffset(for hour: Int, reference: Date) -> Int? {
        let nowHour = Calendar.current.component(.hour, from: reference)
        let wheelHours = (0..<timeWheelSlotCount).map { (nowHour + $0) % 24 }
        return wheelHours.firstIndex(of: hour)
    }

    private func refreshForecastOverlay() {
        guard let targetDate = targetDateForSelectedHour(reference: Date()) else { return }
        let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)
        latestForecastRequestHour = hourStamp
        let probeCoordinate = resolvedProbeCoordinate()

        print(
            overlayDebugPrefix,
            "refresh start",
            "selectedHour=\(selectedHour)",
            "hourStamp=\(hourStamp)",
            "hasCache=\(forecastFrameCache[hourStamp] != nil)",
            "inFlight=\(forecastFrameRequestsInFlight.contains(hourStamp))",
            "hasProbeCoord=\(probeCoordinate != nil)"
        )

        if let cached = forecastFrameCache[hourStamp] {
            if needsLocalProbeRefresh(cached), probeCoordinate != nil {
                print(overlayDebugPrefix, "cached frame lacks local probe, refetch", hourStamp)
            } else {
                print(overlayDebugPrefix, "use cached frame", hourStamp)
                applyForecastFrame(cached, hourStamp: hourStamp)
                scheduleForecastTilePrefetch(delay: 0.0)
                return
            }
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

        if
            forecastFrameCache[hourStamp] == nil &&
            forecastFrameRequestsInFlight.count >= maxConcurrentFrameFetches
        {
            print(overlayDebugPrefix, "skip fetch (busy)", hourStamp)
            scheduleForecastOverlayRefresh(delay: 0.12)
            return
        }

        forecastFrameRequestsInFlight.insert(hourStamp)
        print(overlayDebugPrefix, "fetch start", hourStamp)

        CloudOverlayService.fetchForecastFrame(
            targetDate: targetDate,
            near: probeCoordinate,
            probeSignalNearUser: false
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
                scheduleWheelDotRefresh(delay: 0.04)
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
        guard forecastPrefetchEnabled else { return }
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
        // Phase 1: first warm the currently selected hour in the visible viewport.
        let selectedZooms = preferredPrefetchZooms(around: snapshot.zoom)
        prefetchHour(
            selectedDate,
            snapshot: snapshot,
            requestedZooms: selectedZooms,
            renderedTileBudget: 2,
            visibleTileLimit: min(18, max(8, snapshot.tiles.count / 3)),
            sourceTileLimit: 6,
            fetchIfMissing: true,
            applyIfLatest: true,
            probeSignalNearUser: false
        )

        // Phase 2: lightweight adjacent-hour warmup for quick wheel switching.
        forecastBackgroundPrefetchWorkItem?.cancel()
        guard let adjacentDate = neighboringPrefetchDate(around: selectedDate, reference: now) else {
            return
        }
        let backgroundWork = DispatchWorkItem {
            prefetchHour(
                adjacentDate,
                snapshot: snapshot,
                requestedZooms: [snapshot.zoom],
                renderedTileBudget: 0,
                visibleTileLimit: min(10, max(6, snapshot.tiles.count / 4)),
                sourceTileLimit: 3,
                fetchIfMissing: true,
                applyIfLatest: false,
                probeSignalNearUser: false
            )
        }
        forecastBackgroundPrefetchWorkItem = backgroundWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: backgroundWork)
    }

    private func neighboringPrefetchDate(
        around selectedDate: Date,
        reference: Date
    ) -> Date? {
        let currentHour = Calendar.current.component(.hour, from: reference)
        let direction = selectedHour >= currentHour ? 1 : -1
        return Calendar.current.date(byAdding: .hour, value: direction, to: selectedDate)
    }

    private func prefetchHour(
        _ targetDate: Date,
        snapshot: UIKitMap.VisibleTileSnapshot,
        requestedZooms: [Int],
        renderedTileBudget: Int,
        visibleTileLimit: Int,
        sourceTileLimit: Int,
        fetchIfMissing: Bool,
        applyIfLatest: Bool,
        probeSignalNearUser: Bool
    ) {
        let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)
        let probeCoordinate = resolvedProbeCoordinate()

        if let frame = forecastFrameCache[hourStamp] {
            if !(probeSignalNearUser && needsLocalProbeRefresh(frame) && probeCoordinate != nil) {
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
            print(overlayDebugPrefix, "prefetch refetch missing local probe", hourStamp)
        }

        guard fetchIfMissing else { return }
        if forecastFrameRequestsInFlight.contains(hourStamp) { return }
        forecastFrameRequestsInFlight.insert(hourStamp)

        CloudOverlayService.fetchForecastFrame(
            targetDate: targetDate,
            near: probeCoordinate,
            probeSignalNearUser: probeSignalNearUser
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

    private func preferredPrefetchZooms(around zoom: Int) -> [Int] {
        let clamped = max(0, min(20, zoom))
        // Do not prewarm lower zoom during active navigation; it is expensive and hurts zoom-out FPS.
        let candidates = [clamped, clamped + 1]
        var seen = Set<Int>()
        var out: [Int] = []
        for value in candidates {
            let z = max(0, min(20, value))
            if seen.insert(z).inserted {
                out.append(z)
            }
        }
        return out
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
        let template = forecastTemplate(for: frame, hourStamp: hourStamp)
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
                    template: template,
                    z: sourceZ,
                    x: tile.x,
                    y: tile.y
                )
            }

            let perZoomBudget = (requestedZoom == snapshot.zoom)
                ? renderedTileBudget
                : max(0, renderedTileBudget / 2)

            guard perZoomBudget > 0 else { continue }
            guard requestedZoom >= 3 else { continue }

            for tile in visibleTiles.prefix(perZoomBudget) {
                UIKitMap.ForecastTileOverlay.prewarmRenderedTile(
                    template: template,
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
        return (0..<timeWheelSlotCount).compactMap { calendar.date(byAdding: .hour, value: $0, to: base) }
    }

    private func scheduleWheelDotRefresh(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            refreshWheelDotColors(reference: Date())
        }
    }

    private func refreshWheelDotColors(reference: Date) {
        guard let coordinate = resolvedProbeCoordinate() else {
            wheelDotColorsByHour = [:]
            wheelDotColorByHourStamp = [:]
            wheelDotRequestsInFlight.removeAll()
            return
        }

        let dates = wheelHourDates(reference: reference)
        var colors: [Int: Color] = [:]
        for date in dates {
            let hourStamp = Int(date.timeIntervalSince1970 / 3600)
            let slotHour = Calendar.current.component(.hour, from: date)
            if let cached = wheelDotColorByHourStamp[hourStamp] {
                if let cached {
                    colors[slotHour] = cached
                }
                continue
            }
            requestWheelDotColor(for: date, coordinate: coordinate, slotHour: slotHour)
        }
        wheelDotColorsByHour = colors
    }

    private func requestWheelDotColor(
        for targetDate: Date,
        coordinate: CLLocationCoordinate2D,
        slotHour: Int
    ) {
        let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)
        if wheelDotRequestsInFlight.contains(hourStamp) { return }
        wheelDotRequestsInFlight.insert(hourStamp)

        let consumeFrame: (CloudOverlayService.ForecastFrame) -> Void = { frame in
            sampleTileColorAtCoordinate(
                template: forecastTemplate(for: frame, hourStamp: hourStamp),
                zoom: frame.maxZoom,
                coordinate: coordinate
            ) { sampledColor in
                wheelDotRequestsInFlight.remove(hourStamp)
                wheelDotColorByHourStamp[hourStamp] = sampledColor
                if let sampledColor {
                    wheelDotColorsByHour[slotHour] = sampledColor
                } else {
                    wheelDotColorsByHour.removeValue(forKey: slotHour)
                }
            }
        }

        if let cached = forecastFrameCache[hourStamp] {
            consumeFrame(cached)
            return
        }

        CloudOverlayService.fetchForecastFrame(
            targetDate: targetDate,
            near: coordinate,
            probeSignalNearUser: false
        ) { result in
            switch result {
            case .success(let frame):
                forecastFrameCache[hourStamp] = frame
                consumeFrame(frame)
            case .failure:
                wheelDotRequestsInFlight.remove(hourStamp)
                wheelDotColorByHourStamp[hourStamp] = nil
                wheelDotColorsByHour.removeValue(forKey: slotHour)
            }
        }
    }

    private func sampleTileColorAtCoordinate(
        template: String,
        zoom: Int,
        coordinate: CLLocationCoordinate2D,
        completion: @escaping (Color?) -> Void
    ) {
        let z = max(0, min(20, zoom))
        let scale = pow(2.0, Double(z))
        let n = Int(scale)
        guard n > 0 else {
            completion(nil)
            return
        }

        let lat = max(-85.05112878, min(85.05112878, coordinate.latitude))
        let lon = coordinate.longitude
        let xFloat = (lon + 180.0) / 360.0 * scale
        let latRad = lat * .pi / 180.0
        let mercN = log(tan(.pi / 4.0 + latRad / 2.0))
        let yFloat = (1.0 - mercN / .pi) / 2.0 * scale

        let tileX = ((Int(floor(xFloat)) % n) + n) % n
        let tileY = max(0, min(n - 1, Int(floor(yFloat))))
        let px = max(0, min(255, Int((xFloat - floor(xFloat)) * 256.0)))
        let py = max(0, min(255, Int((yFloat - floor(yFloat)) * 256.0)))

        let urlString = template
            .replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(tileX)")
            .replacingOccurrences(of: "{y}", with: "\(tileY)")
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let data,
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage,
                  let providerData = cgImage.dataProvider?.data,
                  let ptr = CFDataGetBytePtr(providerData)
            else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let width = cgImage.width
            let height = cgImage.height
            let bpp = max(1, cgImage.bitsPerPixel / 8)
            let bpr = max(1, cgImage.bytesPerRow)
            let sx = max(0, min(width - 1, px * max(1, width) / 256))
            let sy = max(0, min(height - 1, py * max(1, height) / 256))
            let idx = sy * bpr + sx * bpp
            guard idx + 3 < CFDataGetLength(providerData) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            let r = Double(ptr[idx + 0]) / 255.0
            let g = Double(ptr[idx + 1]) / 255.0
            let b = Double(ptr[idx + 2]) / 255.0
            let a = Double(ptr[idx + 3]) / 255.0
            let minAlpha = 0.03
            let color: Color? = {
                guard a > minAlpha else { return nil }
                // Palette requested by user (from weak to strong):
                // 79D5FF, 49B3FF, 008BFF, 0277D8, 1C5CC4, 004680
                let palette: [(Double, Double, Double)] = [
                    (0x79, 0xD5, 0xFF),
                    (0x49, 0xB3, 0xFF),
                    (0x00, 0x8B, 0xFF),
                    (0x02, 0x77, 0xD8),
                    (0x1C, 0x5C, 0xC4),
                    (0x00, 0x46, 0x80)
                ].map { ($0.0 / 255.0, $0.1 / 255.0, $0.2 / 255.0) }

                let signal = clamp01(max(a, (0.45 * b + 0.35 * g + 0.20 * r)))
                let idx = min(palette.count - 1, max(0, Int((signal * Double(palette.count - 1)).rounded())))
                let p = palette[idx]
                let boostedAlpha = min(1.0, max(0.86, a * 1.12))
                return Color(red: p.0, green: p.1, blue: p.2).opacity(clamp01(boostedAlpha))
            }()
            DispatchQueue.main.async { completion(color) }
        }.resume()
    }

    private func twelveHourBubbleInfo(reference: Date) -> (icon: String, text: String) {
        guard let hourly = hourlyWeather else {
            return ("sun.max", "Good weather in the next 12 hours")
        }

        let parsedTimes = hourly.time.compactMap { Self.hourlyDateFormatter.date(from: $0) }
        guard !parsedTimes.isEmpty else {
            return ("sun.max", "Good weather in the next 12 hours")
        }

        let precipitationProbability = hourly.precipitation_probability ?? []
        let twelveHoursAhead = reference.addingTimeInterval(12 * 3600)

        let windowIndices: [Int] = parsedTimes.enumerated().compactMap { idx, date in
            (date >= reference && date <= twelveHoursAhead) ? idx : nil
        }
        guard !windowIndices.isEmpty else {
            return ("sun.max", "Good weather in the next 12 hours")
        }

        var rainySlots = 0
        var firstRainIndex: Int?
        for idx in windowIndices {
            let code = idx < hourly.weather_code.count ? hourly.weather_code[idx] : 0
            let precipProb = idx < precipitationProbability.count ? precipitationProbability[idx] : 0
            let rainByCode = (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code)
            if precipProb >= 20 || rainByCode {
                rainySlots += 1
                if firstRainIndex == nil { firstRainIndex = idx }
            }
        }

        if rainySlots == windowIndices.count, windowIndices.count >= 8 {
            return ("cloud.rain", "Rain for the next 12 hours")
        }

        if let firstRainIndex {
            return ("cloud.rain", "Rain possible at \(Self.bubbleTimeFormatter.string(from: parsedTimes[firstRainIndex]))")
        }

        if rainySlots >= max(2, Int(Double(windowIndices.count) * 0.6)) {
            return ("cloud.rain", "Rain for most of the day")
        }

        return ("sun.max", "Good weather in the next 12 hours")
    }

    private func wheelCloudDotColorByHour(reference: Date) -> [Int: Color] {
        guard let hourly = hourlyWeather else { return [:] }
        let calendar = Calendar.current
        let parsedTimes = hourly.time.compactMap { Self.hourlyDateFormatter.date(from: $0) }
        guard !parsedTimes.isEmpty else { return [:] }
        var result: [Int: Color] = [:]

        for slotDate in wheelHourDates(reference: reference) {
            let slotHour = calendar.component(.hour, from: slotDate)
            guard let idx = parsedTimes.firstIndex(where: { $0 >= slotDate }) else { continue }
            let precipitation = seriesValue(hourly.precipitation, index: idx) ?? 0
            let weatherCode = (idx < hourly.weather_code.count) ? hourly.weather_code[idx] : 0
            let cloudCover = resolvedCloudCover(from: hourly, index: idx) ?? fallbackCloudCover(from: weatherCode)
            // Show dots by cloudiness level at location.
            if cloudCover < 8 { continue }
            result[slotHour] = cloudDotColor(
                cloudCoverPercent: cloudCover,
                precipitationMmPerHour: precipitation,
                weatherCode: weatherCode
            )
        }

        return result
    }

    private func resolvedCloudCover(
        from hourly: WeatherData.Hourly,
        index: Int
    ) -> Double? {
        if let cover = seriesValue(hourly.cloud_cover, index: index) {
            return cover
        }
        let layers = [
            seriesValue(hourly.cloud_cover_low, index: index),
            seriesValue(hourly.cloud_cover_mid, index: index),
            seriesValue(hourly.cloud_cover_high, index: index)
        ].compactMap { $0 }
        guard !layers.isEmpty else { return nil }
        return layers.reduce(0, +) / Double(layers.count)
    }

    private func seriesValue(_ values: [Double]?, index: Int) -> Double? {
        guard let values, index >= 0, index < values.count else { return nil }
        return max(0, min(100, values[index]))
    }

    private func cloudDotColor(
        cloudCoverPercent: Double,
        precipitationMmPerHour: Double,
        weatherCode: Int
    ) -> Color {
        let cloudIntensity = clamp01(cloudCoverPercent / 100.0)
        // Precipitation only slightly boosts saturation/alpha.
        let rainBoost = clamp01(precipitationMmPerHour / 4.0)
        let snow = isSnowWeatherCode(weatherCode)
        let storm = isStormWeatherCode(weatherCode)

        // Accessibility tuning by theme:
        // light theme -> brighter and more saturated,
        // dark theme -> lighter values to keep contrast on dark background.
        let lightTheme = !isDarkTheme
        var red = lightTheme
            ? lerp(120.0, 42.0, cloudIntensity)
            : lerp(162.0, 88.0, cloudIntensity)
        var green = lightTheme
            ? lerp(196.0, 122.0, cloudIntensity)
            : lerp(216.0, 164.0, cloudIntensity)
        var blue = lightTheme
            ? lerp(255.0, 246.0, cloudIntensity)
            : lerp(255.0, 250.0, cloudIntensity)
        var alpha = lightTheme
            ? lerp(0.90, 1.0, cloudIntensity)
            : lerp(0.88, 0.98, cloudIntensity)

        red = mix(red, 40.0, rainBoost * 0.14)
        green = mix(green, 102.0, rainBoost * 0.20)
        blue = mix(blue, 232.0, rainBoost * 0.34)
        alpha = max(alpha, 0.78 + 0.16 * rainBoost)

        if snow {
            let snowMix = 0.42
            let snowRed = lerp(132.0, 84.0, cloudIntensity)
            let snowGreen = lerp(206.0, 156.0, cloudIntensity)
            let snowBlue = lerp(255.0, 246.0, cloudIntensity)
            red = mix(red, snowRed, snowMix)
            green = mix(green, snowGreen, snowMix)
            blue = mix(blue, snowBlue, snowMix)
            alpha = max(alpha, 0.88)
        }

        if storm {
            red = mix(red, 8.0, 0.58)
            green = mix(green, 32.0, 0.58)
            blue = mix(blue, 190.0, 0.58)
            alpha = max(alpha, 0.94)
        }

        return Color(
            red: clamp01(red / 255.0),
            green: clamp01(green / 255.0),
            blue: clamp01(blue / 255.0)
        ).opacity(clamp01(alpha))
    }

    private func isSnowWeatherCode(_ code: Int) -> Bool {
        (71...77).contains(code) || code == 85 || code == 86
    }

    private func isStormWeatherCode(_ code: Int) -> Bool {
        (95...99).contains(code)
    }

    private func clamp01(_ value: Double) -> Double {
        max(0.0, min(1.0, value))
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private func fallbackCloudCover(from weatherCode: Int) -> Double {
        switch weatherCode {
        case 0: return 6
        case 1: return 32
        case 2: return 56
        case 3: return 86
        case 45, 48: return 94
        case 51...67: return 88
        case 71...77: return 90
        case 80...82: return 92
        case 95...99: return 97
        default: return 60
        }
    }

    private func rebuildCloudCells() {
        scheduleCloudFieldRefresh(delay: 0.28)
    }

    private func scheduleCloudFieldRefresh(delay: TimeInterval) {
        cloudFieldRefreshWorkItem?.cancel()
        let requestNonce = cloudFieldRequestNonce + 1
        cloudFieldRequestNonce = requestNonce

        let work = DispatchWorkItem {
            guard !showStartupSplash else {
                cloudCells = []
                return
            }
            guard let targetDate = targetDateForSelectedHour(reference: Date()) else { return }
            let rawZoom = visibleTileSnapshot?.zoom ?? 7
            let zoom = max(6, min(10, rawZoom))
            let points: [CloudFieldService.GridPoint]
            if let snapshot = visibleTileSnapshot,
               let viewportPoints = makeViewportGridPoints(from: snapshot)
            {
                points = viewportPoints
            } else if let centerCoordinate = resolvedViewportCenterCoordinate() {
                let fallbackProfile = fallbackCloudGridProfile(forZoom: zoom)
                points = makeGridPoints(
                    center: centerCoordinate,
                    gridSize: fallbackProfile.gridSize,
                    stepDegrees: fallbackProfile.stepDegrees
                )
            } else {
                cloudCells = []
                return
            }
            guard !points.isEmpty else {
                cloudCells = []
                return
            }

            let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)
            let queryKey = cloudFieldQueryKey(
                hourStamp: hourStamp,
                zoom: zoom,
                points: points
            )
            if let cached = cloudFieldResultCache[queryKey], !cached.isEmpty {
                cloudCells = cached
            }
            let now = Date()

            if now < cloudFieldBackoffUntil {
#if DEBUG
                let remaining = cloudFieldBackoffUntil.timeIntervalSince(now)
                print("☁️DBG cloud backoff active seconds=\(String(format: "%.1f", remaining))")
#endif
                return
            }

            if queryKey == cloudFieldLastQueryKey,
               now.timeIntervalSince(cloudFieldLastRequestAt) < 1.5
            {
                return
            }

            if now.timeIntervalSince(cloudFieldLastRequestAt) < 0.9 {
                scheduleCloudFieldRefresh(delay: 0.55)
                return
            }

            cloudFieldLastQueryKey = queryKey
            cloudFieldLastRequestAt = now

            CloudFieldService.fetchField(
                points: points,
                targetDate: targetDate,
                model: selectedCloudModel
            ) { result in
                guard cloudFieldRequestNonce == requestNonce else { return }
                switch result {
                case .success(let cells):
                    cloudCells = cells
                    cloudField429Streak = 0
                    cloudFieldBackoffUntil = .distantPast
                    if !cells.isEmpty {
                        cloudFieldLastNonEmptyCells = cells
                        cloudFieldResultCache[queryKey] = cells
                        debugDumpCloudCells(cells)
                    }
#if DEBUG
                    let maxRain = cells.map(\.rainIntensity).max() ?? 0
                    let maxStorm = cells.map(\.stormRisk).max() ?? 0
                    print(
                        "☁️DBG cloudCells",
                        "source=\(selectedCloudModel.rawValue)",
                        "cells=\(cells.count)",
                        "zoom=\(zoom)",
                        "maxRain=\(String(format: "%.3f", maxRain))",
                        "maxStorm=\(String(format: "%.3f", maxStorm))"
                    )
#endif
                case .failure(let reason):
                    print("☁️DBG cloud field failed:", reason)
                    if reason.contains("429") {
                        cloudField429Streak += 1
                        let backoffSeconds = min(
                            24.0,
                            1.6 * pow(2.0, Double(max(0, cloudField429Streak - 1)))
                        )
                        cloudFieldBackoffUntil = Date().addingTimeInterval(backoffSeconds)
                        print("☁️DBG cloud backoff set seconds=\(String(format: "%.1f", backoffSeconds))")
                    }
                    if cloudCells.isEmpty, !cloudFieldLastNonEmptyCells.isEmpty {
                        cloudCells = cloudFieldLastNonEmptyCells
                    }
                }
            }
        }

        cloudFieldRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resolvedViewportCenterCoordinate() -> CLLocationCoordinate2D? {
        if let snapshot = visibleTileSnapshot,
           let coordinate = viewportCenterCoordinate(from: snapshot)
        {
            return coordinate
        }
        return locationManager.location?.coordinate
    }

    private func makeGridPoints(
        center: CLLocationCoordinate2D,
        gridSize: Int,
        stepDegrees: Double
    ) -> [CloudFieldService.GridPoint] {
        let half = Double(gridSize - 1) / 2.0
        var points: [CloudFieldService.GridPoint] = []
        points.reserveCapacity(gridSize * gridSize)

        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let lat = center.latitude + (Double(row) - half) * stepDegrees
                let lonScale = max(0.30, cos(lat * .pi / 180.0))
                let lon = center.longitude + ((Double(col) - half) * stepDegrees) / lonScale
                points.append(
                    CloudFieldService.GridPoint(
                        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        row: row,
                        col: col,
                        gridSize: gridSize,
                        stepDegrees: stepDegrees
                    )
                )
            }
        }
        return points
    }

    private func viewportCenterCoordinate(
        from snapshot: UIKitMap.VisibleTileSnapshot
    ) -> CLLocationCoordinate2D? {
        guard !snapshot.tiles.isEmpty else { return nil }
        let centerX = snapshot.tiles.reduce(0.0) { $0 + Double($1.x) } / Double(snapshot.tiles.count)
        let centerY = snapshot.tiles.reduce(0.0) { $0 + Double($1.y) } / Double(snapshot.tiles.count)
        return coordinateForTile(
            x: centerX + 0.5,
            y: centerY + 0.5,
            zoom: snapshot.zoom
        )
    }

    private func coordinateForTile(
        x: Double,
        y: Double,
        zoom: Int
    ) -> CLLocationCoordinate2D? {
        guard zoom >= 0 else { return nil }
        let n = pow(2.0, Double(zoom))
        guard n > 0 else { return nil }
        let lon = x / n * 360.0 - 180.0
        let latRad = atan(sinh(.pi * (1.0 - (2.0 * y / n))))
        let lat = latRad * 180.0 / .pi
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func cloudGridProfile(forZoom zoom: Int) -> (gridSize: Int, stepDegrees: Double) {
        switch zoom {
        case 11...: return (gridSize: 8, stepDegrees: 0.040)
        case 10: return (gridSize: 8, stepDegrees: 0.058)
        case 9: return (gridSize: 8, stepDegrees: 0.080)
        case 8: return (gridSize: 7, stepDegrees: 0.120)
        case 7: return (gridSize: 7, stepDegrees: 0.180)
        case 6: return (gridSize: 6, stepDegrees: 0.280)
        default: return (gridSize: 6, stepDegrees: 0.400)
        }
    }

    private func fallbackCloudGridProfile(forZoom zoom: Int) -> (gridSize: Int, stepDegrees: Double) {
        switch zoom {
        case 11...: return (gridSize: 7, stepDegrees: 0.050)
        case 10: return (gridSize: 7, stepDegrees: 0.070)
        case 9: return (gridSize: 7, stepDegrees: 0.095)
        case 8: return (gridSize: 6, stepDegrees: 0.120)
        case 7: return (gridSize: 6, stepDegrees: 0.180)
        case 6: return (gridSize: 5, stepDegrees: 0.280)
        default: return (gridSize: 5, stepDegrees: 0.400)
        }
    }

    private func makeViewportGridPoints(
        from snapshot: UIKitMap.VisibleTileSnapshot
    ) -> [CloudFieldService.GridPoint]? {
        guard !snapshot.tiles.isEmpty else { return nil }
        if snapshot.zoom < 3 { return nil }
        guard let minX = snapshot.tiles.map(\.x).min(),
              let maxX = snapshot.tiles.map(\.x).max(),
              let minY = snapshot.tiles.map(\.y).min(),
              let maxY = snapshot.tiles.map(\.y).max()
        else {
            return nil
        }

        let n = 1 << snapshot.zoom
        guard n > 0 else { return nil }
        let padTiles = 1
        let x0 = max(0, minX - padTiles)
        let x1 = min(n - 1, maxX + padTiles + 1)
        let y0 = max(0, minY - padTiles)
        let y1 = min(n - 1, maxY + padTiles + 1)

        guard let northWest = coordinateForTile(
            x: Double(x0),
            y: Double(y0),
            zoom: snapshot.zoom
        ),
        let southEast = coordinateForTile(
            x: Double(x1),
            y: Double(y1),
            zoom: snapshot.zoom
        ) else {
            return nil
        }

        let latMinRaw = min(northWest.latitude, southEast.latitude)
        let latMaxRaw = max(northWest.latitude, southEast.latitude)
        let lonMinRaw = min(northWest.longitude, southEast.longitude)
        let lonMaxRaw = max(northWest.longitude, southEast.longitude)

        let latPadding = max(0.03, (latMaxRaw - latMinRaw) * 0.08)
        let lonPadding = max(0.03, (lonMaxRaw - lonMinRaw) * 0.08)
        let latMin = max(-85.0, latMinRaw - latPadding)
        let latMax = min(85.0, latMaxRaw + latPadding)
        let lonMin = max(-180.0, lonMinRaw - lonPadding)
        let lonMax = min(180.0, lonMaxRaw + lonPadding)
        let latSpan = max(0.01, latMax - latMin)
        let lonSpan = max(0.01, lonMax - lonMin)

        let profile = cloudGridProfile(forZoom: snapshot.zoom)
        let gridSize = max(5, min(10, profile.gridSize))
        let rowStep = latSpan / Double(max(1, gridSize - 1))
        let colStep = lonSpan / Double(max(1, gridSize - 1))
        let approxStep = max(0.02, (rowStep + colStep) * 0.5)

        var points: [CloudFieldService.GridPoint] = []
        points.reserveCapacity(gridSize * gridSize)

        for row in 0..<gridSize {
            let lat = latMin + Double(row) * rowStep
            for col in 0..<gridSize {
                let lon = lonMin + Double(col) * colStep
                points.append(
                    CloudFieldService.GridPoint(
                        center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        row: row,
                        col: col,
                        gridSize: gridSize,
                        stepDegrees: approxStep
                    )
                )
            }
        }

        return points
    }

    private func cloudFieldQueryKey(
        hourStamp: Int,
        zoom: Int,
        points: [CloudFieldService.GridPoint]
    ) -> String {
        let first = points.first?.center
        let last = points.last?.center
        let latA = ((first?.latitude ?? 0) * 20).rounded() / 20
        let lonA = ((first?.longitude ?? 0) * 20).rounded() / 20
        let latB = ((last?.latitude ?? 0) * 20).rounded() / 20
        let lonB = ((last?.longitude ?? 0) * 20).rounded() / 20
        return [
            selectedCloudModel.rawValue,
            "h\(hourStamp)",
            "z\(zoom)",
            "n\(points.count)",
            String(format: "a%.2f,%.2f", latA, lonA),
            String(format: "b%.2f,%.2f", latB, lonB)
        ].joined(separator: "|")
    }

    private func debugDumpCloudCells(_ cells: [CloudOverlayService.CloudCell]) {
#if DEBUG
        struct DumpCell: Codable {
            let latitude: Double
            let longitude: Double
            let rainIntensity: Double
            let stormRisk: Double
            let stepDegrees: Double
            let row: Int
            let col: Int
            let gridSize: Int
        }

        let payload = cells.map {
            DumpCell(
                latitude: $0.center.latitude,
                longitude: $0.center.longitude,
                rainIntensity: $0.rainIntensity,
                stormRisk: $0.stormRisk,
                stepDegrees: $0.stepDegrees,
                row: $0.row,
                col: $0.col,
                gridSize: $0.gridSize
            )
        }

        do {
            let data = try JSONEncoder().encode(payload)
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("cloud_cells_latest.json")
            try data.write(to: url, options: .atomic)
            print("☁️DBG dump json=\(url.path) cells=\(cells.count)")
        } catch {
            print("☁️DBG dump failed:", error.localizedDescription)
        }
#endif
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
                temperatureCelsius = w.current.temperature_2m
                feelsLikeCelsius = w.current.apparent_temperature
                applyDisplayedTemperatureUnit()
                wind = "\(Int(w.current.wind_speed_10m)) km/h"
                humidity = "\(w.current.relative_humidity_2m)%"
                hourlyWeather = w.hourly
#if DEBUG
                let cloudCount = w.hourly.cloud_cover?.count ?? 0
                let lowCount = w.hourly.cloud_cover_low?.count ?? 0
                let midCount = w.hourly.cloud_cover_mid?.count ?? 0
                let highCount = w.hourly.cloud_cover_high?.count ?? 0
                let precipitationCount = w.hourly.precipitation?.count ?? 0
                print(
                    "☁️DBG source",
                    "time=\(w.hourly.time.count)",
                    "cloud=\(cloudCount)",
                    "low=\(lowCount)",
                    "mid=\(midCount)",
                    "high=\(highCount)",
                    "prec=\(precipitationCount)"
                )
#endif

                let currentIsDay = (w.current.is_day ?? 1) == 1
                withAnimation(.easeInOut(duration: 0.45)) {
                    selectedHourIsDay = currentIsDay
                }
                let info = weatherInfo(from: w.current.weather_code, isDay: currentIsDay)
                weatherIcon = info.0
                weatherText = info.1

                applySelectedHourForecast()
                hasAppliedFirstForecastOverlay = true
                dismissStartupSplashIfReady()
                scheduleForecastOverlayRefresh(delay: 0.0)
            }
        }
    }

    private func applyForecastFrame(
        _ frame: CloudOverlayService.ForecastFrame,
        hourStamp: Int
    ) {
        let frameHour = Int(frame.time.timeIntervalSince1970 / 3600)
        print("☁️ Forecast frame:", frameHour, "for:", hourStamp)

        scheduleOverlayApply(frame, hourStamp: hourStamp)
    }

    private func scheduleOverlayApply(
        _ frame: CloudOverlayService.ForecastFrame,
        hourStamp: Int
    ) {
        overlayApplyWorkItem?.cancel()

        let template = forecastTemplate(for: frame, hourStamp: hourStamp)
        let currentToken = overlayTemplateToken(from: forecastTileTemplate ?? "")
        let incomingToken = overlayTemplateToken(from: template)
        let sameZoomRange =
            forecastTileMinZoom == frame.minZoom &&
            forecastTileMaxZoom == frame.maxZoom
        if sameZoomRange && currentToken == incomingToken && lastAppliedOverlayHourStamp == hourStamp {
            print(overlayDebugPrefix, "schedule skip same key", "hour=\(hourStamp)")
            return
        }

        let currentKey = "\(forecastTileTemplate ?? "")|\(forecastTileMinZoom)|\(forecastTileMaxZoom)"
        let incomingKey = "\(template)|\(frame.minZoom)|\(frame.maxZoom)"

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
                template: template,
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
        template: String,
        hourStamp: Int,
        attempt: Int
    ) {
        guard pendingOverlayHourStamp == hourStamp else {
            print("☁️ Overlay skip pending-mismatch:", hourStamp, "pending:", pendingOverlayHourStamp ?? -1)
            return
        }

        let currentToken = overlayTemplateToken(from: forecastTileTemplate ?? "")
        let incomingToken = overlayTemplateToken(from: template)
        let sameZoomRange =
            forecastTileMinZoom == frame.minZoom &&
            forecastTileMaxZoom == frame.maxZoom
        let incomingKey = "\(template)|\(frame.minZoom)|\(frame.maxZoom)"
        if sameZoomRange && currentToken == incomingToken && lastAppliedOverlayHourStamp == hourStamp {
            print("☁️ Overlay skip same-key:", hourStamp)
            print(overlayDebugPrefix, "apply skip same key", "hour=\(hourStamp)")
            return
        }

        if isViewportZooming && attempt < 10 {
            let retry = DispatchWorkItem {
                applyForecastFrameWhenReady(
                    frame,
                    template: template,
                    hourStamp: hourStamp,
                    attempt: attempt + 1
                )
            }
            overlayApplyWorkItem = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: retry)
            print(overlayDebugPrefix, "apply defer (zooming)", "hour=\(hourStamp)", "attempt=\(attempt)")
            return
        }

        if shouldDeferInitialOverlayApply(
            frame: frame,
            template: template,
            attempt: attempt
        ) {
            let retry = DispatchWorkItem {
                applyForecastFrameWhenReady(
                    frame,
                    template: template,
                    hourStamp: hourStamp,
                    attempt: attempt + 1
                )
            }
            overlayApplyWorkItem = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: retry)
            print(
                overlayDebugPrefix,
                "apply defer (bootstrap-cache)",
                "hour=\(hourStamp)",
                "attempt=\(attempt)"
            )
            return
        }

        print("☁️ Overlay APPLY:", hourStamp, "key:", incomingKey)
        print(overlayDebugPrefix, "apply success", "hour=\(hourStamp)")
        forecastTileTemplate = template
        forecastTileMinZoom = frame.minZoom
        forecastTileMaxZoom = frame.maxZoom
        bootstrapForecastVisibility(frame: frame, template: template)
        hasAppliedFirstForecastOverlay = true
        dismissStartupSplashIfReady()
        lastOverlayAppliedAt = Date()
        lastAppliedOverlayHourStamp = hourStamp
        pendingOverlayHourStamp = nil
    }

    private func shouldDeferInitialOverlayApply(
        frame: CloudOverlayService.ForecastFrame,
        template: String,
        attempt: Int
    ) -> Bool {
        // For the very first overlay on screen, wait briefly until at least some
        // source tiles for the current viewport are in cache to avoid "empty-first" flash.
        guard forecastTileTemplate == nil else { return false }
        // Do not block overlay apply for long; better show quickly and let tile cache catch up.
        guard attempt < 3 else { return false }
        guard let snapshot = visibleTileSnapshot, !snapshot.tiles.isEmpty else {
            // Wait until MKMapView produces the first visible tile snapshot, otherwise
            // bootstrap prewarm can target the wrong zoom and you end up with "nothing until zoom".
            return true
        }

        let hasCoverage = UIKitMap.ForecastTileOverlay.hasSourceCacheCoverage(
            template: template,
            minSourceZ: frame.minZoom,
            maxSourceZ: frame.maxZoom,
            requestedZoom: snapshot.zoom,
            visibleTiles: snapshot.tiles,
            minimumTiles: 1
        )
        if hasCoverage { return false }

        if attempt == 0 {
            bootstrapForecastVisibility(frame: frame, template: template)
        }
        return true
    }

    private func bootstrapForecastVisibility(
        frame: CloudOverlayService.ForecastFrame,
        template: String
    ) {
        var prewarmCenters: [(requestedZoom: Int, tile: UIKitMap.VisibleTile)] = []

        if let snapshot = visibleTileSnapshot, !snapshot.tiles.isEmpty {
            var requestedZooms: [Int] = []
            var seenZooms = Set<Int>()
            for candidate in [snapshot.zoom, max(0, snapshot.zoom - 1)] {
                if seenZooms.insert(candidate).inserted {
                    requestedZooms.append(candidate)
                }
            }
            for requestedZoom in requestedZooms {
                let projected = projectVisibleTiles(
                    snapshot.tiles,
                    fromZoom: snapshot.zoom,
                    toZoom: requestedZoom,
                    limit: 1
                )
                if let center = projected.first {
                    prewarmCenters.append((requestedZoom, center))
                }
            }
        }

        if prewarmCenters.isEmpty,
           let probe = resolvedProbeCoordinate()
        {
            let requestedZoom = min(max(frame.minZoom, 5), frame.maxZoom)
            if let center = tileForCoordinate(probe, zoom: requestedZoom) {
                prewarmCenters.append((requestedZoom, center))
            }
        }

        guard !prewarmCenters.isEmpty else { return }

        var warmedSourceKeys = Set<String>()
        var warmedRenderedKeys = Set<String>()

        for entry in prewarmCenters {
            let requestedZoom = max(0, min(20, entry.requestedZoom))
            let sourceZ = min(max(requestedZoom, frame.minZoom), frame.maxZoom)
            let sourceN = 1 << sourceZ
            let requestedN = 1 << requestedZoom
            guard sourceN > 0, requestedN > 0 else { continue }
            let zoomDelta = max(0, requestedZoom - sourceZ)

            for dy in -1...1 {
                for dx in -1...1 {
                    let reqX = ((entry.tile.x + dx) % requestedN + requestedN) % requestedN
                    let reqY = max(0, min(requestedN - 1, entry.tile.y + dy))
                    let sourceX = ((reqX >> zoomDelta) % sourceN + sourceN) % sourceN
                    let sourceY = reqY >> zoomDelta
                    guard sourceY >= 0, sourceY < sourceN else { continue }

                    let sourceKey = "\(sourceZ)|\(sourceX)|\(sourceY)"
                    guard warmedSourceKeys.insert(sourceKey).inserted else { continue }

                    UIKitMap.ForecastTileOverlay.prewarmTile(
                        template: template,
                        z: sourceZ,
                        x: sourceX,
                        y: sourceY
                    )
                }
            }

            let renderedKey = "\(requestedZoom)|\(entry.tile.x)|\(entry.tile.y)"
            if warmedRenderedKeys.insert(renderedKey).inserted {
                UIKitMap.ForecastTileOverlay.prewarmRenderedTile(
                    template: template,
                    minSourceZ: frame.minZoom,
                    maxSourceZ: frame.maxZoom,
                    requestedZoom: requestedZoom,
                    x: entry.tile.x,
                    y: entry.tile.y
                )
            }
        }
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

    private func resolvedProbeCoordinate() -> CLLocationCoordinate2D? {
        locationManager.location?.coordinate ?? lastKnownProbeCoordinate
    }

    private func needsLocalProbeRefresh(_ frame: CloudOverlayService.ForecastFrame) -> Bool {
        false
    }

    private static let hourlyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    private static let bubbleTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
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

    private func forecastTemplate(
        for frame: CloudOverlayService.ForecastFrame,
        hourStamp: Int
    ) -> String {
        _ = hourStamp
        let frameStamp = Int(frame.time.timeIntervalSince1970 / 3600)
        return cacheBustingTemplate(frame.tileTemplate, stamp: frameStamp)
    }

    private func cacheBustingTemplate(_ template: String, stamp: Int) -> String {
        // Backend templates already contain immutable frame stamp in path
        // (/v1/tiles/{YYYYMMDDHHMM}/...), so extra "t=" only hurts cache reuse.
        if template.contains("/v1/tiles/") {
            return template
        }

        // Keep {z}/{x}/{y} placeholders untouched.
        let parts = template.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let baseWithQuery = String(parts.first ?? "")
        let fragment = parts.count > 1 ? String(parts[1]) : nil

        let querySplit = baseWithQuery.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let base = String(querySplit.first ?? "")
        let rawQuery = querySplit.count > 1 ? String(querySplit[1]) : ""

        var kept: [String] = []
        if !rawQuery.isEmpty {
            for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
                let item = String(pair)
                let key = item.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                if key == "v" || key == "t" { continue }
                kept.append(item)
            }
        }
        kept.append("t=\(stamp)")

        let rebuilt = base + "?" + kept.joined(separator: "&")
        if let fragment, !fragment.isEmpty {
            return rebuilt + "#" + fragment
        }
        return rebuilt
    }
}

private enum CloudFieldService {
    enum Model: String, CaseIterable {
        case auto = "forecast"
        case icon = "dwd-icon"
        case gfs = "gfs"
        case ecmwf = "ecmwf"
    }

    struct GridPoint {
        let center: CLLocationCoordinate2D
        let row: Int
        let col: Int
        let gridSize: Int
        let stepDegrees: Double
    }

    enum FetchResult {
        case success([CloudOverlayService.CloudCell])
        case failure(String)
    }

    private struct CacheEntry {
        let expiresAt: Date
        let cells: [CloudOverlayService.CloudCell]
    }

    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
    private static let stateQueue = DispatchQueue(label: "RainApp.CloudFieldService.state")
    private static var cache: [String: CacheEntry] = [:]
    private static var inFlight: [String: [(FetchResult) -> Void]] = [:]

    static func fetchField(
        points: [GridPoint],
        targetDate: Date,
        model: Model = .icon,
        completion: @escaping (FetchResult) -> Void
    ) {
        guard !points.isEmpty else {
            completion(.success([]))
            return
        }
        let reqKey = requestKey(points: points, targetDate: targetDate, model: model)
        guard beginRequest(reqKey: reqKey, completion: completion) else {
            return
        }

        let plan = requestPlan(for: model)
        fetchFieldFromPlan(
            points: points,
            targetDate: targetDate,
            reqKey: reqKey,
            plan: plan,
            index: 0
        )
    }

    private static func requestPlan(for preferred: Model) -> [Model] {
        switch preferred {
        case .auto:
            return [.auto, .icon, .gfs, .ecmwf]
        case .icon:
            return [.icon, .auto, .gfs]
        case .gfs:
            return [.gfs, .auto, .icon]
        case .ecmwf:
            return [.ecmwf, .auto, .icon]
        }
    }

    private static func fetchFieldFromPlan(
        points: [GridPoint],
        targetDate: Date,
        reqKey: String,
        plan: [Model],
        index: Int
    ) {
        guard index < plan.count else {
            finishRequest(
                reqKey: reqKey,
                result: .failure("All Open-Meteo cloud sources failed")
            )
            return
        }

        let model = plan[index]
        let latitudes = points.map { String(format: "%.4f", $0.center.latitude) }.joined(separator: ",")
        let longitudes = points.map { String(format: "%.4f", $0.center.longitude) }.joined(separator: ",")
        let hourlyVars = [
            "cloud_cover",
            "precipitation",
            "rain",
            "snowfall",
            "weather_code"
        ].joined(separator: ",")

        let endpoint = "https://api.open-meteo.com/v1/\(model.rawValue)"
        let urlString =
            endpoint +
            "?latitude=\(latitudes)" +
            "&longitude=\(longitudes)" +
            "&hourly=\(hourlyVars)" +
            "&forecast_days=2&timezone=auto"

        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded)
        else {
            fetchFieldFromPlan(
                points: points,
                targetDate: targetDate,
                reqKey: reqKey,
                plan: plan,
                index: index + 1
            )
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 16
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                _ = error
                fetchFieldFromPlan(
                    points: points,
                    targetDate: targetDate,
                    reqKey: reqKey,
                    plan: plan,
                    index: index + 1
                )
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard statusCode == 200, let data else {
                fetchFieldFromPlan(
                    points: points,
                    targetDate: targetDate,
                    reqKey: reqKey,
                    plan: plan,
                    index: index + 1
                )
                return
            }

            do {
                let payloads: [CloudFieldResponsePayload]
                if let list = try? JSONDecoder().decode([CloudFieldResponsePayload].self, from: data) {
                    payloads = list
                } else {
                    payloads = [try JSONDecoder().decode(CloudFieldResponsePayload.self, from: data)]
                }
                guard !payloads.isEmpty else {
                    finishRequest(
                        reqKey: reqKey,
                        result: .failure("Empty model payload")
                    )
                    return
                }

                let referenceTimes = payloads[0].hourly.time
                let parsedTimes = referenceTimes.compactMap { parser.date(from: $0) }
                guard !parsedTimes.isEmpty else {
                    finishRequest(
                        reqKey: reqKey,
                        result: .failure("No hourly timestamps in model payload")
                    )
                    return
                }

                let hourIndex: Int = {
                    if let idx = parsedTimes.firstIndex(where: { $0 >= targetDate }) {
                        return idx
                    }
                    return max(0, parsedTimes.count - 1)
                }()

                let count = min(points.count, payloads.count)
                var cells: [CloudOverlayService.CloudCell] = []
                cells.reserveCapacity(count)

                for index in 0..<count {
                    let point = points[index]
                    let hourly = payloads[index].hourly
                    let cover = value(hourly.cloud_cover, at: hourIndex) ?? 0
                    let precipitation = value(hourly.precipitation, at: hourIndex) ?? 0
                    let rain = value(hourly.rain, at: hourIndex) ?? max(0, precipitation)
                    let snowfall = value(hourly.snowfall, at: hourIndex) ?? 0
                    let cloudFactor = max(0.0, min(1.0, cover / 100.0))
                    let rainNorm = min(1.0, rain / 2.8)
                    let snowNorm = min(1.0, snowfall / 1.0)
                    let precipNorm = min(1.0, precipitation / 3.0)
                    let precipitationSignal = max(rainNorm, max(snowNorm * 0.9, precipNorm * 0.6))

                    // Main signal is cloud coverage across viewport.
                    // Precipitation only slightly boosts opacity so we avoid isolated dark patches.
                    let rainIntensity: Double = {
                        let cloudBase = 0.020 + cloudFactor * 0.110
                        let precipBoost = precipitationSignal * 0.030
                        let snowBoost = snowNorm * 0.018
                        return min(0.20, cloudBase + precipBoost + snowBoost)
                    }()

                    // Disable storm darkening in cloud mode.
                    let stormRisk: Double = 0

                    cells.append(
                        CloudOverlayService.CloudCell(
                            center: point.center,
                            rainIntensity: rainIntensity,
                            stormRisk: stormRisk,
                            stepDegrees: point.stepDegrees,
                            row: point.row,
                            col: point.col,
                            gridSize: point.gridSize
                        )
                    )
                }

                finishRequest(
                    reqKey: reqKey,
                    result: .success(cells),
                    cacheTTL: 90
                )
            } catch {
                fetchFieldFromPlan(
                    points: points,
                    targetDate: targetDate,
                    reqKey: reqKey,
                    plan: plan,
                    index: index + 1
                )
            }
        }.resume()
    }

    private static func requestKey(
        points: [GridPoint],
        targetDate: Date,
        model: Model
    ) -> String {
        let hourStamp = Int(targetDate.timeIntervalSince1970 / 3600)
        let center = points[points.count / 2].center
        let latQ = (center.latitude * 20).rounded() / 20
        let lonQ = (center.longitude * 20).rounded() / 20
        let step = points.first?.stepDegrees ?? 0.2
        return [
            model.rawValue,
            "h\(hourStamp)",
            "n\(points.count)",
            String(format: "lat%.2f", latQ),
            String(format: "lon%.2f", lonQ),
            String(format: "step%.3f", step)
        ].joined(separator: "|")
    }

    private static func beginRequest(
        reqKey: String,
        completion: @escaping (FetchResult) -> Void
    ) -> Bool {
        var cachedCells: [CloudOverlayService.CloudCell]?
        var shouldStart = false
        stateQueue.sync {
            let now = Date()
            pruneExpiredCache(now: now)
            if let entry = cache[reqKey], entry.expiresAt > now {
                cachedCells = entry.cells
                return
            }
            if var callbacks = inFlight[reqKey] {
                callbacks.append(completion)
                inFlight[reqKey] = callbacks
                return
            }
            inFlight[reqKey] = [completion]
            shouldStart = true
        }

        if let cachedCells {
            DispatchQueue.main.async {
                completion(.success(cachedCells))
            }
            return false
        }

        return shouldStart
    }

    private static func finishRequest(
        reqKey: String,
        result: FetchResult,
        cacheTTL: TimeInterval? = nil
    ) {
        var callbacks: [(FetchResult) -> Void] = []
        stateQueue.sync {
            if case .success(let cells) = result, let cacheTTL {
                cache[reqKey] = CacheEntry(
                    expiresAt: Date().addingTimeInterval(cacheTTL),
                    cells: cells
                )
            }
            callbacks = inFlight.removeValue(forKey: reqKey) ?? []
        }

        DispatchQueue.main.async {
            for callback in callbacks {
                callback(result)
            }
        }
    }

    private static func pruneExpiredCache(now: Date) {
        cache = cache.filter { $0.value.expiresAt > now }
    }

    private static func value(_ values: [Double]?, at index: Int) -> Double? {
        guard let values, index >= 0, index < values.count else { return nil }
        return max(0, values[index])
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

private struct CloudFieldResponsePayload: Decodable {
    struct Hourly: Decodable {
        let time: [String]
        let cloud_cover: [Double]?
        let precipitation: [Double]?
        let rain: [Double]?
        let snowfall: [Double]?
        let weather_code: [Int]?
    }

    let hourly: Hourly
}
