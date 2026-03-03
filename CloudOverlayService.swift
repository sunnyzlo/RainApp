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
        let tileTemplate: String
        let time: Date
        let minZoom: Int
        let maxZoom: Int
        let hasLikelySignal: Bool

        init(
            tileTemplate: String,
            time: Date,
            minZoom: Int,
            maxZoom: Int,
            hasLikelySignal: Bool = true
        ) {
            self.tileTemplate = tileTemplate
            self.time = time
            self.minZoom = minZoom
            self.maxZoom = maxZoom
            self.hasLikelySignal = hasLikelySignal
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
        probeSignalNearUser: Bool = true,
        completion: @escaping (ForecastResult) -> Void
    ) {
        queue.async {
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

    private struct AvailableResponse: Decodable {
        let minzoom: Int?
        let maxzoom: Int?
        let times: [TimeEntry]

        struct TimeEntry: Decodable {
            let time: String
            let tiles: TileSet
        }

        struct TileSet: Decodable {
            let png: String?
            let webp: String?
        }
    }

    private static let endpoint = URL(string:
        "https://prod.yr-maps.met.no/api/precipitation-amount/available.json"
    )!

    private static let userAgent = "RainApp/1.0 (+https://github.com/alex/RainApp)"
    private static let queue = DispatchQueue(label: "CloudOverlayService.queue")
    private static let cacheTTL: TimeInterval = 2 * 60
    private static let signalProbeCacheTTL: TimeInterval = 8 * 60
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
    private static var isFetchingAvailable = false
    private static var pendingRequests: [
        (Date, CLLocationCoordinate2D?, Bool, (ForecastResult) -> Void)
    ] = []
    private static var signalProbeCache: [String: (value: Bool, at: Date)] = [:]
    private static var signalTileCache: [String: (value: Bool, at: Date)] = [:]
    private static var lastSignaledFrame: ForecastFrame?

    private static func fetchAvailable() {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        networkSession.dataTask(with: request) { data, response, error in
            queue.async {
                isFetchingAvailable = false

                if let error {
                    flushPending(with: .failure("Network error: \(error.localizedDescription)"))
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard statusCode == 200, let data else {
                    flushPending(with: .failure("HTTP \(statusCode)"))
                    return
                }

                do {
                    let available = try JSONDecoder().decode(AvailableResponse.self, from: data)
                    cachedAvailable = available
                    cachedAt = Date()
                    flushPendingFromCache()
                } catch {
                    let bodyPrefix = String(decoding: data.prefix(180), as: UTF8.self)
                    flushPending(with: .failure("Decode error: \(error.localizedDescription) | \(bodyPrefix)"))
                }
            }
        }.resume()
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
            let template = entry.tiles.png ?? entry.tiles.webp
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

        guard let selected = (frames
            .filter({ $0.time >= targetDate })
            .min(by: { $0.time < $1.time })) ?? frames.max(by: { $0.time < $1.time })
        else {
            return nil
        }

        guard probeSignalNearUser, let coordinate else {
            return selected
        }

        guard let selectedIndex = frames.firstIndex(where: { $0.time == selected.time }) else {
            return selected
        }

        // If chosen frame is locally empty around user, pick nearest neighbor with signal.
        let maxStep = min(6, max(0, frames.count - 1))
        var candidateIndices: [Int] = [selectedIndex]
        if maxStep > 0 {
            for step in 1...maxStep {
                let future = selectedIndex + step
                if future < frames.count {
                    candidateIndices.append(future)
                }
                let past = selectedIndex - step
                if past >= 0 {
                    candidateIndices.append(past)
                }
            }
        }

        for idx in candidateIndices {
            let frame = frames[idx]
            if hasLikelySignal(frame: frame, near: coordinate) {
                lastSignaledFrame = frame
                if idx != selectedIndex {
                    let fromHour = Int(selected.time.timeIntervalSince1970 / 3600)
                    let toHour = Int(frame.time.timeIntervalSince1970 / 3600)
                    print("☁️ Frame fallback:", fromHour, "->", toHour)
                }
                return frame
            }
        }

        if let reused = lastSignaledFrame {
            let fromHour = Int(selected.time.timeIntervalSince1970 / 3600)
            let toHour = Int(reused.time.timeIntervalSince1970 / 3600)
            print("☁️ Frame fallback: reuse", fromHour, "->", toHour)
            return reused
        }

        let selectedHour = Int(selected.time.timeIntervalSince1970 / 3600)
        print("☁️ Frame fallback: none for", selectedHour)
        return ForecastFrame(
            tileTemplate: selected.tileTemplate,
            time: selected.time,
            minZoom: selected.minZoom,
            maxZoom: selected.maxZoom,
            hasLikelySignal: false
        )
    }

    private static func hasLikelySignal(
        frame: ForecastFrame,
        near coordinate: CLLocationCoordinate2D
    ) -> Bool {
        let cacheKey = "\(frame.tileTemplate)|\(frame.maxZoom)|\(coordinate.latitude)|\(coordinate.longitude)"
        if let cached = signalProbeCache[cacheKey],
           Date().timeIntervalSince(cached.at) < signalProbeCacheTTL
        {
            return cached.value
        }

        guard let tile = tileForCoordinate(coordinate, zoom: frame.maxZoom) else {
            return true
        }
        let result = hasSignalAroundTile(
            frame: frame,
            tile: tile,
            zoom: frame.maxZoom
        )
        signalProbeCache[cacheKey] = (result, Date())
        return result
    }

    private static func hasSignalAroundTile(
        frame: ForecastFrame,
        tile: (x: Int, y: Int, px: Int, py: Int),
        zoom: Int
    ) -> Bool {
        let n = 1 << zoom
        let offsets: [(Int, Int)] = [
            (0, 0),
            (1, 0), (-1, 0), (0, 1), (0, -1),
            (1, 1), (-1, 1), (1, -1), (-1, -1)
        ]

        for (dx, dy) in offsets {
            var probeX = tile.x + dx
            var probeY = tile.y + dy
            if probeY < 0 || probeY >= n { continue }
            probeX = ((probeX % n) + n) % n

            guard let url = makeTileURL(
                template: frame.tileTemplate,
                z: zoom,
                x: probeX,
                y: probeY
            ) else {
                continue
            }

            let isCenterTile = (dx == 0 && dy == 0)
            var remoteHasSignal = fetchSignalProbe(
                url: url,
                samplePoint: isCenterTile ? (x: tile.px, y: tile.py) : nil
            )
            if !remoteHasSignal && isCenterTile {
                // Center sample can miss nearby precip inside same tile.
                remoteHasSignal = fetchSignalProbe(url: url, samplePoint: nil)
            }

            if remoteHasSignal { return true }
        }

        return false
    }

    private static func fetchSignalProbe(
        url: URL,
        samplePoint: (x: Int, y: Int)?
    ) -> Bool {
        let cacheKey = "\(url.absoluteString)|\(samplePoint?.x ?? -1)|\(samplePoint?.y ?? -1)"
        if let cached = signalTileCache[cacheKey],
           Date().timeIntervalSince(cached.at) < signalProbeCacheTTL
        {
            return cached.value
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("image/png,image/*;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        // Be conservative: failed probes should not force switching to empty frames.
        var result = false

        networkSession.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, let data else {
                result = false
                return
            }

            if let samplePoint {
                result = tileHasSignal(data: data, at: samplePoint)
            } else {
                result = tileHasSignalAnywhere(data: data)
            }
        }.resume()

        _ = semaphore.wait(timeout: .now() + 8)
        signalTileCache[cacheKey] = (result, Date())
        return result
    }

    private static func tileHasSignal(
        data: Data,
        at sample: (x: Int, y: Int)
    ) -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return true
        }
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return true
        }

        let width = image.width
        let height = image.height
        guard width > 1, height > 1 else { return true }

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
            return true
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { return true }
        let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)

        let centerX = max(0, min(width - 1, sample.x))
        let centerY = max(0, min(height - 1, sample.y))
        let radius = max(10, min(width, height) / 9)
        let minX = max(0, centerX - radius)
        let maxX = min(width - 1, centerX + radius)
        let minY = max(0, centerY - radius)
        let maxY = min(height - 1, centerY + radius)

        var coloredPixels = 0
        for y in minY...maxY {
            for x in minX...maxX {
                let idx = (y * width + x) * 4
                let alpha = Int(ptr[idx + 3])
                if alpha < 3 { continue }

                let r = Double(ptr[idx])
                let g = Double(ptr[idx + 1])
                let b = Double(ptr[idx + 2])

                // Black-ish pixel means no precipitation signal in yr tiles.
                if r <= 12.0 && g <= 12.0 && b <= 18.0 { continue }
                let brightness = max(r, max(g, b)) / 255.0
                if brightness < 0.16 { continue }
                coloredPixels += 1
                if coloredPixels >= 12 { return true }
            }
        }
        return false
    }

    private static func tileHasSignalAnywhere(data: Data) -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return true
        }
        guard let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return true
        }

        let width = image.width
        let height = image.height
        guard width > 1, height > 1 else { return true }

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
            return true
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { return true }
        let ptr = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var coloredPixels = 0
        let step = max(1, min(width, height) / 40)
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let idx = (y * width + x) * 4
                let alpha = Int(ptr[idx + 3])
                if alpha < 3 { continue }

                let r = Double(ptr[idx])
                let g = Double(ptr[idx + 1])
                let b = Double(ptr[idx + 2])

                if r <= 12.0 && g <= 12.0 && b <= 18.0 { continue }
                let brightness = max(r, max(g, b)) / 255.0
                if brightness < 0.16 { continue }
                coloredPixels += 1
                if coloredPixels >= 8 { return true }
            }
        }

        return false
    }

    private static func tileForCoordinate(
        _ coordinate: CLLocationCoordinate2D,
        zoom: Int
    ) -> (x: Int, y: Int, px: Int, py: Int)? {
        guard zoom >= 0 else { return nil }
        let lat = max(-85.05112878, min(85.05112878, coordinate.latitude))
        let lon = coordinate.longitude
        let scale = pow(2.0, Double(zoom))

        let xFloat = (lon + 180.0) / 360.0 * scale
        let latRad = lat * .pi / 180.0
        let mercN = log(tan(.pi / 4.0 + latRad / 2.0))
        let yFloat = (1.0 - mercN / .pi) / 2.0 * scale

        let tileX = Int(floor(xFloat))
        let tileY = Int(floor(yFloat))
        let fracX = xFloat - floor(xFloat)
        let fracY = yFloat - floor(yFloat)
        let pixelX = Int((fracX * 256.0).rounded())
        let pixelY = Int((fracY * 256.0).rounded())

        return (
            x: max(0, tileX),
            y: max(0, tileY),
            px: max(0, min(255, pixelX)),
            py: max(0, min(255, pixelY))
        )
    }

    private static func makeTileURL(
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
