//
//  FLIMessage+CoreDataProperties.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData


extension FLIMessage {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<FLIMessage> {
        return NSFetchRequest<FLIMessage>(entityName: "FLIMessage")
    }

    @NSManaged public var deliveryStateMap: NSObject?
    @NSManaged public var direction: String?
    @NSManaged public var plainText: String?
    @NSManaged public var sentDate: NSDate?
    @NSManaged public var state: String?
    @NSManaged public var type: String?
    @NSManaged public var attachments: FLIAttachment?
    @NSManaged public var sender: FLIUser?
    @NSManaged public var thread: FLIThread?

}
