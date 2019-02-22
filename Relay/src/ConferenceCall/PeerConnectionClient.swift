//
//  PeerConnectionClient.swift
//  Relay
//
//  Copyright © 2019 Forsta, Inc. All rights reserved.
//  Copyright © 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import WebRTC
import RelayServiceKit
import RelayMessaging

public enum PeerConnectionClientState: String {
    case undefined
    case awaitingLocalJoin
    case sendingAcceptOffer
    case sentAcceptOffer
    case sendingOffer
    case awaitingAcceptOffer
    case receivedAcceptOffer
    case connected
    case peerLeft       // the peer sent us a callLeave
    case leftPeer       // we sent the peer a callLeave
    case discarded      // owning call is just throwing it away
    case disconnected   // ice disconnected
    case failed         // ice failed
}
extension PeerConnectionClientState {
    var isTerminal: Bool {
        switch self {
        case .peerLeft, .leftPeer, .discarded, .disconnected, .failed: return true
        default: return false
        }
    }
}

// HACK - Seeing crazy SEGFAULTs on iOS9 when accessing these objc externs.
// iOS10 seems unaffected. Reproducible for ~1 in 3 calls.
// Binding them to a file constant seems to work around the problem.
let kAudioTrackType = kRTCMediaStreamTrackKindAudio
let kVideoTrackType = kRTCMediaStreamTrackKindVideo

private let connectingTimeoutSeconds: TimeInterval = 60

/**
 * The PeerConnectionClient notifies it's delegate (the ConferenceCallService) of key events
 *
 * The delegate's methods will always be called on the main thread.
 */
protocol PeerConnectionClientDelegate: class {
    func stateDidChange(pcc: PeerConnectionClient, oldState: PeerConnectionClientState, newState: PeerConnectionClientState)
    func owningCall() -> ConferenceCall
    func updatedRemoteVideoTrack(strongPcc: PeerConnectionClient, remoteVideoTrack: RTCVideoTrack)
    func updatedLocalVideoCaptureSession(strongPcc: PeerConnectionClient, captureSession: AVCaptureSession?)
}

// In Swift (at least in Swift v3.3), weak variables aren't thread safe. It
// isn't safe to resolve/acquire/lock a weak reference into a strong reference
// while the instance might be being deallocated on another thread.
//
// PeerConnectionProxy provides thread-safe access to a strong reference.
// PeerConnectionClient has an PeerConnectionProxy to itself that its many async blocks
// (which run on more than one thread) can use to safely try to acquire a strong
// reference to the PeerConnectionClient. In ARC we'd normally, we'd avoid
// having an instance retain a strong reference to itself to avoid retain
// cycles, but it's safe in this case: PeerConnectionClient is owned (and only
// used by) a single entity CallService and CallService always calls
// [PeerConnectionClient terminate] when it is done with a PeerConnectionClient
// instance, so terminate is a reliable place where we can break the retain cycle.
//
// Note that we use the proxy in two ways:
//
// * As a delegate for the peer connection and the data channel,
//   safely forwarding delegate method invocations to the PCC.
// * To safely obtain references to the PCC within the PCC's
//   async blocks.
//
// This should be fixed in Swift 4, but it isn't.
//
// To test using the following scenarios:
//
// * Alice and Bob place simultaneous calls to each other. Both should get busy.
//   Repeat 10-20x.  Then verify that they can connect a call by having just one
//   call the other.
// * Alice or Bob (randomly alternating) calls the other. Recipient (randomly)
//   accepts call or hangs up.  If accepted, Alice or Bob (randomly) hangs up.
//   Repeat immediately, as fast as you can, 10-20x.
class PeerConnectionProxy: NSObject, RTCPeerConnectionDelegate {

    private var value: PeerConnectionClient?

    deinit {
        Logger.info("[PeerConnectionProxy] deinit")
    }

    func set(value: PeerConnectionClient) {
        objc_sync_enter(self)
        self.value = value
        objc_sync_exit(self)
    }

    func get() -> PeerConnectionClient? {
        objc_sync_enter(self)
        let result = value
        objc_sync_exit(self)

        if result == nil {
            // Every time this method returns nil is a
            // possible crash avoided.
            Logger.verbose("\(logTag) cleared get.")
        }

        return result
    }

    func clear() {
        Logger.info("\(logTag) \(#function)")

        objc_sync_enter(self)
        value = nil
        objc_sync_exit(self)
    }

