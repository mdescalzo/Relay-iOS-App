//
//  FLContactsManager.swift
//  RelayMessaging
//
//  Created by Mark Descalzo on 8/14/18.
//  Copyright © 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import RelayStorage
import SignalCoreKit
import CoreData

@objc public class FLIUserManager: NSObject {

    private static let shared = FLIUserManager()

    private let avatarCache: NSCache<NSString, UIImage>
    private let userCache: NSCache<NSString, FLIUser>
    private let tagCache: NSCache<NSString, FLITag>
    
    private lazy var localContext: NSManagedObjectContext = {
        let aContext = StorageManager.shared.persistentContainer.newBackgroundContext()
        aContext.automaticallyMergesChangesFromParent = true
        return aContext
    }()

    @objc
    public class func displayName(userId: String) -> String {
        if let user: FLIUser = FLIUserManager.shared.user(uuid: userId, context: FLIUserManager.shared.localContext) {
            return user.fullName()
        } else {
            return NSLocalizedString("UNKNOWN_CONTACT_NAME", comment: "")
        }
    }

    public class func compare(user left: FLIUser, with right: FLIUser) -> ComparisonResult {
        
        var comparisonResult: ComparisonResult = .orderedSame
        
        if left.lastName != nil && right.lastName != nil {
            comparisonResult = (left.lastName!.caseInsensitiveCompare(right.lastName!))
        }
        if comparisonResult == .orderedSame && left.firstName != nil && right.firstName != nil {
            comparisonResult = (left.firstName!.caseInsensitiveCompare(right.firstName!))
        }
        return comparisonResult
    }
    
    public class func avatarImage(userId: String) -> UIImage? {
        
        var cacheKey: NSString? = nil
        
        let useGravatars: Bool = Environment.preferences().useGravatars()
        
        if useGravatars {
            cacheKey = "gravatar:\(userId)" as NSString
        } else {
            cacheKey = "avatar:\(userId)" as NSString
        }
        
        // Check the avatarCache...
        if let image = FLIUserManager.shared.avatarCache.object(forKey: cacheKey!) {
//            Logger.debug("Avatar cache hit!")
            return image;
        }
        
        // Check local storage
        guard let recipient = self.recipient(withId: recipientId) else {
            Logger.debug("Attempt to get avatar image for unknown recipient: \(recipientId)")
            return nil
        }

