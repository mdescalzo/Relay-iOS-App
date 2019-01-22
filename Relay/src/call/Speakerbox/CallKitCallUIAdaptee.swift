//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import UIKit
import CallKit
import AVFoundation
import RelayServiceKit
import RelayMessaging

/**
 * Connects user interface to the CallService using CallKit.
 *
 * User interface is routed to the CallManager which requests CXCallActions, and if the CXProvider accepts them,
 * their corresponding consequences are implmented in the CXProviderDelegate methods, e.g. using the CallService
 */
@available(iOS 10.0, *)
final class CallKitCallUIAdaptee: NSObject, CallUIAdaptee, CXProviderDelegate {

    let TAG = "[CallKitCallUIAdaptee]"

    private let callManager: CallKitCallManager
    internal let callService: CallService
    internal let notificationsAdapter: CallNotificationsAdapter
    internal let contactsManager: FLContactsManager
    private let showNamesOnCallScreen: Bool
    private let provider: CXProvider
    private let audioActivity: AudioActivity

    // CallKit handles incoming ringer stop/start for us. Yay!
    let hasManualRinger = false

    // Instantiating more than one CXProvider can cause us to miss call transactions, so
    // we maintain the provider across Adaptees using a singleton pattern
    private static var _sharedProvider: CXProvider?
    class func sharedProvider(useSystemCallLog: Bool) -> CXProvider {
        let configuration = buildProviderConfiguration(useSystemCallLog: useSystemCallLog)

        if let sharedProvider = self._sharedProvider {
            sharedProvider.configuration = configuration
            return sharedProvider
        } else {
            SwiftSingletons.register(self)
            let provider = CXProvider(configuration: configuration)
            _sharedProvider = provider
            return provider
        }
    }

    // The app's provider configuration, representing its CallKit capabilities
    class func buildProviderConfiguration(useSystemCallLog: Bool) -> CXProviderConfiguration {
        let localizedName = NSLocalizedString("APPLICATION_NAME", comment: "Name of application")
        let providerConfiguration = CXProviderConfiguration(localizedName: localizedName)

        providerConfiguration.supportsVideo = true

        providerConfiguration.maximumCallGroups = 1

        providerConfiguration.maximumCallsPerCallGroup = 1

        providerConfiguration.supportedHandleTypes = [.phoneNumber, .generic]

        let iconMaskImage = #imageLiteral(resourceName: "logoForsta")
        providerConfiguration.iconTemplateImageData = UIImagePNGRepresentation(iconMaskImage)

        // We don't set the ringtoneSound property, so that we use either the
        // default iOS ringtone OR the custom ringtone associated with this user's
        // system contact, if possible (iOS 11 or later).

        if #available(iOS 11.0, *) {
            providerConfiguration.includesCallsInRecents = useSystemCallLog
        } else {
            // not configurable for iOS10+
            assert(useSystemCallLog)
        }

        return providerConfiguration
    }

    init(callService: CallService, contactsManager: FLContactsManager, notificationsAdapter: CallNotificationsAdapter, showNamesOnCallScreen: Bool, useSystemCallLog: Bool) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(#function)")

        self.callManager = CallKitCallManager(showNamesOnCallScreen: showNamesOnCallScreen)
        self.callService = callService
        self.contactsManager = contactsManager
        self.notificationsAdapter = notificationsAdapter

        self.provider = type(of: self).sharedProvider(useSystemCallLog: useSystemCallLog)

        self.audioActivity = AudioActivity(audioDescription: "[CallKitCallUIAdaptee]")
        self.showNamesOnCallScreen = showNamesOnCallScreen

        super.init()

        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings

        self.provider.setDelegate(self, queue: nil)
    }

    // MARK: CallUIAdaptee

    func startOutgoingCall(threadId: String) -> RelayCall {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        let call = RelayCall.outgoingCall(threadId: threadId, callId: UUID().uuidString.lowercased())

        // make sure we don't terminate audio session during call
        OWSAudioSession.shared.startAudioActivity(call.audioActivity)

        // Add the new outgoing call to the app's list of calls.
        // So we can find it in the provider delegate callbacks.
        callManager.addCall(call)
        callManager.startCall(call)

        return call
    }

    // Called from CallService after call has ended to clean up any remaining CallKit call state.
    func failCall(_ call: RelayCall, error: CallError) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        switch error {
        case .timeout(description: _):
            provider.reportCall(with: call.localId, endedAt: Date(), reason: CXCallEndedReason.unanswered)
        default:
            provider.reportCall(with: call.localId, endedAt: Date(), reason: CXCallEndedReason.failed)
        }

        self.callManager.removeCall(call)
    }

    func reportIncomingCall(_ call: RelayCall, callerName: String) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        // Construct a CXCallUpdate describing the incoming call, including the caller.
        let update = CXCallUpdate()

        update.localizedCallerName = call.thread.displayName() // self.contactsManager.displayName(forRecipientId: call.callId)
        update.remoteHandle = CXHandle(type: .generic, value: call.thread.displayName())