    // MARK: - RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        self.get()?.peerConnection(peerConnection, didChange: stateChanged)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        self.get()?.peerConnection(peerConnection, didAdd: stream)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        self.get()?.peerConnection(peerConnection, didRemove: stream)
    }

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        self.get()?.peerConnectionShouldNegotiate(peerConnection)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        self.get()?.peerConnection(peerConnection, didChange: newState)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        self.get()?.peerConnection(peerConnection, didChange: newState)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        self.get()?.peerConnection(peerConnection, didGenerate: candidate)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        self.get()?.peerConnection(peerConnection, didRemove: candidates)
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        self.get()?.peerConnection(peerConnection, didOpen: dataChannel)
    }

}

/**
 * `PeerConnectionClient` is our interface to WebRTC.
 *
 * It is primarily a wrapper around `RTCPeerConnection`, which is responsible for sending and receiving our call data
 * including audio, video, and some post-connected signaling (hangup, add video)
 */
public class PeerConnectionClient: NSObject, RTCPeerConnectionDelegate {
    private var pendingIceCandidates = Set<RTCIceCandidate>()
    private var iceCandidatesDebounceTimer: Timer?
    
    let callId: String
    let userId: String
    let deviceId: UInt32
    var peerId: String
    
    var state: PeerConnectionClientState {
        didSet {
            delegate?.stateDidChange(pcc: self, oldState: oldValue, newState: self.state)
        }
    }

    private weak var delegate: PeerConnectionClientDelegate?

    private var peerConnection: RTCPeerConnection?
    
    var audioSender: RTCRtpSender?
    var videoSender: RTCRtpSender?
    // RTCVideoTrack is fragile and prone to throwing exceptions and/or
    // causing deadlock in its destructor.  Therefore we take great care
    // with this property.
    var remoteVideoTrack: RTCVideoTrack?

    private let proxy = PeerConnectionProxy()
    // Note that we're deliberately leaking proxy instances using this
    // collection to avoid EXC_BAD_ACCESS.  Calls are rare and the proxy
    // is tiny (a single property), so it's better to leak and be safe.
    private static var expiredProxies = [PeerConnectionProxy]()
    
    // promises and their resolvers for controlling ordering and timing of actions
    let readyToSendOfferPromise: Promise<Void>
    let readyToSendOfferResolver: Resolver<Void>
    let readyToSendIceCandidatesPromise: Promise<Void>
    let readyToSendIceCandidatesResolver: Resolver<Void>
    let peerConnectedPromise: Promise<Void>
    let peerConnectedResolver: Resolver<Void>


