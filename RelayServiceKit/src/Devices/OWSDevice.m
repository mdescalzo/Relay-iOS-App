//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSDevice.h"
#import "NSDate+OWS.h"
#import "OWSError.h"
#import "OWSPrimaryStorage.h"
#import "YapDatabaseConnection+OWS.h"
#import "YapDatabaseConnection.h"
#import "YapDatabaseTransaction.h"
#import <Mantle/MTLValueTransformer.h>

NS_ASSUME_NONNULL_BEGIN

//uint32_t const OWSDevicePrimaryDeviceId = 1;
NSString *const kOWSPrimaryStorage_OWSDeviceCollection = @"kTSStorageManager_OWSDeviceCollection";
NSString *const kOWSPrimaryStorage_MayHaveLinkedDevices = @"kTSStorageManager_MayHaveLinkedDevices";

NSString *const kFLCurrentDeviceIdKey = @"kFLCurrentDeviceIdKey";

@interface OWSDeviceManager ()

@property (atomic) NSDate *lastReceivedSyncMessage;
@property (assign) uint32_t cachedDeviceId;

@end

#pragma mark -

@implementation OWSDeviceManager

+ (instancetype)sharedManager
{
    static OWSDeviceManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] initDefault];
    });
    return instance;
}

- (instancetype)initDefault
{
    return [super init];
}

-(uint32_t)currentDeviceId
{
    if (self.cachedDeviceId == 0) {
        NSNumber *numberId = (NSNumber *)[OWSPrimaryStorage.sharedManager.dbReadConnection objectForKey:kFLCurrentDeviceIdKey
                                                                                           inCollection:kOWSPrimaryStorage_OWSDeviceCollection];
        if (numberId) {
            self.cachedDeviceId = [numberId unsignedIntValue];
        } else {
            self.cachedDeviceId = 1;
        }
    }
    return self.cachedDeviceId;
}

-(void)setCurrentDeviceId:(uint32_t)value
{
    if (_cachedDeviceId != value && value != 0) {
        [OWSPrimaryStorage.sharedManager.dbReadWriteConnection setObject:[NSNumber numberWithUnsignedInteger:value]
                                                                  forKey:kFLCurrentDeviceIdKey
                                                            inCollection:kOWSPrimaryStorage_OWSDeviceCollection];
        self.cachedDeviceId = value;
    }
}

- (BOOL)mayHaveLinkedDevices:(YapDatabaseConnection *)dbConnection
{
    OWSAssertDebug(dbConnection);

    return [dbConnection boolForKey:kOWSPrimaryStorage_MayHaveLinkedDevices
                       inCollection:kOWSPrimaryStorage_OWSDeviceCollection
                       defaultValue:YES];
}

// In order to avoid skipping necessary sync messages, the default value
// for mayHaveLinkedDevices is YES.  Once we've successfully sent a
// sync message with no device messages (e.g. the service has confirmed
// that we have no linked devices), we can set mayHaveLinkedDevices to NO
// to avoid unnecessary message sends for sync messages until we learn
// of a linked device (e.g. through the device linking UI or by receiving
// a sync message, etc.).
- (void)clearMayHaveLinkedDevicesIfNotSet
{
    // Note that we write async to avoid opening transactions within transactions.
    [OWSPrimaryStorage.sharedManager.newDatabaseConnection
        asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            if (![transaction objectForKey:kOWSPrimaryStorage_MayHaveLinkedDevices
                              inCollection:kOWSPrimaryStorage_OWSDeviceCollection]) {
                [transaction setObject:@(NO)
                                forKey:kOWSPrimaryStorage_MayHaveLinkedDevices
                          inCollection:kOWSPrimaryStorage_OWSDeviceCollection];
            }
        }];
}

- (void)setMayHaveLinkedDevices
{
    // Note that we write async to avoid opening transactions within transactions.
    [OWSPrimaryStorage.sharedManager.newDatabaseConnection
        asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            [transaction setObject:@(YES)
                            forKey:kOWSPrimaryStorage_MayHaveLinkedDevices
                      inCollection:kOWSPrimaryStorage_OWSDeviceCollection];
        }];
}

- (BOOL)hasReceivedSyncMessageInLastSeconds:(NSTimeInterval)intervalSeconds
{
    return (self.lastReceivedSyncMessage && fabs(self.lastReceivedSyncMessage.timeIntervalSinceNow) < intervalSeconds);
}

- (void)setHasReceivedSyncMessage
{
    self.lastReceivedSyncMessage = [NSDate new];

    [self setMayHaveLinkedDevices];
}



@end

#pragma mark -

@interface OWSDevice ()

@property (nonatomic) NSInteger deviceId;
@property (nonatomic, nullable) NSString *name;
@property (nonatomic) NSDate *createdAt;
@property (nonatomic) NSDate *lastSeenAt;

