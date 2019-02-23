//
//  ConferenceCallService.swift
//  Relay
//
//  Created by Greg Perkins on 1/28/19.
//  Copyright © 2019 Forsta, Inc. All rights reserved.
//

import Foundation
import RelayServiceKit
import WebRTC
import PromiseKit

protocol ConferenceCallServiceDelegate: class {
    func createdConferenceCall(call: ConferenceCall)
}

let defaultCallAVPolicy = CallAVPolicy(startAudioMuted: false, allowAudioMuteToggle: true, startVideoMuted: false, allowVideoMuteToggle: true)


@objc public class ConferenceCallService: NSObject, FLCallMessageHandler, ConferenceCallDelegate {
    static let rtcFactory = RTCPeerConnectionFactory()
    @objc static let shared = ConferenceCallService()
    let rtcQueue = DispatchQueue(label: "WebRTCDanceCard")
    lazy var iceServers: Promise<[RTCIceServer]> = ConferenceCallService.getIceServers();
    var delegates = [Weak<ConferenceCallServiceDelegate>]()

    var conferenceCall: ConferenceCall?
    
    @objc func startCall(thread: TSThread) -> ConferenceCall? {
        if self.conferenceCall != nil {
            Logger.debug("Rejected request to create a second ConferenceCall (for now)")
            return nil
        }
        
        let newCallId = thread.uniqueId
        let originatorId = TSAccountManager.localUID()!
        self.conferenceCall = ConferenceCall(thread: thread, callId: newCallId, originatorId: originatorId, delegate: self, policy: defaultCallAVPolicy, direction: .outgoing)
        notifyDelegates({ delegate in delegate.createdConferenceCall(call: conferenceCall!) })
        self.conferenceCall!.joinCall()
        return self.conferenceCall!
    }
    
    func endCall(_ call: ConferenceCall) {
        if (call != self.conferenceCall) {
            Logger.debug("Ignoring endCall for an inactive(??) call")
            return
        }
        self.conferenceCall?.leaveCall()
    }
    
