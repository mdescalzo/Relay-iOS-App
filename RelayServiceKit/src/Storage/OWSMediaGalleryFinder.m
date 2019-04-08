//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "OWSMediaGalleryFinder.h"
#import "OWSStorage.h"
#import "TSAttachmentStream.h"
#import "TSMessage.h"
#import "TSThread.h"
#import <YapDatabase/YapDatabaseAutoView.h>
#import <YapDatabase/YapDatabaseTransaction.h>
#import <YapDatabase/YapDatabaseViewTypes.h>
#import <YapDatabase/YapWhitelistBlacklist.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *const OWSMediaGalleryFinderExtensionName = @"OWSMediaGalleryFinderExtensionName";

@interface OWSMediaGalleryFinder ()

@property (nonatomic, readonly) TSThread *thread;

@end

@implementation OWSMediaGalleryFinder

- (instancetype)initWithThread:(TSThread *)thread
{
    self = [super init];
    if (!self) {
        return self;
    }

    _thread = thread;

    return self;
}

#pragma mark - Public Finder Methods

- (NSUInteger)mediaCountWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return [[self galleryExtensionWithTransaction:transaction] numberOfItemsInGroup:self.mediaGroup];
}

- (NSUInteger)mediaIndexForMessage:(TSMessage *)message transaction:(YapDatabaseReadTransaction *)transaction
{
    NSString *groupId;
    NSUInteger index;

    BOOL wasFound = [[self galleryExtensionWithTransaction:transaction] getGroup:&groupId
                                                                           index:&index
                                                                          forKey:message.uniqueId
                                                                    inCollection:[TSMessage collection]];

    OWSAssert(wasFound);
    OWSAssert([self.mediaGroup isEqual:groupId]);

    return index;
}

- (nullable TSMessage *)oldestMediaMessageWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return [[self galleryExtensionWithTransaction:transaction] firstObjectInGroup:self.mediaGroup];
}

- (nullable TSMessage *)mostRecentMediaMessageWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return [[self galleryExtensionWithTransaction:transaction] lastObjectInGroup:self.mediaGroup];
}

- (void)enumerateMediaMessagesWithRange:(NSRange)range
                            transaction:(YapDatabaseReadTransaction *)transaction
                                  block:(void (^)(TSMessage *))messageBlock
{

    [[self galleryExtensionWithTransaction:transaction]
        enumerateKeysAndObjectsInGroup:self.mediaGroup
                           withOptions:0
                                 range:range
                            usingBlock:^(NSString *_Nonnull collection,
                                NSString *_Nonnull key,
                                id _Nonnull object,
                                NSUInteger index,
                                BOOL *_Nonnull stop) {

                                OWSAssert([object isKindOfClass:[TSMessage class]]);
                                messageBlock((TSMessage *)object);
                            }];
}

#pragma mark - Util

- (YapDatabaseAutoViewTransaction *)galleryExtensionWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    YapDatabaseAutoViewTransaction *extension = [transaction extension:OWSMediaGalleryFinderExtensionName];
    OWSAssert(extension);
    
    return extension;
}

+ (NSString *)mediaGroupWithThreadId:(NSString *)threadId
{
    return [NSString stringWithFormat:@"%@-media", threadId];
}

- (NSString *)mediaGroup
{
    return [[self class] mediaGroupWithThreadId:self.thread.uniqueId];
}

#pragma mark - Extension registration

+ (NSString *)databaseExtensionName
{
    return OWSMediaGalleryFinderExtensionName;
}

+ (void)asyncRegisterDatabaseExtensionsWithPrimaryStorage:(OWSStorage *)storage
{
    [storage asyncRegisterExtension:[self mediaGalleryDatabaseExtension]
                           withName:OWSMediaGalleryFinderExtensionName];
}

+ (YapDatabaseAutoView *)mediaGalleryDatabaseExtension
{
    YapDatabaseViewSorting *sorting = [YapDatabaseViewSorting withObjectBlock:^NSComparisonResult(YapDatabaseReadTransaction * _Nonnull transaction, NSString * _Nonnull group, NSString * _Nonnull collection1, NSString * _Nonnull key1, id  _Nonnull object1, NSString * _Nonnull collection2, NSString * _Nonnull key2, id  _Nonnull object2) {
        // Sanity check
        if (object1 == nil || key1 == nil || collection1 == nil || object2 == nil || key2 == nil || collection2 == nil) {
            OWSFailDebug(@"%@ Invalid object1 %@ in collection1: %@ with key1: %@\n\tobject2 %@ in collection2: %@ with key2: %@",
                         self.logTag, [object1 class], collection1, key1, [object2 class], collection2, key2);
            return NSOrderedSame;
        }

        if (![object1 isKindOfClass:[TSMessage class]]) {
            OWSFailDebug(@"%@ Unexpected object while sorting: %@", self.logTag, [object1 class]);
            return NSOrderedSame;
        }
        TSMessage *message1 = (TSMessage *)object1;
        
        if (![object2 isKindOfClass:[TSMessage class]]) {
            OWSFailDebug(@"%@ Unexpected object while sorting: %@", self.logTag, [object2 class]);
            return NSOrderedSame;
        }
        TSMessage *message2 = (TSMessage *)object2;
        
        return [@(message1.timestampForSorting) compare:@(message2.timestampForSorting)];
    }];
    
    YapDatabaseViewGrouping *grouping = [YapDatabaseViewGrouping withObjectBlock:^NSString * _Nullable(YapDatabaseReadTransaction * _Nonnull transaction, NSString * _Nonnull collection, NSString * _Nonnull key, id  _Nonnull object) {
        // Sanity check
        if (object == nil || key == nil || collection == nil) {
            OWSFailDebug(@"%@ Invalid entity %@ in collection: %@ with key: %@", self.logTag, [object class], collection, key);
            return nil;
        }
        
        if (![object isKindOfClass:[TSMessage class]]) {
            return nil;
        }
        TSMessage *message = (TSMessage *)object;
        
        if (message.attachmentIds.count > 1) {
            DDLogInfo(@"Message found with more than one attachment");
        }
        
        BOOL shouldAppear = NO;
        for (NSString *attachmentId in message.attachmentIds) {
            if (attachmentId.length > 0) {
                if ([self attachmentIdShouldAppearInMediaGallery:attachmentId transaction:transaction]) {
                    shouldAppear = YES;
                    break;
                }
            }
        }
        
        if (shouldAppear) {
            return [self mediaGroupWithThreadId:message.uniqueThreadId];
        } else {
            return nil;
        }
    }];
    
    YapDatabaseViewOptions *options = [YapDatabaseViewOptions new];
    options.allowedCollections = [[YapWhitelistBlacklist alloc] initWithWhitelist:[NSSet setWithObject:TSMessage.collection]];

    return [[YapDatabaseAutoView alloc] initWithGrouping:grouping sorting:sorting versionTag:@"1" options:options];
}

+ (BOOL)attachmentIdShouldAppearInMediaGallery:(NSString *)attachmentId transaction:(YapDatabaseReadTransaction *)transaction
{
    TSAttachmentStream *attachment = [TSAttachmentStream fetchObjectWithUniqueID:attachmentId
                                                                     transaction:transaction];

    // Don't include nil or not yet downloaded attachments.
    if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
        return NO;
    }
    
    return attachment.isImage || attachment.isVideo || attachment.isAnimated;
}

@end

NS_ASSUME_NONNULL_END
