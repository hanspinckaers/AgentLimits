// MARK: - ClaudeUsageFetcher.swift
// Fetches usage data from Claude.ai via JavaScript injection.
// Extracts organization ID from cookies or page content to call usage API.

import Foundation
import WebKit

// MARK: - API Response Models

/// Response structure from Claude.ai usage API
struct ClaudeUsageResponse: Codable {
    struct Window: Codable {
        let utilization: Double?
        let resets_at: String?
    }

    let five_hour: Window?
    let seven_day: Window?
    let seven_day_oauth_apps: Window?
    let seven_day_opus: Window?
    let seven_day_sonnet: Window?
    let iguana_necktie: Window?
    let extra_usage: Window?
    let enterprise_monthly: Window?
}

extension ClaudeUsageResponse {
    /// Converts API response to a UsageSnapshot for persistence and display.
    /// - Parameters:
    ///   - fetchedAt: The timestamp when this data was fetched
    ///   - parseResetDate: Function to parse ISO8601 date strings from the API
    /// - Returns: A UsageSnapshot containing primary (5h) and secondary (7d) windows
    func toSnapshot(fetchedAt: Date, parseResetDate: (String) -> Date?) -> UsageSnapshot {
        let primary = makeWindow(
            kind: .primary,
            source: five_hour,
            limitSeconds: UsageLimitDuration.fiveHours,
            parseResetDate: parseResetDate
        )
        let secondary = makeWindow(
            kind: .secondary,
            source: seven_day,
            limitSeconds: UsageLimitDuration.sevenDays,
            parseResetDate: parseResetDate
        )

        if primary == nil,
           secondary == nil,
           let monthly = makeMonthlyWindow(source: enterprise_monthly, parseResetDate: parseResetDate) {
            return UsageSnapshot(
                provider: .claudeCode,
                fetchedAt: fetchedAt,
                primaryWindow: monthly,
                secondaryWindow: nil
            )
        }

        return UsageSnapshot(
            provider: .claudeCode,
            fetchedAt: fetchedAt,
            primaryWindow: primary,
            secondaryWindow: secondary
        )
    }

    private func makeWindow(
        kind: UsageWindowKind,
        source: Window?,
        limitSeconds: TimeInterval,
        parseResetDate: (String) -> Date?
    ) -> UsageWindow? {
        guard let source, let usedPercent = source.utilization else {
            return nil
        }
        // resets_at が null の場合は初期状態として扱い、UsageWindow を作らない
        guard let resetAtString = source.resets_at,
              let resetAt = parseResetDate(resetAtString) else {
            return nil
        }
        return UsageWindow(
            kind: kind,
            usedPercent: usedPercent,
            resetAt: resetAt,
            limitWindowSeconds: limitSeconds
        )
    }

    private func makeMonthlyWindow(
        source: Window?,
        parseResetDate: (String) -> Date?
    ) -> UsageWindow? {
        guard let source, let usedPercent = source.utilization else {
            return nil
        }
        guard let resetAtString = source.resets_at,
              let resetAt = parseResetDate(resetAtString) else {
            return nil
        }
        return UsageWindow(
            kind: .primary,
            usedPercent: usedPercent,
            resetAt: resetAt,
            limitWindowSeconds: Self.computeMonthlyLimitWindowSeconds(resetAt: resetAt)
        )
    }

    private static func computeMonthlyLimitWindowSeconds(resetAt: Date) -> TimeInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let windowStart = calendar.date(byAdding: .month, value: -1, to: resetAt) else {
            return UsageLimitDuration.thirtyDays
        }
        let duration = resetAt.timeIntervalSince(windowStart)
        return duration > UsageLimitDuration.sevenDays ? duration : UsageLimitDuration.thirtyDays
    }
}

// MARK: - Error Types

/// Errors that can occur when fetching Claude usage data
enum ClaudeUsageFetcherError: LocalizedError {
    case scriptFailed(String)
    case invalidResponse
    case missingOrganization

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return "error.fetchFailed".localized(message)
        case .invalidResponse:
            return "error.parseFailed".localized()
        case .missingOrganization:
            return "error.missingOrg".localized()
        }
    }
}

// MARK: - Claude Usage Fetcher

/// Fetches usage data from Claude.ai by executing JavaScript in WebView.
/// Obtains organization ID from cookies or page content to authenticate.
final class ClaudeUsageFetcher {
    private let scriptRunner: WebViewScriptRunner