        var image: UIImage?
        if useGravatars {
            // Post a notification to fetch the gravatar image so it doesn't block and then fall back to default
            NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLRecipientNeedsGravatarFetched),
                                                                 object: self,
                                                                 userInfo: ["recipientId" : recipientId ])
        }
        if useGravatars && recipient.gravatarImage != nil {
            image = recipient.gravatarImage
        } else if recipient.avatarImage != nil {
            image = recipient.avatarImage
        } else if recipient.defaultImage != nil {
            image = recipient.defaultImage
        } else {
            image = OWSContactAvatarBuilder.init(nonSignalName: recipient.fullName(),
                                                 colorSeed: recipient.uniqueId,
                                                 diameter: 128,
                                                 contactsManager: self).build()
            recipient.defaultImage = image
            self.save(recipient: recipient)
        }
        self.avatarCache.setObject(image!, forKey: cacheKey!)
        return image
    }
    
    private let serialLookupQueue = DispatchQueue(label: "contactsManagerLookupQueue")
    
    private let readConnection = { () -> YapDatabaseConnection in 
        let aConnection: YapDatabaseConnection = OWSPrimaryStorage.shared().newDatabaseConnection()
        aConnection.beginLongLivedReadTransaction()
        return aConnection
    }()
    private let readWriteConnection: YapDatabaseConnection = OWSPrimaryStorage.shared().newDatabaseConnection()
    private var latestRecipientsById: [AnyHashable : Any] = [:]
    private var activeRecipientsBacker: [ FLIUser ] = []
    private var visibleRecipientsPredicate: NSCompoundPredicate?
    private var pendingTagIds = Set<String>()
    private var pendingRecipientIds = Set<String>()
    
    @objc public func flushAvatarCache() {
        avatarCache.removeAllObjects()
    }

    override init() {
        avatarCache = NSCache<NSString, UIImage>()
        userCache = NSCache<NSString, FLIUser>()
        tagCache = NSCache<NSString, FLTag>()

        super.init()
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.processRecipientsBlob),
                                               name: NSNotification.Name(rawValue: FLCCSMUsersUpdated),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.processTagsBlob),
                                               name: NSNotification.Name(rawValue: FLCCSMTagsUpdated),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.handleRecipientRefresh(notification:)),
                                               name: NSNotification.Name(rawValue: FLRecipientsNeedRefreshNotification),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.handleTagRefresh(notification:)),
                                               name: NSNotification.Name(rawValue: FLTagsNeedRefreshNotification),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.fetchGravtarForRecipient(notification:)),
                                               name: NSNotification.Name(rawValue: FLRecipientNeedsGravatarFetched),
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(yapDatabaseModified),
                                               name: NSNotification.Name.YapDatabaseModified,
                                               object: nil)
        avatarCache.delegate = self
        userCache.delegate = self
        tagCache.delegate = self
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc public func allTags() -> [FLTag] {
        return FLTag.allObjectsInCollection() as! [FLTag]
    }
    
    @objc public func allRecipients() -> [FLIUser] {
        return FLIUser.allObjectsInCollection() as! [FLIUser]
    }

    @objc public func selfRecipient() -> FLIUser? {
        guard let selfId = TSAccountManager.localUID() else {
            Logger.debug("\(self.logTag): No stored localUID.")
            return nil
        }
        
        if let recipient:FLIUser = userCache.object(forKey: selfId as NSString) {
            return recipient
        } else if let recipient = FLIUser.fetch(uniqueId: selfId as String) {
            userCache.setObject(recipient, forKey: selfId as NSString)
            return recipient
        }
        return nil
    }
    
    @objc public class func recipientComparator() -> Comparator {
        return { obj1, obj2 in
            let contact1 = obj1 as? FLIUser
            let contact2 = obj2 as? FLIUser
            
            // Use lastname sorting
            return (contact1?.lastName!.caseInsensitiveCompare(contact2?.lastName ?? ""))!
        }
    }
    
    @objc public func doAfterEnvironmentInitSetup() {
    }

    @objc public func handleRecipientRefresh(notification: Notification) {
        if let payloadArray: Array<String> = notification.userInfo!["userIds"] as? Array<String> {
            self.serialLookupQueue.async {
                self.ccsmFetchRecipients(uids: payloadArray)
            }
        }
    }
    
    @objc public func handleTagRefresh(notification: Notification) {
        if let payloadArray: Array<String> = notification.userInfo!["tagIds"] as? Array<String> {
            self.serialLookupQueue.async {
                for uid: String in payloadArray {
                    self.ccsmFetchTag(tagId: uid)
                }
            }
        }
    }
    
    fileprivate func updateRecipients(userIds: Array<String>) {
        NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLRecipientsNeedRefreshNotification),
                                                             object: self,
                                                             userInfo: ["userIds" : userIds])
    }

    fileprivate func updateTags(tagIds: Array<String>) {
        NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLTagsNeedRefreshNotification),
                                                             object: self,
                                                             userInfo: ["tagIds" : tagIds])
    }

    fileprivate func ccsmFetchTag(tagId: String) {
        // must not execute on main thread
        assert(!Thread.isMainThread)

        // Ensure there isn't already a lookup taking place fo this id
        guard !self.pendingTagIds.contains(tagId) else {
            Logger.debug("Skippinig lookup for pending tagId: \(tagId)")
            return
        }
        
        self.pendingTagIds.insert(tagId)
        let homeURL = Bundle.main.object(forInfoDictionaryKey: "CCSM_Home_URL") as! String
        let urlString = "\(homeURL)/v1/tag/\(tagId)/"
        
        CCSMCommManager.getThing(urlString,
                                 success: { (payload) in
                                    if let _: String = payload?["id"] as? String {
                                        self.readWriteConnection .asyncReadWrite({ (transaction) in
                                            if let newTag: FLTag = FLTag.getOrCreateTag(with: payload!, transaction: transaction){
                                                self.save(tag: newTag, with: transaction)
                                            }
                                        })
                                    }
                                    self.pendingTagIds.remove(tagId)
        }, failure: { (error) in
            Logger.debug("CCSM User lookup failed with error: \(String(describing: error?.localizedDescription))")
            self.pendingTagIds.remove(tagId)
        })
    }

    
    fileprivate func ccsmFetchRecipients(uids: [String]) {
        
        // must not execute on main thread
        assert(!Thread.isMainThread)
        
        var idsToLookup = [String]()
        for uid in uids {
            if !self.pendingRecipientIds.contains(uid) {
                idsToLookup.append(uid)
                self.pendingRecipientIds.insert(uid)
            } else {
                Logger.debug("Skipping lookup for pending id: \(uid)")
            }
        }
        
        var lookupString: String = ""
        for uid in idsToLookup {
            if UUID.init(uuidString: uid) != nil {
                if lookupString.count == 0 {
                    lookupString = uid
                } else {
                    lookupString.append(",\(uid)")
                }
            }
        }
        if lookupString.count > 0 {
            
            let homeURL = Bundle.main.object(forInfoDictionaryKey: "CCSM_Home_URL") as! String
            let url = "\(homeURL)/v1/directory/user/?id_in=\(lookupString)"
            
            CCSMCommManager.getThing(url,
                                     success: { (payload) in
                                        
                                        if let resultsArray: Array = payload?["results"] as? Array<Dictionary<String, Any>> {
                                            self.readWriteConnection.asyncReadWrite({ (transaction) in
                                                for userDict: Dictionary<String, Any> in resultsArray {
                                                    if let recipient = FLIUser.getOrCreateRecipient(withUserDictionary: userDict as NSDictionary, transaction: transaction) {
                                                        self.save(recipient: recipient, with: transaction)
                                                    }
                                                }
                                            })
                                        }
                                        for uid in idsToLookup {
                                            self.pendingRecipientIds.remove(uid)
                                        }
            }, failure: { (error) in
                Logger.debug("CCSM User lookup failed with error: \(String(describing: error?.localizedDescription))")
                for uid in idsToLookup {
                    self.pendingRecipientIds.remove(uid)
                }
            })
            
        }
    }
    
    @objc public func tag(withId uuid: String) -> FLTag? {
        
        // Check the cache
        if let atag:FLTag = tagCache.object(forKey: uuid as NSString) {
            return atag
        } else if let atag = FLTag.fetch(uniqueId: uuid) {
            self.tagCache.setObject(atag, forKey: atag.uniqueId as NSString);
            return atag
        } else {
            NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLRecipientsNeedRefreshNotification),
                                            object: self, userInfo: [ "tagIds" : [uuid] ])
            return nil
        }
    }
    
    @objc public func tag(withId uuid: String, transaction: YapDatabaseReadTransaction) -> FLTag? {
        
        // Check the cache
        if let atag:FLTag = tagCache.object(forKey: uuid as NSString) {
            return atag
        } else if let atag: FLTag = FLTag.fetch(uniqueId: uuid, transaction: transaction) {
            tagCache.setObject(atag, forKey: uuid as NSString)
            return atag
        } else {
            NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLTagsNeedRefreshNotification),
                                                                 object: self, userInfo: [ "tagIds" : [uuid] ])
            return nil
        }
    }

    @objc public func user(uuid: String, context: NSManagedObjectContext) -> FLIUser? {

        let userFetch = FLIUser.fetchRequest()
        userFetch.predicate = NSPredicate.init(format: "uuid == %@)", uuid)
        
        var result: [ FLIUser ]
        do {
            result = try (context.fetch(fetchRequest))
        } catch {
            // FIXME: Add error handling
            return nil
        }
        
        if result.count > 0 {
            return result.last
        } else {
            return nil
        }
    }
    
    @objc public func tag(uuid: String, context: NSManagedObjectContext) -> FLITag? {
        
        let userFetch = FLITag.fetchRequest()
        userFetch.predicate = NSPredicate.init(format: "uuid == %@)", uuid)
        
        var result: [ FLITag ]
        do {
            result = try (context.fetch(fetchRequest))
        } catch {
            // FIXME: Add error handling
            return nil
        }
        
        if result.count > 0 {
            return result.last
        } else {
            return nil
        }
    }

    
    @objc public func refreshCCSMRecipients() {
        DispatchQueue.global(qos: .background).async {
            self.userCache.removeAllObjects()
            self.tagCache.removeAllObjects()
            CCSMCommManager.refreshCCSMData()
            self.validateNonOrgRecipients()
        }
    }
    
    private func validateNonOrgRecipients() {
        let nonOrgRecipients = FLIUser.allObjectsInCollection().filter() {
            if let recipient = ($0 as? FLIUser) {
                return (recipient.orgID != TSAccountManager.selfRecipient().orgID ||
                    recipient.orgID == "public" ||
                    recipient.orgID == "forsta" )
            } else {
                return false
            }
            } as! [FLIUser]
        
        if nonOrgRecipients.count > 0 {
            var recipientIds = [String]()
            for recipient in nonOrgRecipients {
                recipientIds.append(recipient.uniqueId)
            }
            NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLRecipientsNeedRefreshNotification),
                                                                 object: self,
                                                                 userInfo: ["userIds" : recipientIds])
        }
    }

    
    @objc public func setAvatarImage(image: UIImage, recipientId: String) {
        if let recipient = self.recipient(withId: recipientId) {
            recipient.avatarImage = image
            self.avatarCache.setObject(image, forKey: recipientId as NSString)
        }
    }
    
