//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSProfileManager.h"
#import "Environment.h"
#import "OWSUserProfile.h"
#import <RelayMessaging/RelayMessaging-Swift.h>

@import RelayServiceKit;
@import SignalCoreKit;

NS_ASSUME_NONNULL_BEGIN

NSString *const kNSNotificationName_ProfileWhitelistDidChange = @"kNSNotificationName_ProfileWhitelistDidChange";

NSString *const kOWSProfileManager_UserWhitelistCollection = @"kOWSProfileManager_UserWhitelistCollection";
NSString *const kOWSProfileManager_GroupWhitelistCollection = @"kOWSProfileManager_GroupWhitelistCollection";

// The max bytes for a user's profile name, encoded in UTF8.
// Before encrypting and submitting we NULL pad the name data to this length.
const NSUInteger kOWSProfileManager_NameDataLength = 26;
const NSUInteger kOWSProfileManager_MaxAvatarDiameter = 640;

@interface OWSProfileManager ()

@property (nonatomic, readonly) MessageSender *messageSender;
@property (nonatomic, readonly) YapDatabaseConnection *dbConnection;
@property (nonatomic, readonly) TSNetworkManager *networkManager;
@property (nonatomic, readonly) OWSIdentityManager *identityManager;

// This property can be accessed on any thread, while synchronized on self.
@property (atomic, readonly) OWSUserProfile *localUserProfile;

// This property can be accessed on any thread, while synchronized on self.
@property (atomic, readonly) NSCache<NSString *, UIImage *> *profileAvatarImageCache;

// This property can be accessed on any thread, while synchronized on self.
@property (atomic, readonly) NSMutableSet<NSString *> *currentAvatarDownloads;

@end

#pragma mark -

// Access to most state should happen while synchronized on the profile manager.
// Writes should happen off the main thread, wherever possible.
@implementation OWSProfileManager

@synthesize localUserProfile = _localUserProfile;

+ (instancetype)sharedManager
{
    static OWSProfileManager *sharedMyManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedMyManager = [[self alloc] initDefault];
    });
    return sharedMyManager;
}

- (instancetype)initDefault
{
    OWSPrimaryStorage *primaryStorage = [OWSPrimaryStorage sharedManager];
    MessageSender *messageSender = [Environment current].messageSender;
    TSNetworkManager *networkManager = [Environment current].networkManager;

    return [self initWithPrimaryStorage:primaryStorage messageSender:messageSender networkManager:networkManager];
}

- (instancetype)initWithPrimaryStorage:(OWSPrimaryStorage *)primaryStorage
                         messageSender:(MessageSender *)messageSender
                        networkManager:(TSNetworkManager *)networkManager
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSAssertIsOnMainThread();
    OWSAssert(primaryStorage);
    OWSAssert(messageSender);
    OWSAssert(messageSender);

    _messageSender = messageSender;
    _dbConnection = primaryStorage.newDatabaseConnection;
    _networkManager = networkManager;

    _profileAvatarImageCache = [NSCache new];
    _currentAvatarDownloads = [NSMutableSet new];

    OWSSingletonAssert();

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)observeNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidBecomeActive:)
                                                 name:OWSApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (OWSIdentityManager *)identityManager
{
    return [OWSIdentityManager sharedManager];
}

#pragma mark - User Profile Accessor

- (void)ensureLocalProfileCached
{
    // Since localUserProfile can create a transaction, we want to make sure it's not called for the first
    // time unexpectedly (e.g. in a nested transaction.)
    __unused OWSUserProfile *profile = [self localUserProfile];
}

#pragma mark - Local Profile

- (OWSUserProfile *)localUserProfile
{
    @synchronized(self)
    {
        if (!_localUserProfile) {
            _localUserProfile = [OWSUserProfile getOrBuildUserProfileForRecipientId:kLocalProfileUniqueId
                                                                       dbConnection:self.dbConnection];
        }
    }

    OWSAssert(_localUserProfile.profileKey);

    return _localUserProfile;
}

- (BOOL)localProfileExists
{
    return [OWSUserProfile localUserProfileExists:self.dbConnection];
}

