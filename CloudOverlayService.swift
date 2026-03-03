import Foundation
import MapKit

struct CloudOverlayService {

    struct CloudCell {
        let center: CLLocationCoordinate2D
        let rainIntensity: Double
        let stormRisk: Double
        let stepDegrees: Double
        let row: Int
        let col: Int
        let gridSize: Int
    }

    enum FetchResult {
        case success([CloudCell])
        case rateLimited(String)
        case failure(String)
    }

    struct ForecastFrame {
        struct LocalSignalSample {
            let hasSignal: Bool
            let red: Double
            let green: Double
            let blue: Double
            let alpha: Double

            static let none = LocalSignalSample(
                hasSignal: false,
                red: 0,
                green: 0,
                blue: 0,
                alpha: 0
            )
        }

        let tileTemplate: String
        let time: Date
        let minZoom: Int
        let maxZoom: Int
        let hasLikelySignal: Bool
        let localSignalSample: LocalSignalSample?

        init(
            tileTemplate: String,
            time: Date,
            minZoom: Int,
            maxZoom: Int,
            hasLikelySignal: Bool = true,
            localSignalSample: LocalSignalSample? = nil
        ) {
            self.tileTemplate = tileTemplate
            self.time = time
            self.minZoom = minZoom
            self.maxZoom = maxZoom
            self.hasLikelySignal = hasLikelySignal
            self.localSignalSample = localSignalSample
        }
    }

    enum ForecastResult {
        case success(ForecastFrame)
        case failure(String)
    }

    // Legacy method kept for compatibility with older call sites.
    static func fetchCloudCells(
        center: CLLocationCoordinate2D,
        targetDate: Date,
        completion: @escaping (FetchResult) -> Void
    ) {
        completion(.failure("Legacy cloud grid endpoint is disabled"))
    }

    static func fetchForecastFrame(
        targetDate: Date,
        near coordinate: CLLocationCoordinate2D? = nil,
        probeSignalNearUser: Bool = false,
        completion: @escaping (ForecastResult) -> Void
    ) {
        queue.async {
            loadPersistentCacheIfNeeded()
            if
                let cached = cachedAvailable,
                Date().timeIntervalSince(cachedAt) < cacheTTL,
                let frame = pickFrame(
                    from: cached,
                    targetDate: targetDate,
                    near: coordinate,
                    probeSignalNearUser: probeSignalNearUser
                )
            {
                DispatchQueue.main.async {
                    completion(.success(frame))
                }
                return
            }

            pendingRequests.append((targetDate, coordinate, probeSignalNearUser, completion))
            if isFetchingAvailable { return }
            isFetchingAvailable = true
            fetchAvailable()
        }
    }

    // MARK: - Private

    private struct AvailableResponse: Codable {
        let minzoom: Int?
        let maxzoom: Int?
        let times: [TimeEntry]

        struct TimeEntry: Codable {
            let time: String
            let tiles: TileSet
        }

        struct TileSet: Codable {
            let png: String?
            let webp: String?
        }
    }

    private static let defaultEndpoint = URL(string:
        "https://prod.yr-maps.met.no/api/precipitation-amount/available.json"
    )!
    private static let backendBaseURL: URL? = {
        guard
            let raw = Bundle.main.object(
                forInfoDictionaryKey: "RainBackendBaseURL"
            ) as? String
        else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        return url
    }()
    private static let backendStrictMode: Bool = {
        if
            let value = Bundle.main.object(
                forInfoDictionaryKey: "RainBackendStrictMode"
            ) as? Bool
        {
            return value
        }
        return true
    }()
    private static let preferWebPTiles: Bool = {
        // MapKit tile overlays historically preferred PNG/JPEG, but modern iOS can decode WebP.
        // Keep it opt-in so we can fall back quickly if MapKit rejects the format.
        if
            let value = Bundle.main.object(
                forInfoDictionaryKey: "RainPreferWebPTiles"
            ) as? Bool
        {
            return value
        }
        return false
    }()

    private static let userAgent = "RainApp/1.0 (+https://github.com/alex/RainApp)"
    private static let queue = DispatchQueue(label: "CloudOverlayService.queue")
    private static let cacheTTL: TimeInterval = 2 * 60
    private static let persistentCacheKey = "rain.available.cache"
    private static let persistentCacheTimeKey = "rain.available.cache.time"
    private static let networkSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 14
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private static var cachedAvailable: AvailableResponse?
    private static var cachedAt: Date = .distantPast
    private static var persistentCacheLoaded = false
    private static var isFetchingAvailable = false
    private static var pendingRequests: [
        (Date, CLLocationCoordinate2D?, Bool, (ForecastResult) -> Void)
    ] = []

    private static func fetchAvailable() {
        let endpoints = availableEndpoints()
        fetchAvailable(from: endpoints, index: 0, allowDefaultFallback: true)
    }

