//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSThread.h"
#import "NSDate+OWS.h"
#import "NSString+SSK.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "OWSPrimaryStorage.h"
#import "OWSReadTracking.h"
#import "TSDatabaseView.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSInteraction.h"
#import "TSInvalidIdentityKeyReceivingErrorMessage.h"
#import "TSOutgoingMessage.h"
#import "TSAccountManager.h"
#import "TSAttachmentStream.h"
#import "CCSMKeys.h"
#import "CCSMCommunication.h"
#import <RelayServiceKit/RelayServiceKit-Swift.h>
#import "TextSecureKitEnv.h"
#import "ContactsManagerProtocol.h"
#import "NSNotificationCenter+OWS.h"

@import YapDatabase;
@import SignalCoreKit;

NS_ASSUME_NONNULL_BEGIN


NSString *const TSThreadAvatarChangedNotification = @"TSThreadAvatarChangedNotification";
NSString *const TSThreadExpressionChangedNotification = @"TSThreadExpressionChangedNotification";
NSString *const TSThread_NotificationKey_UniqueId = @"TSThread_NotificationKey_UniqueId";

@interface TSThread ()

@property (nonatomic) NSDate *creationDate;
@property (nonatomic, copy, nullable) NSDate *archivalDate;
@property (nonatomic, nullable) NSString *conversationColorName;
@property (nonatomic, nullable) NSDate *lastMessageDate;
@property (nonatomic, copy, nullable) NSString *messageDraft;
@property (atomic, nullable) NSDate *mutedUntilDate;

@end

#pragma mark -

@implementation TSThread

@synthesize type = _type;

+ (NSString *)collection {
    return @"TSThread";
}

- (instancetype)initWithUniqueId:(NSString *_Nullable)uniqueId
{
    self = [super initWithUniqueId:uniqueId];
    
    if (self) {
        _archivalDate    = nil;
        _lastMessageDate = nil;
        _creationDate    = [NSDate date];
        _messageDraft    = nil;
        
//        _conversationColorName = [self.class stableConversationColorNameForString:self.uniqueId];
    }
    
    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }
    
//    if (_conversationColorName.length == 0) {
//        _conversationColorName = [self.class stableConversationColorNameForString:self.uniqueId];
//    }
    
    return self;
}

+(instancetype)getOrCreateThreadWithId:(nonnull NSString *)threadId
{
    __block TSThread *thread = nil;
    
    [OWSPrimaryStorage.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
    }];
    
    return thread;
}

+(instancetype)getOrCreateThreadWithId:(NSString *)threadId transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    TSThread *thread = [TSThread fetchObjectWithUniqueID:threadId transaction:transaction];
    if (thread == nil) {
        thread = [[TSThread alloc] initWithUniqueId:threadId];
        if (thread == nil) {
            OWSFailDebug(@"%@: unable to initialize new thread.", self.logTag);
            return nil;
        }
        [thread saveWithTransaction:transaction];
    }
    return thread;
}

+(nullable instancetype)getOrCreateThreadWithPayload:(nonnull NSDictionary *)payload
                             transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    NSString *threadId = [payload objectForKey:FLThreadIDKey];
    if (threadId == nil) {
        DDLogError(@"%@: unable to extract threadId from payload.", self.logTag);
        return nil;
    }
    TSThread *thread = [TSThread getOrCreateThreadWithId:threadId transaction:transaction];
    
    if (thread != nil) {
        [thread updateWithPayload:payload transaction:transaction];
    }
    
    return thread;
}

- (void)removeWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self removeAllThreadInteractionsWithTransaction:transaction];
    
    [super removeWithTransaction:transaction];
}

- (void)removeAllThreadInteractionsWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    // We can't safely delete interactions while enumerating them, so
    // we collect and delete separately.
    //
    // We don't want to instantiate the interactions when collecting them
    // or when deleting them.
    NSMutableArray<NSString *> *interactionIds = [NSMutableArray new];
    YapDatabaseViewTransaction *interactionsByThread = [transaction ext:TSMessageDatabaseViewExtensionName];
    OWSAssert(interactionsByThread);
    __block BOOL didDetectCorruption = NO;
    [interactionsByThread enumerateKeysInGroup:self.uniqueId
                                    usingBlock:^(NSString *collection, NSString *key, NSUInteger index, BOOL *stop) {
                                        if (![key isKindOfClass:[NSString class]] || key.length < 1) {
                                            OWSFailDebug(@"%@ invalid key in thread interactions: %@, %@.",
                                                              self.logTag,
                                                              key,
                                                              [key class]);
                                            didDetectCorruption = YES;
                                            return;
                                        }
                                        [interactionIds addObject:key];
                                    }];
    
    if (didDetectCorruption) {
        DDLogWarn(@"%@ incrementing version of: %@", self.logTag, TSMessageDatabaseViewExtensionName);
        [OWSPrimaryStorage incrementVersionOfDatabaseExtension:TSMessageDatabaseViewExtensionName];
    }
    
    for (NSString *interactionId in interactionIds) {
        // We need tononatomic fetch each interaction, since [TSInteraction removeWithTransaction:] does important work.
        TSInteraction *_Nullable interaction =
        [TSInteraction fetchObjectWithUniqueID:interactionId transaction:transaction];
        if (!interaction) {
            OWSFailDebug(@"%@ couldn't load thread's interaction for deletion.", self.logTag);
            continue;
        }
        [interaction removeWithTransaction:transaction];
    }
}

- (NSString *)name {
    OWSAbstractMethod();
    
    return nil;
}

- (NSArray<NSString *> *)recipientIdentifiers
{
    OWSAbstractMethod();
    
    return @[];
}

- (BOOL)hasSafetyNumbers
{
    return NO;
}

#pragma mark Interactions

/**
 * Iterate over this thread's interactions
 */
- (void)enumerateInteractionsWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
                                  usingBlock:(void (^)(TSInteraction *interaction,
                                                       YapDatabaseReadTransaction *transaction))block
{
    void (^interactionBlock)(NSString *, NSString *, id, id, NSUInteger, BOOL *) = ^void(
                                                                                         NSString *collection, NSString *key, id _Nonnull object, id _Nonnull metadata, NSUInteger index, BOOL *stop) {
        TSInteraction *interaction = object;
        block(interaction, transaction);
    };
    
    YapDatabaseViewTransaction *interactionsByThread = [transaction ext:TSMessageDatabaseViewExtensionName];
    [interactionsByThread enumerateRowsInGroup:self.uniqueId usingBlock:interactionBlock];
}

/**
 * Enumerates all the threads interactions. Note this will explode if you try to create a transaction in the block.
 * If you need a transaction, use the sister method: `enumerateInteractionsWithTransaction:usingBlock`
 */
- (void)enumerateInteractionsUsingBlock:(void (^)(TSInteraction *interaction))block
{
    [self.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        [self enumerateInteractionsWithTransaction:transaction
                                        usingBlock:^(
                                                     TSInteraction *interaction, YapDatabaseReadTransaction *transaction) {
                                            
                                            block(interaction);
                                        }];
    }];
}

/**
 * Useful for tests and debugging. In production use an enumeration method.
 */
- (NSArray<TSInteraction *> *)allInteractions
{
    NSMutableArray<TSInteraction *> *interactions = [NSMutableArray new];
    [self enumerateInteractionsUsingBlock:^(TSInteraction *interaction) {
        [interactions addObject:interaction];
    }];
    
    return [interactions copy];
}

- (NSArray<TSInvalidIdentityKeyReceivingErrorMessage *> *)receivedMessagesForInvalidKey:(NSData *)key
{
    NSMutableArray *errorMessages = [NSMutableArray new];
    [self enumerateInteractionsUsingBlock:^(TSInteraction *interaction) {
        if ([interaction isKindOfClass:[TSInvalidIdentityKeyReceivingErrorMessage class]]) {
            TSInvalidIdentityKeyReceivingErrorMessage *error = (TSInvalidIdentityKeyReceivingErrorMessage *)interaction;
            if ([[error newIdentityKey] isEqualToData:key]) {
                [errorMessages addObject:(TSInvalidIdentityKeyReceivingErrorMessage *)interaction];
            }
        }
    }];
    
    return [errorMessages copy];
}

