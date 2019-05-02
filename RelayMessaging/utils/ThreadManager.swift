//
//  ThreadManager.swift
//  RelayServiceKit
//
//  Created by Mark Descalzo on 10/5/18.
//

// TODO: Merge functionality with ThreadUtil?

import Foundation
import RelayStorage
import SignalCoreKit
import CoreData

// Manager to handle thead update notifications in background
@objc public class ThreadManager : NSObject {
    
    // Shared singleton
    @objc public static let sharedManager = ThreadManager()

    fileprivate let imageCache = NSCache<NSString, UIImage>()
    
    fileprivate lazy var moc: NSManagedObjectContext = {
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.parent = StorageManager.shared.mainContext
        context.automaticallyMergesChangesFromParent = true
        return context
    }()
    
    @objc public override init() {
        super.init()
        
        // FIXME: Replace this notification
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(threadExpressionUpdated(notification:)),
//                                               name: NSNotification.Name.TSThreadExpressionChanged,
//                                               object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc public func fetchThread(uuid: String, context: NSManagedObjectContext) -> FLIThread? {
        return StorageManager.shared.fetchObject(uuid: uuid, context: context) as? FLIThread
    }

    @objc public func image(threadId: String) -> UIImage? {
        if let image = self.imageCache.object(forKey: threadId as NSString) {
            return image
        } else {
            // FIXME: Thread lookup here

            guard let thread = fetchThread(uuid: threadId, context: moc) else {
                Logger.debug("Attempt to retrieve unknown thread: \(threadId)")
                return nil
            }
            
            if thread.avatar != nil,
                let image = UIImage(data: thread.avatar! as Data) {
                // thread has assigned image
                imageCache.setObject(image, forKey: threadId as NSString)
                return image
            } else if thread.type == "annoucement" {  // FIXME: This shouldn't be
                if let image = UIImage(named: "Announcement") {
                    self.imageCache.setObject(image, forKey: threadId as NSString)
                    return image
                }
            } else if thread.isOneOnOne() {
                // one-on-one, use other avatar
                if let image = UserManager.image(userId: thread.otherParticipant()!.uuid!) {
                    self.imageCache.setObject(image, forKey: threadId as NSString)
                    return image
                }
            }
        }
        // Return default avatar
        return UIImage.init(named:"empty-group-avatar-gray");
    }
    
    @objc public func flushImageCache() {
        imageCache.removeAllObjects()
    }
    
    // FIXME: Pass threadId, not the actual thread
    @objc func threadExpressionUpdated(notification: Notification?) {
        Logger.debug("notification: \(String(describing: notification))")
        if let threadId = notification?.userInfo?["threadId"] as? String {
            self.validate(threadId: threadId)
        }
    }
    
    @objc public func validate(threadId: String) {
       
        guard let thread = fetchThread(uuid: threadId, context: moc) else {
            Logger.debug("\(self.logTag): Thread doesn't exist for id: \(threadId)")
            return
        }
        var lookupString: String
        if thread.expression != nil {
            lookupString = thread.expression!
        } else if thread.currentParticipants!.count > 0 {
            lookupString = FLCCSMJSONService.expression(forIds: thread.participantIds)
        } else {
            Logger.debug("Aborting attept to validate thread with missing universal expression.")
            return
        }
        
        CCSMCommManager.asyncTagLookup(with: lookupString, success: { lookupDict in
            self.dbReadWriteConnection.asyncReadWrite({ (transaction) in
                if let userIds = lookupDict["userids"] as? [String] {
                    thread.participantIds = userIds
                    NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLRecipientsNeedRefreshNotification),
                                                                         object: nil,
                                                                         userInfo: [ "userIds" : userIds ])
                }
                if let pretty = lookupDict["pretty"] as? String {
                    if pretty.count > 0 {
                        thread.prettyExpression = pretty
                    }
                }
                if let expression = lookupDict["universal"] as? String {
                    if expression.count > 0 {
                        thread.universalExpression = expression
                    }
                }
                if let monitorids = lookupDict["monitorids"] as? [String] {
                    if monitorids.count > 0 {
                        thread.monitorIds = NSCountedSet.init(array: monitorids)
                    }
                }
                thread.save(with: transaction)
            })
        }, failure: { error in
            Logger.debug("\(self.logTag): TagMath query failed for expression: \(lookupString).  Error: \(error.localizedDescription)")
        })
    }
}
