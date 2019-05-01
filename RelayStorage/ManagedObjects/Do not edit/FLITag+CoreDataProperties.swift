//
//  FLITag+CoreDataProperties.swift
//  
//
//  Created by Mark Descalzo on 5/1/19.
//
//

import Foundation
import CoreData


extension FLITag {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<FLITag> {
        return NSFetchRequest<FLITag>(entityName: "FLITag")
    }

    @NSManaged public var avatar: NSData?
    @NSManaged public var hiddenDate: NSDate?
    @NSManaged public var orgUrl: String?
    @NSManaged public var orgSlug: String?
    @NSManaged public var slug: String?
    @NSManaged public var tagDescription: String?
    @NSManaged public var url: String?
    @NSManaged public var users: NSSet?

}

// MARK: Generated accessors for users
extension FLITag {

    @objc(addUsersObject:)
    @NSManaged public func addToUsers(_ value: FLIUser)

    @objc(removeUsersObject:)
    @NSManaged public func removeFromUsers(_ value: FLIUser)

    @objc(addUsers:)
    @NSManaged public func addToUsers(_ values: NSSet)

    @objc(removeUsers:)
    @NSManaged public func removeFromUsers(_ values: NSSet)

}