- (NSUInteger)numberOfInteractions
{
    __block NSUInteger count;
    [[self dbReadConnection] readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        YapDatabaseViewTransaction *interactionsByThread = [transaction ext:TSMessageDatabaseViewExtensionName];
        count = [interactionsByThread numberOfItemsInGroup:self.uniqueId];
    }];
    return count;
}

- (NSArray<id<OWSReadTracking>> *)unseenMessagesWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    NSMutableArray<id<OWSReadTracking>> *messages = [NSMutableArray new];
    [[TSDatabaseView unseenDatabaseViewExtension:transaction]
     enumerateRowsInGroup:self.uniqueId
     usingBlock:^(
                  NSString *collection, NSString *key, id object, id metadata, NSUInteger index, BOOL *stop) {
         
         if (![object conformsToProtocol:@protocol(OWSReadTracking)]) {
             OWSFailDebug(@"%@ Unexpected object in unseen messages: %@", self.logTag, object);
             return;
         }
         [messages addObject:(id<OWSReadTracking>)object];
     }];
    
    return [messages copy];
}

- (NSUInteger)unreadMessageCountWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return [[transaction ext:TSUnreadDatabaseViewExtensionName] numberOfItemsInGroup:self.uniqueId];
}

- (void)markAllAsReadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    for (id<OWSReadTracking> message in [self unseenMessagesWithTransaction:transaction]) {
        [message markAsReadAtTimestamp:[NSDate ows_millisecondTimeStamp] sendReadReceipt:YES transaction:transaction];
    }
    
    // Just to be defensive, we'll also check for unread messages.
    OWSAssertDebug([self unseenMessagesWithTransaction:transaction].count < 1);
}

- (nullable TSInteraction *)lastInteractionForInboxWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssert(transaction);
    
    __block NSUInteger missedCount = 0;
    __block TSInteraction *last = nil;
    [[transaction ext:TSMessageDatabaseViewExtensionName]
     enumerateRowsInGroup:self.uniqueId
     withOptions:NSEnumerationReverse
     usingBlock:^(NSString *collection, NSString *key, id object, id metadata, NSUInteger index, BOOL *stop) {
         
         if ([object isKindOfClass:[TSInteraction class]]) {
             missedCount++;
             TSInteraction *interaction = (TSInteraction *)object;
             if ([TSThread shouldInteractionAppearInInbox:interaction]) {
                 last = interaction;
                 
                 // For long ignored threads, with lots of SN changes this can get really slow.
                 // I see this in development because I have a lot of long forgotten threads with members
                 // who's test devices are constantly reinstalled. We could add a purpose-built DB view,
                 // but I think in the real world this is rare to be a hotspot.
                 if (missedCount > 50) {
                     DDLogWarn(@"%@ found last interaction for inbox after skipping %lu items",
                               self.logTag,
                               (unsigned long)missedCount);
                 }
                 *stop = YES;
             }
         } else {
             OWSFailDebug(@"%@: Invalid object %@, with key %@, in collection: %@", self.logTag, object, key, collection);
         }
     }];
    return last;
}

- (nonnull NSDate *)lastMessageDate {
    if (_lastMessageDate) {
        return _lastMessageDate;
    } else {
        return _creationDate;
    }
}

- (nonnull NSString *)lastMessageTextWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    TSInteraction *interaction = [self lastInteractionForInboxWithTransaction:transaction];
    if ([interaction conformsToProtocol:@protocol(OWSPreviewText)]) {
        id<OWSPreviewText> previewable = (id<OWSPreviewText>)interaction;
        return [previewable previewTextWithTransaction:transaction].filterStringForDisplay;
    } else {
        return @"";
    }
}

// Returns YES IFF the interaction should show up in the inbox as the last message.
+ (BOOL)shouldInteractionAppearInInbox:(TSInteraction *)interaction
{
    OWSAssert(interaction);
    
    if (interaction.isDynamicInteraction) {
        return NO;
    }
    
    if ([interaction isKindOfClass:[TSErrorMessage class]]) {
        TSErrorMessage *errorMessage = (TSErrorMessage *)interaction;
        if (errorMessage.errorType == TSErrorMessageNonBlockingIdentityChange) {
            // Otherwise all group threads with the recipient will percolate to the top of the inbox, even though
            // there was no meaningful interaction.
            return NO;
        }
    } else if ([interaction isKindOfClass:[TSInfoMessage class]]) {
        TSInfoMessage *infoMessage = (TSInfoMessage *)interaction;
        if (infoMessage.infoMessageType == TSInfoMessageVerificationStateChange) {
            return NO;
        }
    }
    
    return YES;
}

