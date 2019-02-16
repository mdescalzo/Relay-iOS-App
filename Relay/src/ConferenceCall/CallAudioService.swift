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
    
    private(set) var isSpeakerphoneEnabled: Bool = false {
        didSet {
            self.delegate?.callAudioService(self, didUpdateIsSpeakerphoneEnabled: isSpeakerphoneEnabled)
        }
    }
    private var vibrateTimer: Timer?
    private let audioPlayer = AVAudioPlayer()
    private let handleRinging: Bool
    weak var delegate: CallAudioServiceDelegate? {
        willSet {
            assert(newValue == nil || delegate == nil)
        }
    }
    
    
    var availableInputs: [AudioSource] {
        guard let availableInputs = avAudioSession.availableInputs else {
            // I'm not sure why this would happen, but it may indicate an error.
            owsFailDebug("No available inputs or inputs not ready")
            return [AudioSource.builtInSpeaker]
        }
        
        Logger.info("availableInputs: \(availableInputs)")
        return [AudioSource.builtInSpeaker] + availableInputs.map { portDescription in
            return AudioSource(portDescription: portDescription)
        }
    }
    
    // MARK: - Vibration config
    private let vibrateRepeatDuration = 1.6
    
    // Our ring buzz is a pair of vibrations.
    // `pulseDuration` is the small pause between the two vibrations in the pair.
    private let pulseDuration = 0.2
    
    lazy var audioSession: OWSAudioSession = OWSAudioSession.shared
    lazy var avAudioSession: AVAudioSession = AVAudioSession.sharedInstance()

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

    // MARK: - Initializers
    init(handleRinging: Bool) {
        self.handleRinging = handleRinging
        
        super.init()
        
        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings
        
        // Configure audio session so we don't prompt user with Record permission until call is connected.
        
        audioSession.configureRTCAudio()
        NotificationCenter.default.addObserver(forName: .AVAudioSessionRouteChange, object: avAudioSession, queue: nil) { _ in
            assert(!Thread.isMainThread)
            self.updateIsSpeakerphoneEnabled()
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func currentAudioSource(_ call: ConferenceCall) -> AudioSource? {
        if let audioSource = call.audioSource {
            return audioSource
        }
        
        // Before the user has specified an audio source on the call, we rely on the existing
        // system state to determine the current audio source.
        // If a bluetooth is connected, this will be bluetooth, otherwise
        // this will be the receiver.
        guard let portDescription = avAudioSession.currentRoute.inputs.first else {
            return nil
        }
        
        return AudioSource(portDescription: portDescription)
    }
    
    public func requestSpeakerphone(isEnabled: Bool) {
        // This is a little too slow to execute on the main thread and the results are not immediately available after execution
        // anyway, so we dispatch async. If you need to know the new value, you'll need to check isSpeakerphoneEnabled and take
        // advantage of the CallAudioServiceDelegate.callAudioService(_:didUpdateIsSpeakerphoneEnabled:)
        DispatchQueue.global().async {
            do {
                try self.avAudioSession.overrideOutputAudioPort( isEnabled ? .speaker : .none )
            } catch {
                Logger.error("failed to set \(#function) = \(isEnabled) with error: \(error)")
            }
        }
    }
    
    private func updateIsSpeakerphoneEnabled() {
        let value = self.avAudioSession.currentRoute.outputs.contains { (portDescription: AVAudioSessionPortDescription) -> Bool in
            return portDescription.portName == AVAudioSessionPortBuiltInSpeaker
        }
        DispatchQueue.main.async {
            self.isSpeakerphoneEnabled = value
        }
    }

    private func ensureProperAudioSession(call: ConferenceCall?) {
        AssertIsOnMainThread()
        
        guard let call = call, !call.state.isTerminal else {
            // Revert to default audio
            setAudioSession(category: AVAudioSessionCategorySoloAmbient,
                            mode: AVAudioSessionModeDefault)
            return
        }
        
        // Disallow bluetooth while (and only while) the user has explicitly chosen the built in receiver.
        //
        // NOTE: I'm actually not sure why this is required - it seems like we should just be able
        // to setPreferredInput to call.audioSource.portDescription in this case,
        // but in practice I'm seeing the call revert to the bluetooth headset.
        // Presumably something else (in WebRTC?) is touching our shared AudioSession. - mjk
        let options: AVAudioSessionCategoryOptions = call.audioSource?.isBuiltInEarPiece == true ? [] : [.allowBluetooth]
        
        if call.state == .ringing || call.state == .vibrating {
            // SoloAmbient plays through speaker, but respects silent switch
            setAudioSession(category: AVAudioSessionCategorySoloAmbient,
                            mode: AVAudioSessionModeDefault)
        } else if call.localVideoTrack != nil {
            // Because ModeVideoChat affects gain, we don't want to apply it until the call is connected.
            // otherwise sounds like ringing will be extra loud for video vs. speakerphone
            // Apple Docs say that setting mode to AVAudioSessionModeVideoChat has the
            // side effect of setting options: .allowBluetooth, when I remove the (seemingly unnecessary)
            // option, and inspect AVAudioSession.sharedInstance.categoryOptions == 0. And availableInputs
            // does not include my linked bluetooth device
            setAudioSession(category: AVAudioSessionCategoryPlayAndRecord,
                            mode: AVAudioSessionModeVideoChat,
                            options: options)
        } else {
            // Apple Docs say that setting mode to AVAudioSessionModeVoiceChat has the
            // side effect of setting options: .allowBluetooth, when I remove the (seemingly unnecessary)
            // option, and inspect AVAudioSession.sharedInstance.categoryOptions == 0. And availableInputs
            // does not include my linked bluetooth device
            setAudioSession(category: AVAudioSessionCategoryPlayAndRecord,
                            mode: AVAudioSessionModeVoiceChat,
                            options: options)
        }
        
        do {
            // It's important to set preferred input *after* ensuring properAudioSession
            // because some sources are only valid for certain category/option combinations.
            let existingPreferredInput = avAudioSession.preferredInput
            if  existingPreferredInput != call.audioSource?.portDescription {
                Logger.info("changing preferred input: \(String(describing: existingPreferredInput)) -> \(String(describing: call.audioSource?.portDescription))")
                try avAudioSession.setPreferredInput(call.audioSource?.portDescription)
            }
            
        } catch {
            owsFailDebug("failed setting audio source with error: \(error) isSpeakerPhoneEnabled: \(self.isSpeakerphoneEnabled)")
        }
    }
    
    private func setAudioSession(category: String,
                                 mode: String? = nil,
                                 options: AVAudioSessionCategoryOptions = AVAudioSessionCategoryOptions(rawValue: 0)) {
        AssertIsOnMainThread()
        
        var audioSessionChanged = false
        do {
            if #available(iOS 10.0, *), let mode = mode {
                let oldCategory = avAudioSession.category
                let oldMode = avAudioSession.mode
                let oldOptions = avAudioSession.categoryOptions
                
                guard oldCategory != category || oldMode != mode || oldOptions != options else {
                    return
                }
                
                audioSessionChanged = true
                
                if oldCategory != category {
                    Logger.debug("audio session changed category: \(oldCategory) -> \(category) ")
                }
                if oldMode != mode {
                    Logger.debug("audio session changed mode: \(oldMode) -> \(mode) ")
                }
                if oldOptions != options {
                    Logger.debug("audio session changed options: \(oldOptions) -> \(options) ")
                }
                try avAudioSession.setCategory(category, mode: mode, options: options)
                
            } else {
                let oldCategory = avAudioSession.category
                let oldOptions = avAudioSession.categoryOptions
                
                guard avAudioSession.category != category || avAudioSession.categoryOptions != options else {
                    return
                }
                
                audioSessionChanged = true
                
                if oldCategory != category {
                    Logger.debug("audio session changed category: \(oldCategory) -> \(category) ")
                }
                if oldOptions != options {
                    Logger.debug("audio session changed options: \(oldOptions) -> \(options) ")
                }
                try avAudioSession.setCategory(category, with: options)
                
            }
        } catch {
            let message = "failed to set category: \(category) mode: \(String(describing: mode)), options: \(options) with error: \(error)"
            owsFailDebug(message)
        }
        
        if audioSessionChanged {
            Logger.info("")
            self.delegate?.callAudioServiceDidChangeAudioSession(self)
        }
    }

    // MARK: - ConferenceCallDelegate methods
    func audioSourceDidChange(call: ConferenceCall, audioSource: AudioSource?) {
        ensureProperAudioSession(call: call)
        
        if let audioSource = audioSource, audioSource.isBuiltInSpeaker {
            self.isSpeakerphoneEnabled = true
        } else {
            self.isSpeakerphoneEnabled = false
        }
    }
    
    func stateDidChange(call: ConferenceCall, oldState: ConferenceCallState, newState: ConferenceCallState) {
        if oldState != newState {
            self.stopPlayingAnySounds()
            self.ensureProperAudioSession(call: call)

            switch newState {
            case .undefined:
                do { /* TODO */ }
            case .ringing:
                do { /* TODO */ }
            case .vibrating:
                do { /* TODO */ }
            case .rejected:
                do { /* TODO */ }
            case .joined:
                do { /* TODO */ }
            case .leaving:
                do { /* TODO */ }
            case .left:
                do {
                    self.isSpeakerphoneEnabled = false
                    self.setAudioSession(category: AVAudioSessionCategorySoloAmbient)
                }
            }
        }
    }
    
    func peerConnectionStateDidChange(pcc: PeerConnectionClient, oldState: PeerConnectionClientState, newState: PeerConnectionClientState) {
        // CallAudioService don't care (probably)
    }
    
    func didUpdateLocalVideoTrack(captureSession: AVCaptureSession?) {
        // CallAudioService don't care (probably)
    }
    
    func peerConnectiongDidUpdateRemoteVideoTrack(peerId: String) {
        // CallAudioService don't care (probably)
    }
    
    func peerConnectionDidConnect(peerId: String) {
        // CallAudioService don't care (probably)
    }
    
    func stateDidChange(call: ConferenceCall, state: ConferenceCallState) {
        // CallAudioService don't care (probably)
    }
    
    func peerConnectionsNeedAttention(call: ConferenceCall, peerId: String) {
        // CallAudioService don't care (probably)
    }
}
