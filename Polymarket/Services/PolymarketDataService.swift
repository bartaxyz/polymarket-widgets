//
//  PolymarketDataService.swift
//  Polymarket
//
//  Created by Ondřej Bárta on 1/5/25.
//

import Foundation

class PolymarketDataService {
    
    // Cache manager for API responses
    private static let cache = NSCache<NSString, CacheEntry>()
    private static let cacheDuration: TimeInterval = 300 // 5 minutes
    
    class CacheEntry {
        let data: Data
        let timestamp: Date
        
        init(data: Data) {
            self.data = data
            self.timestamp = Date()
        }
        
        var isValid: Bool {
            return Date().timeIntervalSince(timestamp) < cacheDuration
        }
    }
    
    // Method to invalidate all cached data
    static func invalidateCache() {
        cache.removeAllObjects()
    }
    
    // Helper method to fetch data with caching
    private static func fetchData(from url: URL) throws -> Data {
        let cacheKey = url.absoluteString as NSString
        
        // Check if we have a valid cached response
        if let cachedEntry = cache.object(forKey: cacheKey), cachedEntry.isValid {
            return cachedEntry.data
        }
        
        // If no valid cache entry, fetch from network
        let data = try Data(contentsOf: url)
        
        // Store in cache
        let cacheEntry = CacheEntry(data: data)
        cache.setObject(cacheEntry, forKey: cacheKey)
        
        return data
    }
    
    /**
     * Fetch Portfolio
     * ```
     * GET https://data-api.polymarket.com/value?user=<user_id>
     * [{
     *   "user": "0x235a480a9ccb7ada0ad2dc11dac3a11fb433febd",
     *   "value": 1209.4328514150002,
     * }]
     * ```
     */
    static func fetchPortfolio(userId: String) async throws -> Double {
        let url = URL(string: "https://data-api.polymarket.com/value?user=\(userId)")!
        let data = try fetchData(from: url)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as! [[String: Any]]
        return json[0]["value"] as! Double
    }

    /**
     * Fetch PnL
     * ```
     * GET https://user-pnl-api.polymarket.com/user-pnl?user_address=<user_id>&interval=1w&fidelity=3h
     * [{"t":1745971200,"p":317.79596}, ...
     * ```
     */
    enum PnLInterval: String {
        case max = "max"
        case month = "1m"
        case week = "1w"
        case day = "1d"
        case twelveHours = "12h"
        case sixHours = "6h"
        
        var defaultFidelity: PnLFidelity {
            switch self {
            case .max: return .twelveHours
            case .month: return .threeHours
            case .week: return .threeHours
            case .day, .twelveHours, .sixHours: return .oneHour
            }
        }
    }
    enum PnLFidelity: String {
        case day = "1d"
        case eighteenHours = "18h"
        case twelveHours = "12h"
        case threeHours = "3h"
        case oneHour = "1h"
    }
    enum PnLRange: String, CaseIterable {
        case today = "today"
        case day = "1d"
        case week = "1w"
        case month = "1m"
        case max = "max"

        var interval: PnLInterval {
            switch self {
            case .max: return .max
            case .month: return .month
            case .week: return .week
            case .day: return .day
            case .today: return .day
            }
        }
        var label: String {
            switch self {
            case .max: return "All"
            case .month: return "1M"
            case .week: return "1W"
            case .day: return "1D"
            case .today: return "Today"
            }
        }
    }
    struct PnLRawDataPoint: Decodable {
        var t: Int
        var p: String
    }
    struct PnLDataPoint: Decodable, Equatable {
        var t: Date
        var p: Double
    }
    static func fetchPnL(userId: String, interval: PnLInterval = .day, fidelity: PnLFidelity? = nil) async throws -> [PnLDataPoint] {
        let effectiveFidelity = fidelity ?? interval.defaultFidelity
        let url = URL(string: "https://user-pnl-api.polymarket.com/user-pnl?user_address=\(userId)&interval=\(interval.rawValue)&fidelity=\(effectiveFidelity.rawValue)")!
        print(url)
        let data = try fetchData(from: url)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        
        print(data)

        return raw.compactMap { dict in
            guard let t = dict["t"] as? Int else { return nil }

            // p might be Double or String
            let p: Double
            if let num = dict["p"] as? Double {
                p = num
            } else if let str = dict["p"] as? String, let num = Double(str) {
                p = num
            } else {
                return nil
            }

            return PnLDataPoint(
                t: Date(timeIntervalSince1970: TimeInterval(t)),
                p: p
            )
        }
    }
    