    // MARK: - internal helpers
    private static func getIceServers() -> Promise<[RTCIceServer]> {
        AssertIsOnMainThread(file: #function)
        
        return firstly {
            SignalApp.shared().accountManager.getTurnServerInfo()
            }.map { turnServerInfo -> [RTCIceServer] in
                Logger.debug("got turn server urls: \(turnServerInfo.urls)")
                
                return turnServerInfo.urls.map { url in
                    if url.hasPrefix("turn") {
                        // Only "turn:" servers require authentication. Don't include the credentials to other ICE servers
                        // as 1.) they aren't used, and 2.) the non-turn servers might not be under our control.
                        // e.g. we use a public fallback STUN server.
                        return RTCIceServer(urlStrings: [url], username: turnServerInfo.username, credential: turnServerInfo.password)
                    } else {
                        return RTCIceServer(urlStrings: [url])
                    }
                    } + [RTCIceServer(urlStrings: [fallbackIceServerUrl])]
            }.recover { (error: Error) -> Guarantee<[RTCIceServer]> in
                Logger.error("fetching ICE servers failed with error: \(error)")
                Logger.warn("using fallback ICE Server")
                
                return Guarantee.value([RTCIceServer(urlStrings: [fallbackIceServerUrl])])
        }
    }
    
    // MARK: - FLCallMessageHandler implementation
    
    public func receivedJoin(with thread: TSThread, senderId: String, senderDeviceId: UInt32, originatorId: String, callId: String) {
        if conferenceCall != nil && conferenceCall?.callId != callId {
            Logger.debug("Ignoring call-offer for a different call than the one we already have running")
            return
        }
        
        if conferenceCall == nil {
            self.conferenceCall = ConferenceCall(thread: thread,
                                                 callId: callId,
                                                 originatorId: originatorId,
                                                 delegate: self,
                                                 policy: defaultCallAVPolicy,
                                                 direction: .incoming)
            notifyDelegates({ delegate in delegate.createdConferenceCall(call: conferenceCall!) })
            conferenceCall!.state = .ringing
        }
        
        self.conferenceCall!.handleJoin(userId: senderId, deviceId: senderDeviceId)
    }
    
    public func receivedOffer(with thread: TSThread, senderId: String, senderDeviceId: UInt32, callId: String, peerId: String, sessionDescription: String) {
        if conferenceCall != nil && conferenceCall?.callId != callId {
            Logger.debug("Ignoring call-offer from/for a different call since we already have one running")
            return
        }
        if conferenceCall == nil {
            Logger.debug("Ignoring call-offer for a nonexistent call")
            return
        }
        conferenceCall!.handleOffer(userId: senderId, deviceId: senderDeviceId, peerId: peerId, sessionDescription: sessionDescription)
    }

    public func receivedAcceptOffer(with thread: TSThread, callId: String, peerId: String, sessionDescription: String) {
        if conferenceCall == nil || (conferenceCall != nil && conferenceCall?.callId != callId) {
            Logger.debug("Ignoring accept-offer from/for an unknown call")
            return
        }
        conferenceCall!.handleAcceptOffer(peerId: peerId, sessionDescription: sessionDescription)
    }

    public func receivedSelfAcceptOffer(with thread: TSThread, callId: String, deviceId: UInt32) {
        if conferenceCall == nil || (conferenceCall != nil && conferenceCall?.callId != callId) {
            Logger.debug("Ignoring self-accept-offer from/for an unknown call")
            return
        }
        conferenceCall!.handleSelfAcceptOffer(deviceId: deviceId)
    }
    
    
    public func receivedIceCandidates(with thread: TSThread, senderId: String, senderDeviceId: UInt32, callId: String, iceCandidates: [Any]) {
        if conferenceCall == nil || (conferenceCall != nil && conferenceCall?.callId != callId) {
            Logger.debug("Ignoring ice candidates from/for an unknown call")
            return
        }
        conferenceCall?.handleRemoteIceCandidates(userId:senderId, deviceId:senderDeviceId, iceCandidates: iceCandidates)
    }
    
    public func receivedLeave(with thread: TSThread, senderId: String, senderDeviceId: UInt32, callId: String) {
        if conferenceCall == nil || (conferenceCall != nil && conferenceCall?.callId != callId) {
            Logger.debug("Ignoring leave from/for an unknown call")
            return
        }
        
        conferenceCall?.handleLeave(userId: senderId, deviceId: senderDeviceId);
    }
    

    // MARK: - ConferenceCallDelegate implementation
    
    func audioSourceDidChange(call: ConferenceCall, audioSource: AudioSource?) {
        // TODO: implement
    }

    func stateDidChange(call: ConferenceCall, oldState: ConferenceCallState, newState: ConferenceCallState) {
        ConferenceCallEvents.add(.CallStateChange(callId: call.callId, oldState: oldState, newState: newState))
        if oldState == .leaving && newState == .left && self.conferenceCall == call {
            self.conferenceCall!.cleanupBeforeDestruction()
            self.conferenceCall = nil
        }
    }
    
    func peerConnectionStateDidChange(pcc: PeerConnectionClient, oldState: PeerConnectionClientState, newState: PeerConnectionClientState) {
        ConferenceCallEvents.add(.PeerStateChange(callId: pcc.callId, peerId: pcc.peerId, userId: pcc.userId, deviceId: pcc.deviceId, oldState: oldState, newState: newState))
    }
    
    func peerConnectionDidUpdateRemoteVideoTrack(peerId: String, remoteVideoTrack: RTCVideoTrack) {
        // don't care
    }
    
    func peerConnectionDidUpdateRemoteAudioTrack(peerId: String, remoteAudioTrack: RTCAudioTrack) {
        // don't care
    }
    
    func didUpdateLocalVideoTrack(captureSession: AVCaptureSession?) {
        // don't care
    }
    
    // MARK: - Self Delegates Management
    
    func addDelegate(delegate: ConferenceCallServiceDelegate) {
        AssertIsOnMainThread(file: #function)
        delegates.append(Weak(value: delegate))
    }
    
    func removeDelegate(_ delegate: ConferenceCallServiceDelegate) {
        AssertIsOnMainThread(file: #function)
        while let index = delegates.index(where: { $0.value === delegate }) {
            delegates.remove(at: index)
        }
    }
    
    func removeAllDelegates() {
        AssertIsOnMainThread(file: #function)
        delegates = []
    }
    
    func notifyDelegates(_ todo: (_ theDelegate: ConferenceCallServiceDelegate) -> Void) {
        for delegate in delegates {
            if delegate.value != nil {
                todo(delegate.value!)
            }
        }
    }
}
