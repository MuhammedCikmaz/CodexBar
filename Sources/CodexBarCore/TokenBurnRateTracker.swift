import Foundation

/// A single sample of token usage at a point in time.
public struct TokenBurnSample: Sendable {
    public let timestamp: Date
    public let sessionTokens: Int

    public init(timestamp: Date, sessionTokens: Int) {
        self.timestamp = timestamp
        self.sessionTokens = sessionTokens
    }
}

/// Tracks token burn rate using a sliding window of samples,
/// only counting intervals where tokens actually changed (active use).
public final class TokenBurnRateTracker: @unchecked Sendable {
    /// Maximum number of samples to retain per provider.
    private static let maxSamples = 20
    /// Minimum number of active intervals needed before reporting a rate.
    private static let minimumActiveIntervals = 2
    /// Minimum elapsed active seconds before reporting a rate (avoid divide-by-tiny-number).
    private static let minimumActiveSeconds: TimeInterval = 120 // 2 minutes

    private let lock = NSLock()
    private var samples: [UsageProvider: [TokenBurnSample]] = [:]

    public init() {}

    /// Record a new sample. Call this every time a `CostUsageTokenSnapshot` is updated for a provider.
    public func record(provider: UsageProvider, sessionTokens: Int, at date: Date = Date()) {
        self.lock.lock()
        defer { self.lock.unlock() }

        var ring = self.samples[provider] ?? []

        // If sessionTokens decreased (new day / reset), clear history and start fresh
        if let last = ring.last, sessionTokens < last.sessionTokens {
            ring.removeAll()
        }

        ring.append(TokenBurnSample(timestamp: date, sessionTokens: sessionTokens))

        // Trim to max size, keeping the most recent samples
        if ring.count > Self.maxSamples {
            ring.removeFirst(ring.count - Self.maxSamples)
        }

        self.samples[provider] = ring
    }

    /// Compute the current burn rate in tokens per hour, considering only "active" intervals.
    /// Returns `nil` if insufficient data.
    public func tokensPerHour(for provider: UsageProvider) -> Double? {
        self.lock.lock()
        defer { self.lock.unlock() }

        guard let ring = self.samples[provider], ring.count >= 2 else { return nil }

        var activeSeconds: TimeInterval = 0
        var activeTokens: Int = 0
        var activeIntervals = 0

        for i in 1..<ring.count {
            let prev = ring[i - 1]
            let curr = ring[i]
            let deltaTokens = curr.sessionTokens - prev.sessionTokens

            // Only count intervals where tokens actually changed (user was active)
            if deltaTokens > 0 {
                let deltaTime = curr.timestamp.timeIntervalSince(prev.timestamp)
                // Sanity: skip if time delta is negative or zero
                guard deltaTime > 0 else { continue }
                activeSeconds += deltaTime
                activeTokens += deltaTokens
                activeIntervals += 1
            }
        }

        guard activeIntervals >= Self.minimumActiveIntervals else { return nil }
        guard activeSeconds >= Self.minimumActiveSeconds else { return nil }

        let tokensPerSecond = Double(activeTokens) / activeSeconds
        return tokensPerSecond * 3600.0
    }

    /// Clear samples for a provider (e.g., when provider is disabled or reset).
    public func reset(provider: UsageProvider) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.samples.removeValue(forKey: provider)
    }

    /// Clear all samples.
    public func resetAll() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.samples.removeAll()
    }
}
