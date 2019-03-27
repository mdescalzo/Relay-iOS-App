//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSQuotedMessage.h"
#import "OWSSignalServiceProtos.pb.h"
#import "TSAccountManager.h"
#import "TSAttachment.h"
#import "TSAttachmentPointer.h"
#import "TSAttachmentStream.h"
#import "TSIncomingMessage.h"
#import "TSInteraction.h"
#import "TSOutgoingMessage.h"
#import "TSThread.h"
#import <YapDatabase/YapDatabaseTransaction.h>

NS_ASSUME_NONNULL_BEGIN

@implementation OWSAttachmentInfo

- (instancetype)initWithAttachmentStream:(TSAttachmentStream *)attachmentStream;
{
    OWSAssert([attachmentStream isKindOfClass:[TSAttachmentStream class]]);
    OWSAssert(attachmentStream.uniqueId);
    OWSAssert(attachmentStream.contentType);

    return [self initWithAttachmentId:attachmentStream.uniqueId
                          contentType:attachmentStream.contentType
                       sourceFilename:attachmentStream.sourceFilename];
}

- (instancetype)initWithAttachmentId:(nullable NSString *)attachmentId
                         contentType:(NSString *)contentType
                      sourceFilename:(NSString *)sourceFilename
{
    self = [super init];
    if (!self) {
        return self;
    }

    _attachmentId = attachmentId;
    _contentType = contentType;
    _sourceFilename = sourceFilename;

    return self;
}

@end

@interface TSQuotedMessage ()

@property (atomic) NSArray<OWSAttachmentInfo *> *quotedAttachments;
@property (atomic) NSArray<TSAttachmentStream *> *quotedAttachmentsForSending;

@end

@implementation TSQuotedMessage

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         authorId:(NSString *)authorId
                        messageId:(NSString *)messageId
                             body:(NSString *_Nullable)body
    receivedQuotedAttachmentInfos:(NSArray<OWSAttachmentInfo *> *)attachmentInfos
{
    OWSAssert(timestamp > 0);
    OWSAssert(authorId.length > 0);

    self = [super init];
    if (!self) {
        return nil;
    }

    _timestamp = timestamp;
    _authorId = authorId;
    _messageId = messageId;
    _body = body;
    _quotedAttachments = attachmentInfos;

    return self;
}

- (instancetype)initWithTimestamp:(uint64_t)timestamp
                         authorId:(NSString *)authorId
                        messageId:(NSString *)messageId
                             body:(NSString *_Nullable)body
      quotedAttachmentsForSending:(NSArray<TSAttachmentStream *> *)attachments
{
    OWSAssert(timestamp > 0);
    OWSAssert(authorId.length > 0);

    self = [super init];
    if (!self) {
        return nil;
    }

    _timestamp = timestamp;
    _authorId = authorId;
    _messageId = messageId;
    _body = body;
    
    NSMutableArray *attachmentInfos = [NSMutableArray new];
    for (TSAttachmentStream *attachmentStream in attachments) {
        [attachmentInfos addObject:[[OWSAttachmentInfo alloc] initWithAttachmentStream:attachmentStream]];
    }
    _quotedAttachments = [NSArray arrayWithArray:attachmentInfos];

    return self;
}

