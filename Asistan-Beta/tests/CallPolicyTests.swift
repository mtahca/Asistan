import Foundation

@main struct CallPolicyTests {
    static func main() {
        precondition(CallUI.answer("‎Accept"))
        precondition(CallUI.answer(" Yanıtla "))
        precondition(!CallUI.answer("Start voice call with Ayşe"))
        precondition(!CallUI.answer("Accept invitation"))
        precondition(!CallUI.answer("Do not accept"))
        precondition(CallUI.decline("‎Decline"))
        precondition(CallUI.end("‎End Call"))
        precondition(!CallUI.end("Close"))
        precondition(!CallUI.end("Kapat"))
        precondition(CallUI.appleNotification("FACETIME_NOTIFICATION"))
        precondition(CallUI.appleNotification("PHONE_NOTIFICATION"))
        precondition(!CallUI.appleNotification("mail notification"))
        precondition(CallUI.voiceIncoming(["Incoming voice call", "Accept", "Decline"]))
        precondition(!CallUI.voiceIncoming(["Incoming video call", "Accept", "Decline"]))
        precondition(!CallUI.voiceIncoming(["Start voice call with Ayşe", "Accept invitation"]))
        precondition(!CallUI.voiceIncoming(["Voice call, answered yesterday", "Accept", "Decline"]))
        precondition(CallSource.whatsapp.bundleIDs == ["net.whatsapp.WhatsApp"])
        precondition(BetaAudio.listenName != BetaAudio.microphoneName)
        precondition(BetaAudio.playbackName != BetaAudio.microphoneName)
        let whatsappIncoming = ["‎WhatsApp audio call", "hang up", "CallUI_DeclineButton", "‎Accept call", "CallUI_AcceptButton"]
        precondition(CallUI.voiceIncoming(whatsappIncoming))
        precondition(CallUI.decline("CallUI_DeclineButton"))
        precondition(CallUI.answer("CallUI_AcceptButton"))
        precondition(!CallUI.connectedEndControl(["hang up", "CallUI_DeclineButton"], rootHasAnswer: true, rootHasDecline: true))
        precondition(CallUI.connectedEndControl(["hang up", "CallUI_DeclineButton"], rootHasAnswer: false, rootHasDecline: true))
        precondition(!CallUI.voiceIncoming(["WhatsApp audio call", "Accept invitation", "Decline"]))
        precondition(!CallUI.voiceIncoming(["WhatsApp audio call", "CallUI_AcceptButton"]))
        precondition(!CallUI.voiceIncoming(["WhatsApp video call", "CallUI_AcceptButton", "CallUI_DeclineButton"]))
        precondition(!CallUI.voiceIncoming(["Incoming call", "WhatsApp video call", "CallUI_AcceptButton", "CallUI_DeclineButton"]))
        precondition(!CallUI.connectedEndControl(["Close"], rootHasAnswer: false, rootHasDecline: false))
        // Observed connected WhatsApp voice call, including its video upgrade control.
        let whatsappConnected = ["‎video call", "‎mute off", "‎leave call"]
        precondition(CallUI.connectedEndControl(whatsappConnected, rootHasAnswer: false, rootHasDecline: false))
        precondition(!CallUI.voiceIncoming(whatsappConnected))
        precondition(!CallUI.connectedEndControl(["Leave call history"], rootHasAnswer: false, rootHasDecline: false))
        print("Arama ayırma: 32 kontrol başarılı.")
    }
}