    init(delegate: PeerConnectionClientDelegate, userId: String, deviceId: UInt32, peerId: String, callId: String) {
        AssertIsOnMainThread(file: #function)
        ConferenceCallEvents.add(.PeerInit(callId: callId, peerId: peerId, userId: userId, deviceId: deviceId))

        self.delegate = delegate
        self.callId = callId
        self.userId = userId
        self.deviceId = deviceId
        self.peerId = peerId
        self.state = .undefined

        (self.readyToSendOfferPromise, self.readyToSendOfferResolver) = Promise<Void>.pending()
        (self.readyToSendIceCandidatesPromise, self.readyToSendIceCandidatesResolver) = Promise<Void>.pending()
        (self.peerConnectedPromise, self.peerConnectedResolver) = Promise<Void>.pending()

        super.init()

        self.proxy.set(value: self)
    }
    
    deinit {
        ConferenceCallEvents.add(.PeerDeinit(callId: self.callId, peerId: self.peerId, userId: self.userId, deviceId: self.deviceId))
    }
    
    
    public func handleOffer(sessionDescription: String) {
        guard let cc = self.delegate?.owningCall() else {
            Logger.error("handleOffer owning call isn't available")
            return
        }
        
        self.state = .sendingAcceptOffer
        firstly {
            cc.setUpLocalAV()
        }.then { _ -> Promise<HardenedRTCSessionDescription> in
            self.peerConnection = ConferenceCallService.rtcFactory.peerConnection(with: cc.configuration!,
                                                                                  constraints: cc.connectionConstraints!,
                                                                                  delegate: self.proxy)

            let videoSender = self.peerConnection!.sender(withKind: kVideoTrackType, streamId: CCIdentifiers.mediaStream.rawValue)
            videoSender.track = cc.localVideoTrack
            self.videoSender = videoSender
            
            let audioSender = self.peerConnection!.sender(withKind: kAudioTrackType, streamId: CCIdentifiers.mediaStream.rawValue)
            audioSender.track = cc.audioTrack
            self.audioSender = audioSender

            let offerSessionDescription = RTCSessionDescription(type: .offer, sdp: sessionDescription)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            
            return self.negotiateSessionDescription(remoteDescription: offerSessionDescription, constraints: constraints)
        }.then { hardenedSessionDesc -> Promise<Void> in
            self.sendCallAcceptOffer(negotiatedSessionDescription: hardenedSessionDesc)
        }.then { () -> Promise<Void> in
            self.state = .sentAcceptOffer
            self.readyToSendIceCandidatesResolver.fulfill(())
            
            let timeout: Promise<Void> = after(seconds: connectingTimeoutSeconds).done {
                // rejecting a promise by throwing is safely a no-op if the promise has already been fulfilled
                throw CallError.timeout(description: "timed out waiting for peer connect")
            }
            
            return race(self.peerConnectedPromise, timeout)
        }.done {
            self.state = .connected
        }.recover { error in
            if let callError = error as? CallError {
                self.handleFailedConnection(error: callError)
            } else {
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedConnection(error: externalError)
            }
        }.ensure {
            Logger.debug("\(self.logTag) ended background task awaiting inbound call connection")
        }.retainUntilComplete()
    }


    private func sendCallAcceptOffer(negotiatedSessionDescription: HardenedRTCSessionDescription) -> Promise<Void> {
        guard let call = self.delegate?.owningCall() else {
            return Promise(error: CallError.other(description: "can't get owning call"))
        }
        guard let messageSender = Environment.current()?.messageSender else {
            return Promise(error: CallError.other(description: "can't get messageSender"))
        }
        let members = call.thread.participantIds
        let originator = call.originatorId
        let answer = [ "type" : "answer",
                       "sdp" : negotiatedSessionDescription.sdp ]
        
        let allTheData = [ "answer" : answer,
                           "callId" : self.callId,
                           "members" : members,
                           "originator" : originator,
                           "peerId" : self.peerId,
                           ] as NSMutableDictionary
        
        let message = OutgoingControlMessage(thread: call.thread, controlType: FLControlMessageCallAcceptOfferKey, moreData: allTheData)
        return messageSender.sendPromise(message: message, recipientId: self.userId, recipientDeviceId: self.deviceId)
    }

    func queueOffer() {
        guard let cc = self.delegate?.owningCall() else {
            Logger.error("queueOffer owning call isn't available")
            return
        }
        
        if (cc.state == .joined) {
            self.readyToSendOfferResolver.fulfill(())
        } else {
            self.state = .awaitingLocalJoin
        }
        
        firstly {
            cc.setUpLocalAV()
        }.then {
            self.readyToSendOfferPromise
        }.then { (Void) -> Promise<HardenedRTCSessionDescription> in
            self.state = .sendingOffer
            self.peerConnection = ConferenceCallService.rtcFactory.peerConnection(with: cc.configuration!,
                                                                                  constraints: cc.connectionConstraints!,
                                                                                  delegate: self.proxy)
            
            let videoSender = self.peerConnection!.sender(withKind: kVideoTrackType, streamId: CCIdentifiers.mediaStream.rawValue)
            videoSender.track = cc.localVideoTrack
            self.videoSender = videoSender
            
            let audioSender = self.peerConnection!.sender(withKind: kAudioTrackType, streamId: CCIdentifiers.mediaStream.rawValue)
            audioSender.track = cc.audioTrack
            self.audioSender = audioSender

            return self.createSessionDescriptionOffer()
        }.then { (sessionDescription: HardenedRTCSessionDescription) -> Promise<Void> in
            return firstly {
                self.setLocalSessionDescription(sessionDescription)
            }.then { _ -> Promise<Void> in
                guard let call = self.delegate?.owningCall() else {
                    return Promise(error: CallError.other(description: "can't get owning call"))
                }
                guard let messageSender = Environment.current()?.messageSender else {
                    return Promise(error: CallError.other(description: "can't get messageSender"))
                }
                let allTheData = [ "callId" : self.callId,
                                   "members" : call.thread.participantIds,
                                   "originator" : call.originatorId,
                                   "peerId" : self.peerId,
                                   "offer" : [ "type" : "offer",
                                               "sdp" : sessionDescription.sdp ],
                                   ] as NSMutableDictionary
                
                let offerControlMessage = OutgoingControlMessage(thread: call.thread, controlType: FLControlMessageCallOfferKey, moreData: allTheData)
                return messageSender.sendPromise(message: offerControlMessage, recipientId: self.userId, recipientDeviceId: self.deviceId)
            }
        }.then { () -> Promise<Void> in
            self.state = .awaitingAcceptOffer
            self.readyToSendIceCandidatesResolver.fulfill(())
            
            // Don't let the outgoing call ring forever. We don't support inbound ringing forever anyway.
            let timeout: Promise<Void> = after(seconds: connectingTimeoutSeconds).done {
                // This code will always be called, whether or not the call has timed out.
                // However, if the call has already connected, the `race` promise will have already been
                // fulfilled. Rejecting an already fulfilled promise is a no-op.
                throw CallError.timeout(description: "timed out waiting to receive call answer")
            }
            
            return race(timeout, self.peerConnectedPromise)
        }.done {
            self.state = .connected
        }.recover { error in
            Logger.error("\(self.logTag) call offer for peer \(self.peerId) failed with error: \(error)")
            if let callError = error as? CallError {
                self.handleFailedConnection(error: callError)
            } else {
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedConnection(error: externalError)
            }
        }.retainUntilComplete()
    }
    
    func handleAcceptOffer(sessionDescription: String) {
        self.state = .receivedAcceptOffer
        let sessionDescription = RTCSessionDescription(type: .answer, sdp: sessionDescription)
        firstly {
            self.setRemoteSessionDescription(sessionDescription)
        }.done {
            // Logger.debug("\(self.logTag) successfully set remote description")
        }.catch { error in
            Logger.error("\(self.logTag) setting remote session description for peer \(self.peerId) failed with error: \(error)")
            if let callError = error as? CallError {
                self.handleFailedConnection(error: callError)
            } else {
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedConnection(error: externalError)
            }
        }.retainUntilComplete()
    }

    private func handleFailedConnection(error: CallError) {
        Logger.error("\(self.logTag) connection failed with error: \(error)")
        self.state = .failed
    }

    // MARK: - Session negotiation

    private var defaultOfferConstraints: RTCMediaConstraints {
        let mandatoryConstraints = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": "true"
        ]
        return RTCMediaConstraints(mandatoryConstraints: mandatoryConstraints, optionalConstraints: nil)
    }

