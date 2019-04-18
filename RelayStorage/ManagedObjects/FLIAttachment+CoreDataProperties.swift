//
//  FLIAttachment+CoreDataProperties.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData


extension FLIAttachment {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<FLIAttachment> {
        return NSFetchRequest<FLIAttachment>(entityName: "FLIAttachment")
    }

    @NSManaged public var data: NSData?
    @NSManaged public var name: String?
    @NSManaged public var message: FLIMessage?

}
