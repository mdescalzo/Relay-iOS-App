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

enum ConferenceCallEvent {
    case CallStateChange(timestamp: Date,
                         callId: String,
                         oldState: ConferenceCallState,
                         newState: ConferenceCallState)
    case PeerStateChange(timestamp: Date,
                         callId: String,
                         peerId: String,
                         oldState: PeerConnectionClientState,
                         newState: PeerConnectionClientState)
}

extension Formatter {
    static let withCommas: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.groupingSeparator = ","
        formatter.numberStyle = .decimal
        return formatter
    }()
}
extension Double {
    var formattedWithCommas: String {
        return Formatter.withCommas.string(for: self) ?? ""
    }
}

extension ConferenceCallEvent {
    func str(_ epoch: Date) -> String {
        switch self {
        case .CallStateChange(timestamp: let timestamp, callId: let callId, oldState: let oldState, newState: let newState):
            let ms = round((timestamp.timeIntervalSince(epoch) * 1000))
            return "call transition: \(oldState)->\(newState) @ \(ms.formattedWithCommas)ms call \(callId)"
        case .PeerStateChange(timestamp: let timestamp, callId: let callId, peerId: let peerId, oldState: let oldState, newState: let newState):
            let ms = round((timestamp.timeIntervalSince(epoch) * 1000))
            return "peer transition: \(oldState)->\(newState) @ \(ms.formattedWithCommas)ms peer \(peerId) call \(callId)"
        }
    }
}

protocol ConferenceCallServiceDelegate: class {
    func createdConferenceCall(call: ConferenceCall)
}

@objc public class ConferenceCallService: NSObject, FLCallMessageHandler, ConferenceCallDelegate {
    static let rtcFactory = RTCPeerConnectionFactory()
    @objc static let shared = ConferenceCallService()
    
    let rtcQueue = DispatchQueue(label: "WebRTCDanceCard")
    lazy var iceServers: Promise<[RTCIceServer]> = ConferenceCallService.getIceServers();
    var delegates = [Weak<ConferenceCallServiceDelegate>]()

    var events = [ConferenceCallEvent]()
    var eventsEpoch = Date()
    
    var conferenceCall: ConferenceCall?  // this can be a collection in the future, indexed by callId
    
    public func receivedOffer(with thread: TSThread, callId: String, senderId: String, peerId: String, originatorId: String, sessionDescription: String) {
        if conferenceCall != nil && conferenceCall?.callId != callId {
            Logger.debug("Ignoring call-offer from/for a new call since we already have one running")
            return
        }
        if conferenceCall == nil {
            conferenceCall = ConferenceCall(thread: thread, callId: callId, originatorId: originatorId, delegate: self)
            notifyDelegates({ delegate in delegate.createdConferenceCall(call: conferenceCall!) })
        }
        conferenceCall!.handleOffer(senderId: senderId, peerId: peerId, sessionDescription: sessionDescription)
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
    
    
    public func receivedIceCandidates(with thread: TSThread, callId: String, peerId: String, iceCandidates: [Any]) {
        if conferenceCall == nil || (conferenceCall != nil && conferenceCall?.callId != callId) {
            Logger.debug("Ignoring ice candidates from/for an unknown call")
            return
        }
        conferenceCall?.handleRemoteIceCandidates(peerId: peerId, iceCandidates: iceCandidates)
    }
    
    public func receivedLeave(with thread: TSThread, callId: String, senderId: String) {
        if conferenceCall == nil || (conferenceCall != nil && conferenceCall?.callId != callId) {
            Logger.debug("Ignoring leave from/for an unknown call")
            return
        }
        
        guard let (_, pcc) = (conferenceCall!.peerConnectionClients.first { (k, v) in v.userId == senderId }) else {
            Logger.debug("unable to find a PeerConnectionClient for sender \(senderId)")
            return
        }
        conferenceCall?.handlePeerLeave(peerId: pcc.peerId);
    }
    
    // initiate an outbound call
    @objc public func startCall(thread: TSThread) -> ConferenceCall {
        let newCallId = thread.uniqueId // temporary -- should be: NSUUID().uuidString.lowercased()
        let originatorId = TSAccountManager.localUID()!
        conferenceCall = ConferenceCall(thread: thread, callId: newCallId, originatorId: originatorId, delegate: self)
        notifyDelegates({ delegate in delegate.createdConferenceCall(call: conferenceCall!) })
        conferenceCall!.inviteMissingParticipants()
        return conferenceCall!
    }
    
    // terminate an existing call
    func endCall(call: ConferenceCall) {
        if (call != self.conferenceCall) {
            Logger.debug("Ignoring endCall for an unknown call")
            return
        }
        call.leaveCall()
    }
    
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
    
    // MARK: - ConferenceCallDelegate implementation
    
    public func stateDidChange(call: ConferenceCall, oldState: ConferenceCallState, newState: ConferenceCallState) {
        self.events.append(.CallStateChange(timestamp: Date(), callId: call.callId, oldState: oldState, newState: newState))
        Logger.info("\n\(self.events.last!.str(self.eventsEpoch))\n")
    }
    
    public func peerConnectionStateDidChange(callId: String, peerId: String, oldState: PeerConnectionClientState, newState: PeerConnectionClientState) {
        self.events.append(.PeerStateChange(timestamp: Date(), callId: callId, peerId: peerId, oldState: oldState, newState: newState))
        Logger.info("\n\(self.events.last!.str(self.eventsEpoch))\n")
    }
    
    public func peerConnectiongDidUpdateRemoteVideoTrack(peerId: String) {
        // don't care
    }
    
    public func didUpdateLocalVideoTrack(captureSession: AVCaptureSession?) {
        // don't care
    }
    

    // MARK: - Delegates
    
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
