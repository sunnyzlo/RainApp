import Foundation

struct WeatherData: Codable {

    struct Current: Codable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let wind_speed_10m: Double
        let relative_humidity_2m: Int
        let weather_code: Int
    }

    struct Hourly: Codable {
        let time: [String]
        let temperature_2m: [Double]
        let apparent_temperature: [Double]
        let wind_speed_10m: [Double]
        let relative_humidity_2m: [Int]
        let weather_code: [Int]
        let precipitation: [Double]?
    }

    let current: Current
    let hourly: Hourly
}//
//  WeatherData.swift
//  RainApp
//
//  Created by Alexander Savchenko on 2/7/26.
//