//+ (TSQuotedMessage *_Nullable)quotedMessageForDataMessage:(OWSSignalServiceProtosDataMessage *)dataMessage
//                                                   thread:(TSThread *)thread
//                                              transaction:(YapDatabaseReadWriteTransaction *)transaction
//{
//    OWSAssert(dataMessage);
//
//    if (!dataMessage.hasQuote) {
//        return nil;
//    }
//
//    OWSSignalServiceProtosDataMessageQuote *quoteProto = [dataMessage quote];
//
//    if (![quoteProto hasId] || [quoteProto id] == 0) {
//        OWSFailDebug(@"%@ quoted message missing id", self.logTag);
//        return nil;
//    }
//    uint64_t timestamp = [quoteProto id];
//
//    if (![quoteProto hasAuthor] || [quoteProto author].length == 0) {
//        OWSFailDebug(@"%@ quoted message missing author", self.logTag);
//        return nil;
//    }
//    // TODO: We could verify that this is a valid e164 value.
//    NSString *authorId = [quoteProto author];
//
//    NSString *_Nullable body = nil;
//    BOOL hasText = NO;
//    BOOL hasAttachment = NO;
//    if ([quoteProto hasText] && [quoteProto text].length > 0) {
//        body = [quoteProto text];
//        hasText = YES;
//    }
//
//    NSMutableArray<OWSAttachmentInfo *> *attachmentInfos = [NSMutableArray new];
//    for (OWSSignalServiceProtosDataMessageQuoteQuotedAttachment *quotedAttachment in quoteProto.attachments) {
//        hasAttachment = YES;
//        OWSAttachmentInfo *attachmentInfo = [[OWSAttachmentInfo alloc] initWithAttachmentId:nil
//                                                                                contentType:quotedAttachment.contentType
//                                                                             sourceFilename:quotedAttachment.fileName];
//
//        // We prefer deriving any thumbnail locally rather than fetching one from the network.
//        TSAttachmentStream *_Nullable thumbnailStream =
//            [self tryToDeriveLocalThumbnailWithAttachmentInfo:attachmentInfo
//                                                    timestamp:timestamp
//                                                     threadId:thread.uniqueId
//                                                     authorId:authorId
//                                                  transaction:transaction];
//
//        if (thumbnailStream) {
//            DDLogDebug(@"%@ Generated local thumbnail for quoted quoted message: %@:%lu",
//                self.logTag,
//                thread.uniqueId,
//                (unsigned long)timestamp);
//
//            [thumbnailStream saveWithTransaction:transaction];
//
//            attachmentInfo.thumbnailAttachmentStreamId = thumbnailStream.uniqueId;
//        } else if (quotedAttachment.hasThumbnail) {
//            DDLogDebug(@"%@ Saving reference for fetching remote thumbnail for quoted message: %@:%lu",
//                self.logTag,
//                thread.uniqueId,
//                (unsigned long)timestamp);
//
//            OWSSignalServiceProtosAttachmentPointer *thumbnailAttachmentProto = quotedAttachment.thumbnail;
//            TSAttachmentPointer *thumbnailPointer =
//                [TSAttachmentPointer attachmentPointerFromProto:thumbnailAttachmentProto];
//            [thumbnailPointer saveWithTransaction:transaction];
//
//            attachmentInfo.thumbnailAttachmentPointerId = thumbnailPointer.uniqueId;
//        } else {
//            DDLogDebug(
//                @"%@ No thumbnail for quoted message: %@:%lu", self.logTag, thread.uniqueId, (unsigned long)timestamp);
//        }
//
//        [attachmentInfos addObject:attachmentInfo];
//    }
//
//    if (!hasText && !hasAttachment) {
//        OWSFailDebug(@"%@ quoted message has neither text nor attachment", self.logTag);
//        return nil;
//    }
//
//    return [[TSQuotedMessage alloc] initWithTimestamp:timestamp
//                                             authorId:authorId
//                                            messageId:messageId
//                                                 body:body
//                        receivedQuotedAttachmentInfos:attachmentInfos];
//}

+ (nullable TSAttachmentStream *)tryToDeriveLocalThumbnailWithAttachmentInfo:(OWSAttachmentInfo *)attachmentInfo
                                                                   timestamp:(uint64_t)timestamp
                                                                    threadId:(NSString *)threadId
                                                                    authorId:(NSString *)authorId
                                                                 transaction:
                                                                     (YapDatabaseReadWriteTransaction *)transaction
{
    if (![TSAttachmentStream hasThumbnailForMimeType:attachmentInfo.contentType]) {
        return nil;
    }

    NSArray<TSMessage *> *quotedMessages = (NSArray<TSMessage *> *)[TSInteraction
        interactionsWithTimestamp:timestamp
                           filter:^BOOL(TSInteraction *interaction) {

                               if (![threadId isEqual:interaction.uniqueThreadId]) {
                                   return NO;
                               }

                               if ([interaction isKindOfClass:[TSIncomingMessage class]]) {
                                   TSIncomingMessage *incomingMessage = (TSIncomingMessage *)interaction;
                                   return [authorId isEqual:incomingMessage.messageAuthorId];
                               } else if ([interaction isKindOfClass:[TSOutgoingMessage class]]) {
                                   return [authorId isEqual:[TSAccountManager localUID]];
                               } else {
                                   // ignore other interaction types
                                   return NO;
                               }

                           }
                  withTransaction:transaction];

    TSMessage *_Nullable quotedMessage = quotedMessages.firstObject;

    if (!quotedMessage) {
        return nil;
    }

    TSAttachment *attachment = [quotedMessage attachmentWithTransaction:transaction];
    if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
        return nil;
    }
    TSAttachmentStream *sourceStream = (TSAttachmentStream *)attachment;

    TSAttachmentStream *_Nullable thumbnailStream = [sourceStream cloneAsThumbnail];
    if (!thumbnailStream) {
        return nil;
    }

    return thumbnailStream;
}