@end

#pragma mark -

@implementation OWSDevice

+ (instancetype)deviceFromJSONDictionary:(NSDictionary *)deviceAttributes error:(NSError **)error
{
    return [MTLJSONAdapter modelOfClass:[self class] fromJSONDictionary:deviceAttributes error:error];
}

+ (NSDictionary *)JSONKeyPathsByPropertyKey
{
    return @{
             @"createdAt": @"created",
             @"lastSeenAt": @"lastSeen",
             @"deviceId": @"id",
             @"name": @"name"
             };
}

+ (MTLValueTransformer *)createdAtJSONTransformer
{
    return self.millisecondTimestampToDateTransformer;
}

+ (MTLValueTransformer *)lastSeenAtJSONTransformer
{
    return self.millisecondTimestampToDateTransformer;
}

+ (void)replaceAll:(NSArray<OWSDevice *> *)currentDevices
{
    NSMutableArray<OWSDevice *> *existingDevices = [[self allObjectsInCollection] mutableCopy];
    for (OWSDevice *currentDevice in currentDevices) {
        NSUInteger existingDeviceIndex = [existingDevices indexOfObject:currentDevice];
        if (existingDeviceIndex == NSNotFound) {
            // New Device
            [currentDevice save];
        } else {
            OWSDevice *existingDevice = existingDevices[existingDeviceIndex];
            if ([existingDevice updateAttributesWithDevice:currentDevice]) {
                [existingDevice save];
            }
            [existingDevices removeObjectAtIndex:existingDeviceIndex];
        }
    }

    // Since we removed existing devices as we went, only stale devices remain
    for (OWSDevice *staleDevice in existingDevices) {
        [staleDevice remove];
    }
}

+ (MTLValueTransformer *)millisecondTimestampToDateTransformer
{
    static MTLValueTransformer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [MTLValueTransformer transformerUsingForwardBlock:^id(id value, BOOL *success, NSError **error) {
            if ([value isKindOfClass:[NSNumber class]]) {
                NSNumber *number = (NSNumber *)value;
                NSDate *result = [NSDate ows_dateWithMillisecondsSince1970:[number longLongValue]];
                if (result) {
                    *success = YES;
                    return result;
                }
            }
            *success = NO;
            DDLogError(@"%@ unable to decode date from %@", self.logTag, value);
            *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecodeJson, @"Unable to decode date from %@");
            return nil;
        }
            reverseBlock:^id(id value, BOOL *success, NSError **error) {
                if ([value isKindOfClass:[NSDate class]]) {
                    NSDate *date = (NSDate *)value;
                    NSNumber *result = [NSNumber numberWithLongLong:[NSDate ows_millisecondsSince1970ForDate:date]];
                    if (result) {
                        *success = YES;
                        return result;
                    }
                }
                DDLogError(@"%@ unable to encode date from %@", self.logTag, value);
                *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToEncodeJson, @"Unable to encode date");
                *success = NO;
                return nil;
            }];
    });
    return instance;
}

//+ (uint32_t)currentDeviceId
//{
//    // Someday it may be possible to have a non-primary iOS device, but for now
//    // any iOS device must be the primary device.
//    return OWSDevicePrimaryDeviceId;
//}

- (BOOL)isPrimaryDevice
{
    return self.deviceId == OWSDeviceManager.sharedManager.currentDeviceId;
}

- (NSString *)displayName
{
    if (self.name) {
        return self.name;
    }

    if (self.deviceId == OWSDeviceManager.sharedManager.currentDeviceId) {
        return @"This Device";
    }
    return NSLocalizedString(@"UNNAMED_DEVICE", @"Label text in device manager for a device with no name");
}

- (BOOL)updateAttributesWithDevice:(OWSDevice *)other
{
    BOOL changed = NO;
    if (![self.lastSeenAt isEqual:other.lastSeenAt]) {
        self.lastSeenAt = other.lastSeenAt;
        changed = YES;
    }

    if (![self.createdAt isEqual:other.createdAt]) {
        self.createdAt = other.createdAt;
        changed = YES;
    }

    if (![self.name isEqual:other.name]) {
        self.name = other.name;
        changed = YES;
    }

    return changed;
}

+ (BOOL)hasSecondaryDevicesWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return [self numberOfKeysInCollectionWithTransaction:transaction] > 1;
}

- (BOOL)isEqual:(id)object
{
    if (self == object) {
        return YES;
    }

    if (![object isKindOfClass:[OWSDevice class]]) {
        return NO;
    }

    return [self isEqualToDevice:(OWSDevice *)object];
}

- (BOOL)isEqualToDevice:(OWSDevice *)device
{
    return self.deviceId == device.deviceId;
}

@end

NS_ASSUME_NONNULL_END
