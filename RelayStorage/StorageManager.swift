//
//  StorageManager.swift
//  RelayServiceKit
//
//  Created by Mark Descalzo on 4/15/19.
//  Copyright © 2019 Forsta Labs, Inc. All rights reserved.
//

import Foundation
import CoreData
import SignalProtocol

@objc
public class StorageManager : NSObject, PreKeyStore, SessionStore, SignedPreKeyStore {
    
    @objc public static let shared = StorageManager()
    
    @objc lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "ForstaRelay1")
        container.loadPersistentStores(completionHandler: {
            (storeDescription, error) in
            print("\(storeDescription)")
            if let error = error as NSError? {
                fatalError("Fatal error loading CoreData persistent store: \(error), \(error.userInfo)")
            }
        })
        return container
    }()
    
    @objc public lazy var mainContext: NSManagedObjectContext = {
        let context = self.persistentContainer.viewContext
        context.automaticallyMergesChangesFromParent = true
        return context
    }()
    
    private static let PrekeyStoreSpace = "PrekeyStoreSpace"
    private static let SessionRecordSpace = "SessionRecordSpace"
    private static let IdentityKeyStoreSpace = "IdentityKeyStoreSpace"
    private static let SignedPreKeyStoreSpace = "SignedPreKeyStoreSpace"

    
    @objc override init() {
         super.init()
    }
    
    @objc deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - External interface
    @objc public func fetchObject(uuid: String, context: NSManagedObjectContext) -> BaseChatObject? {

        let fetchRequest: NSFetchRequest<BaseChatObject> = BaseChatObject.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "uuid = %@", uuid)
        
        var object: BaseChatObject? = nil
        do {
            let results = try context.fetch(fetchRequest)
            if results.count == 1 {
                object = results.first!
            } else if results.count > 1 {
                fatalError("\(#function): should never return more than one object: \(results)")
            }
        } catch {
            let nserror = error as NSError
            fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
        }
        return object
    }

    @objc public func set(namespace: String, key: AnyHashable, content: Data, protocolContext: Any? = nil) throws {
        var context: NSManagedObjectContext? = protocolContext as? NSManagedObjectContext
        if protocolContext == nil {
            context = self.persistentContainer.newBackgroundContext()
            context!.automaticallyMergesChangesFromParent = true
        }
        
        let storageKey = [namespace, key]
        let fetchRequest: NSFetchRequest<ProtocolObject> = ProtocolObject.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "key == %@", storageKey)
        
        var object: ProtocolObject? = nil
        do {
            let result: [ProtocolObject] = try (context!.fetch(fetchRequest))
            guard result.count <= 1 else {
                // FIXME: Throw error here
                return
            }
            if result.count == 1 {
                object = result.last
            }
        } catch {
            // FIXME: Throw error here
            return
        }
        if object == nil {
            object = ProtocolObject(context: context!)
            object!.key = storageKey as NSObject
        }
        object!.data = content as NSData
        saveContext(context!)
    }
    
    @objc public func get(namespace: String, key: AnyHashable, protocolContext: Any? = nil) -> Data? {
        var context: NSManagedObjectContext? = protocolContext as? NSManagedObjectContext
        if protocolContext == nil {
            context = self.persistentContainer.newBackgroundContext()
            context!.automaticallyMergesChangesFromParent = true
        }
        
        let storageKey = [namespace, key]
        let fetchRequest: NSFetchRequest<ProtocolObject> = ProtocolObject.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "key == %@", storageKey)
        
        var object: ProtocolObject? = nil
        do {
            let result: [ProtocolObject] = try (context!.fetch(fetchRequest))
            guard result.count <= 1 else {
                // FIXME: Throw error here
                return nil
            }
            object = result.last
        } catch {
            // FIXME: Throw error here
            return nil
        }
        return object?.data as Data?
    }
    
    @objc public func allKeys(namespace: String, protocolContext: Any? = nil) -> [AnyHashable] {
        var context: NSManagedObjectContext? = protocolContext as? NSManagedObjectContext
        if protocolContext == nil {
            context = self.persistentContainer.newBackgroundContext()
            context!.automaticallyMergesChangesFromParent = true
        }
        return [AnyHashable]()
    }
    
    @objc public func has(namespace: String, key: AnyHashable, protocolContext: Any? = nil) -> Bool {
        var context: NSManagedObjectContext? = protocolContext as? NSManagedObjectContext
        if protocolContext == nil {
            context = self.persistentContainer.newBackgroundContext()
            context!.automaticallyMergesChangesFromParent = true
        }
        
        let storageKey = [namespace, key]
        let fetchRequest: NSFetchRequest<ProtocolObject> = ProtocolObject.fetchRequest()
        fetchRequest.resultType = .managedObjectIDResultType
        fetchRequest.predicate = NSPredicate(format: "key == %@", storageKey)
        
        do {
            let result: [ProtocolObject] = try (context!.fetch(fetchRequest))
            return (result.count > 0)
        } catch {
            // FIXME: Throw error here
            return false
        }
    }
    
    @objc public func remove(namespace: String, key: AnyHashable, protocolContext: Any? = nil) throws {
        var context: NSManagedObjectContext? = protocolContext as? NSManagedObjectContext
        if protocolContext == nil {
            context = self.persistentContainer.newBackgroundContext()
            context!.automaticallyMergesChangesFromParent = true
        }
        let storageKey = [namespace, key]
        let fetchRequest: NSFetchRequest<ProtocolObject> = ProtocolObject.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "key == %@", storageKey)
        
        var object: ProtocolObject? = nil
        do {
            let result: [ProtocolObject] = try (context!.fetch(fetchRequest))
            guard result.count <= 1 else {
                // FIXME: Throw error here
                return
            }
            if result.count == 1 {
                object = result.last
            }
        } catch {
            // FIXME: Throw error here
            return
        }
        guard object != nil else {
            return
        }
        context!.delete(object!)
        saveContext(context!)
    }
    
    @objc public func saveMainContext() {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
                
            } catch {
                if let error = error as NSError? {
                    fatalError("Fatal error loading CoreData persistent store: \(error), \(error.userInfo)")
                }
            }
        }
    }
    
    @objc public func saveContext(_ context: NSManagedObjectContext) {
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                if let error = error as NSError? {
                    fatalError("Fatal error loading CoreData persistent store: \(error), \(error.userInfo)")
                }
            }
        }
    }
    
    // FIXME: This is probably a bad approach.  Make whatever uses this build a child context of this main context.
    @objc public func newBackgroundContext() -> NSManagedObjectContext {
        let context: NSManagedObjectContext = persistentContainer.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = true
        return persistentContainer.newBackgroundContext()
    }
    
    // MARK: - PreKeyStore protocol
    public var lastId: UInt32 = 0
    
    public func preKey(for id: UInt32) throws -> Data {
        guard let keyData = get(namespace: StorageManager.PrekeyStoreSpace, key: id, protocolContext: nil) else {
            throw SignalError(.storageError, "No pre key for id \(id)")
        }
        return keyData
    }
    
    public func store(preKey: Data, for id: UInt32) throws {
        try set(namespace: StorageManager.PrekeyStoreSpace, key: id, content: preKey, protocolContext: nil)
        lastId = id
    }
    
    public func containsPreKey(for id: UInt32) -> Bool {
        return has(namespace: StorageManager.PrekeyStoreSpace, key: id, protocolContext: nil)
    }
    
    public func removePreKey(for id: UInt32) throws {
        try remove(namespace: StorageManager.PrekeyStoreSpace, key: id, protocolContext: nil)
    }

    // MARK: - SessionStore protocol
    public typealias Address = SignalAddress
    
    public func loadSession(for address: StorageManager.Address) throws -> Data? {
        guard let storedSessionData = get(namespace: StorageManager.SessionRecordSpace, key: address, protocolContext: nil) else {
            throw SignalError(.storageError, "No session for id \(address)")
        }
        return storedSessionData
    }
    
    public func store(session: Data, for address: StorageManager.Address) throws {
        try set(namespace: StorageManager.SessionRecordSpace, key: address, content: session, protocolContext: nil)
    }
    
    public func containsSession(for address: StorageManager.Address) -> Bool {
        return has(namespace: StorageManager.SessionRecordSpace, key: address, protocolContext: nil)
    }
    
    public func deleteSession(for address: StorageManager.Address) throws {
        try remove(namespace: StorageManager.SessionRecordSpace, key: address, protocolContext: nil)
    }

    // MARK: - SignedPreKeyStore protocol
    public func store(signedPreKey: Data, for id: UInt32) throws {
        try set(namespace: StorageManager.SignedPreKeyStoreSpace, key: id, content: signedPreKey, protocolContext: nil)
    }
    
    public func signedPreKey(for id: UInt32) throws -> Data {
        guard let key = get(namespace: StorageManager.SignedPreKeyStoreSpace, key: id, protocolContext: nil) else {
            throw SignalError(.invalidId, "No signed pre key for id \(id)")
        }
        return key
    }
    
    public func containsSignedPreKey(for id: UInt32) throws -> Bool {
        return has(namespace: StorageManager.SignedPreKeyStoreSpace, key: id, protocolContext: nil)
    }
    
    public func removeSignedPreKey(for id: UInt32) throws {
        try remove(namespace: StorageManager.SignedPreKeyStoreSpace, key: id, protocolContext: nil)
    }
    
    public func allIds() throws -> [UInt32] {
        if let allIds = allKeys(namespace: StorageManager.SignedPreKeyStoreSpace, protocolContext: nil) as? [UInt32] {
            return allIds
        } else {
            return [UInt32]()
        }
    }
    
    // MARK: - IdentityKeyStore protocol
    func getIdentityKeyData() throws -> Data {
        // FIXME: Retrive self ID and Device FIRST
        let address = SignalAddress(identifier: "selfId", deviceId: 1)
        return try identity(for: address) ?? SignalCrypto.generateIdentityKeyPair()
    }
    
    func identity(for address: SignalAddress) throws -> Data? {
        return get(namespace: StorageManager.IdentityKeyStoreSpace, key: address, protocolContext: nil)
    }
    
    func store(identity: Data?, for address: SignalAddress) throws {
        // TODO: Does passing nil data imply a desire to delete the identity
        if let data = identity {
            try set(namespace: StorageManager.IdentityKeyStoreSpace, key: address, content: data, protocolContext: nil)
        } else {
            try remove(namespace: StorageManager.IdentityKeyStoreSpace, key: address, protocolContext: nil)
        }
    }
}
