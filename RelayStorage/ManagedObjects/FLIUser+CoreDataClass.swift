//
//  FLIUser+CoreDataClass.swift
//  
//
//  Created by Mark Descalzo on 4/18/19.
//
//

import Foundation
import CoreData

@objc(FLIUser)
public class FLIUser: BaseChatObject {

    @objc public func fullName() -> String {
        if firstName != nil && lastName != nil {
            return "\(firstName!) \(lastName!)"
        } else if lastName != nil {
            return lastName!
        } else if firstName != nil {
            return firstName!
        } else {
            return "No Name"
        }
    }

}
