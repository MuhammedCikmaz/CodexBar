# CodexBar: Token Burn Rate Per Hour — Implementation Spec

## Goal
Show a **tokens/hour burn rate** in the menu bar, computed only over intervals when the user was actively using AI (not idle hours). Display it prominently at the **top of the Overview page** and also in each provider's **token usage section**.

---

## Architecture Overview

CodexBar refreshes provider data on a configurable interval (1m, 2m, 5m, 15m). Each refresh writes a `CostUsageTokenSnapshot` into `UsageStore.tokenSnapshots[provider]`. That snapshot includes `sessionTokens` (today's cumulative total) and `updatedAt`.

The burn rate feature adds a **ring buffer** that records `(timestamp, sessionTokens)` pairs on each token refresh. Rate is computed only across intervals where tokens actually changed — ignoring idle periods.

---

## Files to Modify (6 files)

### 1. NEW FILE: `Sources/CodexBarCore/TokenBurnRateTracker.swift`

This is the core logic. Create this new file in `Sources/CodexBarCore/`.

```swift
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
```

### 2. MODIFY: `Sources/CodexBarCore/UsageFormatter.swift`

Add a formatting helper for the burn rate. Add this method inside the `UsageFormatter` enum:

```swift
/// Formats a tokens-per-hour burn rate for display (e.g., "12.3K tok/hr").
public static func burnRateString(_ tokensPerHour: Double) -> String {
    let tokenCount = Int(tokensPerHour.rounded())
    return "\(tokenCountString(tokenCount)) tok/hr"
}
```

### 3. MODIFY: `Sources/CodexBar/UsageStore.swift`

**3a.** Add the tracker as a property. Near line ~103, alongside the existing `tokenSnapshots` declaration, add:

```swift
@ObservationIgnored let burnRateTracker = TokenBurnRateTracker()
```

**3b.** Add a public accessor method. Add this somewhere in `UsageStore` or in a new extension:

```swift
func burnRate(for provider: UsageProvider) -> Double? {
    self.burnRateTracker.tokensPerHour(for: provider)
}
```

**3c.** Record samples on token snapshot update. In `UsageStore.swift` around line ~1189, where `self.tokenSnapshots[provider] = snapshot` is set after a successful cost usage fetch, add a recording call right after that line:

```swift
self.tokenSnapshots[provider] = snapshot  // existing line
if let sessionTokens = snapshot.sessionTokens {
    self.burnRateTracker.record(provider: provider, sessionTokens: sessionTokens, at: snapshot.updatedAt)
}
```

**3d.** Clear tracker when provider is reset. Wherever `tokenSnapshots.removeValue(forKey: provider)` is called (there are ~5 locations in UsageStore.swift and UsageStore+Refresh.swift), add alongside it:

```swift
self.burnRateTracker.reset(provider: provider)
```

And in the `resetAll` path (around line ~1097 where `self.tokenSnapshots.removeAll()` is called):

```swift
self.burnRateTracker.resetAll()
```

### 4. MODIFY: `Sources/CodexBar/MenuCardView.swift`

**4a.** Add `burnRateLine` to `TokenUsageSection` struct (around line ~77):

```swift
struct TokenUsageSection {
    let sessionLine: String
    let monthLine: String
    let burnRateLine: String?   // <-- ADD THIS
    let hintLine: String?
    let errorLine: String?
    let errorCopyText: String?
}
```

**4b.** Update the `tokenUsageSection(...)` factory method (around line ~1227). The `Input` struct needs a new field for the burn rate, OR the burn rate can be passed directly. The simplest approach: add a `burnRate: Double?` field to `Input`.

In the `Input` struct (around line ~652), add:

```swift
let burnRate: Double?
```

Update the `Input.init(...)` to accept and store it:

```swift
init(
    // ... existing params ...
    burnRate: Double? = nil,
    // ... existing params ...
) {
    // ... existing assignments ...
    self.burnRate = burnRate
}
```

Then in the `tokenUsageSection(...)` static method (around line ~1227), compute the burn rate line and include it:

```swift
let burnRateLine: String? = {
    guard let rate = input.burnRate, rate > 0 else { return nil }
    return "Burn rate: \(UsageFormatter.burnRateString(rate))"
}()
```

Wait — `tokenUsageSection` is a static method that doesn't have access to `input` (it receives specific params). Looking at the call site at line ~742:

```swift
let tokenUsage = Self.tokenUsageSection(
    provider: input.provider,
    enabled: input.tokenCostUsageEnabled,
    snapshot: input.tokenSnapshot,
    error: input.tokenError)
```

So we need to add `burnRate` as a parameter to `tokenUsageSection`:

```swift
private static func tokenUsageSection(
    provider: UsageProvider,
    enabled: Bool,
    snapshot: CostUsageTokenSnapshot?,
    error: String?,
    burnRate: Double?) -> TokenUsageSection?    // <-- ADD burnRate param
```

And update the call site:

```swift
let tokenUsage = Self.tokenUsageSection(
    provider: input.provider,
    enabled: input.tokenCostUsageEnabled,
    snapshot: input.tokenSnapshot,
    error: input.tokenError,
    burnRate: input.burnRate)     // <-- ADD this
```

Inside `tokenUsageSection(...)`, build the burn rate line and pass it to the returned struct:

```swift
let burnRateLine: String? = if let burnRate, burnRate > 0 {
    "Burn rate: \(UsageFormatter.burnRateString(burnRate))"
} else {
    nil
}

return TokenUsageSection(
    sessionLine: sessionLine,
    monthLine: monthLine,
    burnRateLine: burnRateLine,   // <-- ADD
    hintLine: nil,
    errorLine: err,
    errorCopyText: (error?.isEmpty ?? true) ? nil : error)
```

**4c.** Render the burn rate line in BOTH view sites. There are two places the token usage is rendered in `MenuCardView.swift`:

**Site 1** (~line 178-200, inside the full card view):

After the `Text(tokenUsage.sessionLine)` line, add:

```swift
if let burnRate = tokenUsage.burnRateLine {
    Text(burnRate)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
}
```

**Site 2** (~line 590-615, inside the compact/alternative layout):

Same addition after the `Text(tokenUsage.sessionLine)` line in that section.

### 5. MODIFY: `Sources/CodexBar/StatusItemController+Menu.swift`

**5a.** Pass burn rate through when building menu card models. In the `menuCardModel(for:...)` method (around line ~1525), where the `Input` is constructed (line ~1569), add the burn rate:

```swift
let burnRate = self.store.burnRate(for: target)

let input = UsageMenuCardView.Model.Input(
    // ... existing params ...
    burnRate: burnRate,        // <-- ADD this
    // ... existing params ...
    now: now)
```

**5b.** Add a summary burn rate header to the Overview page. In the `addOverviewRows(to:enabledProviders:menuWidth:)` method (around line ~380), BEFORE the provider rows loop, add a summary header showing the aggregate burn rate across all active providers:

```swift
private func addOverviewRows(
    to menu: NSMenu,
    enabledProviders: [UsageProvider],
    menuWidth: CGFloat) -> Bool
{
    let overviewProviders = self.settings.reconcileMergedOverviewSelectedProviders(
        activeProviders: enabledProviders)
    let rows: [(provider: UsageProvider, model: UsageMenuCardView.Model)] = overviewProviders
        .compactMap { provider in
            guard let model = self.menuCardModel(for: provider) else { return nil }
            return (provider: provider, model: model)
        }
    guard !rows.isEmpty else { return false }

    // ── NEW: Aggregate burn rate header at top of overview ──
    let burnRates: [(UsageProvider, Double)] = overviewProviders.compactMap { provider in
        guard let rate = self.store.burnRate(for: provider), rate > 0 else { return nil }
        return (provider, rate)
    }
    if !burnRates.isEmpty {
        let headerItem = self.makeOverviewBurnRateHeader(
            burnRates: burnRates,
            width: menuWidth)
        menu.addItem(headerItem)
        menu.addItem(.separator())
    }
    // ── END NEW ──

    for (index, row) in rows.enumerated() {
        // ... existing loop unchanged ...
    }
    return true
}
```

Then add the helper method to build that header menu item. Add this as a new private method on `StatusItemController`:

```swift
private func makeOverviewBurnRateHeader(
    burnRates: [(UsageProvider, Double)],
    width: CGFloat) -> NSMenuItem
{
    let view = OverviewBurnRateHeaderView(burnRates: burnRates, width: width)
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: width, height: 44)
    let item = NSMenuItem()
    item.view = hostingView
    item.representedObject = "overviewBurnRateHeader"
    return item
}
```

### 6. NEW FILE: `Sources/CodexBar/OverviewBurnRateHeaderView.swift`

Create this SwiftUI view for the overview header:

```swift
import CodexBarCore
import SwiftUI

struct OverviewBurnRateHeaderView: View {
    let burnRates: [(UsageProvider, Double)]
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "flame")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.orange)
                Text("Token Burn Rate")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }

            if self.burnRates.count == 1 {
                let (provider, rate) = self.burnRates[0]
                let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
                Text("\(name): \(UsageFormatter.burnRateString(rate))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                let parts = self.burnRates.map { provider, rate in
                    let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
                    return "\(name) \(UsageFormatter.burnRateString(rate))"
                }
                Text(parts.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(width: self.width, alignment: .leading)
    }
}
```

---

## Data Flow Summary

```
Token refresh completes
    → UsageStore sets tokenSnapshots[provider]
    → UsageStore records sample in burnRateTracker
    → Menu opens
    → menuCardModel() reads store.burnRate(for:) 
    → Passes to UsageMenuCardView.Model.Input.burnRate
    → tokenUsageSection() formats as "Burn rate: 12.3K tok/hr"
    → Rendered in per-provider card AND overview header
```

## Ring Buffer Behavior

- Stores up to 20 samples per provider
- Resets when `sessionTokens` decreases (new day)  
- Resets when provider is disabled or errors out
- Requires **≥ 2 active intervals** (intervals where tokens changed) before showing a rate
- Requires **≥ 2 minutes** of active time to avoid division-by-small-number artifacts
- Ignores idle intervals entirely — only counts time between samples where tokens actually increased

## Display Behavior

- **Overview header**: Shows at the very top of the Overview tab, above all provider cards. Flame icon + "Token Burn Rate" label + per-provider rates joined with " · ".
- **Per-provider card**: Shows as a line under "Today: $X.XX · YK tokens" reading "Burn rate: ZK tok/hr".
- When no burn rate data is available yet (too few samples or no activity), the line is simply omitted — no "N/A" or placeholder.

## Build Note

This is a Swift Package Manager project (macOS 14+, Swift 6.2). Build with:
```bash
swift build -c debug    # for development
swift build -c release  # for production
```
The new file `TokenBurnRateTracker.swift` goes in the `CodexBarCore` target. The new file `OverviewBurnRateHeaderView.swift` goes in the `CodexBar` target. No changes to `Package.swift` needed since both targets use directory-based source discovery.
