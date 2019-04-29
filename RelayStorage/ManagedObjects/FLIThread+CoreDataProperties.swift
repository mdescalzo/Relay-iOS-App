//
//  FLIThread+CoreDataProperties.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData


extension FLIThread {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<FLIThread> {
        return NSFetchRequest<FLIThread>(entityName: "FLIThread")
    }

    @NSManaged public var archiveDate: NSDate?
    @NSManaged public var avatar: NSData?
    @NSManaged public var expression: String?
    @NSManaged public var mutedUntilDate: NSDate?
    @NSManaged public var pinPosition: Int16
    @NSManaged public var pretty: String?
    @NSManaged public var title: String?
    @NSManaged public var type: String?
    @NSManaged public var visible: Bool
    @NSManaged public var pinned: Bool
    @NSManaged public var currentMonitors: NSSet?
    @NSManaged public var currentParticipants: NSSet?
    @NSManaged public var messages: NSSet?

}

// MARK: Generated accessors for currentMonitors
extension FLIThread {

    @objc(addCurrentMonitorsObject:)
    @NSManaged public func addToCurrentMonitors(_ value: FLIUser)

    @objc(removeCurrentMonitorsObject:)
    @NSManaged public func removeFromCurrentMonitors(_ value: FLIUser)

    @objc(addCurrentMonitors:)
    @NSManaged public func addToCurrentMonitors(_ values: NSSet)

    @objc(removeCurrentMonitors:)
    @NSManaged public func removeFromCurrentMonitors(_ values: NSSet)

}

// MARK: Generated accessors for currentParticipants
extension FLIThread {

    @objc(addCurrentParticipantsObject:)
    @NSManaged public func addToCurrentParticipants(_ value: FLIUser)

    @objc(removeCurrentParticipantsObject:)
    @NSManaged public func removeFromCurrentParticipants(_ value: FLIUser)

    @objc(addCurrentParticipants:)
    @NSManaged public func addToCurrentParticipants(_ values: NSSet)

    @objc(removeCurrentParticipants:)
    @NSManaged public func removeFromCurrentParticipants(_ values: NSSet)

}

// MARK: Generated accessors for messages
extension FLIThread {

    @objc(addMessagesObject:)
    @NSManaged public func addToMessages(_ value: FLIMessage)

    @objc(removeMessagesObject:)
    @NSManaged public func removeFromMessages(_ value: FLIMessage)

    @objc(addMessages:)
    @NSManaged public func addToMessages(_ values: NSSet)

    @objc(removeMessages:)
    @NSManaged public func removeFromMessages(_ values: NSSet)

}