#pragma mark - Attachment (not necessarily with a thumbnail)

- (nullable OWSAttachmentInfo *)firstAttachmentInfo
{
    OWSAssert(self.quotedAttachments.count <= 1);
    return self.quotedAttachments.firstObject;
}

- (nullable NSString *)contentType
{
    OWSAttachmentInfo *firstAttachment = self.firstAttachmentInfo;

    return firstAttachment.contentType;
}

- (nullable NSString *)sourceFilename
{
    OWSAttachmentInfo *firstAttachment = self.firstAttachmentInfo;

    return firstAttachment.sourceFilename;
}

- (nullable NSString *)thumbnailAttachmentPointerId
{
    OWSAttachmentInfo *firstAttachment = self.firstAttachmentInfo;

    return firstAttachment.thumbnailAttachmentPointerId;
}

- (nullable NSString *)thumbnailAttachmentStreamId
{
    OWSAttachmentInfo *firstAttachment = self.firstAttachmentInfo;

    return firstAttachment.thumbnailAttachmentStreamId;
}

- (void)setThumbnailAttachmentStream:(TSAttachmentStream *)attachmentStream
{
    OWSAssert([attachmentStream isKindOfClass:[TSAttachmentStream class]]);
    OWSAssert(self.quotedAttachments.count == 1);

    OWSAttachmentInfo *firstAttachment = self.firstAttachmentInfo;
    firstAttachment.thumbnailAttachmentStreamId = attachmentStream.uniqueId;
}

- (NSArray<NSString *> *)thumbnailAttachmentStreamIds
{
    NSMutableArray *streamIds = [NSMutableArray new];
    for (OWSAttachmentInfo *info in self.quotedAttachments) {
        if (info.thumbnailAttachmentStreamId) {
            [streamIds addObject:info.thumbnailAttachmentStreamId];
        }
    }

    return [NSArray arrayWithArray:streamIds];
}

// Before sending, persist a thumbnail attachment derived from the quoted attachment
- (NSArray<TSAttachmentStream *> *)createThumbnailAttachmentsIfNecessaryWithTransaction:
    (YapDatabaseReadWriteTransaction *)transaction
{
    NSMutableArray<TSAttachmentStream *> *thumbnailAttachments = [NSMutableArray new];

    for (OWSAttachmentInfo *info in self.quotedAttachments) {

        OWSAssert(info.attachmentId);
        TSAttachment *attachment = [TSAttachment fetchObjectWithUniqueID:info.attachmentId transaction:transaction];
        if (![attachment isKindOfClass:[TSAttachmentStream class]]) {
            continue;
        }
        TSAttachmentStream *sourceStream = (TSAttachmentStream *)attachment;

        TSAttachmentStream *_Nullable thumbnailStream = [sourceStream cloneAsThumbnail];
        if (!thumbnailStream) {
            continue;
        }

        [thumbnailStream saveWithTransaction:transaction];
        info.thumbnailAttachmentStreamId = thumbnailStream.uniqueId;
        [thumbnailAttachments addObject:thumbnailStream];
    }

    return [NSArray arrayWithArray:thumbnailAttachments];
}

@end

NS_ASSUME_NONNULL_END
