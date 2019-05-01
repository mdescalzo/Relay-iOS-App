//
//  UserManager.swift
//  RelayMessaging
//
//  Created by Mark Descalzo on 8/14/18.
//  Copyright © 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import RelayStorage
import SignalCoreKit
import CoreData
import LetterAvatarKit

@objc public class UserManager: NSObject {

    private static let shared = UserManager()

    private let avatarCache = NSCache<NSString, UIImage>()
//    private let userCache: NSCache<NSString, FLIUser>
//    private let tagCache: NSCache<NSString, FLITag>
    
    private lazy var localContext: NSManagedObjectContext = {
        let aContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        aContext.parent = StorageManager.shared.mainContext
        aContext.automaticallyMergesChangesFromParent = true
        return aContext
    }()

    @objc
    public class func displayName(userId: String) -> String {
        if let user: FLIUser = UserManager.shared.fetchUser(uuid: userId, context: UserManager.shared.localContext) {
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
    
    public class func image(userId: String) -> UIImage? {
        
        var cacheKey: NSString? = nil
        
        let useGravatars: Bool = Environment.preferences().useGravatars()
        
        if useGravatars {
            cacheKey = "gravatar:\(userId)" as NSString
        } else {
            cacheKey = "avatar:\(userId)" as NSString
        }
        
        // Check the avatarCache...
        if let image = shared.avatarCache.object(forKey: cacheKey!) {
            return image;
        }
        
        // Check local storage
        guard let user = shared.fetchUser(uuid: userId, context: shared.localContext) else {
            Logger.debug("Attempt to get avatar image for unknown recipient: \(userId)")
            return nil
        }

        if useGravatars {
            // Post a notification to fetch the gravatar image so it doesn't block and then fall back to default
            // FIXME: Wire this notification back up
//            NotificationCenter.default.postNotificationNameAsync(NSNotification.Name(rawValue: FLRecipientNeedsGravatarFetched),
//                                                                 object: self,
//                                                                 userInfo: ["userId" : recipientId ])
        }
        
        if user.avatar != nil,
            let image = UIImage(data: user.avatar! as Data) {
            shared.avatarCache.setObject(image, forKey: cacheKey!)
            return image
        } else if let image = UIImage.makeLetterAvatar(withUsername: user.fullName(), size: CGSize(width: 128.0, height: 128.0)) {
            shared.avatarCache.setObject(image, forKey: cacheKey!)
            return image
        } else {
            return nil
        }
    }
    
    private let serialLookupQueue = DispatchQueue(label: "contactsManagerLookupQueue")
    
    private var latestRecipientsById: [AnyHashable : Any] = [:]
    private var activeRecipientsBacker: [ FLIUser ] = []
    private var visibleRecipientsPredicate: NSCompoundPredicate?
    private var pendingTagIds = Set<String>()
    private var pendingRecipientIds = Set<String>()
    
    @objc public func flushAvatarCache() {
        avatarCache.removeAllObjects()
    }

    override init() {

        super.init()
        
        // FIXME: Bring these back as necessary
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(self.processRecipientsBlob),
//                                               name: NSNotification.Name(rawValue: FLCCSMUsersUpdated),
//                                               object: nil)
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(self.processTagsBlob),
//                                               name: NSNotification.Name(rawValue: FLCCSMTagsUpdated),
//                                               object: nil)
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(self.handleRecipientRefresh(notification:)),
//                                               name: NSNotification.Name(rawValue: FLRecipientsNeedRefreshNotification),
//                                               object: nil)
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(self.handleTagRefresh(notification:)),
//                                               name: NSNotification.Name(rawValue: FLTagsNeedRefreshNotification),
//                                               object: nil)
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(self.fetchGravtarForRecipient(notification:)),
//                                               name: NSNotification.Name(rawValue: FLRecipientNeedsGravatarFetched),
//                                               object: nil)
//        NotificationCenter.default.addObserver(self,
//                                               selector: #selector(yapDatabaseModified),
//                                               name: NSNotification.Name.YapDatabaseModified,
//                                               object: nil)
        avatarCache.delegate = self
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // FIXME: Replace usage of this with FetchedResultsController
    @objc public func allTags() -> [FLITag] {
        return [FLITag]()
    }
    
    // FIXME: Replace usage of this with FetchedResultsController
    @objc public func allUsers() -> [FLIUser] {
        return [FLIUser]()
    }

    @objc public func localUserId() -> String? {
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
        NotificationCenter.default.post(NSNotification.Name(rawValue: FLIRecipientsNeedRefreshNotification),
                                        object: self,
                                        userInfo: ["userIds" : userIds])
    }
    
    fileprivate func updateTags(tagIds: Array<String>) {
        NotificationCenter.default.post(NSNotification.Name(rawValue: FLITagsNeedRefreshNotification),
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
    
    @objc public func fetchTag(uuid: String, context: NSManagedObjectContext) -> FLITag? {
        if let aTag = StorageManager.shared.fetchObject(uuid: uuid, context: context) as? FLITag {
            return aTag
        } else {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "FLITagsNeedRefreshNotification"),
                                            object: self,
                                            userInfo: [ "tagIds" : [uuid] ])
            return nil
        }
    }
    
    @objc public func fetchUser(uuid: String, context: NSManagedObjectContext) -> FLIUser? {
        if let user = StorageManager.shared.fetchObject(uuid: uuid, context: context) as? FLIUser {
            return user
        } else {
            NotificationCenter.default.post(name: NSNotification.Name(rawValue: "FLIUsersNeedRefreshNotification"),
                                            object: self,
                                            userInfo: [ "userIds" : [uuid] ])
            return nil
        }
    }
    
    @objc public func refreshCCSMRecipients() {
        DispatchQueue.global(qos: .background).async {
            self.userCache.removeAllObjects()
            self.tagCache.removeAllObjects()
            CCSMCommManager.refreshCCSMData()
            self.validateNonOrgUsers()
        }
    }
    
    private func validateNonOrgUsers() {
        // FIXME: Get local user orgId string
        let localOrgId = "anId"
        let workingContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        workingContext.parent = self.localContext
        workingContext.automaticallyMergesChangesFromParent = true

        let fetchRequest: NSFetchRequest<FLIUser> = FLIUser.fetchRequest()
        fetchRequest.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "orgId != %@", localOrgId),
            NSPredicate(format: "orgId == %@", "forsta"),
            NSPredicate(format: "orgId == %@", "public"),
            ])
//            NSPredicate(format: "uuid = %@", uuid)
        