    public func createSessionDescriptionOffer() -> Promise<HardenedRTCSessionDescription> {
        AssertIsOnMainThread(file: #function)
        let proxyCopy = self.proxy
        let (promise, resolver) = Promise<HardenedRTCSessionDescription>.pending()
        let completion: ((RTCSessionDescription?, Error?) -> Void) = { (sdp, error) in
            guard let strongSelf = proxyCopy.get() else {
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            strongSelf.assertOnSignalingQueue()
            guard strongSelf.peerConnection != nil else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            if let error = error {
                resolver.reject(error)
                return
            }

            guard let sessionDescription = sdp else {
                Logger.error("\(strongSelf.logTag) No session description was obtained, even though there was no error reported.")
                let error = OWSErrorMakeUnableToProcessServerResponseError()
                resolver.reject(error)
                return
            }

            resolver.fulfill(HardenedRTCSessionDescription(rtcSessionDescription: sessionDescription))
        }

        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else {
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            strongSelf.assertOnSignalingQueue()
            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }

            peerConnection.offer(for: strongSelf.defaultOfferConstraints, completionHandler: { (sdp: RTCSessionDescription?, error: Error?) in
                ConferenceCallService.shared.rtcQueue.async {
                    completion(sdp, error)
                }
            })
        }

        return promise
    }

    public func setLocalSessionDescriptionInternal(_ sessionDescription: HardenedRTCSessionDescription) -> Promise<Void> {
        let proxyCopy = self.proxy
        let (promise, resolver) = Promise<Void>.pending()
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else {
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            strongSelf.assertOnSignalingQueue()

            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }

            Logger.verbose("\(strongSelf.logTag) setting local session description: \(sessionDescription)")
            peerConnection.setLocalDescription(sessionDescription.rtcSessionDescription, completionHandler: { (error) in
                if let error = error {
                    resolver.reject(error)
                } else {
                    resolver.fulfill(())
                }
            })
        }
        return promise
    }

    public func setLocalSessionDescription(_ sessionDescription: HardenedRTCSessionDescription) -> Promise<Void> {
        AssertIsOnMainThread(file: #function)
        let proxyCopy = self.proxy
        let (promise, resolver) = Promise<Void>.pending()
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else {
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            strongSelf.assertOnSignalingQueue()
            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }

            Logger.verbose("\(strongSelf.logTag) setting local session description: \(sessionDescription)")
            peerConnection.setLocalDescription(sessionDescription.rtcSessionDescription,
                                               completionHandler: { error in
                                                if let error = error {
                                                    resolver.reject(error)
                                                    return
                                                }
                                                resolver.fulfill(())
            })
        }

        return promise
    }

