//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import WebRTC
import RelayServiceKit
import RelayMessaging


public enum PeerConnectionState: String {
    case idle
    case dialing
    case answering
    case remoteRinging
    case localRinging
    case connected
    case reconnecting
    case localFailure // terminal
    case localHangup // terminal
    case remoteHangup // terminal
    case remoteBusy // terminal
}

// HACK - Seeing crazy SEGFAULTs on iOS9 when accessing these objc externs.
// iOS10 seems unaffected. Reproducible for ~1 in 3 calls.
// Binding them to a file constant seems to work around the problem.
let kAudioTrackType = kRTCMediaStreamTrackKindAudio
let kVideoTrackType = kRTCMediaStreamTrackKindVideo
let kMediaConstraintsMinWidth = kRTCMediaConstraintsMinWidth
let kMediaConstraintsMaxWidth = kRTCMediaConstraintsMaxWidth
let kMediaConstraintsMinHeight = kRTCMediaConstraintsMinHeight
let kMediaConstraintsMaxHeight = kRTCMediaConstraintsMaxHeight

/**
 * The PeerConnectionClient notifies it's delegate (the ConferenceCallService) of key events
 *
 * The delegate's methods will always be called on the main thread.
 */
protocol PeerConnectionClientDelegate: class {
    func peerConnectionFailed(pcc: PeerConnectionClient)
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
class PeerConnectionProxy: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {

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

    // MARK: - RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        self.get()?.dataChannelDidChangeState(dataChannel)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        self.get()?.dataChannel(dataChannel, didReceiveMessageWith: buffer)
    }

    public func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        self.get()?.dataChannel(dataChannel, didChangeBufferedAmount: amount)
    }
}

/**
 * `PeerConnectionClient` is our interface to WebRTC.
 *
 * It is primarily a wrapper around `RTCPeerConnection`, which is responsible for sending and receiving our call data
 * including audio, video, and some post-connected signaling (hangup, add video)
 */
class PeerConnectionClient: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, VideoCaptureSettingsDelegate {
    private static let factory = RTCPeerConnectionFactory()
    private var pendingIceCandidates = Set<RTCIceCandidate>()
    private var iceCandidatesDebounceTimer: Timer?
    
    let userId: String
    var peerId: String

    enum Identifiers: String {
        case mediaStream = "ARDAMS",
             videoTrack = "ARDAMSv0",
             audioTrack = "ARDAMSa0",
             dataChannelSignaling = "signaling"
    }

    // Delegate is notified of key events in the call lifecycle.
    //
    // This property should only be accessed on the main thread.
    private weak var delegate: PeerConnectionClientDelegate?

    // Connection

    private var peerConnection: RTCPeerConnection?
    private let connectionConstraints: RTCMediaConstraints?
    private let configuration: RTCConfiguration?

    // DataChannel

    private var dataChannel: RTCDataChannel?

    // Audio

    private var audioSender: RTCRtpSender?
    private var audioTrack: RTCAudioTrack?
    private var audioConstraints: RTCMediaConstraints

    // Video

    private var videoCaptureController: VideoCaptureController?
    private var videoSender: RTCRtpSender?

    // RTCVideoTrack is fragile and prone to throwing exceptions and/or
    // causing deadlock in its destructor.  Therefore we take great care
    // with this property.
    private var localVideoTrack: RTCVideoTrack?
    private var remoteVideoTrack: RTCVideoTrack?
    private var cameraConstraints: RTCMediaConstraints

    private let proxy = PeerConnectionProxy()
    // Note that we're deliberately leaking proxy instances using this
    // collection to avoid EXC_BAD_ACCESS.  Calls are rare and the proxy
    // is tiny (a single property), so it's better to leak and be safe.
    private static var expiredProxies = [PeerConnectionProxy]()
    
    // promises and their resolvers for controlling ordering of async actions
    let readyToSendIceCandidatesResolver: Resolver<Void>
    let readyToSendIceCandidatesPromise: Promise<Void>
    let peerConnectedPromise: Promise<Void>
    let peerConnectedResolver: Promise<Void>


