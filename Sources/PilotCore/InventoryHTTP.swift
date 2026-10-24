import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data; self.statusCode = statusCode; self.headers = headers
    }
}
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> HTTPResponse
}
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }
    public init(session: URLSession) { self.session = session }
    public func data(for request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AppleServiceError.invalidResponse("Expected HTTP response") }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key).lowercased()] = String(describing: entry.value)
        }
        return HTTPResponse(data: data, statusCode: response.statusCode, headers: headers)
    }
}
public enum AppleServiceError: Error, Equatable, Sendable, LocalizedError {
    case invalidInput(String), authenticationRequired, blocked(Int), rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int), invalidResponse(String), unsupportedMarket(String), productUnavailable(Market)
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let detail): detail
        case .authenticationRequired: "Apple did not allow this guest request (HTTP 401). Guest availability could not be checked."
        case .blocked(let status): "Apple blocked this request (HTTP \(status)). Monitoring will back off."
        case .rateLimited: "Apple requested fewer requests. Monitoring will back off."
        case .httpStatus(let status): "Apple returned HTTP \(status)."
        case .invalidResponse(let detail): "Apple's response could not be safely understood: \(detail)."
        case .unsupportedMarket(let country): "The \(country) storefront is not supported. Choose a country manually."
        case .productUnavailable(let market): "iPhone Duo product selection is unavailable in \(market.displayName)."
        }
    }
    public var retryDelay: TimeInterval? {
        switch self {
        case .rateLimited(let delay): max(60, delay ?? 60)
        case .blocked: 300
        case .httpStatus(let status) where status >= 500: 60
        default: nil
        }
    }
}
public enum AppleHTTP {
    public static func validate(_ response: HTTPResponse, now: Date = Date()) throws {
        switch response.statusCode {
        case 200...299: return
        case 401: throw AppleServiceError.authenticationRequired
        case 403, 541: throw AppleServiceError.blocked(response.statusCode)
        case 429:
            let raw = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
            throw AppleServiceError.rateLimited(retryAfter: raw.flatMap { retryAfter($0, now: now) })
        default: throw AppleServiceError.httpStatus(response.statusCode)
        }
    }
    private static func retryAfter(_ raw: String, now: Date) -> TimeInterval? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
    public static func request(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("PickupPilot/1.0 (macOS; retail pickup availability)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/html;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }
}