    struct Position: Decodable {
        let proxyWallet: String
        let asset: String
        let conditionId: String
        let size: Double
        let avgPrice: Double
        let initialValue: Double
        let currentValue: Double
        let cashPnl: Double
        let percentPnl: Double
        let totalBought: Double
        let realizedPnl: Double
        let percentRealizedPnl: Double
        let curPrice: Double
        let redeemable: Bool
        let mergeable: Bool
        let title: String
        let slug: String
        let icon: String
        let eventSlug: String
        let outcome: String
        let outcomeIndex: Int
        let oppositeOutcome: String
        let oppositeAsset: String
        let endDate: String
        let negativeRisk: Bool
    }
    
    static func fetchPositions(userId: String, sizeThreshold: Double = 0.1, limit: Int = 50, offset: Int = 0, sortBy: String = "CURRENT", sortDirection: String = "DESC") async throws -> [Position] {
        var components = URLComponents(string: "https://data-api.polymarket.com/positions")!
        components.queryItems = [
            URLQueryItem(name: "user", value: userId),
            URLQueryItem(name: "sizeThreshold", value: String(sizeThreshold)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortDirection", value: sortDirection)
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        let data = try fetchData(from: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([Position].self, from: data)
    }
    
    struct UserData {
        var portfolioValue: Double?
        var pnlData: [PnLDataPoint]?
        var positions: [Position]?
    }
    
    static func fetchUserData(userId: String, pnlInterval: PnLInterval = .day, pnlFidelity: PnLFidelity? = nil) async -> UserData {
        async let portfolioTask = Task<Double?, Never> {
            do {
                return try await fetchPortfolio(userId: userId)
            } catch {
                print("Failed to fetch portfolio: \(error)")
                return nil
            }
        }
        
        async let pnlTask = Task<[PnLDataPoint]?, Never> {
            do {
                return try await fetchPnL(userId: userId, interval: pnlInterval, fidelity: pnlFidelity)
            } catch {
                print("Failed to fetch PnL: \(error)")
                return nil
            }
        }
        
        async let positionsTask = Task<[Position]?, Never> {
            do {
                return try await fetchPositions(userId: userId)
            } catch {
                print("Failed to fetch positions: \(error)")
                return nil
            }
        }
        
        let portfolioValue = await portfolioTask.value
        let pnlData = await pnlTask.value
        let positions = await positionsTask.value
        
        return UserData(
            portfolioValue: portfolioValue,
            pnlData: pnlData,
            positions: positions
        )
    }

    struct SearchResponse: Decodable {
        let events: [Event]
        let hasMore: Bool
    }
    
    struct Event: Decodable {
        let id: String
        let title: String
        let slug: String
        let description: String?
        let imageUrl: String?
        let endDate: String?
        let volume: Double?
        let liquidity: Double?
    }
    
    static func searchEvents(query: String, category: String = "all", page: Int = 1) async throws -> SearchResponse {
        var components = URLComponents(string: "https://polymarket.com/api/events/search")!
        components.queryItems = [
            URLQueryItem(name: "_c", value: category),
            URLQueryItem(name: "_q", value: query),
            URLQueryItem(name: "_p", value: String(page))
        ]
        
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        
        let data = try fetchData(from: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SearchResponse.self, from: data)
    }
}