- (OWSAES256Key *)localProfileKey
{
    OWSAssert(self.localUserProfile.profileKey.keyData.length == kAES256_KeyByteLength);

    return self.localUserProfile.profileKey;
}

- (BOOL)hasLocalProfile
{
    return (self.localProfileName.length > 0 || self.localProfileAvatarImage != nil);
}

- (nullable NSString *)localProfileName
{
    return self.localUserProfile.profileName;
}

- (nullable UIImage *)localProfileAvatarImage
{
    return [self loadProfileAvatarWithFilename:self.localUserProfile.avatarFileName];
}

- (void)updateLocalProfileName:(nullable NSString *)profileName
                   avatarImage:(nullable UIImage *)avatarImage
                       success:(void (^)(void))successBlockParameter
                       failure:(void (^)(void))failureBlockParameter
{
    OWSAssert(successBlockParameter);
    OWSAssert(failureBlockParameter);

    // Ensure that the success and failure blocks are called on the main thread.
    void (^failureBlock)(void) = ^{
        DDLogError(@"%@ Updating service with profile failed.", self.logTag);

        dispatch_async(dispatch_get_main_queue(), ^{
            failureBlockParameter();
        });
    };
    void (^successBlock)(void) = ^{
        DDLogInfo(@"%@ Successfully updated service with profile.", self.logTag);

        dispatch_async(dispatch_get_main_queue(), ^{
            successBlockParameter();
        });
    };

    // The final steps are to:
    //
    // * Try to update the service.
    // * Update client state on success.
    void (^tryToUpdateService)(NSString *_Nullable, NSString *_Nullable) = ^(
        NSString *_Nullable avatarUrlPath, NSString *_Nullable avatarFileName) {
        [self updateServiceWithProfileName:profileName
            success:^{
                OWSUserProfile *userProfile = self.localUserProfile;
                OWSAssert(userProfile);

                [userProfile updateWithProfileName:profileName
                                     avatarUrlPath:avatarUrlPath
                                    avatarFileName:avatarFileName
                                      dbConnection:self.dbConnection
                                        completion:^{
                                            if (avatarFileName) {
                                                [self updateProfileAvatarCache:avatarImage filename:avatarFileName];
                                            }

                                            successBlock();
                                        }];
            }
            failure:^{
                failureBlock();
            }];
    };

    OWSUserProfile *userProfile = self.localUserProfile;
    OWSAssert(userProfile);

    if (avatarImage) {
        // If we have a new avatar image, we must first:
        //
        // * Encode it to JPEG.
        // * Write it to disk.
        // * Encrypt it
        // * Upload it to asset service
        // * Send asset service info to Signal Service
        if (self.localProfileAvatarImage == avatarImage) {
            OWSAssert(userProfile.avatarUrlPath.length > 0);
            OWSAssert(userProfile.avatarFileName.length > 0);

            DDLogVerbose(@"%@ Updating local profile on service with unchanged avatar.", self.logTag);
            // If the avatar hasn't changed, reuse the existing metadata.
            tryToUpdateService(userProfile.avatarUrlPath, userProfile.avatarFileName);
        } else {
            DDLogVerbose(@"%@ Updating local profile on service with new avatar.", self.logTag);
            tryToUpdateService(nil, nil);
        }
    } else if (userProfile.avatarUrlPath) {
        DDLogVerbose(@"%@ Updating local profile on service with cleared avatar.", self.logTag);
        tryToUpdateService(nil, nil);
    } else {
        DDLogVerbose(@"%@ Updating local profile on service with no avatar.", self.logTag);
        tryToUpdateService(nil, nil);
    }
}

- (void)writeAvatarToDisk:(UIImage *)avatar
                  success:(void (^)(NSData *data, NSString *fileName))successBlock
                  failure:(void (^)(void))failureBlock
{
    OWSAssert(avatar);
    OWSAssert(successBlock);
    OWSAssert(failureBlock);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (avatar) {
            NSData *data = [self processedImageDataForRawAvatar:avatar];
            OWSAssert(data);
            if (data) {
                NSString *fileName = [[NSUUID UUID].UUIDString stringByAppendingPathExtension:@"jpg"];
                NSString *filePath = [OWSUserProfile profileAvatarFilepathWithFilename:fileName];
                BOOL success = [data writeToFile:filePath atomically:YES];
                OWSAssert(success);
                if (success) {
                    successBlock(data, fileName);
                    return;
                }
            }
        }
        failureBlock();
    });
}

