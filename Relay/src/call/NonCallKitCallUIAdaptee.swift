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
    let callService: CallService

    // Starting/Stopping incoming call ringing is our apps responsibility for the non CallKit interface.
    let hasManualRinger = true

    required init(callService: CallService, notificationsAdapter: CallNotificationsAdapter) {
        AssertIsOnMainThread(file: #function)

        self.callService = callService
        self.notificationsAdapter = notificationsAdapter

        super.init()
    }

    func startOutgoingCall(threadId: String) -> RelayCall {
        AssertIsOnMainThread(file: #function)

        let call = RelayCall.outgoingCall(threadId: threadId, callId: UUID().uuidString)

        // make sure we don't terminate audio session during call
        OWSAudioSession.shared.startAudioActivity(call.audioActivity)

        self.callService.handleOutgoingCall(call).then {
            Logger.debug("\(self.TAG) handleOutgoingCall succeeded")
        }.catch { error in
            Logger.error("\(self.TAG) handleOutgoingCall failed with error: \(error)")
        }.retainUntilComplete()

        return call
    }

    func reportIncomingCall(_ call: RelayCall, callerName: String) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(TAG) \(#function)")

        self.showCall(call)

        // present lock screen notification
        if UIApplication.shared.applicationState == .active {
            Logger.debug("\(TAG) skipping notification since app is already active.")
        } else {
            notificationsAdapter.presentIncomingCall(call, callerName: callerName)
        }
    }

    func reportMissedCall(_ call: RelayCall, callerName: String) {
        AssertIsOnMainThread(file: #function)

        notificationsAdapter.presentMissedCall(call, callerName: callerName)
    }

    func answerCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)

        guard let call = self.callService.call else {
            owsFailDebug("\(self.TAG) in \(#function) No current call.")
            return
        }

        guard call.localId == localId else {
            owsFailDebug("\(self.TAG) in \(#function) localId does not match current call")
            return
        }

        self.answerCall(call)
    }

    func answerCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)

        guard call.localId == self.callService.call?.localId else {
            owsFailDebug("\(self.TAG) in \(#function) localId does not match current call")
            return
        }

        OWSAudioSession.shared.isRTCAudioEnabled = true
        self.callService.handleAnswerCall(call)
    }

    func declineCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)

        guard let call = self.callService.call else {
            owsFailDebug("\(self.TAG) in \(#function) No current call.")
            return
        }

        guard call.localId == localId else {
            owsFailDebug("\(self.TAG) in \(#function) localId does not match current call")
            return
        }

        self.declineCall(call)
    }

    func declineCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)

        guard call.localId == self.callService.call?.localId else {
            owsFailDebug("\(self.TAG) in \(#function) localId does not match current call")
            return
        }

        self.callService.handleDeclineCall(call)
    }

    func recipientAcceptedCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)

        OWSAudioSession.shared.isRTCAudioEnabled = true
    }

    func localHangupCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)

        // If both parties hang up at the same moment,
        // call might already be nil.
        guard self.callService.call == nil || call.localId == self.callService.call?.localId else {
            owsFailDebug("\(self.TAG) in \(#function) localId does not match current call")
            return
        }

        self.callService.handleLocalHungupCall(call)
    }

    internal func remoteDidHangupCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(TAG) in \(#function) is no-op")
    }

    internal func remoteBusy(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(TAG) in \(#function) is no-op")
    }

    internal func failCall(_ call: RelayCall, error: CallError) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(TAG) in \(#function) is no-op")
    }

    func setIsMuted(call: RelayCall, isMuted: Bool) {
        AssertIsOnMainThread(file: #function)

        guard call.localId == self.callService.call?.localId else {
            owsFailDebug("\(self.TAG) in \(#function) localId does not match current call")
            return
        }

        self.callService.setIsMuted(call: call, isMuted: isMuted)
    }

    func setHasLocalVideo(call: RelayCall, hasLocalVideo: Bool) {
        AssertIsOnMainThread(file: #function)

        guard call.localId == self.callService.call?.localId else {
            owsFailDebug("\(self.TAG) in \(#function) localId does not match current call")
            return
        }

        self.callService.setHasLocalVideo(hasLocalVideo: hasLocalVideo)
    }
}
