//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSPrimaryStorage+PreKeyStore.h"
#import "OWSPrimaryStorage+keyFromIntLong.h"
#import "TSStorageKeys.h"
#import "YapDatabaseConnection+OWS.h"
#import <AxolotlKit/AxolotlExceptions.h>
#import <AxolotlKit/SessionBuilder.h>

#define OWSPrimaryStoragePreKeyStoreCollection @"TSStorageManagerPreKeyStoreCollection"
#define TSNextPrekeyIdKey @"TSStorageInternalSettingsNextPreKeyId"
#define BATCH_SIZE 100

@implementation OWSPrimaryStorage (PreKeyStore)

- (PreKeyRecord *)getOrGenerateLastResortKey
{
    if ([self containsPreKey:kPreKeyOfLastResortId]) {
        return [self loadPreKey:kPreKeyOfLastResortId];
    } else {
        PreKeyRecord *lastResort =
            [[PreKeyRecord alloc] initWithId:kPreKeyOfLastResortId keyPair:[Curve25519 generateKeyPair]];
        [self storePreKey:kPreKeyOfLastResortId preKeyRecord:lastResort];
        return lastResort;
    }
}

- (NSArray *)generatePreKeyRecords
{
    NSMutableArray *preKeyRecords = [NSMutableArray array];

    @synchronized(self)
    {
        int preKeyId = [self nextPreKeyId];

        DDLogInfo(@"%@ building %d new preKeys starting from preKeyId: %d", self.logTag, BATCH_SIZE, preKeyId);
        for (int i = 0; i < BATCH_SIZE; i++) {
            ECKeyPair *keyPair = [Curve25519 generateKeyPair];
            PreKeyRecord *record = [[PreKeyRecord alloc] initWithId:preKeyId keyPair:keyPair];

            [preKeyRecords addObject:record];
            preKeyId++;
        }

        [self.dbReadWriteConnection setInt:preKeyId
                                    forKey:TSNextPrekeyIdKey
                              inCollection:TSStorageInternalSettingsCollection];
    }
    return preKeyRecords;
}

- (void)storePreKeyRecords:(NSArray *)preKeyRecords
{
    for (PreKeyRecord *record in preKeyRecords) {
        [self.dbReadWriteConnection setObject:record
                                       forKey:[self keyFromInt:record.Id]
                                 inCollection:OWSPrimaryStoragePreKeyStoreCollection];
    }
}

- (void)storePreKey:(int)preKeyId preKeyRecord:(PreKeyRecord *)record
{
    [self.dbReadWriteConnection setObject:record
                                   forKey:[self keyFromInt:preKeyId]
                             inCollection:OWSPrimaryStoragePreKeyStoreCollection];
}

- (BOOL)containsPreKey:(int)preKeyId
{
    PreKeyRecord *preKeyRecord = [self.dbReadConnection preKeyRecordForKey:[self keyFromInt:preKeyId]
                                                              inCollection:OWSPrimaryStoragePreKeyStoreCollection];
    return (preKeyRecord != nil);
}

- (void)removePreKey:(int)preKeyId
{
    [self.dbReadWriteConnection removeObjectForKey:[self keyFromInt:preKeyId]
                                      inCollection:OWSPrimaryStoragePreKeyStoreCollection];
}

- (nullable PreKeyRecord *)loadPreKey:(int)preKeyId {
    return [self.dbReadConnection preKeyRecordForKey:[self keyFromInt:preKeyId]
                                        inCollection:OWSPrimaryStoragePreKeyStoreCollection];
}

- (int)nextPreKeyId
{
    int lastPreKeyId =
        [self.dbReadConnection intForKey:TSNextPrekeyIdKey inCollection:TSStorageInternalSettingsCollection];

    if (lastPreKeyId < 1) {
        // One-time prekey ids must be > 0 and < kPreKeyOfLastResortId.
        lastPreKeyId = 1 + arc4random_uniform(kPreKeyOfLastResortId - (BATCH_SIZE + 1));
    } else if (lastPreKeyId > kPreKeyOfLastResortId - BATCH_SIZE) {
        // We want to "overflow" to 1 when we reach the "prekey of last resort" id
        // to avoid biasing towards higher values.
        lastPreKeyId = 1;
    }
    OWSCAssert(lastPreKeyId > 0 && lastPreKeyId < kPreKeyOfLastResortId);

    return lastPreKeyId;
}

@end
