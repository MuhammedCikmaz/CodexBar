import AppKit
import CodexBarCore
import SwiftUI

extension ProviderSwitcherSelection {
    var provider: UsageProvider? {
        switch self {
        case .overview:
            nil
        case let .provider(provider):
            provider
        }
    }
}

struct OverviewMenuCardRowView: View {
    let model: UsageMenuCardView.Model
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(
                model: self.model,
                showDivider: self.hasUsageBlock,
                width: self.width)
            if self.hasUsageBlock {
                UsageMenuCardUsageSectionView(
                    model: self.model,
                    showBottomDivider: false,
                    bottomPadding: 6,
                    width: self.width)
            }
        }
        .frame(width: self.width, alignment: .leading)
    }

    private var hasUsageBlock: Bool {
        !self.model.metrics.isEmpty || !self.model.usageNotes.isEmpty || self.model.placeholder != nil
    }
}

extension StatusItemController {
    func makeOverviewBurnRateHeader(
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
}