- (void)updateWithLastMessage:(nonnull TSInteraction *)lastMessage
                  transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    if (![self.class shouldInteractionAppearInInbox:lastMessage]) {
        return;
    }
    
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        thread.hasEverHadMessage = YES;
        
        NSDate *lastMessageDate = [lastMessage dateForSorting];
        if (!thread.lastMessageDate || [lastMessageDate timeIntervalSinceDate:thread.lastMessageDate] > 0) {
            thread.lastMessageDate = lastMessageDate;
        }
    }];
}

#pragma mark Disappearing Messages

- (OWSDisappearingMessagesConfiguration *)disappearingMessagesConfigurationWithTransaction:
(YapDatabaseReadTransaction *)transaction
{
    return [OWSDisappearingMessagesConfiguration fetchOrBuildDefaultWithThreadId:self.uniqueId transaction:transaction];
}

- (uint32_t)disappearingMessagesDurationWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    
    OWSDisappearingMessagesConfiguration *config = [self disappearingMessagesConfigurationWithTransaction:transaction];
    
    if (!config.isEnabled) {
        return 0;
    } else {
        return config.durationSeconds;
    }
}

#pragma mark Archival

- (nullable NSDate *)archivalDate
{
    return _archivalDate;
}

- (void)archiveThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction {
    [self archiveThreadWithTransaction:transaction referenceDate:[NSDate date]];
}

- (void)archiveThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction referenceDate:(NSDate *)date {
    [self markAllAsReadWithTransaction:transaction];
    
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        thread.archivalDate = date;
    }];
}

- (void)unarchiveThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction {
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        thread.archivalDate = nil;
    }];
}

#pragma mark Drafts

- (NSString *)currentDraftWithTransaction:(YapDatabaseReadTransaction *)transaction {
    TSThread *thread = [TSThread fetchObjectWithUniqueID:self.uniqueId transaction:transaction];
    if (thread.messageDraft) {
        return thread.messageDraft;
    } else {
        return @"";
    }
}

- (void)setDraft:(NSString *)draftString transaction:(YapDatabaseReadWriteTransaction *)transaction {
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        thread.messageDraft = draftString;
    }];
}

#pragma mark - Muted

- (BOOL)isMuted
{
    NSDate *mutedUntilDate = self.mutedUntilDate;
    NSDate *now = [NSDate date];
    return (mutedUntilDate != nil &&
            [mutedUntilDate timeIntervalSinceDate:now] > 0);
}

- (void)updateWithMutedUntilDate:(NSDate *)mutedUntilDate transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        [thread setMutedUntilDate:mutedUntilDate];
    }];
}

#pragma mark - Conversation Color
// Moved to Theme.h
// TODO:  Implement per-conversation colors in our environment
//+ (NSString *)randomConversationColorName
//{
//    NSUInteger count = self.conversationColorNames.count;
//    NSUInteger index = arc4random_uniform((uint32_t)count);
//    return [self.conversationColorNames objectAtIndex:index];
//}
//
//+ (NSString *)stableConversationColorNameForString:(NSString *)colorSeed
//{
//    NSData *contactData = [colorSeed dataUsingEncoding:NSUTF8StringEncoding];
//
//    unsigned long long hash = 0;
//    NSUInteger hashingLength = sizeof(hash);
//    NSData *_Nullable hashData = [Cryptography computeSHA256Digest:contactData truncatedToBytes:hashingLength];
//    if (hashData) {
//        [hashData getBytes:&hash length:hashingLength];
//    } else {
//        OWSFailDebug(@"%@ could not compute hash for color seed.", self.logTag);
//    }
//
//    NSUInteger index = (hash % [self.conversationColorNames count]);
//    return [self.conversationColorNames objectAtIndex:index];
//}
//
//+ (NSArray<NSString *> *)conversationColorNames
//{
//    return @[
//             @"red",
//             @"pink",
//             @"purple",
//             @"indigo",
//             @"blue",
//             @"cyan",
//             @"teal",
//             @"green",
//             @"deep_orange",
//             @"grey"
//             ];
//}
//
//- (void)updateConversationColorName:(NSString *)colorName transaction:(YapDatabaseReadWriteTransaction *)transaction
//{
//    [self applyChangeToSelfAndLatestCopy:transaction
//                             changeBlock:^(TSThread *thread) {
//                                 thread.conversationColorName = colorName;
//                             }];
//}

