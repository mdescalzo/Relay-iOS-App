//
//  ThreadManager.swift
//  RelayServiceKit
//
//  Created by Mark Descalzo on 10/5/18.
//

// TODO: Merge functionality with ThreadUtil?

import Foundation

// Manager to handle thead update notifications in background
@objc public class ThreadManager : NSObject {
    
    // Shared singleton
    @objc public static let sharedManager = ThreadManager()

    fileprivate let imageCache = NSCache<NSString, UIImage>()
    
    fileprivate let dbReadConnection  = { () -> YapDatabaseConnection in
        let aConnection: YapDatabaseConnection = OWSPrimaryStorage.shared().newDatabaseConnection()
        aConnection.beginLongLivedReadTransaction()
        return aConnection
    }()
    fileprivate let dbReadWriteConnection = OWSPrimaryStorage.shared().newDatabaseConnection()
    
    @objc public override init() {
        super.init()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(threadExpressionUpdated(notification:)),
                                               name: NSNotification.Name.TSThreadExpressionChanged,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(yapDatabaseModified),
                                               name: NSNotification.Name.YapDatabaseModified,
                                               object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc public func image(threadId: String) -> UIImage? {
        if let image = self.imageCache.object(forKey: threadId as NSString) {
            return image
        } else {
            var thread: TSThread?
            self.dbReadConnection.read { (transaction) in
                thread = TSThread.fetch(uniqueId: threadId, transaction: transaction)
            }
            guard thread != nil else {
                Logger.debug("Attempt to retrieve unknown thread: \(threadId)")
                return nil
            }
            
            if let image = thread!.image {
                // thread has assigned image
                self.imageCache.setObject(image, forKey: threadId as NSString)
                return image
            } else if thread!.type == FLThreadTypeAnnouncement {
                if let image = UIImage(named: "Announcement") {
                    self.imageCache.setObject(image, forKey: threadId as NSString)
                    return image
                }
            } else if thread!.isOneOnOne {
                // one-on-one, use other avatar
                if let image = TextSecureKitEnv.shared().contactsManager.avatarImageRecipientId(thread!.otherParticipantId!) {
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
    
    @objc func threadExpressionUpdated(notification: Notification?) {
        Logger.debug("notification: \(String(describing: notification))")
        if (notification?.object is TSThread) {
            if let thread = notification?.object as? TSThread {
                self.validate(thread: thread)
            }
        }
    }
    
    @objc public func validate(thread: TSThread) {
        
        guard thread.universalExpression != nil else {
            Logger.debug("Aborting attept to validate thread with empty universal expression.")
            return
        }
        
        CCSMCommManager.asyncTagLookup(with: thread.universalExpression!, success: { lookupDict in
            //if lookupDict
            self.dbReadWriteConnection.asyncReadWrite({ (transaction) in
                thread.applyChange(toSelfAndLatestCopy: transaction, change: { object in
                    let aThread = object as! TSThread
                    if let userIds = lookupDict["userids"] as? [String] {
                        aThread.participantIds = userIds
                        NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLRecipientsNeedRefreshNotification),
                                                                             object: nil,
                                                                             userInfo: [ "userIds" : userIds ])
                    }
                    if let pretty = lookupDict["pretty"] as? String {
                        aThread.prettyExpression = pretty
                    }
                    if let expression = lookupDict["universal"] as? String {
                        aThread.universalExpression = expression
                    }
                    if let monitorids = lookupDict["monitorids"] as? [String] {
                        aThread.monitorIds = NSCountedSet.init(array: monitorids)
                    }
                })
            })
        }, failure: { error in
            Logger.debug("\(self.logTag): TagMath query for expression failed.  Error: \(error.localizedDescription)")
        })
    }
    
//    // MARK: - KVO
//    @objc override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
//        if keyPath == "useGravatars" {
//            for obj in TSThread.allObjectsInCollection() {
//                let thread = obj as! TSThread
//                thread.touch()
//            }
//        }
//    }
    
    @objc func yapDatabaseModified(notification: Notification?) {
        
        DispatchQueue.global(qos: .background).async {
            let notifications = self.dbReadConnection.beginLongLivedReadTransaction()
            self.dbReadConnection.enumerateChangedKeys(inCollection: TSThread.collection(),
                                                     in: notifications) { (threadId, stop) in
                                                        // Remove cached image
                                                        self.imageCache.removeObject(forKey: threadId as NSString)
            }
        }
    }


}
