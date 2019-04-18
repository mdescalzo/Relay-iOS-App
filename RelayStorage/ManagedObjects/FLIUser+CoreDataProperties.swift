//
//  FLIUser+CoreDataProperties.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData


extension FLIUser {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<FLIUser> {
        return NSFetchRequest<FLIUser>(entityName: "FLIUser")
    }

    @NSManaged public var avatar: NSData?
    @NSManaged public var devices: NSObject?
    @NSManaged public var emailAddress: String?
    @NSManaged public var firstName: String?
    @NSManaged public var gravtarHash: String?
    @NSManaged public var hiddenDate: NSDate?
    @NSManaged public var isActive: Bool
    @NSManaged public var isMonitor: Bool
    @NSManaged public var lastName: String?
    @NSManaged public var notes: String?
    @NSManaged public var orgId: String?
    @NSManaged public var orgSlug: String?
    @NSManaged public var phoneNumber: String?
    @NSManaged public var primaryTagId: String?
    @NSManaged public var messages: NSSet?
    @NSManaged public var tags: NSSet?

}

// MARK: Generated accessors for messages
extension FLIUser {

    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: FLIMessage)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: FLIMessage)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)

}

// MARK: Generated accessors for tags
extension FLIUser {

    @objc(addTagsObject:)
    @NSManaged public func addToTags(_ value: FLITag)

    @objc(removeTagsObject:)
    @NSManaged public func removeFromTags(_ value: FLITag)

    @objc(addTags:)
    @NSManaged public func addToTags(_ values: NSSet)

    @objc(removeTags:)
    @NSManaged public func removeFromTags(_ values: NSSet)

}
