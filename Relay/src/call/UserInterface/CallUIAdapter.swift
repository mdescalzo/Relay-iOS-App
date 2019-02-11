//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import CallKit
import RelayServiceKit
import RelayMessaging
import WebRTC

protocol CallUIAdaptee {
    var notificationsAdapter: CallNotificationsAdapter { get }
    var callService: ConferenceCallService { get }
    var hasManualRinger: Bool { get }
    
    func startOutgoingCall(threadId: String) -> ConferenceCall
    func reportIncomingCall(_ call: ConferenceCall, callerName: String)
    func reportMissedCall(_ call: ConferenceCall, callerName: String)
    func answerCall(localId: UUID)
    func answerCall(_ call: ConferenceCall)
    func declineCall(localId: UUID)
    func declineCall(_ call: ConferenceCall)
    func recipientAcceptedCall(_ call: ConferenceCall)
    func localHangupCall(_ call: ConferenceCall)
    //    func otherOwnedDeviceAnswered(_ call: ConferenceCall)
    func remoteDidHangupCall(_ call: ConferenceCall)
    func remoteBusy(_ call: ConferenceCall)
    func failCall(_ call: ConferenceCall, error: CallError)
    func setIsMuted(call: ConferenceCall, isMuted: Bool)
    func setHasLocalVideo(call: ConferenceCall, hasLocalVideo: Bool)
    func startAndShowOutgoingCall(recipientId: String, hasLocalVideo: Bool)
}