    init(scriptRunner: WebViewScriptRunner = WebViewScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    /// Fetches current usage snapshot by executing JavaScript in the WebView
    @MainActor
    func fetchUsageSnapshot(using webView: WKWebView) async throws -> UsageSnapshot {
        let response: ClaudeUsageResponse
        do {
            response = try await scriptRunner.decodeJSONScript(
                ClaudeUsageResponse.self,
                script: Self.usageScript,
                webView: webView
            )
        } catch let error as WebViewScriptRunnerError {
            throw mapScriptError(error)
        } catch {
            throw ClaudeUsageFetcherError.invalidResponse
        }
        let snapshot = response.toSnapshot(fetchedAt: Date(), parseResetDate: parseResetDate)
        guard snapshot.primaryWindow != nil || snapshot.secondaryWindow != nil else {
            throw ClaudeUsageFetcherError.invalidResponse
        }
        return snapshot
    }

    /// Checks if user is logged in by verifying the session cookie
    @MainActor
    func hasValidSession(using webView: WKWebView) async -> Bool {
        await hasValidSessionCookie(using: webView)
    }

    private func hasValidSessionCookie(using webView: WKWebView) async -> Bool {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                let now = Date()
                // Look for a valid Claude session cookie scoped to claude.ai.
                let isValid = cookies.contains { cookie in
                    guard cookie.name == "sessionKey" else { return false }
                    guard cookie.domain.hasSuffix("claude.ai") else { return false }
                    if let expiresDate = cookie.expiresDate {
                        return expiresDate > now
                    }
                    return true
                }
                continuation.resume(returning: isValid)
            }
        }
    }

    private func mapScriptError(_ error: WebViewScriptRunnerError) -> ClaudeUsageFetcherError {
        // Map script errors to user-facing domain errors.
        switch error {
        case .invalidResponse:
            return .invalidResponse
        case .scriptFailed(let message):
            if message.contains("Missing organization id") {
                return .missingOrganization
            }
            return .scriptFailed(message)
        }
    }

    // MARK: - Date Parsing

    /// Parses ISO8601 date string with various fractional second formats
    private func parseResetDate(_ value: String) -> Date? {
        // Try full ISO8601 with fractional seconds first.
        if let date = Self.formatterWithFractionalSeconds.date(from: value) {
            return date
        }
        // Fallback to ISO8601 without fractional seconds.
        if let date = Self.formatterWithoutFractionalSeconds.date(from: value) {
            return date
        }
        // Normalize long fractional precision to milliseconds if needed.
        if let trimmed = trimFractionalSeconds(value),
           let date = Self.formatterWithFractionalSeconds.date(from: trimmed) {
            return date
        }
        return nil
    }

    private func trimFractionalSeconds(_ value: String) -> String? {
        guard let dotIndex = value.firstIndex(of: ".") else { return nil }
        let fractionStart = value.index(after: dotIndex)
        guard let suffixStart = value[fractionStart...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            return nil
        }
        let fraction = value[fractionStart..<suffixStart]
        if fraction.count <= 3 {
            return value
        }
        // Truncate to milliseconds precision.
        let trimmedFraction = fraction.prefix(3)
        return String(value[..<fractionStart]) + trimmedFraction + value[suffixStart...]
    }

    private static let formatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let formatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - JavaScript Scripts

    /// Script to fetch usage: finds org ID from cookie/resources/HTML, then calls API
    private static let usageScript = """
    return (async () => {
      try {
        function readCookieValue(name) {
          const pattern = new RegExp("(?:^|; )" + name + "=([^;]*)");
          const match = document.cookie.match(pattern);
          return match ? decodeURIComponent(match[1]) : null;
        }

        function findOrgIdFromResources() {
          const entries = performance.getEntriesByType("resource");
          for (const entry of entries) {
            if (!entry || !entry.name) { continue; }
            const match = entry.name.match(/\\/api\\/organizations\\/([a-f0-9-]{36})\\/usage/);
            if (match) { return match[1]; }
          }
          return null;
        }

        function findOrgIdFromHtml() {
          const html = document.documentElement ? document.documentElement.innerHTML : "";
          const match = html.match(/\\/api\\/organizations\\/([a-f0-9-]{36})\\/usage/);
          return match ? match[1] : null;
        }

        function parseSpendPercent(text) {
          const usedMatch = text.match(/([0-9]{1,3}(?:\\.[0-9]+)?)\\s*%\\s*used/i);
          if (usedMatch) {
            return Number(usedMatch[1]);
          }

          const spendMatch = text.match(/[^0-9\\n]*([0-9][0-9,]*(?:\\.[0-9]+)?)\\s+of\\s+[^0-9\\n]*([0-9][0-9,]*(?:\\.[0-9]+)?)\\s+spent/i);
          if (!spendMatch) { return null; }

          const spent = Number(spendMatch[1].replace(/,/g, ""));
          const limit = Number(spendMatch[2].replace(/,/g, ""));
          if (!Number.isFinite(spent) || !Number.isFinite(limit) || limit <= 0) {
            return null;
          }
          return (spent / limit) * 100;
        }

        function parseEnterpriseSpendWindow() {
          const rawText = document.body ? document.body.innerText : "";
          const text = rawText.replace(/\\u00a0/g, " ");
          if (!text) { return null; }

          const utilization = parseSpendPercent(text);
          if (!Number.isFinite(utilization)) { return null; }
          const months = {
            jan: 0, january: 0,
            feb: 1, february: 1,
            mar: 2, march: 2,
            apr: 3, april: 3,
            may: 4,
            jun: 5, june: 5,
            jul: 6, july: 6,
            aug: 7, august: 7,
            sep: 8, sept: 8, september: 8,
            oct: 9, october: 9,
            nov: 10, november: 10,
            dec: 11, december: 11
          };

          const dateMatch = text.match(/Resets?\\s+(?:[A-Za-z]{3,9},\\s*)?([A-Za-z]{3,9})\\s+(\\d{1,2})(?:,\\s*(\\d{4}))?\\s+at\\s+(\\d{1,2}):(\\d{2})\\s*(AM|PM)?\\s*(?:GMT|UTC)?\\s*([+-]\\d{1,2})(?::?(\\d{2}))?/i);
          if (!dateMatch) { return null; }

          const month = months[dateMatch[1].toLowerCase()];
          if (month === undefined) { return null; }

          const day = Number(dateMatch[2]);
          const explicitYear = dateMatch[3] ? Number(dateMatch[3]) : null;
          let hour = Number(dateMatch[4]);
          const minute = Number(dateMatch[5]);
          const meridiem = dateMatch[6] ? dateMatch[6].toUpperCase() : null;
          if (meridiem === "AM" && hour === 12) {
            hour = 0;
          } else if (meridiem === "PM" && hour < 12) {
            hour += 12;
          }

          const offsetHour = Number(dateMatch[7]);
          const offsetMinute = dateMatch[8] ? Number(dateMatch[8]) : 0;
          if (!Number.isFinite(day) || !Number.isFinite(hour) || !Number.isFinite(minute) || !Number.isFinite(offsetHour) || !Number.isFinite(offsetMinute)) {
            return null;
          }

          const offsetSign = offsetHour < 0 ? -1 : 1;
          const offsetMinutes = offsetSign * ((Math.abs(offsetHour) * 60) + offsetMinute);
          const now = new Date();
          const makeDate = (year) => new Date(Date.UTC(year, month, day, hour, minute) - (offsetMinutes * 60 * 1000));
          let resetAt = makeDate(explicitYear || now.getFullYear());
          if (!explicitYear && resetAt.getTime() < now.getTime() - (24 * 60 * 60 * 1000)) {
            resetAt = makeDate(now.getFullYear() + 1);
          }
          if (Number.isNaN(resetAt.getTime())) { return null; }

          return {
            utilization: Math.max(0, Math.min(100, utilization)),
            resets_at: resetAt.toISOString()
          };
        }

        function hasUsableUsageWindow(data) {
          const primary = data && data.five_hour;
          const secondary = data && data.seven_day;
          return Boolean(
            (primary && primary.utilization != null && primary.resets_at)
              || (secondary && secondary.utilization != null && secondary.resets_at)
          );
        }

        function delay(ms) {
          return new Promise(resolve => setTimeout(resolve, ms));
        }

        async function waitForEnterpriseSpendWindow() {
          const startedAt = Date.now();
          while (Date.now() - startedAt < 4000) {
            const enterpriseWindow = parseEnterpriseSpendWindow();
            if (enterpriseWindow) {
              return enterpriseWindow;
            }
            await delay(250);
          }
          return parseEnterpriseSpendWindow();
        }

        async function addEnterpriseSpendWindow(data, shouldWait) {
          const enterpriseWindow = shouldWait
            ? await waitForEnterpriseSpendWindow()
            : parseEnterpriseSpendWindow();
          if (enterpriseWindow) {
            data.enterprise_monthly = enterpriseWindow;
          }
          return data;
        }

        const orgId = readCookieValue("lastActiveOrg")
          || findOrgIdFromResources()
          || findOrgIdFromHtml();
        if (!orgId) {
          const data = await addEnterpriseSpendWindow({}, true);
          if (data.enterprise_monthly) {
            return JSON.stringify(data);
          }
          throw new Error("Missing organization id");
        }

        const response = await fetch("https://claude.ai/api/organizations/" + orgId + "/usage", {
          method: "GET",
          credentials: "include",
          headers: {
            "Accept": "application/json"
          }
        });
        if (!response.ok) {
          const data = await addEnterpriseSpendWindow({}, true);
          if (data.enterprise_monthly) {
            return JSON.stringify(data);
          }
          throw new Error("HTTP " + response.status);
        }
        const data = await response.json();
        await addEnterpriseSpendWindow(data, !hasUsableUsageWindow(data));
        return JSON.stringify(data);
      } catch (error) {
        const message = error && error.message ? error.message : String(error);
        return JSON.stringify({ "__error": message });
      }
    })();
    """

}
