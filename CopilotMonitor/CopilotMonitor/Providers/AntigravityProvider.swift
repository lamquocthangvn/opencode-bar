import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "AntigravityProvider")

// MARK: - Antigravity OAuth Types

struct AntigravityAccount {
    let email: String
    let refreshToken: String
    let projectId: String
}

struct OAuthTokenResponse: Codable {
    let access_token: String
    let expires_in: Int?
    let token_type: String?
}

struct AntigravityModelInfo: Codable {
    let displayName: String?
    let modelName: String?
    let quotaInfo: QuotaInfo?
}

struct QuotaInfo: Codable {
    let remainingFraction: Double?
    let resetTime: String?
}

struct FetchAvailableModelsResponse: Codable {
    let models: [String: AntigravityModelInfo]?
}

// MARK: - AntigravityProvider Implementation

/// Provider for Antigravity quota tracking via OAuth API
/// Uses Antigravity API endpoint with OAuth credentials from antigravity-accounts.json
final class AntigravityProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .antigravity
    let type: ProviderType = .quotaBased

    // MARK: - Constants

    private let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private let quotaEndpoint = "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels"
    private let clientId = "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
    private let clientSecret = "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"
    private let userAgent = "antigravity/1.15.8 darwin/arm64"

    // MARK: - ProviderProtocol Implementation

    func fetch() async throws -> ProviderResult {
        // Step 1: Load accounts from antigravity-accounts.json
        let accounts = try loadAntigravityAccounts()
        guard let account = accounts.first else {
            throw ProviderError.providerError("No Antigravity accounts found")
        }

        logger.info("Using Antigravity account: \(account.email)")

        // Step 2: Refresh OAuth token
        let accessToken = try await refreshAccessToken(refreshToken: account.refreshToken)

        // Step 3: Fetch quota from Antigravity API
        let quotaData = try await fetchQuota(accessToken: accessToken, projectId: account.projectId)

        // Step 4: Parse and return result
        return try parseQuotaData(quotaData, email: account.email)
    }

    // MARK: - Private Helpers

    private func loadAntigravityAccounts() throws -> [AntigravityAccount] {
        let fileManager = FileManager.default
        let accountsPath = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("opencode")
            .appendingPathComponent("antigravity-accounts.json")

        guard fileManager.fileExists(atPath: accountsPath.path) else {
            throw ProviderError.providerError("Antigravity accounts file not found at \(accountsPath.path)")
        }
        guard fileManager.isReadableFile(atPath: accountsPath.path) else {
            throw ProviderError.providerError("Antigravity accounts file not readable at \(accountsPath.path)")
        }

        do {
            let data = try Data(contentsOf: accountsPath)
            let decoder = JSONDecoder()
            let accountsData = try decoder.decode(AntigravityAccountsData.self, from: data)
            return accountsData.accounts.map {
                AntigravityAccount(email: $0.email, refreshToken: $0.refreshToken, projectId: $0.projectId)
            }
        } catch {
            logger.error("Failed to read Antigravity accounts: \(error.localizedDescription)")
            throw ProviderError.decodingError("Invalid accounts file format: \(error.localizedDescription)")
        }
    }

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "client_id=\(clientId)",
            "client_secret=\(clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Token refresh failed: HTTP \(httpResponse.statusCode) - \(errorMessage)")
            throw ProviderError.authenticationFailed("Failed to refresh access token")
        }

        let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        return tokenResponse.access_token
    }

    private func fetchQuota(accessToken: String, projectId: String) async throws -> FetchAvailableModelsResponse {
        var request = URLRequest(url: URL(string: quotaEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let body = ["project": projectId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.networkError("Invalid response type")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Quota fetch failed: HTTP \(httpResponse.statusCode) - \(errorMessage)")
            throw ProviderError.networkError("Failed to fetch quota: HTTP \(httpResponse.statusCode)")
        }

        return try JSONDecoder().decode(FetchAvailableModelsResponse.self, from: data)
    }

    private func parseQuotaData(_ response: FetchAvailableModelsResponse, email: String) throws -> ProviderResult {
        guard let models = response.models, !models.isEmpty else {
            logger.error("Antigravity API response missing models")
            throw ProviderError.providerError("No quota data available")
        }

        // Extract quota info for all models
        var modelBreakdown: [String: Double] = [:]
        var modelResetTimes: [String: Date] = [:]
        var remainingPercentages: [Double] = []
        var parsedResetCount = 0

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso8601FormatterNoFrac = ISO8601DateFormatter()
        iso8601FormatterNoFrac.formatOptions = [.withInternetDateTime]

        for (modelName, modelInfo) in models {
            guard let quotaInfo = modelInfo.quotaInfo else { continue }
            guard let remainingFraction = quotaInfo.remainingFraction else { continue }

            // remainingFraction is 0.0-1.0, convert to percentage
            let remainingPercent = remainingFraction * 100.0

            let displayName = modelInfo.displayName ?? modelInfo.modelName ?? modelName
            modelBreakdown[displayName] = remainingPercent
            remainingPercentages.append(remainingPercent)

            logger.debug("Model \(displayName): \(String(format: "%.1f", remainingPercent))% remaining")

            // Parse reset time if available
            let resetTime = quotaInfo.resetTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !resetTime.isEmpty,
               let resetDate = iso8601Formatter.date(from: resetTime) ?? iso8601FormatterNoFrac.date(from: resetTime) {
                modelResetTimes[displayName] = resetDate
                parsedResetCount += 1
            }
        }

        if parsedResetCount > 0 {
            logger.info("Antigravity: Parsed reset times for \(parsedResetCount)/\(modelBreakdown.count) model(s)")
        } else {
            logger.info("Antigravity: No model reset times parsed (showing ungrouped model usage)")
        }

        guard !remainingPercentages.isEmpty else {
            logger.error("No quota information found in models")
            throw ProviderError.providerError("No quota data available")
        }

        // Use minimum remaining percentage across all models
        let minRemaining = remainingPercentages.min() ?? 0.0

        logger.info("Antigravity usage fetched: \(String(format: "%.1f", minRemaining))% remaining (min of \(remainingPercentages.count) models)")

        // Build detailed usage
        let details = DetailedUsage(
            modelBreakdown: modelBreakdown,
            modelResetTimes: modelResetTimes.isEmpty ? nil : modelResetTimes,
            planType: "Antigravity",
            email: email,
            authSource: "~/.config/opencode/antigravity-accounts.json"
        )

        // Return as quota-based usage
        let usage = ProviderUsage.quotaBased(
            remaining: Int(minRemaining),
            entitlement: 100,
            overagePermitted: false
        )

        return ProviderResult(usage: usage, details: details)
    }
}

// MARK: - Helper Types

struct AntigravityAccountsData: Codable {
    let version: Int
    let accounts: [AccountData]
    let activeIndex: Int

    struct AccountData: Codable {
        let email: String
        let refreshToken: String
        let projectId: String
    }
}