    private static func availableEndpoints() -> [URL] {
        if let backendBaseURL {
            let backendEndpoint = backendBaseURL.appendingPathComponent("v1/available")
            if backendStrictMode {
                return [backendEndpoint]
            }
            return [backendEndpoint, defaultEndpoint]
        }
        return [defaultEndpoint]
    }

    private static func fetchAvailable(
        from endpoints: [URL],
        index: Int,
        allowDefaultFallback: Bool
    ) {
        guard index < endpoints.count else {
            isFetchingAvailable = false
            if cachedAvailable != nil {
                print("☁️DBG available endpoint failed; using cached metadata (stale)")
                flushPendingFromCache()
                return
            }
            if allowDefaultFallback,
               !backendStrictMode,
               backendBaseURL != nil
            {
                print("☁️DBG available endpoint failed; trying upstream fallback")
                fetchAvailable(from: [defaultEndpoint], index: 0, allowDefaultFallback: false)
                return
            }
            flushPending(with: .failure("No available metadata endpoint responded"))
            return
        }

        let endpoint = endpoints[index]
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        networkSession.dataTask(with: request) { data, response, error in
            queue.async {
                if let error {
                    _ = error
                    print("☁️DBG available endpoint failed:", endpoint.absoluteString)
                    fetchAvailable(from: endpoints, index: index + 1, allowDefaultFallback: allowDefaultFallback)
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard statusCode == 200, let data else {
                    print(
                        "☁️DBG available endpoint bad status:",
                        endpoint.absoluteString,
                        statusCode
                    )
                    fetchAvailable(from: endpoints, index: index + 1, allowDefaultFallback: allowDefaultFallback)
                    return
                }

                do {
                    let decoded = try JSONDecoder().decode(AvailableResponse.self, from: data)
                    let baseURL = (response as? HTTPURLResponse)?.url ?? endpoint
                    let available = normalizeAvailableResponse(
                        decoded,
                        responseURL: baseURL
                    )
                    let backendSource = endpoint.path.contains("/v1/available")
                    print(
                        "☁️DBG available endpoint ok:",
                        backendSource ? "backend" : "upstream",
                        endpoint.absoluteString
                    )
                    cachedAvailable = available
                    cachedAt = Date()
                    persistAvailableCache(available, cachedAt: cachedAt)
                    isFetchingAvailable = false
                    flushPendingFromCache()
                } catch {
                    print("☁️DBG available endpoint decode failed:", endpoint.absoluteString)
                    fetchAvailable(from: endpoints, index: index + 1, allowDefaultFallback: allowDefaultFallback)
                }
            }
        }.resume()
    }

    private static func normalizeAvailableResponse(
        _ available: AvailableResponse,
        responseURL: URL
    ) -> AvailableResponse {
        let normalizedTimes = available.times.map { entry -> AvailableResponse.TimeEntry in
            let normalizedTiles = AvailableResponse.TileSet(
                png: normalizeTemplate(entry.tiles.png, responseURL: responseURL),
                webp: normalizeTemplate(entry.tiles.webp, responseURL: responseURL)
            )
            return AvailableResponse.TimeEntry(
                time: entry.time,
                tiles: normalizedTiles
            )
        }
        return AvailableResponse(
            minzoom: available.minzoom,
            maxzoom: available.maxzoom,
            times: normalizedTimes
        )
    }

    private static func loadPersistentCacheIfNeeded() {
        guard !persistentCacheLoaded else { return }
        persistentCacheLoaded = true
        let defaults = UserDefaults.standard
        // For local backend mode, avoid old on-disk metadata (vXX) mixing with current server state.
        if backendBaseURL != nil {
            defaults.removeObject(forKey: persistentCacheKey)
            defaults.removeObject(forKey: persistentCacheTimeKey)
            return
        }
        guard let data = defaults.data(forKey: persistentCacheKey) else { return }
        guard let cachedTime = defaults.object(forKey: persistentCacheTimeKey) as? Date else { return }
        do {
            let decoded = try JSONDecoder().decode(AvailableResponse.self, from: data)
            cachedAvailable = decoded
            cachedAt = cachedTime
            print("☁️DBG available cache loaded from disk")
        } catch {
            _ = error
        }
    }

    private static func persistAvailableCache(
        _ available: AvailableResponse,
        cachedAt: Date
    ) {
        do {
            let data = try JSONEncoder().encode(available)
            let defaults = UserDefaults.standard
            defaults.set(data, forKey: persistentCacheKey)
            defaults.set(cachedAt, forKey: persistentCacheTimeKey)
        } catch {
            _ = error
        }
    }

    private static func normalizeTemplate(
        _ rawTemplate: String?,
        responseURL: URL
    ) -> String? {
        guard let rawTemplate else { return nil }
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if URL(string: trimmed)?.scheme != nil {
            return trimmed
        }
        guard let absolute = URL(
            string: trimmed,
            relativeTo: responseURL
        )?.absoluteURL else {
            return nil
        }
        return absolute.absoluteString
    }

    private static func flushPendingFromCache() {
        guard let cached = cachedAvailable else {
            flushPending(with: .failure("No cached frame metadata"))
            return
        }

        let requests = pendingRequests
        pendingRequests.removeAll()

        for (targetDate, coordinate, probeSignalNearUser, completion) in requests {
            if let frame = pickFrame(
                from: cached,
                targetDate: targetDate,
                near: coordinate,
                probeSignalNearUser: probeSignalNearUser
            ) {
                DispatchQueue.main.async {
                    completion(.success(frame))
                }
            } else {
                DispatchQueue.main.async {
                    completion(.failure("No precipitation frames available"))
                }
            }
        }
    }

    private static func flushPending(with result: ForecastResult) {
        let requests = pendingRequests
        pendingRequests.removeAll()

        for (_, _, _, completion) in requests {
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func pickFrame(
        from available: AvailableResponse,
        targetDate: Date,
        near coordinate: CLLocationCoordinate2D?,
        probeSignalNearUser: Bool
    ) -> ForecastFrame? {
        let minZoom = available.minzoom ?? 0
        let maxZoom = max(minZoom, available.maxzoom ?? 6)

        let parsed: [ForecastFrame] = available.times.compactMap { entry in
            let template: String? = {
                if preferWebPTiles {
                    return entry.tiles.webp ?? entry.tiles.png
                }
                return entry.tiles.png ?? entry.tiles.webp
            }()
            guard let template else { return nil }
            guard let time = parseISODate(entry.time) else { return nil }
            return ForecastFrame(
                tileTemplate: template,
                time: time,
                minZoom: minZoom,
                maxZoom: maxZoom
            )
        }

        let frames = parsed.sorted(by: { $0.time < $1.time })
        guard !frames.isEmpty else { return nil }

        // Prefer stepping through the available frame list based on the user's
        // time-wheel offset, rather than strictly picking the first frame >= targetDate.
        //
        // Reason: depending on upstream/backend availability windows, all wheel hours can
        // map to the same earliest-available frame, making the overlay look "stuck".
        let now = Date()
        let calendar = Calendar.current
        let nowHourStart = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: 0,
            second: 0,
            of: now
        ) ?? now
        let baseIndex: Int = {
            if let idx = frames.firstIndex(where: { $0.time >= nowHourStart }) {
                return idx
            }
            return max(0, frames.count - 1)
        }()
        let stepSeconds: TimeInterval = {
            guard frames.count >= 3 else { return 5 * 60 }
            var deltas: [TimeInterval] = []
            deltas.reserveCapacity(frames.count - 1)
            for i in 1..<frames.count {
                let d = frames[i].time.timeIntervalSince(frames[i - 1].time)
                if d > 0 { deltas.append(d) }
            }
            guard !deltas.isEmpty else { return 5 * 60 }
            deltas.sort()
            let median = deltas[deltas.count / 2]
            // Keep step within reasonable bounds to avoid wild jumps.
            return min(60 * 60, max(60, median))
        }()
        let framesPerHour = max(1, Int((3600.0 / max(1.0, stepSeconds)).rounded()))
        // Align offsets to hour buckets (current hour + N), not to raw "now" minutes.
        // This avoids negative offset at startup when current minutes > 30.
        let offsetHours = calendar.dateComponents([.hour], from: nowHourStart, to: targetDate).hour ?? 0
        let desiredIndex = min(
            max(0, baseIndex + offsetHours * framesPerHour),
            frames.count - 1
        )
        let selected = frames[desiredIndex]

#if DEBUG
        let stamp = selected.tileTemplate
            .split(separator: "/")
            .first(where: { $0.count == 12 && $0.allSatisfy(\.isNumber) })
            .map(String.init) ?? "?"
        print(
            "☁️DBG pickFrame",
            "frames=\(frames.count)",
            "base=\(baseIndex)",
            "step=\(Int(stepSeconds))s",
            "fph=\(framesPerHour)",
            "offH=\(offsetHours)",
            "idx=\(desiredIndex)",
            "stamp=\(stamp)"
        )
#endif

        _ = coordinate
        _ = probeSignalNearUser
        // Always use the precipitation frame directly.
        // Local pixel probing adds latency and can suppress valid rain coverage.
        return selected
    }

    private static func parseISODate(_ raw: String) -> Date? {
        if let date = isoFormatterWithFractional.date(from: raw) { return date }
        if let date = isoFormatter.date(from: raw) { return date }
        return nil
    }

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