- (NSData *)processedImageDataForRawAvatar:(UIImage *)image
{
    NSUInteger kMaxAvatarBytes = 5 * 1000 * 1000;

    if (image.size.width != kOWSProfileManager_MaxAvatarDiameter
        || image.size.height != kOWSProfileManager_MaxAvatarDiameter) {
        // To help ensure the user is being shown the same cropping of their avatar as
        // everyone else will see, we want to be sure that the image was resized before this point.
        OWSFailDebug(@"Avatar image should have been resized before trying to upload");
        image = [image resizedImageToFillPixelSize:CGSizeMake(kOWSProfileManager_MaxAvatarDiameter,
                                                       kOWSProfileManager_MaxAvatarDiameter)];
    }

    NSData *_Nullable data = UIImageJPEGRepresentation(image, 0.95f);
    if (data.length > kMaxAvatarBytes) {
        // Our avatar dimensions are so small that it's incredibly unlikely we wouldn't be able to fit our profile
        // photo. e.g. generating pure noise at our resolution compresses to ~200k.
        OWSFailDebug(@"Suprised to find profile avatar was too large. Was it scaled properly? image: %@", image);
    }

    return data;
}

- (void)updateServiceWithProfileName:(nullable NSString *)localProfileName
                             success:(void (^)(void))successBlock
                             failure:(void (^)(void))failureBlock
{
    OWSAssert(successBlock);
    OWSAssert(failureBlock);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *_Nullable encryptedPaddedName = [self encryptProfileNameWithUnpaddedName:localProfileName];

        TSRequest *request = [OWSRequestBuilder profileNameSetRequestWithEncryptedPaddedName:encryptedPaddedName];
        [self.networkManager makeRequest:request
            success:^(NSURLSessionDataTask *task, id responseObject) {
                successBlock();
            }
            failure:^(NSURLSessionDataTask *task, NSError *error) {
                DDLogError(@"%@ Failed to update profile with error: %@", self.logTag, error);
                failureBlock();
            }];
    });
}

- (void)fetchLocalUsersProfile
{
// We don't use profiles in Forsta world
    return;
}

#pragma mark - Profile Whitelist

- (void)clearProfileWhitelist
{
    DDLogWarn(@"%@ Clearing the profile whitelist.", self.logTag);

    [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [transaction removeAllObjectsInCollection:kOWSProfileManager_UserWhitelistCollection];
        [transaction removeAllObjectsInCollection:kOWSProfileManager_GroupWhitelistCollection];
        OWSAssert(0 == [transaction numberOfKeysInCollection:kOWSProfileManager_UserWhitelistCollection]);
        OWSAssert(0 == [transaction numberOfKeysInCollection:kOWSProfileManager_GroupWhitelistCollection]);
    }];
}

- (void)logProfileWhitelist
{
    [self.dbConnection asyncReadWithBlock:^(YapDatabaseReadTransaction *transaction) {
        DDLogError(@"kOWSProfileManager_UserWhitelistCollection: %lu",
                   (unsigned long)[transaction numberOfKeysInCollection:kOWSProfileManager_UserWhitelistCollection]);
        [transaction enumerateKeysInCollection:kOWSProfileManager_UserWhitelistCollection
                                    usingBlock:^(NSString *_Nonnull key, BOOL *_Nonnull stop) {
                                        DDLogError(@"\t profile whitelist user: %@", key);
                                    }];
        DDLogError(@"kOWSProfileManager_GroupWhitelistCollection: %lu",
                   (unsigned long)[transaction numberOfKeysInCollection:kOWSProfileManager_GroupWhitelistCollection]);
        [transaction enumerateKeysInCollection:kOWSProfileManager_GroupWhitelistCollection
                                    usingBlock:^(NSString *_Nonnull key, BOOL *_Nonnull stop) {
                                        DDLogError(@"\t profile whitelist group: %@", key);
                                    }];
    }];
}