    public func negotiateSessionDescription(remoteDescription: RTCSessionDescription, constraints: RTCMediaConstraints) -> Promise<HardenedRTCSessionDescription> {
        AssertIsOnMainThread(file: #function)
        let proxyCopy = self.proxy
        return setRemoteSessionDescription(remoteDescription)
            .then(on: ConferenceCallService.shared.rtcQueue) { _ -> Promise<HardenedRTCSessionDescription> in
                guard let strongSelf = proxyCopy.get() else {
                    return Promise(error: NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                }
                return strongSelf.negotiateAnswerSessionDescription(constraints: constraints)
        }
    }

    public func setRemoteSessionDescription(_ sessionDescription: RTCSessionDescription) -> Promise<Void> {
        AssertIsOnMainThread(file: #function)
        let proxyCopy = self.proxy
        let (promise, resolver) = Promise<Void>.pending()
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else {
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            strongSelf.assertOnSignalingQueue()
            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            Logger.verbose("\(strongSelf.logTag) setting remote description: \(sessionDescription)")
            peerConnection.setRemoteDescription(sessionDescription,
                                                completionHandler: { error in
                                                    if let error = error {
                                                        resolver.reject(error)
                                                        return
                                                    }
                                                    resolver.fulfill(())
            })
        }
        return promise
    }

    private func negotiateAnswerSessionDescription(constraints: RTCMediaConstraints) -> Promise<HardenedRTCSessionDescription> {
        assertOnSignalingQueue()
        let proxyCopy = self.proxy
        let (promise, resolver) = Promise<HardenedRTCSessionDescription>.pending()
        let completion: ((RTCSessionDescription?, Error?) -> Void) = { (sdp, error) in
            guard let strongSelf = proxyCopy.get() else {
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            strongSelf.assertOnSignalingQueue()
            guard strongSelf.peerConnection != nil else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            if let error = error {
                resolver.reject(error)
                return
            }

            guard let sessionDescription = sdp else {
                Logger.error("\(strongSelf.logTag) unexpected empty session description, even though no error was reported.")
                let error = OWSErrorMakeUnableToProcessServerResponseError()
                resolver.reject(error)
                return
            }

            let hardenedSessionDescription = HardenedRTCSessionDescription(rtcSessionDescription: sessionDescription)

            strongSelf.setLocalSessionDescriptionInternal(hardenedSessionDescription)
                .done(on: ConferenceCallService.shared.rtcQueue) {
                    resolver.fulfill(hardenedSessionDescription)
                }.catch { error in
                    resolver.reject(error)
            }
        }

        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else {
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }
            strongSelf.assertOnSignalingQueue()

            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                resolver.reject(NSError(domain: "Obsolete client", code: 0, userInfo: nil))
                return
            }

            Logger.debug("\(strongSelf.logTag) negotiating answer session.")

            peerConnection.answer(for: constraints, completionHandler: { (sdp: RTCSessionDescription?, error: Error?) in
                ConferenceCallService.shared.rtcQueue.async {
                    completion(sdp, error)
                }
            })
        }
        return promise
    }
    
    public func addRemoteIceCandidates(_ iceCandidates: [Any]) {
        ConferenceCallEvents.add(.ReceivedRemoteIce(callId: self.callId, peerId: self.peerId, userId: self.userId, deviceId: self.deviceId, count: iceCandidates.count))
        for candidate in iceCandidates {
            if let candidateDictiontary: Dictionary<String, Any> = candidate as? Dictionary<String, Any> {
                if let sdpMLineIndex: Int32 = candidateDictiontary["sdpMLineIndex"] as? Int32,
                    let sdpMid: String = candidateDictiontary["sdpMid"] as? String,
                    let sdp: String = candidateDictiontary["candidate"] as? String {
                    self.addRemoteIceCandidate(RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid))
                } else {
                    Logger.debug("dropping bad ice candidate for peer \(peerId)")
                }
            }
        }
    }

    private func addRemoteIceCandidate(_ candidate: RTCIceCandidate) {
        let proxyCopy = self.proxy
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }
            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            Logger.info("\(strongSelf.logTag) adding remote ICE candidate: \(candidate.sdp)")
            peerConnection.add(candidate)
        }
    }

    public func cleanupBeforeDestruction() {
        AssertIsOnMainThread(file: #function)
        Logger.debug("\(logTag) in \(#function)")

        // Clear the delegate immediately so that we can guarantee that
        // no delegate methods are called after terminate() returns.
        delegate = nil

        // Clear the proxy immediately so that enqueued work is aborted
        // going forward.
        PeerConnectionClient.expiredProxies.append(proxy)
        proxy.clear()

        // Don't use [weak self]; we always want to perform terminateInternal().
        ConferenceCallService.shared.rtcQueue.async {
            self.cleanupBeforeDestructionInternal()
        }
    }

    private func cleanupBeforeDestructionInternal() {
        assertOnSignalingQueue()
        Logger.debug("\(logTag) in \(#function)")

        //        Some notes on preventing crashes while disposing of peerConnection for video calls
        //        from: https://groups.google.com/forum/#!searchin/discuss-webrtc/objc$20crash$20dealloc%7Csort:relevance/discuss-webrtc/7D-vk5yLjn8/rBW2D6EW4GYJ
        //        The sequence to make it work appears to be
        //
        //        [capturer stop]; // I had to add this as a method to RTCVideoCapturer
        //        [localRenderer stop];
        //        [remoteRenderer stop];
        //        [peerConnection close];

        // audioTrack is a strong property because we need access to it to mute/unmute, but I was seeing it
        // become nil when it was only a weak property. So we retain it and manually nil the reference here, because
        // we are likely to crash if we retain any peer connection properties when the peerconnection is released

        // localVideoTrack?.isEnabled = false
        remoteVideoTrack?.isEnabled = false

        audioSender = nil
        // audioTrack = nil
        videoSender = nil
        // localVideoTrack = nil
        remoteVideoTrack = nil
        // videoCaptureController = nil

        if let peerConnection = peerConnection {
            peerConnection.delegate = nil
            peerConnection.close()
        }
        peerConnection = nil
    }

    // MARK: - RTCPeerConnectionDelegate

    /** Called when the SignalingState changed. */
    public func peerConnection(_ peerConnectionParam: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Logger.debug("\(logTag) didChange signalingState:\(stateChanged.debugDescription)")
    }

    /** Called when media is received on a new stream from remote peer. */
    public func peerConnection(_ peerConnectionParam: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let proxyCopy = self.proxy
        let completion: (RTCVideoTrack) -> Void = { (remoteVideoTrack) in
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            guard let strongDelegate = strongSelf.delegate else { return }

            // TODO: Consider checking for termination here.

            strongDelegate.updatedRemoteVideoTrack(strongPcc: strongSelf, remoteVideoTrack: remoteVideoTrack)
        }

        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }
            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            guard peerConnection == peerConnectionParam else {
                owsFailDebug("\(strongSelf.logTag) in \(#function) mismatched peerConnection callback.")
                return
            }
            
            Logger.info("GEP: didAdd stream:\(stream)")
            Logger.info("GEP: didAdd video tracks: \(stream.videoTracks.count)")
            Logger.info("GEP: didAdd audio tracks: \(stream.audioTracks.count)")
            
            if stream.videoTracks.count > 0 {
                let remoteVideoTrack = stream.videoTracks[0]
                strongSelf.remoteVideoTrack = remoteVideoTrack

                DispatchQueue.main.async {
                    completion(remoteVideoTrack)
                }
            } else {
                Logger.debug("\(strongSelf.logTag) didAdd stream:\(stream) didn't have any video tracks")
            }
        }
    }

    /** Called when a remote peer closes a stream. */
    public func peerConnection(_ peerConnectionParam: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Logger.debug("\(logTag) didRemove Stream:\(stream)")
    }

    /** Called when negotiation is needed, for example ICE has restarted. */
    public func peerConnectionShouldNegotiate(_ peerConnectionParam: RTCPeerConnection) {
        Logger.debug("\(logTag) shouldNegotiate")
    }

    /** Called any time the IceConnectionState changes. */
    public func peerConnection(_ peerConnectionParam: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let proxyCopy = self.proxy
        let connectedCompletion : () -> Void = {
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            strongSelf.peerConnectedResolver.fulfill(())
        }
        let failedCompletion : () -> Void = {
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            Logger.error("\(strongSelf.logTag) ice connection failed")
            strongSelf.state = .failed
        }
        let disconnectedCompletion : () -> Void = {
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            Logger.error("\(strongSelf.logTag) ice connection disconnected")
            strongSelf.state = .disconnected
        }
        
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }
            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            guard peerConnection == peerConnectionParam else {
                owsFailDebug("\(strongSelf.logTag) in \(#function) mismatched peerConnection callback.")
                return
            }

            Logger.info("\(strongSelf.logTag) didChange IceConnectionState:\(newState.debugDescription)")
            switch newState {
            case .connected, .completed:
                DispatchQueue.main.async(execute: connectedCompletion)
            case .failed:
                Logger.warn("\(strongSelf.logTag) RTCIceConnection failed.")
                DispatchQueue.main.async(execute: failedCompletion)
            case .disconnected:
                Logger.warn("\(strongSelf.logTag) RTCIceConnection disconnected.")
                DispatchQueue.main.async(execute: disconnectedCompletion)
            default:
                Logger.debug("\(strongSelf.logTag) ignoring change IceConnectionState:\(newState.debugDescription)")
            }
        }
    }

    /** Called any time the IceGatheringState changes. */
    public func peerConnection(_ peerConnectionParam: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Logger.info("\(logTag) didChange IceGatheringState:\(newState.debugDescription)")
    }

    /** New ice candidate has been found. */
    public func peerConnection(_ peerConnectionParam: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        ConferenceCallEvents.add(.GeneratedLocalIce(callId: self.callId, peerId: self.peerId, userId: self.userId, deviceId: self.deviceId))
        let proxyCopy = self.proxy
        let completion: (RTCIceCandidate) -> Void = { (candidate) in
            self.pendingIceCandidates.insert(candidate)
            
            if self.pendingIceCandidates.count > 24 {
                if self.iceCandidatesDebounceTimer != nil {
                    self.iceCandidatesDebounceTimer?.invalidate()
                    self.iceCandidatesDebounceTimer = nil
                }
                self.sendLocalIceCandidates()
            } else if self.pendingIceCandidates.count > 0 {
                if self.iceCandidatesDebounceTimer !=  nil {
                    self.iceCandidatesDebounceTimer?.invalidate()
                    self.iceCandidatesDebounceTimer = nil
                }
                self.iceCandidatesDebounceTimer = Timer.scheduledTimer(timeInterval: 0.1,
                                                                       target: self,
                                                                       selector: #selector(self.sendLocalIceCandidates),
                                                                       userInfo: nil,
                                                                       repeats: false)
            } else {
                if self.iceCandidatesDebounceTimer !=  nil {
                    self.iceCandidatesDebounceTimer?.invalidate()
                }
                self.iceCandidatesDebounceTimer = nil
            }
        }

        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }
            guard let peerConnection = strongSelf.peerConnection else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            guard peerConnection == peerConnectionParam else {
                owsFailDebug("\(strongSelf.logTag) in \(#function) mismatched peerConnection callback.")
                return
            }
            Logger.info("\(strongSelf.logTag) adding local ICE candidate:\(candidate.sdp)")
            DispatchMainThreadSafe {
                completion(candidate)
            }
        }
    }

    /** Called when a group of local Ice candidates have been removed. */
    public func peerConnection(_ peerConnectionParam: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Logger.debug("\(logTag) didRemove IceCandidates:\(candidates.debugDescription)")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Logger.debug("\(logTag) didRemove IceCandidates:\(dataChannel.debugDescription)")
    }

    // MARK: Helpers

    /**
     * We synchronize access to state in this class using this queue.
     */
    private func assertOnSignalingQueue() {
        // assertOnQueue(type(of: self).signalingQueue)
        assertOnQueue(ConferenceCallService.shared.rtcQueue)
    }

    // MARK: Test-only accessors

    internal func peerConnectionForTests() -> RTCPeerConnection {
        AssertIsOnMainThread(file: #function)

        var result: RTCPeerConnection? = nil
        ConferenceCallService.shared.rtcQueue.sync {
            result = peerConnection
            Logger.info("\(self.logTag) called \(#function)")
        }
        return result!
    }

    internal func flushSignalingQueueForTests() {
        AssertIsOnMainThread(file: #function)

        ConferenceCallService.shared.rtcQueue.sync {
            // Noop.
        }
    }
    

    @objc private func sendLocalIceCandidates() {
        AssertIsOnMainThread(file: #function)

        let iceToSendSet = Set<RTCIceCandidate>(self.pendingIceCandidates)
        self.pendingIceCandidates.removeAll()
        
        // Wait until we've sent the CallOffer before sending any ice updates for the call to ensure
        // intuitive message ordering for other clients.
        self.readyToSendIceCandidatesPromise.then { _ -> Promise<Void> in
            guard let call = self.delegate?.owningCall() else {
                return Promise(error: CallError.other(description: "can't get owning call"))
            }
            guard let messageSender = Environment.current()?.messageSender else {
                return Promise(error: CallError.other(description: "can't get messageSender"))
            }
            
            var payloadCandidates = [NSDictionary]()
            for candidate in iceToSendSet {
                let sdp = candidate.sdp
                let sdpMLineIndex = candidate.sdpMLineIndex
                let sdpMid = candidate.sdpMid

                let iceCandidate = [ "candidate" : sdp,
                                     "sdpMLineIndex" : sdpMLineIndex,
                                     "sdpMid" : sdpMid!,
                                     ] as NSDictionary
                
                payloadCandidates.append(iceCandidate)
            }
            
            guard payloadCandidates.count > 0 else {
                return Promise(error: CallError.other(description: "can't send zero ice candidates"))
            }
            
            let allTheData = [ "callId": self.callId ,
                               "peerId": self.peerId,
                               "originator" : call.originatorId,
                               "icecandidates" : payloadCandidates
                ] as NSMutableDictionary
            
            let iceControlMessage = OutgoingControlMessage(thread: call.thread, controlType: FLControlMessageCallICECandidatesKey, moreData: allTheData)
            return messageSender.sendPromise(message: iceControlMessage, recipientId: self.userId, recipientDeviceId: self.deviceId)
        }.done {_ in
            ConferenceCallEvents.add(.SentLocalIce(callId: self.callId, peerId: self.peerId, userId: self.userId, deviceId: self.deviceId, count: iceToSendSet.count))
        }.catch { error in
            Logger.error("\(self.logTag) in \(#function) waitUntilReadyToSendIceUpdates failed with error: \(error)")
        }.retainUntilComplete()
    }

}

/**
 * Restrict an RTCSessionDescription to more secure parameters
 */
public class HardenedRTCSessionDescription {
    let rtcSessionDescription: RTCSessionDescription
    var sdp: String { return rtcSessionDescription.sdp }

    init(rtcSessionDescription: RTCSessionDescription) {
        self.rtcSessionDescription = HardenedRTCSessionDescription.harden(rtcSessionDescription: rtcSessionDescription)
    }

    /**
     * Set some more secure parameters for the session description
     */
    class func harden(rtcSessionDescription: RTCSessionDescription) -> RTCSessionDescription {
        var description = rtcSessionDescription.sdp

        // Enforce Constant bit rate.
        let cbrRegex = try! NSRegularExpression(pattern: "(a=fmtp:111 ((?!cbr=).)*)\r?\n", options: .caseInsensitive)
        description = cbrRegex.stringByReplacingMatches(in: description, options: [], range: NSRange(location: 0, length: description.count), withTemplate: "$1;cbr=1\r\n")

        // Strip plaintext audio-level details
        // https://tools.ietf.org/html/rfc6464
        let audioLevelRegex = try! NSRegularExpression(pattern: ".+urn:ietf:params:rtp-hdrext:ssrc-audio-level.*\r?\n", options: .caseInsensitive)
        description = audioLevelRegex.stringByReplacingMatches(in: description, options: [], range: NSRange(location: 0, length: description.count), withTemplate: "")

        return RTCSessionDescription.init(type: rtcSessionDescription.type, sdp: description)
    }
}

// Mark: Pretty Print Objc enums.

fileprivate extension RTCSignalingState {
    var debugDescription: String {
        switch self {
        case .stable:
            return "stable"
        case .haveLocalOffer:
            return "haveLocalOffer"
        case .haveLocalPrAnswer:
            return "haveLocalPrAnswer"
        case .haveRemoteOffer:
            return "haveRemoteOffer"
        case .haveRemotePrAnswer:
            return "haveRemotePrAnswer"
        case .closed:
            return "closed"
        }
    }
}

fileprivate extension RTCIceGatheringState {
    var debugDescription: String {
        switch self {
        case .new:
            return "new"
        case .gathering:
            return "gathering"
        case .complete:
            return "complete"
        }
    }
}

fileprivate extension RTCIceConnectionState {
    var debugDescription: String {
        switch self {
        case .new:
            return "new"
        case .checking:
            return "checking"
        case .connected:
            return "connected"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .disconnected:
            return "disconnected"
        case .closed:
            return "closed"
        case .count:
            return "count"
        }
    }
}
