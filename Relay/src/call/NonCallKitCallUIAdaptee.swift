//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import RelayServiceKit
import RelayMessaging

/**
 * Manage call related UI in a pre-CallKit world.
 */
class NonCallKitCallUIAdaptee: NSObject, CallUIAdaptee {

    let TAG = "[NonCallKitCallUIAdaptee]"

    let notificationsAdapter: CallNotificationsAdapter
    let callService: ConferenceCallService

    // Starting/Stopping incoming call ringing is our apps responsibility for the non CallKit interface.
    let hasManualRinger = true

    required init(callService: ConferenceCallService, notificationsAdapter: CallNotificationsAdapter) {
        AssertIsOnMainThread(file: #function)

        self.callService = callService
        self.notificationsAdapter = notificationsAdapter

        super.init()
    }

    func startOutgoingCall(threadId: String) -> ConferenceCall {
        AssertIsOnMainThread(file: #function)
        return ConferenceCallService.shared.conferenceCall!  // yeah, not real
    }

    func reportIncomingCall(_ call: ConferenceCall, callerName: String) {
        AssertIsOnMainThread(file: #function)
    }

    func reportMissedCall(_ call: ConferenceCall, callerName: String) {
        AssertIsOnMainThread(file: #function)
    }

    func answerCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)
    }

    func answerCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
    }

    func declineCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)
    }

    func declineCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
    }

    func recipientAcceptedCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
    }

    func localHangupCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
    }

    internal func remoteDidHangupCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
    }

    internal func remoteBusy(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
    }

    internal func failCall(_ call: ConferenceCall, error: CallError) {
        AssertIsOnMainThread(file: #function)
    }

    func setIsMuted(call: ConferenceCall, isMuted: Bool) {
        AssertIsOnMainThread(file: #function)
    }

    func setHasLocalVideo(call: ConferenceCall, hasLocalVideo: Bool) {
        AssertIsOnMainThread(file: #function)
    }
}