// Shared default implementations
extension CallUIAdaptee {
    internal func showCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)

        let callViewController = UIStoryboard(name: "Main",
                                              bundle: nil).instantiateViewController(withIdentifier: "ConferenceCallViewController") as! ConferenceCallViewController
        callViewController.configure(call: call)
        callViewController.modalTransitionStyle = .crossDissolve
        
        OWSWindowManager.shared().startCall(callViewController)
    }
    
    internal func reportMissedCall(_ call: ConferenceCall, callerName: String) {
        AssertIsOnMainThread(file: #function)
        
        notificationsAdapter.presentMissedCall(call, callerName: callerName)
    }
    
    internal func startAndShowOutgoingCall(recipientId: String, hasLocalVideo: Bool) {
        AssertIsOnMainThread(file: #function)
        
        guard self.callService.conferenceCall == nil else {
            owsFailDebug("unexpectedly found an existing call when trying to start outgoing call: \(recipientId)")
            return
        }
        
        let call = self.startOutgoingCall(threadId: recipientId)
//        call.hasLocalVideo = hasLocalVideo
        self.showCall(call)
    }
}

/**
 * Notify the user of call related activities.
 * Driven by either a CallKit or System notifications adaptee
 */
@objc public class CallUIAdapter: NSObject, CallServiceObserver {
    
    let TAG = "[CallUIAdapter]"
    private let adaptee: CallUIAdaptee
    private let contactsManager: FLContactsManager
    internal let audioService: CallAudioService
    internal let callService: ConferenceCallService
    
    @available(iOS 10.0, *)
    public required init(callService: ConferenceCallService, notificationsAdapter: CallNotificationsAdapter) {
        AssertIsOnMainThread(file: #function)
        
        self.contactsManager = FLContactsManager.shared
        self.callService = callService
        
        if #available(iOS 11, *) {
            Logger.info("Choosing callkit adaptee for iOS11+")
            let showNames = Environment.preferences().notificationPreviewType() != .noNameNoPreview
            let useSystemCallLog = Environment.preferences().isSystemCallLogEnabled()
            
            adaptee = CallKitCallUIAdaptee(callService: callService, contactsManager: contactsManager, notificationsAdapter: notificationsAdapter, showNamesOnCallScreen: showNames, useSystemCallLog: useSystemCallLog)
        } else {
            Logger.info("Choosing callkit adaptee for iOS10")
            let hideNames = Environment.preferences().isCallKitPrivacyEnabled() || Environment.preferences().notificationPreviewType() == .noNameNoPreview
            let showNames = !hideNames
            
            // All CallKit calls use the system call log on iOS10
            let useSystemCallLog = true
            
            adaptee = CallKitCallUIAdaptee(callService: callService, contactsManager: contactsManager, notificationsAdapter: notificationsAdapter, showNamesOnCallScreen: showNames, useSystemCallLog: useSystemCallLog)
        }
        
        audioService = CallAudioService(handleRinging: adaptee.hasManualRinger)
        
        super.init()
        
        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings
        
        callService.addObserverAndSyncState(observer: self)
    }
    
    internal func reportIncomingCall(_ call: ConferenceCall, thread: TSThread) {
        AssertIsOnMainThread(file: #function)
        
        // make sure we don't terminate audio session during call
        OWSAudioSession.shared.startAudioActivity(call.audioActivity)
        
        let callerName = self.contactsManager.displayName(forRecipientId: call.callId)
        adaptee.reportIncomingCall(call, callerName: callerName!)
    }
    
    internal func reportMissedCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        let callerName = self.contactsManager.displayName(forRecipientId: call.callId)
        adaptee.reportMissedCall(call, callerName: callerName!)
    }
    
    internal func startOutgoingCall(handle: String) -> ConferenceCall {
        AssertIsOnMainThread(file: #function)
        
        let call = adaptee.startOutgoingCall(threadId: handle)
        return call
    }
    
    @objc public func answerCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.answerCall(localId: localId)
    }
    
    internal func answerCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.answerCall(call)
    }
    
    @objc public func declineCall(localId: UUID) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.declineCall(localId: localId)
    }
    
    internal func declineCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.declineCall(call)
    }
    
    internal func didTerminateCall(_ call: ConferenceCall?) {
        AssertIsOnMainThread(file: #function)
        
        if let call = call {
            OWSAudioSession.shared.endAudioActivity(call.audioActivity)
        }
    }
    
    @objc public func startAndShowOutgoingCall(recipientId: String, hasLocalVideo: Bool) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.startAndShowOutgoingCall(recipientId: recipientId, hasLocalVideo: hasLocalVideo)
    }
    
    internal func recipientAcceptedCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.recipientAcceptedCall(call)
    }
    
    internal func remoteDidHangupCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.remoteDidHangupCall(call)
    }
    
    internal func remoteBusy(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.remoteBusy(call)
    }
    
    internal func localHangupCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.localHangupCall(call)
    }
    
    //    internal func otherOwnedDeviceAnswered(_ call: ConferenceCall) {
    //        AssertIsOnMainThread(file: #function)
    //
    //        adaptee.localHangupCall(call)
    //    }
    
    
    internal func failCall(_ call: ConferenceCall, error: CallError) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.failCall(call, error: error)
    }
    
    internal func showCall(_ call: ConferenceCall) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.showCall(call)
    }
    
    internal func setIsMuted(call: ConferenceCall, isMuted: Bool) {
        AssertIsOnMainThread(file: #function)
        
        // With CallKit, muting is handled by a CXAction, so it must go through the adaptee
        adaptee.setIsMuted(call: call, isMuted: isMuted)
    }
    
    internal func setHasLocalVideo(call: ConferenceCall, hasLocalVideo: Bool) {
        AssertIsOnMainThread(file: #function)
        
        adaptee.setHasLocalVideo(call: call, hasLocalVideo: hasLocalVideo)
    }
    
    internal func setAudioSource(call: ConferenceCall, audioSource: AudioSource?) {
        AssertIsOnMainThread(file: #function)
        
        // AudioSource is not handled by CallKit (e.g. there is no CXAction), so we handle it w/o going through the
        // adaptee, relying on the AudioService CallObserver to put the system in a state consistent with the call's
        // assigned property.
        
        // XXXXX
//        call.audioSource = audioSource
    }
    
    internal func setCameraSource(call: ConferenceCall, isUsingFrontCamera: Bool) {
        AssertIsOnMainThread(file: #function)
        
        // XXXXX
//        callService.setCameraSource(call: call, isUsingFrontCamera: isUsingFrontCamera)
    }
    
    // CallKit handles ringing state on it's own. But for non-call kit we trigger ringing start/stop manually.
    internal var hasManualRinger: Bool {
        AssertIsOnMainThread(file: #function)
        
        return adaptee.hasManualRinger
    }
    
    // MARK: - CallServiceObserver
    
    internal func didUpdateCall(call: ConferenceCall?) {
        AssertIsOnMainThread(file: #function)
        
        // XXXXX
//      call?.addObserverAndSyncState(observer: audioService)
    }
    
    internal func didUpdateVideoTracks(call: ConferenceCall?,
                                       localCaptureSession: AVCaptureSession?,
                                       remoteVideoTrack: RTCVideoTrack?) {
        AssertIsOnMainThread(file: #function)
        
        // XXXXX
//        audioService.didUpdateVideoTracks(call: call)
    }
}