- (void)regenerateLocalProfile
{
    OWSUserProfile *userProfile = self.localUserProfile;
    [userProfile clearWithProfileKey:[OWSAES256Key generateRandomKey] dbConnection:self.dbConnection completion:nil];
}

- (void)addUserToProfileWhitelist:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    [self addUsersToProfileWhitelist:@[ recipientId ]];
}

- (void)addUsersToProfileWhitelist:(NSArray<NSString *> *)recipientIds
{
    OWSAssert(recipientIds);

    NSMutableSet<NSString *> *newRecipientIds = [NSMutableSet new];
    [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        for (NSString *recipientId in recipientIds) {
            NSNumber *_Nullable oldValue =
                [transaction objectForKey:recipientId inCollection:kOWSProfileManager_UserWhitelistCollection];
            if (oldValue && oldValue.boolValue) {
                continue;
            }
            [transaction setObject:@(YES) forKey:recipientId inCollection:kOWSProfileManager_UserWhitelistCollection];
            [newRecipientIds addObject:recipientId];
        }
    }
        completionBlock:^{
            for (NSString *recipientId in newRecipientIds) {
                [[NSNotificationCenter defaultCenter]
                    postNotificationNameAsync:kNSNotificationName_ProfileWhitelistDidChange
                                       object:nil
                                     userInfo:@{
                                         kNSNotificationKey_ProfileRecipientId : recipientId,
                                     }];
            }
        }];
}

- (BOOL)isUserInProfileWhitelist:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    __block BOOL result = NO;
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        NSNumber *_Nullable oldValue =
            [transaction objectForKey:recipientId inCollection:kOWSProfileManager_UserWhitelistCollection];
        result = (oldValue && oldValue.boolValue);
    }];
    return result;
}

- (void)addGroupIdToProfileWhitelist:(NSString *)groupId
{
    OWSAssert(groupId.length > 0);

//    NSString *groupIdKey = [groupId hexadecimalString];

    __block BOOL didChange = NO;
    [self.dbConnection asyncReadWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        NSNumber *_Nullable oldValue =
            [transaction objectForKey:groupId inCollection:kOWSProfileManager_GroupWhitelistCollection];
        if (oldValue && oldValue.boolValue) {
            // Do nothing.
        } else {
            [transaction setObject:@(YES) forKey:groupId inCollection:kOWSProfileManager_GroupWhitelistCollection];
            didChange = YES;
        }
    }
        completionBlock:^{
            if (didChange) {
                [[NSNotificationCenter defaultCenter]
                    postNotificationNameAsync:kNSNotificationName_ProfileWhitelistDidChange
                                       object:nil
                                     userInfo:@{
                                         kNSNotificationKey_ProfileGroupId : groupId,
                                     }];
            }
        }];
}

- (void)addThreadToProfileWhitelist:(TSThread *)thread
{
    OWSAssert(thread);

    [self addUsersToProfileWhitelist:thread.participantIds];
    [self addGroupIdToProfileWhitelist:thread.uniqueId];
//    if (thread.isGroupThread) {
//        TSGroupThread *groupThread = (TSGroupThread *)thread;
//        NSData *groupId = groupThread.groupModel.groupId;
//        [self addGroupIdToProfileWhitelist:groupId];
//
//        // When we add a group to the profile whitelist, we might as well
//        // also add all current members to the profile whitelist
//        // individually as well just in case delivery of the profile key
//        // fails.
//        for (NSString *recipientId in groupThread.participantIds) {
//            [self addUserToProfileWhitelist:recipientId];
//        }
//    } else {
//        NSString *recipientId = thread.contactIdentifier;
//        [self addUserToProfileWhitelist:recipientId];
//    }
}

- (BOOL)isGroupIdInProfileWhitelist:(NSString *)groupId
{
    OWSAssert(groupId.length > 0);

//    NSString *groupIdKey = [groupId hexadecimalString];

    __block BOOL result = NO;
    [self.dbConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        NSNumber *_Nullable oldValue =
            [transaction objectForKey:groupId inCollection:kOWSProfileManager_GroupWhitelistCollection];
        result = (oldValue && oldValue.boolValue);
    }];
    return result;
}

- (BOOL)isThreadInProfileWhitelist:(TSThread *)thread
{
    if (thread != nil) {
        return [self isGroupIdInProfileWhitelist:thread.uniqueId];
    } else {
        return NO;
    }
}

