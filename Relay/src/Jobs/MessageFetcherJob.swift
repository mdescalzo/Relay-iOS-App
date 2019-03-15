//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit
import RelayServiceKit

@objc(OWSMessageFetcherJob)
public class MessageFetcherJob: NSObject {

    private var timer: Timer?

    // MARK: injected dependencies
    private let networkManager: TSNetworkManager
    private let messageReceiver: OWSMessageReceiver
    private let signalService: OWSSignalService

    @objc public init(messageReceiver: OWSMessageReceiver, networkManager: TSNetworkManager, signalService: OWSSignalService) {
        self.messageReceiver = messageReceiver
        self.networkManager = networkManager
        self.signalService = signalService

        super.init()

        SwiftSingletons.register(self)
    }

    @discardableResult
    public func run() -> Promise<Void> {
        Logger.debug("\(self.logTag) in \(#function)")

        guard signalService.isCensorshipCircumventionActive else {
            Logger.debug("\(self.logTag) delegating message fetching to SocketManager since we're using normal transport.")
            TSSocketManager.requestSocketOpen()
            return Promise.value(())
        }

        Logger.info("\(self.logTag) fetching messages via REST.")

        let promise = self.fetchUndeliveredMessages().then { (envelopes: [SSKEnvelope], more: Bool) -> Promise<Void> in
            for envelope in envelopes {
                Logger.info("\(self.logTag) received envelope.")
                do {
                    let envelopeData = try envelope.serializedData()
                    self.messageReceiver.handleReceivedEnvelopeData(envelopeData)
                } catch {
                    owsFailDebug("\(self.logTag) in \(#function) failed to serialize envelope")
                }
                self.acknowledgeDelivery(envelope: envelope)
            }

            if more {
                Logger.info("\(self.logTag) fetching more messages.")
                return self.run()
            } else {
                // All finished
                return Promise.value(())
            }
        }

        promise.retainUntilComplete()

        return promise
    }

    @objc
    @discardableResult
    public func run() -> AnyPromise {
        return AnyPromise(run() as Promise)
    }

    // use in DEBUG or wherever you can't receive push notifications to poll for messages.
    // Do not use in production.
    public func startRunLoop(timeInterval: Double) {
        Logger.error("\(self.logTag) Starting message fetch polling. This should not be used in production.")
        timer = WeakTimer.scheduledTimer(timeInterval: timeInterval, target: self, userInfo: nil, repeats: true) {[weak self] _ in
            let _: Promise<Void>? = self?.run()
            return
        }
    }

    public func stopRunLoop() {
        timer?.invalidate()
        timer = nil
    }

    private func parseMessagesResponse(responseObject: Any?) -> (envelopes: [SSKEnvelope], more: Bool)? {
        guard let responseObject = responseObject else {
            Logger.error("\(self.logTag) response object was surpringly nil")
            return nil
        }

        guard let responseDict = responseObject as? [String: Any] else {
            Logger.error("\(self.logTag) response object was not a dictionary")
            return nil
        }

        guard let messageDicts = responseDict["messages"] as? [[String: Any]] else {
            Logger.error("\(self.logTag) messages object was not a list of dictionaries")
            return nil
        }

        let moreMessages = { () -> Bool in
            if let responseMore = responseDict["more"] as? Bool {
                return responseMore
            } else {
                Logger.warn("\(self.logTag) more object was not a bool. Assuming no more")
                return false
            }
        }()

        let envelopes: [SSKEnvelope] = messageDicts.compactMap { buildEnvelope(messageDict: $0) }

        return (
            envelopes: envelopes,
            more: moreMessages
        )
    }

    private func buildEnvelope(messageDict: [String: Any]) -> SSKEnvelope? {
        do {
            let params = ParamParser(dictionary: messageDict)

            let typeInt: Int32 = try params.required(key: "type")
            guard let type: SSKEnvelope.SSKEnvelopeType = SSKEnvelope.SSKEnvelopeType(rawValue: typeInt) else {
                Logger.error("\(self.logTag) `typeInt` was invalid: \(typeInt)")
                throw ParamParser.ParseError.invalidFormat("type")
            }

            let timestamp: UInt64 = try params.required(key: "timestamp")
            let maybeAge: UInt64? = try params.optional(key: "age")
            let age: NSNumber? = (maybeAge != nil) ? NSNumber(value: maybeAge!) : nil
            let source: String = try params.required(key: "source")
            let sourceDevice: UInt32 = try params.required(key: "sourceDevice")
            let legacyMessage: Data? = try params.optionalBase64EncodedData(key: "message")
            let content: Data? = try params.optionalBase64EncodedData(key: "content")

            return SSKEnvelope(timestamp: timestamp, age: age, source: source, sourceDevice: sourceDevice, type: type, content: content, legacyMessage: legacyMessage)
        } catch {
            owsFailDebug("\(self.logTag) in \(#function) error building envelope: \(error)")
            return nil
        }
    }

    private func fetchUndeliveredMessages() -> Promise<(envelopes: [SSKEnvelope], more: Bool)> {
        return Promise { resolver in
            let request = OWSRequestFactory.getMessagesRequest()
            self.networkManager.makeRequest(
                request,
                success: { (_: URLSessionDataTask?, responseObject: Any?) -> Void in
                    guard let (envelopes, more) = self.parseMessagesResponse(responseObject: responseObject) else {
                        Logger.error("\(self.logTag) response object had unexpected content")
                        return resolver.reject(OWSErrorMakeUnableToProcessServerResponseError())
                    }

                    resolver.fulfill((envelopes: envelopes, more: more))
                },
                failure: { (_: URLSessionDataTask?, error: Error?) in
                    guard let error = error else {
                        Logger.error("\(self.logTag) error was surpringly nil. sheesh rough day.")
                        return resolver.reject(OWSErrorMakeUnableToProcessServerResponseError())
                    }

                    resolver.reject(error)
            })
        }
    }

    private func acknowledgeDelivery(envelope: SSKEnvelope) {
        let request = OWSRequestFactory.acknowledgeMessageDeliveryRequest(withSource: envelope.source, timestamp: envelope.timestamp)
        self.networkManager.makeRequest(request,
                                        success: { (_: URLSessionDataTask?, _: Any?) -> Void in
                                            Logger.debug("\(self.logTag) acknowledged delivery for message at timestamp: \(envelope.timestamp)")
        },
                                        failure: { (_: URLSessionDataTask?, error: Error?) in
                                            Logger.debug("\(self.logTag) acknowledging delivery for message at timestamp: \(envelope.timestamp) failed with error: \(String(describing: error))")
        })
    }
}