        var results = [FLIUser]()
        do {
            results = try workingContext.fetch(fetchRequest)
        } catch {
            let nserror = error as NSError
            fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
        }
        
        if results.count > 0 {
            var userIds = [String]()
            for user in results {
                userIds.append(user.uuid!)
            }
            NotificationCenter.default.post(NSNotification.Name(rawValue: FLIRecipientsNeedRefreshNotification),
                                                                 object: self,
                                                                 userInfo: ["userIds" : userIds])
        }
    }

    // MARK: - User management
    @objc public func user(dictionary: [String: AnyObject], context: NSManagedObjectContext) -> FLIUser? {
        guard let userId = dictionary["id"] as? String else {
            Logger.debug("\(self.logTag): Attempt to create user with missing userId.")
            return nil
        }
        
        var user: FLIUser?
        user = self.fetchUser(uuid: userId, context: context)
        if user == nil {
            user = FLIUser(context: context)
            user!.uuid = userId
        }
        guard user != nil else {
            Logger.debug("\(self.logTag): Failed to create or fetch a user with id: \(userId).")
            return nil
        }

        // Set properties
        if dictionary["is_active"] as? NSNumber == 0 {
            user?.isActive = false
        } else {
            user?.isActive = true
        }
        if let firstname = dictionary["first_name"] as? String { user?.firstName = firstname }
        if let lastname = dictionary["last_name"] as? String { user?.lastName = lastname }
        if let email = dictionary["email"] as? String { user?.emailAddress = email }
        if let phone = dictionary["phone"] as? String { user?.phoneNumber = phone }
        if let gravatar = dictionary["gravatar_hash"] as? String { user?.gravtarHash = gravatar }

        StorageManager.shared.saveContext(context)
        return user
    }
    
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


    @objc public func remove(recipient: FLIUser) {
        self.readWriteConnection .readWrite { (transaction) in
            self.remove(recipient: recipient, with: transaction)
        }
    }
    
