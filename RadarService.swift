import Foundation

struct RadarService {

    struct RadarFrame {
        let time: Date
        let path: String
        let isNowcast: Bool
    }

    private struct APIResponse: Decodable {
        let radar: RadarBlock
    }

    private struct RadarBlock: Decodable {
        let past: [APIRadarFrame]?
        let nowcast: [APIRadarFrame]?
    }

    private struct APIRadarFrame: Decodable {
        let time: Int
        let path: String
    }

    static func fetchRadarFrames(completion: @escaping ([RadarFrame]) -> Void) {

        let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard
                let data,
                let decoded = try? JSONDecoder().decode(APIResponse.self, from: data)
            else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            var frames: [RadarFrame] = []

            if let past = decoded.radar.past {
                frames += past.map {
                    RadarFrame(
                        time: Date(timeIntervalSince1970: TimeInterval($0.time)),
                        path: $0.path,
                        isNowcast: false
                    )
                }
            }

            if let nowcast = decoded.radar.nowcast {
                frames += nowcast.map {
                    RadarFrame(
                        time: Date(timeIntervalSince1970: TimeInterval($0.time)),
                        path: $0.path,
                        isNowcast: true
                    )
                }
            }

            let sorted = frames.sorted { $0.time < $1.time }

            DispatchQueue.main.async {
                completion(sorted)
            }
        }.resume()
    }

    static func fetchLatestRadarPath(completion: @escaping (String?) -> Void) {
        fetchRadarFrames { frames in
            completion(frames.last?.path)
        }
    }
}