    init(delegate: PeerConnectionClientDelegate, userId: String, peerId: String) {
        AssertIsOnMainThread(file: #function)

        self.delegate = delegate
        self.userId = userId
        self.peerId = peerId
        
        super.init()
        
        (self.readyToSendIceCandidatesPromise, self.readyToSendIceCandidatesResolver) = Promise<Void>.pending()
        self.proxy.set(value: self)
    }
    
    public func handleOffer(sessionDescription: String) {
        firstly {
            ConferenceCallService.shared.iceServers
        }.then { (iceServers: [RTCIceServer]) -> Promise<HardenedRTCSessionDescription> in
            configuration = RTCConfiguration()
            configuration.iceServers = iceServers
            configuration.bundlePolicy = .maxBundle
            configuration.rtcpMuxPolicy = .require
            
            let connectionConstraintsDict = ["DtlsSrtpKeyAgreement": "true"]
            connectionConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: connectionConstraintsDict)
            
            audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            cameraConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            
            peerConnection = PeerConnectionClient.factory.peerConnection(with: configuration,
                                                                         constraints: connectionConstraints,
                                                                         delegate: proxy)
            createAudioSender()
            createVideoSender()
            
            let offerSessionDescription = RTCSessionDescription(type: .offer, sdp: sessionDescription)
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            
            return pcc.negotiateSessionDescription(remoteDescription: offerSessionDescription, constraints: constraints)
        }.then { hardenedSessionDesc in
            return self.sendCallAcceptOffer(peerId: peerId, negotiatedSessionDescription: hardenedSessionDesc)
        }.then { () -> Promise<Void> in
            guard self.call == newCall else {
                throw CallError.obsoleteCall(description: "sendPromise(message: ) response for obsolete call")
            }
            Logger.debug("\(self.logTag) successfully sent callAnswerMessage for: \(newCall.identifiersForLogs)")
            
            // There's nothing technically forbidding receiving ICE updates before receiving the CallAnswer, but this
            // a more intuitive ordering.
            self.readyToSendIceUpdatesResolver.fulfill(())
            
            let timeout: Promise<Void> = after(seconds: connectingTimeoutSeconds).done {
                // rejecting a promise by throwing is safely a no-op if the promise has already been fulfilled
                throw CallError.timeout(description: "timed out waiting for peer connect")
            }
            
            // This will be fulfilled (potentially) by the RTCDataChannel delegate method
            return race(self.peerConnectedPromise, timeout)
        }.done {
            Logger.debug("peer \(peerId) connected")
        }.recover { error in
            if let callError = error as? CallError {
                self.handleFailedCall(failedCall: newCall, error: callError)
            } else {
                let externalError = CallError.externalError(underlyingError: error)
                self.handleFailedCall(failedCall: newCall, error: externalError)
            }
        }.ensure {
            Logger.debug("\(self.logTag) ending background task awaiting inbound call connection")
        
            assert(backgroundTask != nil)
            backgroundTask = nil
        }.retainUntilComplete()
    }


    private func sendCallAcceptOffer(peerId: String, negotiatedSessionDescription: HardenedRTCSessionDescription) {
        let callId = self.callId
        let members = thread.participantIds
        let originator = self.originatorId
        let answer = [ "type" : "answer",
                       "sdp" : negotiatedSessionDescription.sdp ]
        
        let allTheData = [ "answer" : answer,
                           "callId" : callId,
                           "members" : members,
                           "originator" : originator,
                           "peerId" : peerId,
                           ] as NSMutableDictionary
        
        let message = OutgoingControlMessage(thread: thread, controlType: FLControlMessageCallAcceptOfferKey, moreData: allTheData)
        return self.messageSender.sendPromise(message: message)
    }
    
    func sendOffer() {
        // TODO: do the offer dance
    }

    deinit {
        // TODO: We can demote this log level to debug once we're confident that
        // this class is always deallocated.
        Logger.info("[PeerConnectionClient] deinit")
    }

    // MARK: - Video

    fileprivate func createVideoSender() {
        AssertIsOnMainThread(file: #function)
        Logger.debug("\(logTag) in \(#function)")
        assert(self.videoSender == nil, "\(#function) should only be called once.")

        guard !Platform.isSimulator else {
            Logger.warn("\(logTag) Refusing to create local video track on simulator which has no capture device.")
            return
        }
        guard let peerConnection = peerConnection else {
            Logger.debug("\(logTag) \(#function) Ignoring obsolete event in terminated client")
            return
        }

        let videoSource = PeerConnectionClient.factory.videoSource()

        let localVideoTrack = PeerConnectionClient.factory.videoTrack(with: videoSource, trackId: Identifiers.videoTrack.rawValue)
        self.localVideoTrack = localVideoTrack
        // Disable by default until call is connected.
        // FIXME - do we require mic permissions at this point?
        // if so maybe it would be better to not even add the track until the call is connected
        // instead of creating it and disabling it.
        localVideoTrack.isEnabled = false

        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        self.videoCaptureController = VideoCaptureController(capturer: capturer, settingsDelegate: self)

        let videoSender = peerConnection.sender(withKind: kVideoTrackType, streamId: Identifiers.mediaStream.rawValue)
        videoSender.track = localVideoTrack
        self.videoSender = videoSender
    }

    public func setCameraSource(isUsingFrontCamera: Bool) {
        AssertIsOnMainThread(file: #function)

        let proxyCopy = self.proxy
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }

            guard let captureController = strongSelf.videoCaptureController else {
                owsFailDebug("\(self.logTag) in \(#function) captureController was unexpectedly nil")
                return
            }

            captureController.switchCamera(isUsingFrontCamera: isUsingFrontCamera)
        }
    }

