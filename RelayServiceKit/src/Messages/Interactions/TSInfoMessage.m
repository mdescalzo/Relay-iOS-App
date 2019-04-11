//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSInfoMessage.h"
#import "ContactsManagerProtocol.h"
#import "NSDate+OWS.h"
#import "TextSecureKitEnv.h"
#import <YapDatabase/YapDatabaseConnection.h>

NS_ASSUME_NONNULL_BEGIN

NSUInteger TSInfoMessageSchemaVersion = 1;

@interface TSInfoMessage ()

@property (nonatomic, getter=wasRead) BOOL read;

@property (nonatomic, readonly) NSUInteger infoMessageSchemaVersion;

@end

#pragma mark -

@implementation TSInfoMessage

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }
    
    if (self.infoMessageSchemaVersion < 1) {
        _read = YES;
    }
    
    _infoMessageSchemaVersion = TSInfoMessageSchemaVersion;
    
    if (self.isDynamicInteraction) {
        self.read = YES;
    }
    
    return self;
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(TSThread *)thread
                  infoMessageType:(TSInfoMessageType)infoMessageType
{
    self = [super initMessageWithTimestamp:timestamp
                                  inThread:thread
                               messageBody:nil
                             attachmentIds:@[]
                          expiresInSeconds:0
                           expireStartedAt:0
                             quotedMessage:nil];
    
    if (!self) {
        return self;
    }
    
    _infoMessageType = infoMessageType;
    _infoMessageSchemaVersion = TSInfoMessageSchemaVersion;
    
    if (self.isDynamicInteraction) {
        self.read = YES;
    }
    
    return self;
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(TSThread *)thread
                  infoMessageType:(TSInfoMessageType)infoMessageType
                    customMessage:(NSString *)customMessage
{
    self = [self initWithTimestamp:timestamp inThread:thread infoMessageType:infoMessageType];
    if (self) {
        _customMessage = customMessage;
    }
    return self;
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         inThread:(TSThread *)thread
                  infoMessageType:(TSInfoMessageType)infoMessageType
          unregisteredRecipientId:(NSString *)unregisteredRecipientId
{
    self = [self initWithTimestamp:timestamp inThread:thread infoMessageType:infoMessageType];
    if (self) {
        _unregisteredRecipientId = unregisteredRecipientId;
    }
    return self;
}

+ (instancetype)userNotRegisteredMessageInThread:(TSThread *)thread recipientId:(NSString *)recipientId
{
    OWSAssertDebug(thread);
    OWSAssertDebug(recipientId);
    
    return [[self alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                  inThread:thread
                               infoMessageType:TSInfoMessageUserNotRegistered
                   unregisteredRecipientId:recipientId];
}

- (OWSInteractionType)interactionType
{
    return OWSInteractionType_Info;
}

- (NSString *)previewTextWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    switch (_infoMessageType) {
        case TSInfoMessageTypeSessionDidEnd:
            return NSLocalizedString(@"SECURE_SESSION_RESET", nil);
        case TSInfoMessageTypeUnsupportedMessage:
            return NSLocalizedString(@"UNSUPPORTED_ATTACHMENT", nil);
        case TSInfoMessageUserNotRegistered:
            if (self.unregisteredRecipientId.length > 0) {
                id<ContactsManagerProtocol> contactsManager = [TextSecureKitEnv sharedEnv].contactsManager;
                NSString *recipientName = [contactsManager displayNameForRecipientId:self.unregisteredRecipientId];
                return [NSString stringWithFormat:NSLocalizedString(@"ERROR_UNREGISTERED_USER_FORMAT",
                                                                    @"Format string for 'unregistered user' error. Embeds {{the "
                                                                    @"unregistered user's name or signal id}}."),
                        recipientName];
            } else {
                return NSLocalizedString(@"CONTACT_DETAIL_COMM_TYPE_INSECURE", nil);
            }
        case TSInfoMessageTypeConversationQuit:
            return NSLocalizedString(@"GROUP_YOU_LEFT", nil);
        case TSInfoMessageTypeConversationUpdate:
            return _customMessage != nil ? _customMessage : NSLocalizedString(@"GROUP_UPDATED", nil);
        case TSInfoMessageAddToContactsOffer:
            return NSLocalizedString(@"ADD_TO_CONTACTS_OFFER",
                                     @"Message shown in conversation view that offers to add an unknown user to your phone's contacts.");
        case TSInfoMessageVerificationStateChange:
            return NSLocalizedString(@"VERIFICATION_STATE_CHANGE_GENERIC",
                                     @"Generic message indicating that verification state changed for a given user.");
        case TSInfoMessageAddUserToProfileWhitelistOffer:
            return NSLocalizedString(@"ADD_USER_TO_PROFILE_WHITELIST_OFFER",
                                     @"Message shown in conversation view that offers to share your profile with a user.");
        case TSInfoMessageAddGroupToProfileWhitelistOffer:
            return NSLocalizedString(@"ADD_GROUP_TO_PROFILE_WHITELIST_OFFER",
                                     @"Message shown in conversation view that offers to share your profile with a group.");
        default:
            break;
    }
    
    return @"Unknown Info Message Type";
}

#pragma mark - OWSReadTracking

- (BOOL)shouldAffectUnreadCounts
{
    return NO;
}

- (uint64_t)expireStartedAt
{
    return 0;
}

- (void)markAsReadAtTimestamp:(uint64_t)readTimestamp
              sendReadReceipt:(BOOL)sendReadReceipt
                  transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssertDebug(transaction);
    
    if (_read) {
        return;
    }
    
    DDLogDebug(
               @"%@ marking as read uniqueId: %@ which has timestamp: %llu", self.logTag, self.uniqueId, self.timestamp);
    _read = YES;
    [self saveWithTransaction:transaction];
    [self touchThreadWithTransaction:transaction];
    
    // Ignore sendReadReceipt, it doesn't apply to info messages.
}

@end

NS_ASSUME_NONNULL_END