//        if showNamesOnCallScreen {
//            update.localizedCallerName = self.contactsManager.displayName(forRecipientId: call.callId)
//            update.remoteHandle = CXHandle(type: .phoneNumber, value: call.callId)
//        } else {
//            let callKitId = CallKitCallManager.kAnonymousCallHandlePrefix + call.localId.uuidString
//            update.remoteHandle = CXHandle(type: .generic, value: callKitId)
//            OWSPrimaryStorage.shared().setPhoneNumber(call.callId, forCallKitId: callKitId)
//            update.localizedCallerName = NSLocalizedString("CALLKIT_ANONYMOUS_CONTACT_NAME", comment: "The generic name used for calls if CallKit privacy is enabled")
//        }

        update.hasVideo = call.hasLocalVideo

        disableUnsupportedFeatures(callUpdate: update)

        // Report the incoming call to the system
        provider.reportNewIncomingCall(with: call.localId, update: update) { error in
            /*
             Only add incoming call to the app's list of calls if the call was allowed (i.e. there was no error)
             since calls may be "denied" for various legitimate reasons. See CXErrorCodeIncomingCallError.
             */
            guard error == nil else {
                Logger.error("\(self.TAG) failed to report new incoming call")
                return
            }

            self.callManager.addCall(call)
        }
    }

    func answerCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        owsFailDebug("\(self.TAG) \(#function) CallKit should answer calls via system call screen, not via notifications.")
    }

    func answerCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        callManager.answer(call: call)
    }

    func declineCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)

        owsFailDebug("\(self.TAG) \(#function) CallKit should decline calls via system call screen, not via notifications.")
    }

    func declineCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        callManager.localHangup(call: call)
    }

    func recipientAcceptedCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        self.provider.reportOutgoingCall(with: call.localId, connectedAt: nil)

        let update = CXCallUpdate()
        disableUnsupportedFeatures(callUpdate: update)

        provider.reportCall(with: call.localId, updated: update)
    }

    func localHangupCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        callManager.localHangup(call: call)
    }

    func remoteDidHangupCall(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        provider.reportCall(with: call.localId, endedAt: nil, reason: CXCallEndedReason.remoteEnded)
    }

    func remoteBusy(_ call: RelayCall) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        provider.reportCall(with: call.localId, endedAt: nil, reason: CXCallEndedReason.unanswered)
    }

    func setIsMuted(call: RelayCall, isMuted: Bool) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        callManager.setIsMuted(call: call, isMuted: isMuted)
    }

    func setHasLocalVideo(call: RelayCall, hasLocalVideo: Bool) {
        AssertIsOnMainThread(file: #function)
        Logger.debug("\(self.TAG) \(#function)")

        let update = CXCallUpdate()
        update.hasVideo = hasLocalVideo

        // Update the CallKit UI.
        provider.reportCall(with: call.localId, updated: update)

        self.callService.setHasLocalVideo(hasLocalVideo: hasLocalVideo)
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")

        // End any ongoing calls if the provider resets, and remove them from the app's list of calls,
        // since they are no longer valid.
        callService.handleFailedCurrentCall(error: .providerReset)

        // Remove all calls from the app's list of calls.
        callManager.removeAllCalls()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        AssertIsOnMainThread(file: #function)

        Logger.info("\(TAG) in \(#function) CXStartCallAction")

        guard let call = callManager.callWithLocalId(action.callUUID) else {
            Logger.error("\(TAG) unable to find call in \(#function)")
            return
        }

        // We can't wait for long before fulfilling the CXAction, else CallKit will show a "Failed Call". We don't 
        // actually need to wait for the outcome of the handleOutgoingCall promise, because it handles any errors by 
        // manually failing the call.
        self.callService.handleOutgoingCall(call).retainUntilComplete()

        action.fulfill()
        self.provider.reportOutgoingCall(with: call.localId, startedConnectingAt: nil)

        // Update the name used in the CallKit UI for outgoing calls when the user prefers not to show names
        // in ther notifications
        if !showNamesOnCallScreen {
            let update = CXCallUpdate()
            update.localizedCallerName = NSLocalizedString("CALLKIT_ANONYMOUS_CONTACT_NAME",
                                                           comment: "The generic name used for calls if CallKit privacy is enabled")
            provider.reportCall(with: call.localId, updated: update)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        AssertIsOnMainThread(file: #function)

        Logger.info("\(TAG) Received \(#function) CXAnswerCallAction")
        // Retrieve the instance corresponding to the action's call UUID
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            action.fail()
            return
        }

        self.callService.handleAnswerCall(call)
        self.showCall(call)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        AssertIsOnMainThread(file: #function)

        Logger.info("\(TAG) Received \(#function) CXEndCallAction")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            Logger.error("\(self.TAG) in \(#function) trying to end unknown call with localId: \(action.callUUID)")
            action.fail()
            return
        }

        self.callService.handleLocalHungupCall(call)

        // Signal to the system that the action has been successfully performed.
        action.fulfill()

        // Remove the ended call from the app's list of calls.
        self.callManager.removeCall(call)
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        AssertIsOnMainThread(file: #function)

        Logger.info("\(TAG) Received \(#function) CXSetHeldCallAction")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            action.fail()
            return
        }

        // Update the SignalCall's underlying hold state.
        self.callService.setIsOnHold(call: call, isOnHold: action.isOnHold)

        // Signal to the system that the action has been successfully performed.
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        AssertIsOnMainThread(file: #function)

        Logger.info("\(TAG) Received \(#function) CXSetMutedCallAction")
        guard let call = callManager.callWithLocalId(action.callUUID) else {
            Logger.error("\(TAG) Failing CXSetMutedCallAction for unknown call: \(action.callUUID)")
            action.fail()
            return
        }

        self.callService.setIsMuted(call: call, isMuted: action.isMuted)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        AssertIsOnMainThread(file: #function)

        Logger.warn("\(TAG) unimplemented \(#function) for CXSetGroupCallAction")
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        AssertIsOnMainThread(file: #function)

        Logger.warn("\(TAG) unimplemented \(#function) for CXPlayDTMFCallAction")
    }

    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(TAG) Timed out \(#function) while performing \(action)")

        // React to the action timeout if necessary, such as showing an error UI.
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(TAG) Received \(#function)")

        OWSAudioSession.shared.startAudioActivity(self.audioActivity)
        OWSAudioSession.shared.isRTCAudioEnabled = true
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        AssertIsOnMainThread(file: #function)

        Logger.debug("\(TAG) Received \(#function)")
        OWSAudioSession.shared.isRTCAudioEnabled = false
        OWSAudioSession.shared.endAudioActivity(self.audioActivity)
    }

    // MARK: - Util

    private func disableUnsupportedFeatures(callUpdate: CXCallUpdate) {
        // Call Holding is failing to restart audio when "swapping" calls on the CallKit screen
        // until user returns to in-app call screen.
        callUpdate.supportsHolding = false

        // Not yet supported
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false

        // Is there any reason to support this?
        callUpdate.supportsDTMF = false
    }
}