-(void)removeMembers:(nonnull NSSet *)leavingMemberIds
         transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    if (leavingMemberIds.count > 0) {
        [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
            NSMutableArray *tmpArray = thread.participantIds.mutableCopy;
            for (NSString *uid in leavingMemberIds) {
                [tmpArray removeObject:uid];
            }
            thread.participantIds = [NSArray arrayWithArray:tmpArray];
        }];
    }
}

+(NSArray<TSThread *> *)threadsContainingParticipant:(NSString *)participantId transaction:transaction
{
    __block NSMutableArray<TSThread *> *results = [NSMutableArray<TSThread *> new];
    [transaction enumerateKeysAndObjectsInCollection:[TSThread collection]
                                          usingBlock:^(NSString * _Nonnull key, id  _Nonnull object, BOOL * _Nonnull stop) {
                                              TSThread *thread = (TSThread *)object;
                                              if ([thread.participantIds containsObject:participantId]) {
                                                  [results addObject:thread];
                                              }
                                          }];
    
    return [NSArray<TSThread *> arrayWithArray:results];
}

+(NSArray<TSThread *> *)threadsWithMatchingParticipants:(nonnull NSArray <NSString *> *)participants
                                            transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    __block NSMutableArray<TSThread *> *results = [NSMutableArray<TSThread *> new];
    __block NSCountedSet *inputSet = [NSCountedSet setWithArray:participants];

    [transaction enumerateKeysAndObjectsInCollection:[TSThread collection]
                                          usingBlock:^(NSString * _Nonnull key, id  _Nonnull object, BOOL * _Nonnull stop) {
                                              TSThread *thread = (TSThread *)object;
                                              NSCountedSet *testSet = [NSCountedSet setWithArray:thread.participantIds];
                                              if ([inputSet isEqualToSet:testSet]) {
                                                  [results addObject:thread];
                                              }
                                          }];
    
    return [NSArray<TSThread *> arrayWithArray:results];
}


+(nullable instancetype)getOrCreateThreadWithParticipants:(NSArray <NSString *> *)participantIDs
{
    __block TSThread *thread = nil;
    [[OWSPrimaryStorage.sharedManager dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        thread = [self getOrCreateThreadWithParticipants:participantIDs transaction:transaction];
    }];
    
    return thread;
}

+(nullable instancetype)getOrCreateThreadWithParticipants:(NSArray <NSString *> *)participantIDs
                                     transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    __block TSThread *thread = nil;
    if (participantIDs.count > 0) {
        __block NSCountedSet *testSet = [NSCountedSet setWithArray:participantIDs];
        [transaction enumerateKeysAndObjectsInCollection:[TSThread collection] usingBlock:^(NSString *key, TSThread *aThread, BOOL *stop) {
            NSCountedSet *aSet = [NSCountedSet setWithArray:aThread.participantIds];
            if ([aSet isEqual:testSet]) {
                thread = aThread;
                *stop = YES;
            }
        }];
        
        if (thread == nil && testSet.count > 0) {
            thread = [TSThread getOrCreateThreadWithId:[[NSUUID UUID] UUIDString].lowercaseString transaction:transaction];
            thread.participantIds = [testSet allObjects];
            [thread saveWithTransaction:transaction];
        }
    } else {
        OWSFailDebug(@"Attempt to create a thread with 0 participants.");
    }
    return thread;
}

