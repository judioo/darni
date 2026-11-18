import SidebarModel
import SwiftUI

/// "ReArc can now block ads and trackers": the one-time offer to an install
/// from before blocking (CONTENT-BLOCKING.md §2), in Connect 1Password's
/// place and card. Turn On, Not Now and the close button all end it; the
/// switch stays in Settings › Profiles.
struct ContentBlockingOfferSlot: View {
    let model: BrowserViewModel

    var body: some View {
        SidebarStepCardSlot(shows: model.contentBlocking.showsOffer) {
            SidebarStepCard(
                title: ContentBlockingRollout.offerTitle,
                message: ContentBlockingRollout.offerMessage,
                primary: .init(title: ContentBlockingRollout.offerAccept, identifier: "contentBlockingOfferTurnOn") {
                    model.acceptContentBlockingOffer()
                },
                secondary: .init(title: ContentBlockingRollout.offerDecline, identifier: "contentBlockingOfferNotNow") {
                    model.declineContentBlockingOffer()
                },
                dismissHelp: "Not now — the switch stays in Settings › Profiles",
                dismissLabel: "Dismiss the blocking offer",
                dismissIdentifier: "dismissContentBlockingOffer",
                identifier: "contentBlockingOfferCard"
            ) {
                model.declineContentBlockingOffer()
            }
        }
    }
}
