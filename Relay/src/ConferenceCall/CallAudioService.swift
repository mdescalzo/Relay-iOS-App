//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import AVFoundation
import RelayServiceKit
import RelayMessaging

struct AudioSource: Hashable {

    let image: UIImage
    let localizedName: String
    let portDescription: AVAudioSessionPortDescription?

    // The built-in loud speaker / aka speakerphone
    let isBuiltInSpeaker: Bool

    // The built-in quiet speaker, aka the normal phone handset receiver earpiece
    let isBuiltInEarPiece: Bool

    init(localizedName: String, image: UIImage, isBuiltInSpeaker: Bool, isBuiltInEarPiece: Bool, portDescription: AVAudioSessionPortDescription? = nil) {
        self.localizedName = localizedName
        self.image = image
        self.isBuiltInSpeaker = isBuiltInSpeaker
        self.isBuiltInEarPiece = isBuiltInEarPiece
        self.portDescription = portDescription
    }

    init(portDescription: AVAudioSessionPortDescription) {

        let isBuiltInEarPiece = portDescription.portType == AVAudioSessionPortBuiltInMic

        // portDescription.portName works well for BT linked devices, but if we are using
        // the built in mic, we have "iPhone Microphone" which is a little awkward.
        // In that case, instead we prefer just the model name e.g. "iPhone" or "iPad"
        let localizedName = isBuiltInEarPiece ? UIDevice.current.localizedModel : portDescription.portName

        self.init(localizedName: localizedName,
                  image: #imageLiteral(resourceName: "button_phone_white"), // TODO
                  isBuiltInSpeaker: false,
                  isBuiltInEarPiece: isBuiltInEarPiece,
                  portDescription: portDescription)
    }

    // Speakerphone is handled separately from the other audio routes as it doesn't appear as an "input"
    static var builtInSpeaker: AudioSource {
        return self.init(localizedName: NSLocalizedString("AUDIO_ROUTE_BUILT_IN_SPEAKER", comment: "action sheet button title to enable built in speaker during a call"),
                         image: #imageLiteral(resourceName: "button_phone_white"), //TODO
                         isBuiltInSpeaker: true,
                         isBuiltInEarPiece: false)
    }

    // MARK: Hashable

    static func ==(lhs: AudioSource, rhs: AudioSource) -> Bool {
        // Simply comparing the `portDescription` vs the `portDescription.uid`
        // caused multiple instances of the built in mic to turn up in a set.
        if lhs.isBuiltInSpeaker && rhs.isBuiltInSpeaker {
            return true
        }

        if lhs.isBuiltInSpeaker || rhs.isBuiltInSpeaker {
            return false
        }

        guard let lhsPortDescription = lhs.portDescription else {
            owsFailDebug("only the built in speaker should lack a port description")
            return false
        }

        guard let rhsPortDescription = rhs.portDescription else {
            owsFailDebug("only the built in speaker should lack a port description")
            return false
        }

        return lhsPortDescription.uid == rhsPortDescription.uid
    }

    var hashValue: Int {
        guard let portDescription = self.portDescription else {
            assert(self.isBuiltInSpeaker)
            return "Built In Speaker".hashValue
        }
        return portDescription.uid.hash
    }
}

protocol CallAudioServiceDelegate: class {
    func callAudioService(_ callAudioService: CallAudioService, didUpdateIsSpeakerphoneEnabled isEnabled: Bool)
    func callAudioServiceDidChangeAudioSession(_ callAudioService: CallAudioService)
}

@objc class CallAudioService: NSObject, ConferenceCallDelegate {
    func peerConnectiongDidUpdateRemoteVideoTrack(peerId: String) {
        // CallAudioService don't care (probably)
    }
        
    func peerConnectionDidConnect(peerId: String) {
        // stub
    }
    
    func stateDidChange(call: ConferenceCall, state: ConferenceCallState) {
        // stub
    }
    
    func peerConnectionsNeedAttention(call: ConferenceCall, peerId: String) {
        // stub
    }

    private var vibrateTimer: Timer?
    private let audioPlayer = AVAudioPlayer()
    private let handleRinging: Bool
    weak var delegate: CallAudioServiceDelegate? {
        willSet {
            assert(newValue == nil || delegate == nil)
        }
    }

    // MARK: Vibration config
    private let vibrateRepeatDuration = 1.6

    // Our ring buzz is a pair of vibrations.
    // `pulseDuration` is the small pause between the two vibrations in the pair.
    private let pulseDuration = 0.2

    var audioSession: OWSAudioSession {
        return OWSAudioSession.shared
    }
    var avAudioSession: AVAudioSession {
        return AVAudioSession.sharedInstance()
    }

    // MARK: - Initializers

    init(handleRinging: Bool) {
        self.handleRinging = handleRinging

        super.init()

        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings

        // Configure audio session so we don't prompt user with Record permission until call is connected.

        audioSession.configureRTCAudio()
        NotificationCenter.default.addObserver(forName: .AVAudioSessionRouteChange, object: avAudioSession, queue: nil) { _ in
            assert(!Thread.isMainThread)
            // self.updateIsSpeakerphoneEnabled()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - CallObserver


    // MARK: Playing Sounds

    var currentPlayer: OWSAudioPlayer?

    private func stopPlayingAnySounds() {
        currentPlayer?.stop()
        // stopAnyRingingVibration()
    }

    private func play(sound: OWSSound) {
        guard let newPlayer = OWSSounds.audioPlayer(for: sound) else {
            owsFailDebug("\(self.logTag) unable to build player for sound: \(OWSSounds.displayName(for: sound))")
            return
        }
        Logger.info("\(self.logTag) playing sound: \(OWSSounds.displayName(for: sound))")

        // It's important to stop the current player **before** starting the new player. In the case that 
        // we're playing the same sound, since the player is memoized on the sound instance, we'd otherwise 
        // stop the sound we just started.
        self.currentPlayer?.stop()
        newPlayer.playWithCurrentAudioCategory()
        self.currentPlayer = newPlayer
    }

}
