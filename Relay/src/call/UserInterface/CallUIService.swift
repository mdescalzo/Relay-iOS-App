//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import CallKit
import RelayServiceKit
import RelayMessaging
import WebRTC

/**
 * Notify the user of call related activities.
 * Driven by either a CallKit or System notifications adaptee
 */
@objc
public class CallUIService: NSObject, ConferenceCallServiceDelegate, ConferenceCallDelegate, CXProviderDelegate {
    public func peerConnectionStateDidChange(callId: String, peerId: String, oldState: PeerConnectionClientState, newState: PeerConnectionClientState) {
        // TODO
    }

    @objc static let shared = CallUIService()
    
    let TAG = "[CallUIAdapter]"
    lazy var contactsManager: FLContactsManager = {
        return FLContactsManager.shared
    }()
    internal let audioService: CallAudioService
    lazy var callService: ConferenceCallService = {
        return ConferenceCallService.shared
    }()
    private let callController = CXCallController()
    private let audioActivity: AudioActivity
    private let provider: CXProvider
    var showNamesOnCallScreen: Bool
    var useSystemCallLog: Bool

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
    
    
    override init() {
        AssertIsOnMainThread(file: #function)
        
        if #available(iOS 11, *) {
            Logger.info("Choosing callkit adaptee for iOS11+")
            showNamesOnCallScreen = Environment.preferences().notificationPreviewType() != .noNameNoPreview
            useSystemCallLog = Environment.preferences().isSystemCallLogEnabled()
        } else {
            Logger.info("Choosing callkit adaptee for iOS10")
            let hideNames = Environment.preferences().isCallKitPrivacyEnabled() || Environment.preferences().notificationPreviewType() == .noNameNoPreview
            showNamesOnCallScreen = !hideNames
            
            // All CallKit calls use the system call log on iOS10
            useSystemCallLog = true
        }
        
        audioService = CallAudioService(handleRinging: false)
        audioActivity = AudioActivity(audioDescription: TAG)

        self.provider = type(of: self).sharedProvider(useSystemCallLog: useSystemCallLog)

        super.init()

        self.provider.setDelegate(self, queue: nil)
        
        callService.addDelegate(delegate: self)
    }
    
    internal func reportIncomingCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)

        guard let callUUID = UUID.init(uuidString:call.callId) else {
            Logger.error("\(self.TAG) received call object with malformed id: \(call.callId)")
            return
        }

        // make sure we don't terminate audio session during call
        OWSAudioSession.shared.startAudioActivity(call.audioActivity)
        
        let callName = call.thread.displayName()
        
        // Construct a CXCallUpdate describing the incoming call, including the caller.
        let update = CXCallUpdate()
        
        update.remoteHandle = CXHandle(type: .generic, value: callName)
        
        if showNamesOnCallScreen {
            update.localizedCallerName = callName
        } else {
            update.localizedCallerName = NSLocalizedString("CALLKIT_ANONYMOUS_CONTACT_NAME", comment: "The generic name used for calls if CallKit privacy is enabled")
        }
        
        update.hasVideo = (call.localVideoTrack != nil) ? true : false
        
        disableUnsupportedFeatures(callUpdate: update)
        
         // Report the incoming call to the system
        self.provider.reportNewIncomingCall(with: callUUID, update: update) { error in
            /*
             Only add incoming call to the app's list of calls if the call was allowed (i.e. there was no error)
             since calls may be "denied" for various legitimate reasons. See CXErrorCodeIncomingCallError.
             */
            guard error == nil else {
                Logger.error("\(self.TAG) failed to report new incoming call")
                return
            }
        }
    }
    
    internal func reportMissedCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
        let callName = call.thread.displayName()
        // TODO:  Fix this?
        // self.notificationsAdapter.presentMissedCall(call, callName: callName)
    }
    
    internal func startOutgoingCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)

        self.showCall(call)
    }
    
    @objc public func answerCall(localId: UUID) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
    }
    
    internal func answerCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
    }
    
    @objc public func declineCall(localId: UUID) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
    }
    
    internal func declineCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
    }
    
    internal func didTerminateCall(_ call: ConferenceCall?) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
        if let call = call {
            OWSAudioSession.shared.endAudioActivity(self.audioActivity)
            OWSAudioSession.shared.endAudioActivity(call.audioActivity)
            self.submitEndCallAction(call: call)
        }
    }
    
