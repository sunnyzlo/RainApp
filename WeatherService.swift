import Foundation
import CoreLocation

struct WeatherService {

    static func fetchWeather(
        location: CLLocation,
        completion: @escaping (WeatherData?) -> Void
    ) {

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude

        let urlString =
        """
        https://api.open-meteo.com/v1/forecast\
        ?latitude=\(lat)\
        &longitude=\(lon)\
        &current=temperature_2m,apparent_temperature,wind_speed_10m,relative_humidity_2m,weather_code\
        &hourly=temperature_2m,apparent_temperature,wind_speed_10m,relative_humidity_2m,weather_code,precipitation\
        &timezone=auto
        """

        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in

            guard let data else {
                completion(nil)
                return
            }

            do {
                let decoded = try JSONDecoder()
                    .decode(WeatherData.self, from: data)

                completion(decoded)

            } catch {
                print("Weather decode error:", error)
                completion(nil)
            }

        }.resume()
    }
}