- (void)setContactRecipientIds:(NSArray<NSString *> *)contactRecipientIds
{
    OWSAssert(contactRecipientIds);

    [self addUsersToProfileWhitelist:contactRecipientIds];
}

#pragma mark - Other User's Profiles

- (void)logUserProfiles
{
    [self.dbConnection asyncReadWithBlock:^(YapDatabaseReadTransaction *transaction) {
        DDLogError(@"logUserProfiles: %zd", [transaction numberOfKeysInCollection:OWSUserProfile.collection]);
        [transaction
            enumerateKeysAndObjectsInCollection:OWSUserProfile.collection
                                     usingBlock:^(NSString *_Nonnull key, id _Nonnull object, BOOL *_Nonnull stop) {
                                         OWSAssert([object isKindOfClass:[OWSUserProfile class]]);
                                         OWSUserProfile *userProfile = object;
                                         DDLogError(@"\t [%@]: has profile key: %d, has avatar URL: %d, has "
                                                    @"avatar file: %d, name: %@",
                                             userProfile.recipientId,
                                             userProfile.profileKey != nil,
                                             userProfile.avatarUrlPath != nil,
                                             userProfile.avatarFileName != nil,
                                             userProfile.profileName);
                                     }];
    }];
}

- (void)setProfileKeyData:(NSData *)profileKeyData forRecipientId:(NSString *)recipientId
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        OWSAES256Key *_Nullable profileKey = [OWSAES256Key keyWithData:profileKeyData];
        if (profileKey == nil) {
            OWSFailDebug(@"Failed to make profile key for key data");
            return;
        }

        OWSUserProfile *userProfile =
            [OWSUserProfile getOrBuildUserProfileForRecipientId:recipientId dbConnection:self.dbConnection];

        OWSAssert(userProfile);
        if (userProfile.profileKey && [userProfile.profileKey.keyData isEqual:profileKey.keyData]) {
            // Ignore redundant update.
            return;
        }

        [userProfile clearWithProfileKey:profileKey
                            dbConnection:self.dbConnection
                              completion:^{
//                                  dispatch_async(dispatch_get_main_queue(), ^(void) {
//                                      [ProfileFetcherJob runWithRecipientId:recipientId
//                                                             networkManager:self.networkManager
//                                                           ignoreThrottling:YES];
//                                  });
                              }];
    });
}

- (nullable NSData *)profileKeyDataForRecipientId:(NSString *)recipientId
{
    return [self profileKeyForRecipientId:recipientId].keyData;
}

- (nullable OWSAES256Key *)profileKeyForRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    OWSUserProfile *userProfile =
        [OWSUserProfile getOrBuildUserProfileForRecipientId:recipientId dbConnection:self.dbConnection];
    OWSAssert(userProfile);

    return userProfile.profileKey;
}

- (nullable NSString *)profileNameForRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    OWSUserProfile *userProfile =
        [OWSUserProfile getOrBuildUserProfileForRecipientId:recipientId dbConnection:self.dbConnection];

    return userProfile.profileName;
}

- (nullable UIImage *)profileAvatarForRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    OWSUserProfile *userProfile =
        [OWSUserProfile getOrBuildUserProfileForRecipientId:recipientId dbConnection:self.dbConnection];

    if (userProfile.avatarFileName.length > 0) {
        return [self loadProfileAvatarWithFilename:userProfile.avatarFileName];
    }

    return nil;
}

- (nullable NSData *)profileAvatarDataForRecipientId:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    OWSUserProfile *userProfile =
        [OWSUserProfile getOrBuildUserProfileForRecipientId:recipientId dbConnection:self.dbConnection];

    if (userProfile.avatarFileName.length > 0) {
        return [self loadProfileDataWithFilename:userProfile.avatarFileName];
    }

    return nil;
}