//    @objc public func startAndShowOutgoingCall(recipientId: String, hasLocalVideo: Bool) {
//        Logger.info("\(self.logTag) called \(#function)")
//        AssertIsOnMainThread(file: #function)
//
//    }
    
    internal func recipientAcceptedCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
    }
    
    internal func remoteDidHangupCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        OWSAudioSession.shared.endAudioActivity(call.audioActivity)
        self.submitEndCallAction(call: call)
    }
    
    internal func remoteBusy(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
    }
    
    internal func localHangupCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
        ConferenceCallService.shared.endCall(call: call)
        OWSAudioSession.shared.endAudioActivity(call.audioActivity)
        self.submitEndCallAction(call: call)
    }
    
    internal func failCall(_ call: ConferenceCall, error: CallError) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)

        ConferenceCallService.shared.endCall(call: call)
        OWSAudioSession.shared.endAudioActivity(call.audioActivity)
        self.submitEndCallAction(call: call)
    }
    
    internal func showCall(_ call: ConferenceCall) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
        let callViewController = UIStoryboard(name: "Main",
                                              bundle: nil).instantiateViewController(withIdentifier: "ConferenceCallViewController") as! ConferenceCallViewController
        callViewController.configure(call: call)
        callViewController.modalTransitionStyle = .crossDissolve
        
        OWSWindowManager.shared().startCall(callViewController)
    }
    
    internal func setIsMuted(call: ConferenceCall, isMuted: Bool) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
        guard let callUUID = UUID(uuidString: call.callId) else {
            Logger.debug("\(self.logTag) received call with malformed callId: \(call.callId)")
            return
        }
        
        let muteAction = CXSetMutedCallAction(call: callUUID, muted: isMuted)
        let transaction = CXTransaction()
        transaction.addAction(muteAction)
        requestTransaction(transaction)

    }
    
    internal func setHasLocalVideo(call: ConferenceCall, hasLocalVideo: Bool) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
    }
    
    internal func setAudioSource(call: ConferenceCall, audioSource: AudioSource?) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
        // AudioSource is not handled by CallKit (e.g. there is no CXAction), so we handle it w/o going through the
        // adaptee, relying on the AudioService CallObserver to put the system in a state consistent with the call's
        // assigned property.
        
        // XXXXX
