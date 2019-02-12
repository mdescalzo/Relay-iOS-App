//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import UIKit
import CallKit
import RelayServiceKit

/**
 * Requests actions from CallKit
 *
 * @Discussion:
 *   Based on SpeakerboxCallManager, from the Apple CallKit Example app. Though, it's responsibilities are mostly 
 *   mirrored (and delegated from) CallKitCallUIAdaptee.
 *   TODO: Would it simplify things to merge this into CallKitCallUIAdaptee?
 */
@available(iOS 10.0, *)
final class CallKitCallManager: NSObject {

    let callController = CXCallController()
    let showNamesOnCallScreen: Bool
    
    lazy var callService: ConferenceCallService? = { return ConferenceCallService.shared }()

//    @objc static let kAnonymousCallHandlePrefix = "Forsta:"
    @objc static let kAnonymousCallHandlePrefix = ""

    required init(showNamesOnCallScreen: Bool) {
        AssertIsOnMainThread(file: #function)

        self.showNamesOnCallScreen = showNamesOnCallScreen
        super.init()

        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings
    }

    // MARK: Actions

    func startCall(_ call: ConferenceCall) {
    }

    func localHangup(call: ConferenceCall) {
        self.callService?.endCall(call: call)
    }

    func setHeld(call: ConferenceCall, onHold: Bool) {
    }

    func setIsMuted(call: ConferenceCall, isMuted: Bool) {
    }

    func answer(call: ConferenceCall) {
        call.state = .joined
    }

    private func requestTransaction(_ transaction: CXTransaction) {
    }

    // MARK: Call Management

    private(set) var calls = [ConferenceCall]()

    func callWithLocalId(_ localId: UUID) -> ConferenceCall? {
        return self.calls.filter { (call) -> Bool in
            localId == UUID.init(uuidString: call.callId)
        }.last
    }

    func addCall(_ call: ConferenceCall) {
        calls.append(call)
    }

    func removeCall(_ call: ConferenceCall) {
        calls.removeFirst(where: { $0 === call })
    }

    func removeAllCalls() {
        calls.removeAll()
    }
}

fileprivate extension Array {

    mutating func removeFirst(where predicate: (Element) throws -> Bool) rethrows {
        guard let index = try index(where: predicate) else {
            return
        }

        remove(at: index)
    }
}
