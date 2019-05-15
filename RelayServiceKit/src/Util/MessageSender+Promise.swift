//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//
import Foundation
import PromiseKit

public extension MessageSender {
    
    /**
     * Wrap message sending in a Promise for easier callback chaining.
     */
    func sendPromise(message: TSOutgoingMessage) -> Promise<Void> {
        let promise: Promise<Void> = Promise { resolver in
            self.enqueue(message, success: { resolver.fulfill(()) }, failure: { (error) in resolver.reject(error) })
        }
        
        // Ensure sends complete before they're GC'd.
        // This *should* be redundant, since we should be calling retainUntilComplete
        // at all call sites where the promise isn't otherwise retained.
        promise.retainUntilComplete()
        
        return promise
    }
    
    /**
     * Wrap message sending in a Promise for easier callback chaining.
     */
    func sendPromise(message: OutgoingControlMessage, recipientIds: [String]) -> Promise<Void> {
        let foo = NSCountedSet(array: recipientIds)
        let promise: Promise<Void> = Promise { resolver in
            self.send(message, toRecipients: foo, success: { resolver.fulfill(()) }, failure: { (error) in resolver.reject(error) })
        }
        
        // Ensure sends complete before they're GC'd.
        // This *should* be redundant, since we should be calling retainUntilComplete
        // at all call sites where the promise isn't otherwise retained.
        promise.retainUntilComplete()
        
        return promise
    }
    
    /**
     * Wrap message sending in a Promise for easier callback chaining.
     */
    func sendPromise(message: OutgoingControlMessage, recipientId: String, recipientDeviceId: UInt32) -> Promise<Void> {
        let promise: Promise<Void> = Promise { resolver in
            self.sendSpecialMessage(message,
                                    recipientId: recipientId,
                                    onlyDeviceId: NSNumber(value: recipientDeviceId),
                                    attempts: 3,
                                    success: { resolver.fulfill(()) },
                                    failure: { (error) in resolver.reject(error) })
        }
        
        // Ensure sends complete before they're GC'd.
        // This *should* be redundant, since we should be calling retainUntilComplete
        // at all call sites where the promise isn't otherwise retained.
        promise.retainUntilComplete()
        
        return promise
    }
}