-(void)updateWithPayload:(nonnull NSDictionary *)payload
             transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    NSString *threadId = [payload objectForKey:FLThreadIDKey];
    if (threadId.length == 0 || ![threadId.lowercaseString isEqualToString:self.uniqueId]) {
        DDLogDebug(@"%@ - Attempted to update thread with invalid payload.", self.logTag);
        return;
    }
    
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        NSString *threadExpression = [(NSDictionary *)[payload objectForKey:FLDistributionKey] objectForKey:FLExpressionKey];
        NSString *threadType = [payload objectForKey:FLThreadTypeKey];
        NSString *threadTitle = [payload objectForKey:FLThreadTitleKey];
        thread.title = ((threadTitle.length > 0) ? threadTitle : @"" );
        thread.type = ((threadType.length > 0) ? threadType : nil );
        
        NSArray *members = [(NSDictionary *)[payload objectForKey:@"data"] objectForKey:@"members"];
        if (members != nil) {
            thread.participantIds = members;
        }

        if (![threadExpression isEqualToString:self.universalExpression] ||
            members != nil ||
            thread.participantIds.count == 0 ||
            thread.prettyExpression.length == 0) {
            thread.universalExpression = threadExpression;
            [NSNotificationCenter.defaultCenter postNotificationNameAsync:TSThreadExpressionChangedNotification object:self];
        }
    }];
}

-(void)updateParticipants:(nonnull NSArray *)participants
              transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    if ([participants isEqualToArray:self.participantIds]) {
        //  Duplication, bail...
        return;
    }
    
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        thread.participantIds = [participants copy];
    }];
}

-(void)updateTitle:(nonnull NSString *)newTitle
       transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    if ([newTitle isEqualToString:self.title]) {
        //  Duplication, bail...
        return;
    }
    
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        thread.title = [newTitle copy];
    }];
}

-(void)updateImageWithAttachmentStream:(nonnull TSAttachmentStream *)attachmentStream
                           transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    if ([self.image isEqual:[attachmentStream image]]) {
        return;
    }
    
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        [thread setImage:[attachmentStream image]];
        
        // Avatars are stored directly in the database, so there's no need
        // to keep the attachment around after assigning the image.
        [attachmentStream removeWithTransaction:transaction];
    }];
}

-(void)updateImage:(nonnull UIImage *)image
       transaction:(nonnull YapDatabaseReadWriteTransaction *)transaction
{
    if ([self.image isEqual:image]) {
        return;
    }
    [self applyChangeToSelfAndLatestCopy:transaction changeBlock:^(TSThread *thread) {
        [thread setImage:image];
    }];

}

// MARK: - Accessors
//-(nullable NSString *)universalExpression {
//    return _universalExpression;
//}
//
//-(void)setUniversalExpression:(nullable NSString *)value
//{
//    if (![value isEqualToString:_universalExpression]) {
//        _universalExpression = value;
//        [NSNotificationCenter.defaultCenter postNotificationName:TSThreadExpressionChangedNotification
//                                                          object:self];
//    }
//}

-(NSString *)type
{
    if (_type == nil) {
        return FLThreadTypeConversation;
    } else {
        return _type;
    }
}

-(void)setType:(NSString *)value
{
    if (![value isEqualToString:_type]) {
        _type = [value copy];
    }
}

-(NSArray<NSString *>*)participantIds
{
    if (_participantIds == nil) {
        _participantIds = [NSArray array];
    }
    return _participantIds;
}

-(BOOL)isOneOnOne
{
    return (self.participantIds.count == 2 && [self.participantIds containsObject:TSAccountManager.localUID]);
}

-(nullable NSString *)otherParticipantId
{
    if (self.isOneOnOne) {
        for (NSString *uid in self.participantIds) {
            if (![uid isEqualToString:TSAccountManager.localUID]) {
                return uid;
            }
        }
    }
    return nil;
}

-(NSString *)displayName
{
    NSString *returnString;
    if (self.title.length > 0) {
        returnString = self.title;
    } else if (self.participantIds.count == 1 && [self.participantIds.lastObject isEqualToString:TSAccountManager.localUID]) {
        returnString = NSLocalizedString(@"ME_STRING", @"");
    } else if (self.isOneOnOne) {
        returnString = [TextSecureKitEnv.sharedEnv.contactsManager displayNameForRecipientId:self.otherParticipantId];
    } else if (self.prettyExpression.length > 0) {
        returnString = self.prettyExpression;
    } else {
        returnString = NSLocalizedString(@"NEW_THREAD", @"");
    }
    return [returnString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

@end

NS_ASSUME_NONNULL_END