//        call.audioSource = audioSource
    }
    
    internal func setCameraSource(call: ConferenceCall, isUsingFrontCamera: Bool) {
        Logger.info("\(self.logTag) called \(#function)")
        AssertIsOnMainThread(file: #function)
        
        // XXXXX
//        callService.setCameraSource(call: call, isUsingFrontCamera: isUsingFrontCamera)
    }
    
    // MARK: - Helpers
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
            providerConfiguration.includesCallsInRecents = true
        }
        
        return providerConfiguration
    }
    
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
    
    private func requestTransaction(_ transaction: CXTransaction) {
        callController.request(transaction) { error in
            if let error = error {
                Logger.error("\(self.logTag) Error requesting transaction: \(error)")
            } else {
                Logger.debug("\(self.logTag) Requested transaction successfully")
            }
        }
    }

    private func submitEndCallAction(call: ConferenceCall) {
        guard let callUUID = UUID(uuidString: call.callId) else {
            Logger.debug("\(self.logTag) received call with malformed callId: \(call.callId)")
            return
        }
        
        let endCallAction = CXEndCallAction(call: callUUID)
        let transaction = CXTransaction()
        transaction.addAction(endCallAction)
        
        requestTransaction(transaction)
    }
    
    // MARK: - CallServiceDelegate
    internal func createdConferenceCall(call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        call.addDelegate(delegate: self)
        
        if call.direction == .incoming {
            self.reportIncomingCall(call)
        } else {
            self.startOutgoingCall(call)
        }
    }

    
    internal func didUpdateCall(call: ConferenceCall?) {
        AssertIsOnMainThread(file: #function)
        
        // XXXXX
//      call?.addObserverAndSyncState(observer: audioService)
    }
    
    // MARK: - ConferenceCallDelegate
    public func stateDidChange(call: ConferenceCall, oldState: ConferenceCallState, newState: ConferenceCallState) {
        switch call.state {
        case .undefined:
            do {}
        case .ringing:
            do {
                self.reportIncomingCall(call)
            }
        case .vibrating:
            do {}
        case .rejected:
            do {}
        case .joined:
            do {
            }
        case .leaving:
            do {}
        case .left:
            do {
                self.didTerminateCall(call)
            }
        case .failed:
            do {
                self.didTerminateCall(call)
            }
        }
    }
    
    public func didUpdateLocalVideoTrack(captureSession: AVCaptureSession?) {
        Logger.info("\(self.TAG) \(#function)")
    }
    
    func peerConnectionDidConnect(peerId: String) {
        Logger.info("\(self.TAG) \(#function)")
    }
    
    public func peerConnectiongDidUpdateRemoteVideoTrack(peerId: String) {
        Logger.info("\(self.TAG) \(#function)")
    }

    // MARK: - CXProviderDelegate
    public func providerDidReset(_ provider: CXProvider) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(self.TAG) \(#function)")
        if let call = self.callService.conferenceCall {
            self.callService.endCall(call: call)
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        AssertIsOnMainThread(file: #function)
        
        Logger.info("\(TAG) in \(#function) CXStartCallAction")
        action.fail()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(TAG) Received \(#function) CXAnswerCallAction")
        guard ConferenceCallService.shared.conferenceCall?.callId.lowercased() == action.callUUID.uuidString.lowercased() else {
            Logger.debug("\(TAG) Ignoring action for obsolete call.")
            action.fail()
            return
        }
        self.showCall(ConferenceCallService.shared.conferenceCall!)
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(TAG) Received \(#function) CXEndCallAction")
        guard ConferenceCallService.shared.conferenceCall?.callId.lowercased() == action.callUUID.uuidString.lowercased() else {
            Logger.debug("\(TAG) Ignoring action for obsolete call.")
            action.fulfill()
            return
        }
        // Not
        self.callService.endCall(call: ConferenceCallService.shared.conferenceCall!)
        
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(TAG) Received \(#function) CXSetHeldCallAction")
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        AssertIsOnMainThread(file: #function)
        Logger.info("\(TAG) Received \(#function) CXSetMutedCallAction")
        
        // TODO:  Add mute call logic here
        
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
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        AssertIsOnMainThread(file: #function)
        
        Logger.debug("\(TAG) Timed out \(#function) while performing \(action)")
        
        if let call = callService.conferenceCall {
        self.provider.reportCall(with: UUID(uuidString: call.callId)!, endedAt: Date(), reason: CXCallEndedReason.unanswered)
            self.failCall(call, error: .timeout(description: "Call \(call.callId) timed out"))
        }
        action.fulfill()
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        AssertIsOnMainThread(file: #function)
        
        Logger.debug("\(TAG) Received \(#function)")
        
        OWSAudioSession.shared.startAudioActivity(self.audioActivity)
        OWSAudioSession.shared.isRTCAudioEnabled = true
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        AssertIsOnMainThread(file: #function)
        
        Logger.debug("\(TAG) Received \(#function)")
        OWSAudioSession.shared.isRTCAudioEnabled = false
        OWSAudioSession.shared.endAudioActivity(self.audioActivity)
    }
}