    // MARK: - Tag management
    @objc public func tag(dictionary: [String: AnyObject], context: NSManagedObjectContext) -> FLITag? {
        // Check for existing tag with id
        guard let tagId = dictionary[FLITagIdKey] as? String else {
            Logger.debug("\(self.logTag): Attempt to create tag with missing tagId.")
            return nil
        }
        var aTag: FLITag?
        aTag = self.fetchTag(uuid: tagId, context: context)
        if aTag == nil {
            aTag = FLITag(context: context)
            aTag.uuid = tagId
        }
        guard aTag != nil else {
            Logger.debug("\(self.logTag): Failed to create or fetch a tag id: \(tagId).")
            return nil
        }
        
        // Set properties
        if let tagUrl = dictionary[FLITagURLKey] as? String { aTag.url = tagUrl }
        if let tagDescription = dictionary[FLITagDescriptionKey] as? String { aTag?.tagDescription = tagDescription }
        if let tagSlug = dictionary[FLITagSlugKey] as? String { aTag?.slug = tagSlug }
        if let orgDict = dictionary[FLTagOrgKey] {
            if let orgSlug = orgDict[FLTagSlugKey] { aTag?.orgSlug = orgSlug }
            if let orgUrl = orgDict[FLTagURLKey] { aTag?.orgUrl = orgSlug }
        }

        // Build User association
        var userIds = [String]()
        if let object = dictionary["user"] as? Dictionary<AnyHashable, AnyObject> {
            if let uid = object[FLTagIdKey] as? String {
                userIds.append(uid)
            }
        }
        if let users = dictionary[FLTagUsersKey] as? Dictionary<AnyHashable, AnyObject> {
            for object in users {
                if let dict = object as? [String: AnyObject] {
                    if let associationType = dict["association_type"] as? String {
                        if associationType == "MEMBEROF" {
                            if let userId = dict["user"] as? String {
                                userIds.append(userId)
                            }
                        }
                    }
                }
            }
        }
        for userId in userIds {
            if let user = self.fetchUser(uuid: userId, context: context) {
                if !(aTag?.users?.contains(user))! {
                    aTag?.addToUsers(user)
                }
            }
        }
        StorageManager.shared.saveContext(context)
        return aTag
    }

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

    @objc public func remove(tag: FLTag) {
        self.readWriteConnection.readWrite { (transaction) in
            self.remove(tag: tag, with: transaction)
        }
    }
    
    

    @objc public func nukeAndPave() {
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

        if let aTag = self.fetchTag(uuid: tagId, context: localContext) {
            var rawName: String
            if aTag.users?.count == 1,
                let user = aTag.users?.anyObject() as? FLIUser {
                rawName = user.fullName()
            } else if aTag.tagDescription != nil {
                rawName = aTag.tagDescription!
            } else {
                rawName = aTag.slug!
            }
            
            let normalFontAttributes = [NSAttributedStringKey.font: font, NSAttributedStringKey.foregroundColor: Theme.primaryColor]
            let attrName = NSAttributedString(string: rawName, attributes: normalFontAttributes as [NSAttributedStringKey : Any])
            return attrName
        }
        return nil
    }

    
    @objc public func formattedDisplayName(userId: String, font: UIFont) -> NSAttributedString? {
        
        if let user = self.fetchUser(uuid: userId, context: localContext) {
            let rawName = user.fullName()
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
            let workingContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            workingContext.parent = self.localContext
            workingContext.automaticallyMergesChangesFromParent = true
            
            guard let userId = notification.userInfo!["userId"] as? String else {
                Logger.debug("Request to fetch gravatar without userId")
                return
            }
            guard let user = self.fetchUser(uuid: userId, context: workingContext) else {
                Logger.debug("Request to fetch gravatar for unknown recipientId: \(userId)")
                return
            }
            guard let gravatarHash = user.gravtarHash else {
                Logger.debug("No gravatar hash for recipient: \(userId)")
                return
            }
            let gravatarURLString = String(format: UserManager.kGravatarURLFormat, gravatarHash)
            guard let aURL = URL.init(string: gravatarURLString) else {
                Logger.debug("Unable to form URL from gravatar string: \(gravatarURLString)")
                return
            }
            guard let gravarData = try? Data(contentsOf: aURL) else {
                Logger.error("Unable to parse Gravatar image with hash: \(String(describing: gravatarHash))")
                return
            }
            guard let gravatarImage = UIImage(data: gravarData) else {
                Logger.debug("Failed to generate image from fetched gravatar data for recipient: \(userId)")
                return
            }
            let cacheKey = "gravatar:\(userId)" as NSString
            self.avatarCache.setObject(gravatarImage, forKey: cacheKey)
            
            // FIXME: Add the gravatar image the local store or post a notification that the gravatar download is complete
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



extension UserManager : NSCacheDelegate {

    public func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        // called when objects evicted from any of the caches
    }
}
