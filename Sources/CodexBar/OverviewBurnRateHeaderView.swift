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
                Text(parts.joined(separator: " \u{00B7} "))
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
