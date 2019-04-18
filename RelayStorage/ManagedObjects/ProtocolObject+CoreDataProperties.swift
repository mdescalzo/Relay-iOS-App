//
//  ProtocolObject+CoreDataProperties.swift
//  
//
//  Created by Mark Descalzo on 4/17/19.
//
//

import Foundation
import CoreData


extension ProtocolObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<ProtocolObject> {
        return NSFetchRequest<ProtocolObject>(entityName: "ProtocolObject")
    }

    @NSManaged public var key: NSObject?
    @NSManaged public var data: NSData?

}
