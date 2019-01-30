//
//  ConferenceCall.swift
//  Relay
//
//  Created by Greg Perkins on 1/28/19.
//  Copyright © 2019 Forsta, Inc. All rights reserved.
//

import Foundation
import PromiseKit

enum ConferenceCallDirection {
    case outgoing, incoming
}

enum ConferenceCallState {
    case ringing            // after receiving or sending an offer
    case rejected, joined   // after ringing
    case left               // after joined
    case failed             // after ringing or joined
}

protocol ConferenceCallObserver: class {
    func stateDidChange(call: ConferenceCall, state: ConferenceCallState)
    func peerConnectionsNeedAttention(call: ConferenceCall, peerId: String)
}

class ConferenceCall: PeerConnectionClientDelegate {
    let TAG = "[ConferenceCall]"
    var connectedDate: NSDate?
    
    let direction: ConferenceCallDirection
    let thread: TSThread;
    let callId: String;
    let originatorId: String;
    
    var observers = [Weak<ConferenceCallObserver>]()
    var peerConnectionClients = [String : PeerConnectionClient]() // indexed by peerId
    
    var callRecord: TSCall? {
        didSet {
            AssertIsOnMainThread(file: #function)
            assert(oldValue == nil)
            
            updateCallRecordType()
        }
    }
    
    var state: ConferenceCallState {
        didSet {
            AssertIsOnMainThread(file: #function)
            Logger.debug("\(TAG) state changed: \(oldValue) -> \(self.state) for call: \(self.callId)")
            
            // Update connectedDate
            if case .joined = self.state {
                // if it's the first time we've connected (not a reconnect)
                if connectedDate == nil {
                    connectedDate = NSDate()
                }
            }
            
            updateCallRecordType()
            
            for observer in observers {
                observer.value?.stateDidChange(call: self, state: state)
            }
        }
    }
    

    private init(direction: ConferenceCallDirection, thread: TSThread, callId: String, originatorId: String) {
        self.direction = direction
        self.thread = thread
        self.callId = callId
        self.originatorId = originatorId
    }
    
    class public func buildIncoming(thread: TSThread, callId: String, offererId: String, originatorId: String, peerId: String, sessionDescription: String) -> ConferenceCall {
        let cc = ConferenceCall(direction: .incoming, thread: thread, callId: callId, originatorId: originatorId)
        
        // kick off the incoming-peerconnection dance, if this is incoming
        _ = firstly {
            return ConferenceCallService.shared.iceServers
        }.then { iceServers -> Promise<HardenedRTCSessionDescription> in
            let pcc = PeerConnectionClient(delegate: cc, userId: offererId, iceServers: iceServers)
            pcc.peerId = peerId
            cc.peerConnectionClients[peerId] = pcc
            
            let offerSessionDescription = RTCSessionDescription(type: .offer, sdp: sessionDescription)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            
            return pcc.negotiateSessionDescription(remoteDescription: offerSessionDescription, constraints: constraints)
        }.then { hardenedSessionDesc in
            
        }
        return cc
    }
    
    // MARK: - Class Helpers
    private func updateCallRecordType() {
        AssertIsOnMainThread(file: #function)
        
        guard let callRecord = self.callRecord else { return }
        
        if state == .joined &&
            callRecord.callType == RPRecentCallTypeOutgoingIncomplete {
            callRecord.updateCallType(RPRecentCallTypeOutgoing)
        }
        if state == .joined &&
            callRecord.callType == RPRecentCallTypeIncomingIncomplete {
            callRecord.updateCallType(RPRecentCallTypeIncoming)
        }
    }
    
    func addObserver(observer: ConferenceCallObserver) {
        AssertIsOnMainThread(file: #function)
        observers.append(Weak(value: observer))
    }
    
    func removeObserver(_ observer: ConferenceCallObserver) {
        AssertIsOnMainThread(file: #function)
        while let index = observers.index(where: { $0.value === observer }) {
            observers.remove(at: index)
        }
    }

    // MARK: - PeerConnectionClientDelegate Implementation
    func peerConnectionClientIceConnected(_ peerconnectionClient: PeerConnectionClient) {
        <#code#>
    }
    
    func peerConnectionClientIceFailed(_ peerconnectionClient: PeerConnectionClient) {
        <#code#>
    }
    
    func peerConnectionClientIceDisconnected(_ peerconnectionClient: PeerConnectionClient) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, addedLocalIceCandidate iceCandidate: RTCIceCandidate) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, received dataChannelMessage: OWSWebRTCProtosData) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, didUpdateLocalVideoCaptureSession captureSession: AVCaptureSession?) {
        <#code#>
    }
    
    func peerConnectionClient(_ peerconnectionClient: PeerConnectionClient, didUpdateRemoteVideoTrack videoTrack: RTCVideoTrack?) {
        <#code#>
    }
    
}
