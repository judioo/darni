import SidebarModel
import SwiftUI

/// "Connect 1Password to ReArc" above the bottom bar, in Finish setup's
/// place and card: the one-time step the person does in 1Password, with
/// Open 1Password, Done and a close button (`OnePasswordConnect`). A view of
/// its own, so only it follows the extensions' actions.
struct ConnectOnePasswordSlot: View {
    let model: BrowserViewModel

    var body: some View {
        SidebarStepCardSlot(shows: model.showsOnePasswordPrompt) {
            ConnectOnePasswordCard(model: model)
        }
    }
}

struct ConnectOnePasswordCard: View {
    let model: BrowserViewModel

    var body: some View {
        SidebarStepCard(
            title: OnePasswordConnect.title,
            message: OnePasswordConnect.message,
            primary: .init(title: OnePasswordConnect.open, identifier: "connectOnePasswordOpen") { model.openOnePassword() },
            secondary: .init(title: OnePasswordConnect.done, identifier: "connectOnePasswordDone") { model.markOnePasswordConnected() },
            dismissHelp: "Hide for now — the steps stay in Settings › General",
            dismissLabel: "Dismiss Connect 1Password",
            dismissIdentifier: "dismissConnectOnePassword",
            identifier: "connectOnePasswordCard"
        ) {
            model.dismissOnePasswordPrompt()
        }
    }
}
