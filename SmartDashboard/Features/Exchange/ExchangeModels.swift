import Foundation

/// open.er-api.com/v6/latest/{base} の応答
struct ERAPIResponse: Decodable {
    let result: String
    let time_last_update_unix: TimeInterval
    let time_next_update_unix: TimeInterval
    let base_code: String
    let rates: [String: Double]
}

enum ExchangeError: LocalizedError {
    case apiFailure(String)

    var errorDescription: String? {
        switch self {
        case .apiFailure(let result): return "為替APIがエラーを返しました (\(result))"
        }
    }
}

/// キャッシュと表示に使う為替データ。ratesは「1円=◯外貨」。
struct ExchangeRates: Codable, Equatable {
    var base: String
    var rates: [String: Double]
    var providerUpdatedAt: Date
    var nextUpdateAt: Date

    init(base: String, rates: [String: Double], providerUpdatedAt: Date, nextUpdateAt: Date) {
        self.base = base
        self.rates = rates
        self.providerUpdatedAt = providerUpdatedAt
        self.nextUpdateAt = nextUpdateAt
    }

    init(response r: ERAPIResponse) throws {
        guard r.result == "success" else { throw ExchangeError.apiFailure(r.result) }
        self.init(
            base: r.base_code,
            rates: r.rates,
            providerUpdatedAt: Date(timeIntervalSince1970: r.time_last_update_unix),
            nextUpdateAt: Date(timeIntervalSince1970: r.time_next_update_unix)
        )
    }

    /// 1外貨が何円か
    func yenPerUnit(_ code: String) -> Double? {
        guard let rate = rates[code], rate > 0 else { return nil }
        return 1 / rate
    }

    func toYen(_ amount: Double, from code: String) -> Double? {
        yenPerUnit(code).map { amount * $0 }
    }

    func fromYen(_ yen: Double, to code: String) -> Double? {
        guard let rate = rates[code], rate > 0 else { return nil }
        return yen * rate
    }

    var availableCodes: [String] {
        rates.keys.filter { $0 != base }.sorted()
    }
}

enum CurrencyName {
    static func japanese(_ code: String) -> String {
        Locale(identifier: "ja_JP").localizedString(forCurrencyCode: code) ?? code
    }
}
