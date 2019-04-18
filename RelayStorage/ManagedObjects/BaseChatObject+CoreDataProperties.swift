//
//  BaseChatObject+CoreDataProperties.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData


extension BaseChatObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<BaseChatObject> {
        return NSFetchRequest<BaseChatObject>(entityName: "BaseChatObject")
    }

    @NSManaged public var uuid: String?

}