- (void)updateProfileForRecipientId:(NSString *)recipientId
               profileNameEncrypted:(nullable NSData *)profileNameEncrypted
                      avatarUrlPath:(nullable NSString *)avatarUrlPath
{
    OWSAssert(recipientId.length > 0);

    DDLogDebug(@"%@ update profile for: %@ name: %@ avatar: %@",
        self.logTag,
        recipientId,
        profileNameEncrypted,
        avatarUrlPath);

    // Ensure decryption, etc. off main thread.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        OWSUserProfile *userProfile =
            [OWSUserProfile getOrBuildUserProfileForRecipientId:recipientId dbConnection:self.dbConnection];

        if (!userProfile.profileKey) {
            return;
        }

        NSString *_Nullable profileName =
            [self decryptProfileNameData:profileNameEncrypted profileKey:userProfile.profileKey];

        [userProfile updateWithProfileName:profileName
                             avatarUrlPath:avatarUrlPath
                              dbConnection:self.dbConnection
                                completion:nil];

        // If we're updating the profile that corresponds to our local number,
        // update the local profile as well.
        NSString *_Nullable localUID = [TSAccountManager sharedInstance].localUID;
        if (localUID && [localUID isEqualToString:recipientId]) {
            OWSUserProfile *localUserProfile = self.localUserProfile;
            OWSAssert(localUserProfile);

            [localUserProfile updateWithProfileName:profileName
                                      avatarUrlPath:avatarUrlPath
                                       dbConnection:self.dbConnection
                                         completion:nil];
        }
    });
}

- (BOOL)isNullableDataEqual:(NSData *_Nullable)left toData:(NSData *_Nullable)right
{
    if (left == nil && right == nil) {
        return YES;
    } else if (left == nil || right == nil) {
        return YES;
    } else {
        return [left isEqual:right];
    }
}

- (BOOL)isNullableStringEqual:(NSString *_Nullable)left toString:(NSString *_Nullable)right
{
    if (left == nil && right == nil) {
        return YES;
    } else if (left == nil || right == nil) {
        return YES;
    } else {
        return [left isEqualToString:right];
    }
}

#pragma mark - Profile Encryption

- (nullable NSData *)encryptProfileData:(nullable NSData *)encryptedData profileKey:(OWSAES256Key *)profileKey
{
    OWSAssert(profileKey.keyData.length == kAES256_KeyByteLength);

    if (!encryptedData) {
        return nil;
    }

    return [Cryptography encryptAESGCMWithProfileData:encryptedData key:profileKey];
}

- (nullable NSData *)decryptProfileData:(nullable NSData *)encryptedData profileKey:(OWSAES256Key *)profileKey
{
    OWSAssert(profileKey.keyData.length == kAES256_KeyByteLength);

    if (!encryptedData) {
        return nil;
    }

    return [Cryptography decryptAESGCMWithProfileData:encryptedData key:profileKey];
}

- (nullable NSString *)decryptProfileNameData:(nullable NSData *)encryptedData profileKey:(OWSAES256Key *)profileKey
{
    OWSAssert(profileKey.keyData.length == kAES256_KeyByteLength);

    NSData *_Nullable decryptedData = [self decryptProfileData:encryptedData profileKey:profileKey];
    if (decryptedData.length < 1) {
        return nil;
    }


    // Unpad profile name.
    NSUInteger unpaddedLength = 0;
    const char *bytes = decryptedData.bytes;

    // Work through the bytes until we encounter our first
    // padding byte (our padding scheme is NULL bytes)
    for (NSUInteger i = 0; i < decryptedData.length; i++) {
        if (bytes[i] == 0x00) {
            break;
        }
        unpaddedLength = i + 1;
    }

    NSData *unpaddedData = [decryptedData subdataWithRange:NSMakeRange(0, unpaddedLength)];

    return [[NSString alloc] initWithData:unpaddedData encoding:NSUTF8StringEncoding];
}

- (nullable NSData *)encryptProfileData:(nullable NSData *)data
{
    return [self encryptProfileData:data profileKey:self.localProfileKey];
}

- (BOOL)isProfileNameTooLong:(nullable NSString *)profileName
{
    OWSAssertIsOnMainThread();

    NSData *nameData = [profileName dataUsingEncoding:NSUTF8StringEncoding];
    return nameData.length > kOWSProfileManager_NameDataLength;
}