    public func setLocalVideoEnabled(enabled: Bool) {
        AssertIsOnMainThread(file: #function)
        let proxyCopy = self.proxy
        let completion = {
            guard let strongSelf = proxyCopy.get() else { return }
            guard let strongDelegate = strongSelf.delegate else { return }

            let captureSession: AVCaptureSession? = {
                guard enabled else {
                    return nil
                }

                guard let captureController = strongSelf.videoCaptureController else {
                    owsFailDebug("\(self.logTag) in \(#function) videoCaptureController was unexpectedly nil")
                    return nil
                }

                return captureController.captureSession
            }()

            strongDelegate.peerConnectionClient(strongSelf, didUpdateLocalVideoCaptureSession: captureSession)
        }

        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }
            guard strongSelf.peerConnection != nil else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }

            guard let videoCaptureController = strongSelf.videoCaptureController else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }

            guard let localVideoTrack = strongSelf.localVideoTrack else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            localVideoTrack.isEnabled = enabled

            if enabled {
                Logger.debug("\(strongSelf.logTag) in \(#function) starting video capture")
                videoCaptureController.startCapture()
            } else {
                Logger.debug("\(strongSelf.logTag) in \(#function) stopping video capture")
                videoCaptureController.stopCapture()
            }

            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: VideoCaptureSettingsDelegate

    var videoWidth: Int32 {
        return 400
    }

    var videoHeight: Int32 {
        return 400
    }

    // MARK: - Audio

    fileprivate func createAudioSender() {
        AssertIsOnMainThread(file: #function)
        Logger.debug("\(logTag) in \(#function)")
        assert(self.audioSender == nil, "\(#function) should only be called once.")

        guard let peerConnection = peerConnection else {
            Logger.debug("\(logTag) \(#function) Ignoring obsolete event in terminated client")
            return
        }

        let audioSource = PeerConnectionClient.factory.audioSource(with: self.audioConstraints)

        let audioTrack = PeerConnectionClient.factory.audioTrack(with: audioSource, trackId: Identifiers.audioTrack.rawValue)
        self.audioTrack = audioTrack

        // Disable by default until call is connected.
        // FIXME - do we require mic permissions at this point?
        // if so maybe it would be better to not even add the track until the call is connected
        // instead of creating it and disabling it.
        audioTrack.isEnabled = false

        let audioSender = peerConnection.sender(withKind: kAudioTrackType, streamId: Identifiers.mediaStream.rawValue)
        audioSender.track = audioTrack
        self.audioSender = audioSender
    }

    public func setAudioEnabled(enabled: Bool) {
        AssertIsOnMainThread(file: #function)
        let proxyCopy = self.proxy
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }
            guard strongSelf.peerConnection != nil else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            guard let audioTrack = strongSelf.audioTrack else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }

            audioTrack.isEnabled = enabled
        }
    }

    // MARK: - Session negotiation

    private var defaultOfferConstraints: RTCMediaConstraints {
        let mandatoryConstraints = [
            "OfferToReceiveAudio": "true",
            "OfferToReceiveVideo": "true"
        ]
        return RTCMediaConstraints(mandatoryConstraints: mandatoryConstraints, optionalConstraints: nil)
    }

    public func createOffer() -> Promise<HardenedRTCSessionDescription> {
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

    public func addRemoteIceCandidate(_ candidate: RTCIceCandidate) {
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

    public func terminate() {
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
            self.terminateInternal()
        }
    }

    private func terminateInternal() {
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

        localVideoTrack?.isEnabled = false
        remoteVideoTrack?.isEnabled = false

        if let dataChannel = self.dataChannel {
            dataChannel.delegate = nil
        }

        dataChannel = nil
        audioSender = nil
        audioTrack = nil
        videoSender = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        videoCaptureController = nil

        if let peerConnection = peerConnection {
            peerConnection.delegate = nil
            peerConnection.close()
        }
        peerConnection = nil
    }

    // MARK: - Data Channel

    // should only be accessed on ConferenceCallService.rtcQueue
    var pendingDataChannelMessages: [PendingDataChannelMessage] = []
    struct PendingDataChannelMessage {
        let data: Data
        let description: String
        let isCritical: Bool
    }

    public func sendDataChannelMessage(data: Data, description: String, isCritical: Bool) {
        Logger.debug("Ignoring obsolete data channel send: \(description)")
        return;
        /*
        AssertIsOnMainThread(file: #function)
        let proxyCopy = self.proxy
        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }

            guard strongSelf.peerConnection != nil else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client: \(description)")
                return
            }

            guard let dataChannel = strongSelf.dataChannel else {
                if isCritical {
                    Logger.info("\(strongSelf.logTag) in \(#function) enqueuing critical data channel message for after we have a dataChannel: \(description)")
                    strongSelf.pendingDataChannelMessages.append(PendingDataChannelMessage(data: data, description: description, isCritical: isCritical))
                } else {
                    Logger.error("\(strongSelf.logTag) in \(#function) ignoring sending \(data) for nil dataChannel: \(description)")
                }
                return
            }

            Logger.debug("\(strongSelf.logTag) sendDataChannelMessage trying: \(description)")

            let buffer = RTCDataBuffer(data: data, isBinary: false)
            let result = dataChannel.sendData(buffer)

            if result {
                Logger.debug("\(strongSelf.logTag) sendDataChannelMessage succeeded: \(description)")
            } else {
                Logger.warn("\(strongSelf.logTag) sendDataChannelMessage failed: \(description)")
            }
        }
        */
    }

    // MARK: RTCDataChannelDelegate

    /** The data channel state changed. */
    internal func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Logger.debug("\(logTag) dataChannelDidChangeState: \(dataChannel)")
    }

    /** The data channel successfully received a data buffer. */
    internal func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        Logger.debug("Ignoring obsolete data channel event in terminated client")
        return;
        /*
        let proxyCopy = self.proxy
        let completion: (OWSWebRTCProtosData) -> Void = { (dataChannelMessage) in
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            guard let strongDelegate = strongSelf.delegate else { return }
            strongDelegate.peerConnectionClient(strongSelf, received: dataChannelMessage)
        }

        ConferenceCallService.shared.rtcQueue.async {
            guard let strongSelf = proxyCopy.get() else { return }
            guard strongSelf.peerConnection != nil else {
                Logger.debug("\(strongSelf.logTag) \(#function) Ignoring obsolete event in terminated client")
                return
            }
            Logger.debug("\(strongSelf.logTag) dataChannel didReceiveMessageWith buffer:\(buffer)")

            guard let dataChannelMessage = OWSWebRTCProtosData.parse(from: buffer.data) else {
                // TODO can't proto parsings throw an exception? Is it just being lost in the Objc->Swift?
                Logger.error("\(strongSelf.logTag) failed to parse dataProto")
                return
            }

            DispatchQueue.main.async {
                completion(dataChannelMessage)
            }
        }
        */
    }

    /** The data channel's |bufferedAmount| changed. */
    internal func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        Logger.debug("\(logTag) didChangeBufferedAmount: \(amount)")
    }

    // MARK: - RTCPeerConnectionDelegate

    /** Called when the SignalingState changed. */
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Logger.debug("\(logTag) didChange signalingState:\(stateChanged.debugDescription)")
    }

    /** Called when media is received on a new stream from remote peer. */
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let proxyCopy = self.proxy
        let completion: (RTCVideoTrack) -> Void = { (remoteVideoTrack) in
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            guard let strongDelegate = strongSelf.delegate else { return }

            // TODO: Consider checking for termination here.

            strongDelegate.peerConnectionClient(strongSelf, didUpdateRemoteVideoTrack: remoteVideoTrack)
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
            guard stream.videoTracks.count > 0 else {
                owsFailDebug("\(strongSelf.logTag) in \(#function) didAdd stream missing stream.")
                return
            }
            let remoteVideoTrack = stream.videoTracks[0]
            Logger.debug("\(strongSelf.logTag) didAdd stream:\(stream) video tracks: \(stream.videoTracks.count) audio tracks: \(stream.audioTracks.count)")

            strongSelf.remoteVideoTrack = remoteVideoTrack

            DispatchQueue.main.async {
                completion(remoteVideoTrack)
            }
        }
    }

    /** Called when a remote peer closes a stream. */
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Logger.debug("\(logTag) didRemove Stream:\(stream)")
    }

    /** Called when negotiation is needed, for example ICE has restarted. */
    internal func peerConnectionShouldNegotiate(_ peerConnectionParam: RTCPeerConnection) {
        Logger.debug("\(logTag) shouldNegotiate")
    }

    /** Called any time the IceConnectionState changes. */
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let proxyCopy = self.proxy
        let connectedCompletion : () -> Void = {
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            guard let strongDelegate = strongSelf.delegate else { return }
            strongDelegate.peerConnectionClientIceConnected(strongSelf)
        }
        let failedCompletion : () -> Void = {
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            guard let strongDelegate = strongSelf.delegate else { return }
            strongDelegate.peerConnectionClientIceFailed(strongSelf)
        }
        let disconnectedCompletion : () -> Void = {
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            guard let strongDelegate = strongSelf.delegate else { return }
            strongDelegate.peerConnectionClientIceDisconnected(strongSelf)
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
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        Logger.info("\(logTag) didChange IceGatheringState:\(newState.debugDescription)")
    }

    /** New ice candidate has been found. */
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let proxyCopy = self.proxy
        let completion: (RTCIceCandidate) -> Void = { (candidate) in
            self.pendingIceCandidates.add(iceCandidate)
            
            if self.pendingIceCandidates.count > 24 {
                if self.iceCandidatesDebounceTimer != nil {
                    self.iceCandidatesDebounceTimer?.invalidate()
                    self.iceCandidatesDebounceTimer = nil
                }
                self.sendLocalIceCandidates()()
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
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Logger.debug("\(logTag) didRemove IceCandidates:\(candidates)")
    }

    /** New data channel has been opened. */
    internal func peerConnection(_ peerConnectionParam: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        let proxyCopy = self.proxy
        let completion: ([PendingDataChannelMessage]) -> Void = { (pendingMessages) in
            AssertIsOnMainThread(file: #function)
            guard let strongSelf = proxyCopy.get() else { return }
            pendingMessages.forEach { message in
                strongSelf.sendDataChannelMessage(data: message.data, description: message.description, isCritical: message.isCritical)
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
            Logger.info("\(strongSelf.logTag) didOpen dataChannel:\(dataChannel)")
            if strongSelf.dataChannel != nil {
                Logger.info("\(strongSelf.logTag) weird..setting dataChannel twice:\(dataChannel)")
            }
            strongSelf.dataChannel = dataChannel
            dataChannel.delegate = strongSelf.proxy

            let pendingMessages = strongSelf.pendingDataChannelMessages
            strongSelf.pendingDataChannelMessages = []
            DispatchQueue.main.async {
                completion(pendingMessages)
            }
        }
    }

    // MARK: Helpers

    /**
     * We synchronize access to state in this class using this queue.
     */
    private func assertOnSignalingQueue() {
        assertOnQueue(type(of: self).signalingQueue)
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

    internal func dataChannelForTests() -> RTCDataChannel {
        AssertIsOnMainThread(file: #function)

        var result: RTCDataChannel? = nil
        ConferenceCallService.shared.rtcQueue.sync {
            result = dataChannel
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
        
        guard let callData = self.callData else {
            self.handleFailedCurrentCall(error: CallError.assertionError(description: "ignoring local ice candidate, since there is no current call."))
            return
        }
        let call = callData.call
        
        let iceToSendSet = self.pendingIceCandidates.copy()
        self.pendingIceCandidates.removeAllObjects()
        
        // Wait until we've sent the CallOffer before sending any ice updates for the call to ensure
        // intuitive message ordering for other clients.
        self.readyToSendIceUpdatesPromise.done {
            guard call == self.call else {
                self.handleFailedCurrentCall(error: .obsoleteCall(description: "current call changed since we became ready to send ice updates"))
                return
            }
            
            guard call.state != .idle else {
                // This will only be called for the current peerConnectionClient, so
                // fail the current call.
                self.handleFailedCurrentCall(error: CallError.assertionError(description: "ignoring local ice candidate, since call is now idle."))
                return
            }
            
            var payloadCandidates = [NSDictionary]()
            for candidate in iceToSendSet as! Set<RTCIceCandidate> {
                
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
                Logger.debug("Attempt to build ice candidate message with no ice candidates.")
                return
            }
            
            let allTheData = [ "callId": call.callId ,
                               "peerId": call.peerId,
                               "originator" : TSAccountManager.localUID()!,
                               "icecandidates" : payloadCandidates
                ] as NSMutableDictionary
            
            let iceControlMessage = OutgoingControlMessage(thread: call.thread, controlType: FLControlMessageCallICECandidatesKey, moreData: allTheData)
            Logger.info("\(self.logTag) in \(#function) sending ICE Candidate \(call.identifiersForLogs).")
            let sendPromise = self.messageSender.sendPromise(message: iceControlMessage)
            sendPromise.retainUntilComplete()
            }.catch { error in
                Logger.error("\(self.logTag) in \(#function) waitUntilReadyToSendIceUpdates failed with error: \(error)")
            }.retainUntilComplete()
    }

}

/**
 * Restrict an RTCSessionDescription to more secure parameters
 */
class HardenedRTCSessionDescription {
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

protocol VideoCaptureSettingsDelegate: class {
    var videoWidth: Int32 { get }
    var videoHeight: Int32 { get }
}

class VideoCaptureController {

    private let capturer: RTCCameraVideoCapturer
    private weak var settingsDelegate: VideoCaptureSettingsDelegate?
    private let serialQueue = DispatchQueue(label: "org.signal.videoCaptureController")
    private var isUsingFrontCamera: Bool = true

    public var captureSession: AVCaptureSession {
        return capturer.captureSession
    }

    public init(capturer: RTCCameraVideoCapturer, settingsDelegate: VideoCaptureSettingsDelegate) {
        self.capturer = capturer
        self.settingsDelegate = settingsDelegate
    }

    public func startCapture() {
        serialQueue.sync { [weak self] in
            guard let strongSelf = self else {
                return
            }

            strongSelf.startCaptureSync()
        }
    }

    public func stopCapture() {
        serialQueue.sync { [weak self] in
            guard let strongSelf = self else {
                return
            }

            strongSelf.capturer.stopCapture()
        }
    }

    public func switchCamera(isUsingFrontCamera: Bool) {
        serialQueue.sync { [weak self] in
            guard let strongSelf = self else {
                return
            }

            strongSelf.isUsingFrontCamera = isUsingFrontCamera
            strongSelf.startCaptureSync()
        }
    }

    private func assertIsOnSerialQueue() {
        if _isDebugAssertConfiguration(), #available(iOS 10.0, *) {
            assertOnQueue(serialQueue)
        }
    }

    private func startCaptureSync() {
        assertIsOnSerialQueue()

        let position: AVCaptureDevice.Position = isUsingFrontCamera ? .front : .back
        guard let device: AVCaptureDevice = self.device(position: position) else {
            owsFailDebug("unable to find captureDevice")
            return
        }

        guard let format: AVCaptureDevice.Format = self.format(device: device) else {
            owsFailDebug("unable to find captureDevice")
            return
        }

        let fps = self.framesPerSecond(format: format)
        capturer.startCapture(with: device, format: format, fps: fps)
    }

    private func device(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let captureDevices = RTCCameraVideoCapturer.captureDevices()
        guard let device = (captureDevices.first { $0.position == position }) else {
            Logger.debug("unable to find desired position: \(position)")
            return captureDevices.first
        }

        return device
    }

    private func format(device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let targetWidth = settingsDelegate?.videoWidth ?? 0
        let targetHeight = settingsDelegate?.videoHeight ?? 0

        var selectedFormat: AVCaptureDevice.Format?
        var currentDiff: Int32 = Int32.max

        for format in formats {
            let dimension = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let diff = abs(targetWidth - dimension.width) + abs(targetHeight - dimension.height)
            if diff < currentDiff {
                selectedFormat = format
                currentDiff = diff
            }
        }

        if _isDebugAssertConfiguration(), let selectedFormat = selectedFormat {
            let dimension = CMVideoFormatDescriptionGetDimensions(selectedFormat.formatDescription)
            Logger.debug("in \(#function) selected format width: \(dimension.width) height: \(dimension.height)")
        }

        assert(selectedFormat != nil)

        return selectedFormat
    }

    private func framesPerSecond(format: AVCaptureDevice.Format) -> Int {
        var maxFrameRate: Float64 = 0
        for range in format.videoSupportedFrameRateRanges {
            maxFrameRate = max(maxFrameRate, range.maxFrameRate)
        }

        return Int(maxFrameRate)
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