//    @objc public func image(forRecipientId uid: String) -> UIImage? {
//    }
    
//    @objc public func nameString(forRecipientId uid: String) -> String? {
//
//    }
    
    // MARK: - Recipient management
    @objc public func processRecipientsBlob() {
        let recipientsBlob: NSDictionary = CCSMStorage.sharedInstance().getUsers()! as NSDictionary
        DispatchQueue.global(qos: .background).async {
            for recipientDict in recipientsBlob.allValues {
                self.readWriteConnection.asyncReadWrite({ (transaction) in
                    if let recipient: FLIUser = FLIUser.getOrCreateRecipient(withUserDictionary: recipientDict as! NSDictionary, transaction: transaction) {
                        self.save(recipient: recipient, with: transaction)
                    }
                })
            }
        }
    }

    @objc public func save(recipient: FLIUser) {
        self.readWriteConnection.readWrite { (transaction) in
            self.save(recipient: recipient, with: transaction)
        }
    }
    
    @objc public func save(recipient: FLIUser, with transaction: YapDatabaseReadWriteTransaction) {
        recipient.save(with: transaction)
        if let aTag = recipient.flTag {
            aTag.save(with: transaction)
            self.tagCache.setObject(aTag, forKey: aTag.uniqueId as NSString)
        }
        self.userCache.setObject(recipient, forKey: recipient.uniqueId as NSString)
    }
    
    @objc public func remove(recipient: FLIUser) {
        self.readWriteConnection .readWrite { (transaction) in
            self.remove(recipient: recipient, with: transaction)
        }
    }
    
    @objc public func remove(recipient: FLIUser, with transaction: YapDatabaseReadWriteTransaction) {
        if let aTag = recipient.flTag {
            aTag.remove(with: transaction)
        }
        recipient.remove(with: transaction)
    }
    
    // MARK: - Tag management
    @objc public func processTagsBlob() {
        let tagsBlob: NSDictionary = CCSMStorage.sharedInstance().getTags()! as NSDictionary
        DispatchQueue.global(qos: .background).async {
            for tagDict in tagsBlob.allValues {
                self.readWriteConnection.asyncReadWrite({ (transaction) in
                    let aTag:FLTag = FLTag.getOrCreateTag(with: tagDict as! [AnyHashable : Any], transaction: transaction)!
                    if aTag.recipientIds?.count == 0 {
                        self.remove(tag: aTag, with: transaction)
                    } else {
                        self.save(tag: aTag, with: transaction)
                    }
                })
            }
        }
    }

    @objc public func save(tag: FLTag) {
        self.readWriteConnection.readWrite { (transaction) in
            self.save(tag: tag, with: transaction)
        }
    }
    
    @objc public func save(tag: FLTag, with transaction: YapDatabaseReadWriteTransaction) {
        tag.save(with: transaction)
        self.tagCache.setObject(tag, forKey: tag.uniqueId as NSString)
    }
    
    @objc public func remove(tag: FLTag) {
        self.readWriteConnection.readWrite { (transaction) in
            self.remove(tag: tag, with: transaction)
        }
    }
    
    @objc public func remove(tag: FLTag, with transaction: YapDatabaseReadWriteTransaction) {
        self.tagCache.removeObject(forKey: tag.uniqueId as NSString)
        tag.remove(with: transaction)
    }
    

    @objc public func nukeAndPave() {
        self.tagCache.removeAllObjects()
        self.userCache.removeAllObjects()
        FLIUser.removeAllObjectsInCollection()
        FLTag.removeAllObjectsInCollection()
    }
    
    @objc public func supportsContactEditing() -> Bool {
        return false
    }
    
    @objc public func isSystemContactsAuthorized() -> Bool {
        return false
    }
    
    @objc public func formattedDisplayName(forTagId tagId: String, font: UIFont) -> NSAttributedString? {

        if let aTag = self.tag(withId:tagId) {
            var rawName: String
            if aTag.recipientIds?.count == 1 {
                rawName = self.displayName(forRecipientId: aTag.recipientIds?.anyObject() as! String)!
            } else if aTag.tagDescription != nil {
                rawName = aTag.tagDescription!
            } else {
                rawName = aTag.displaySlug
            }
            
            let normalFontAttributes = [NSAttributedStringKey.font: font, NSAttributedStringKey.foregroundColor: Theme.primaryColor]
            let attrName = NSAttributedString(string: rawName, attributes: normalFontAttributes as [NSAttributedStringKey : Any])
            return attrName
        }
        return nil
    }

    
    @objc public func formattedFullName(forRecipientId recipientId: String, font: UIFont) -> NSAttributedString? {
        
        if let recipient = self.recipient(withId: recipientId) {
            let rawName = recipient.fullName()
            
            let normalFontAttributes = [NSAttributedStringKey.font: font, NSAttributedStringKey.foregroundColor: Theme.primaryColor]
            
            let attrName = NSAttributedString(string: rawName, attributes: normalFontAttributes as [NSAttributedStringKey : Any])

            return attrName
        }
        return nil
    }
    
    // MARK: - Gravatar handling
    fileprivate static let kGravatarURLFormat = "https://www.gravatar.com/avatar/%@?s=128&d=404"
    
    @objc public func fetchGravtarForRecipient(notification: Notification) {
        
        DispatchQueue.global(qos: .background).async {
            guard let recipientId = notification.userInfo!["recipientId"] as? String else {
                Logger.debug("Request to fetch gravatar without recipientId")
                return
            }
            guard let recipient = self.recipient(withId: recipientId) else {
                Logger.debug("Request to fetch gravatar for unknown recipientId: \(recipientId)")
                return
            }
            guard let gravatarHash = recipient.gravatarHash else {
                Logger.debug("No gravatar hash for recipient: \(recipientId)")
                return
            }
            let gravatarURLString = String(format: FLIUserManager.kGravatarURLFormat, gravatarHash)
            guard let aURL = URL.init(string: gravatarURLString) else {
                Logger.debug("Unable to form URL from gravatar string: \(gravatarURLString)")
                return
            }
            guard let gravarData = try? Data(contentsOf: aURL) else {
                Logger.error("Unable to parse Gravatar image with hash: \(String(describing: gravatarHash))")
                return
            }
            guard let gravatarImage = UIImage(data: gravarData) else {
                Logger.debug("Failed to generate image from fetched gravatar data for recipient: \(recipientId)")
                return
            }
            let cacheKey = "gravatar:\(recipientId)" as NSString
            self.avatarCache.setObject(gravatarImage, forKey: cacheKey)
            
            OWSPrimaryStorage.shared().dbReadWriteConnection.asyncReadWrite({ (transaction) in
                recipient.applyChange(toSelfAndLatestCopy: transaction, change: { (obj) in
                    if let theRecipient = obj as? FLIUser {
                        theRecipient.gravatarImage = gravatarImage
                    }
                })
            });
            
//            recipient.gravatarImage = gravatarImage
//            self.save(recipient: recipient)
        }
    }
    
    // MARK: - db modifications
    @objc func yapDatabaseModified(notification: Notification?) {
        
        DispatchQueue.global(qos: .background).async {
            let notifications = self.readConnection.beginLongLivedReadTransaction()
            
            self.readConnection.enumerateChangedKeys(inCollection: FLIUser.collection(),
                                                     in: notifications) { (recipientId, stop) in
                                                        // Remove cached recipient
                                                        self.userCache.removeObject(forKey: recipientId as NSString)
                                                        
                                                        // Touch any threads which contain the recipient
                                                        var threadsToTouch = [TSThread]()
                                                        for obj in TSThread.allObjectsInCollection() {
                                                            if let thread = obj as? TSThread {
                                                                if thread.participantIds.contains(recipientId) {
                                                                    threadsToTouch.append(thread)
                                                                }
                                                            }
                                                        }
                                                        if threadsToTouch.count > 0 {
                                                            self.readWriteConnection.asyncReadWrite({ (transaction) in
                                                                for thread in threadsToTouch {
                                                                    thread.touch(with: transaction)
                                                                }
                                                            })
                                                        }
                                                        
            }
            
            self.readConnection.enumerateChangedKeys(inCollection: FLTag.collection(),
                                                     in: notifications) { (recipientId, stop) in
                                                        // Remove cached tag
                                                        self.tagCache.removeObject(forKey: recipientId as NSString)
            }
        }
    }
}



extension FLIUserManager : NSCacheDelegate {

    public func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        // called when objects evicted from any of the caches
    }
}