- (nullable NSData *)encryptProfileNameWithUnpaddedName:(NSString *)name
{
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (nameData.length > kOWSProfileManager_NameDataLength) {
        OWSFailDebug(@"%@ name data is too long with length:%lu", self.logTag, (unsigned long)nameData.length);
        return nil;
    }

    NSUInteger paddingByteCount = kOWSProfileManager_NameDataLength - nameData.length;

    NSMutableData *paddedNameData = [nameData mutableCopy];
    // Since we want all encrypted profile names to be the same length on the server, we use `increaseLengthBy`
    // to pad out any remaining length with 0 bytes.
    [paddedNameData increaseLengthBy:paddingByteCount];
    OWSAssert(paddedNameData.length == kOWSProfileManager_NameDataLength);

    return [self encryptProfileData:[paddedNameData copy] profileKey:self.localProfileKey];
}

#pragma mark - Avatar Disk Cache

- (nullable NSData *)loadProfileDataWithFilename:(NSString *)filename
{
    OWSAssert(filename.length > 0);

    NSString *filePath = [OWSUserProfile profileAvatarFilepathWithFilename:filename];
    return [NSData dataWithContentsOfFile:filePath];
}

- (nullable UIImage *)loadProfileAvatarWithFilename:(NSString *)filename
{
    if (filename.length == 0) {
        return nil;
    }

    UIImage *_Nullable image = nil;
    @synchronized(self.profileAvatarImageCache)
    {
        image = [self.profileAvatarImageCache objectForKey:filename];
    }
    if (image) {
        return image;
    }

    NSData *data = [self loadProfileDataWithFilename:filename];
    if (![data ows_isValidImage]) {
        return nil;
    }
    image = [UIImage imageWithData:data];
    [self updateProfileAvatarCache:image filename:filename];
    return image;
}

- (void)updateProfileAvatarCache:(nullable UIImage *)image filename:(NSString *)filename
{
    OWSAssert(filename.length > 0);
    OWSAssert(image);

    @synchronized(self.profileAvatarImageCache)
    {
        if (image) {
            [self.profileAvatarImageCache setObject:image forKey:filename];
        } else {
            [self.profileAvatarImageCache removeObjectForKey:filename];
        }
    }
}

#pragma mark - User Interface

- (void)presentAddThreadToProfileWhitelist:(TSThread *)thread
                        fromViewController:(UIViewController *)fromViewController
                                   success:(void (^)(void))successHandler
{
    OWSAssertIsOnMainThread();

    UIAlertController *alertController =
        [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *shareTitle = NSLocalizedString(@"CONVERSATION_SETTINGS_VIEW_SHARE_PROFILE",
        @"Button to confirm that user wants to share their profile with a user or group.");
    [alertController addAction:[UIAlertAction actionWithTitle:shareTitle
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction *_Nonnull action) {
                                                          [self userAddedThreadToProfileWhitelist:thread
                                                                                          success:successHandler];
                                                      }]];
    [alertController addAction:[OWSAlerts cancelAction]];

    [fromViewController presentViewController:alertController animated:YES completion:nil];
}

- (void)userAddedThreadToProfileWhitelist:(TSThread *)thread success:(void (^)(void))successHandler
{
    OWSAssertIsOnMainThread();

    OWSProfileKeyMessage *message =
        [[OWSProfileKeyMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp] inThread:thread];

    BOOL isFeatureEnabled = NO;
    if (!isFeatureEnabled) {
        DDLogWarn(
            @"%@ skipping sending profile-key message because the feature is not yet fully available.", self.logTag);
        [OWSProfileManager.sharedManager addThreadToProfileWhitelist:thread];
        successHandler();
        return;
    }

    [self.messageSender enqueueMessage:message
        success:^{
            DDLogInfo(@"%@ Successfully sent profile key message to thread: %@", self.logTag, thread);
            [OWSProfileManager.sharedManager addThreadToProfileWhitelist:thread];

            dispatch_async(dispatch_get_main_queue(), ^{
                successHandler();
            });
        }
        failure:^(NSError *_Nonnull error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DDLogError(@"%@ Failed to send profile key message to thread: %@", self.logTag, thread);
            });
        }];
}

#pragma mark - Notifications

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();

    // TODO: Sync if necessary.
}

@end

NS_ASSUME_NONNULL_END
