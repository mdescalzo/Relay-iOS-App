//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSInteraction.h"

NS_ASSUME_NONNULL_BEGIN

/**
 *  Abstract message class.
 */

@class OWSContact;
@class TSAttachment;
@class TSAttachmentStream;
@class TSQuotedMessage;
@class YapDatabaseReadWriteTransaction;

extern NSString *const FLMessageNeedsGiphyRetrievalNotification;

@interface TSMessage : TSInteraction <OWSPreviewText>

@property (nonatomic) NSArray<NSString *> *attachmentIds;
@property (nonatomic, nullable) NSString *body;
@property (nonatomic, readonly) uint32_t expiresInSeconds;
@property (nonatomic, readonly) uint64_t expireStartedAt;
@property (nonatomic, readonly) uint64_t expiresAt;
@property (nonatomic, readonly) BOOL isExpiringMessage;
@property (nonatomic, readonly, nullable) TSQuotedMessage *quotedMessage;
@property (nonatomic, readonly, nullable) OWSContact *contactShare;

- (instancetype)initInteractionWithTimestamp:(uint64_t)timestamp inThread:(TSThread *)thread NS_UNAVAILABLE;

- (instancetype)initMessageWithTimestamp:(uint64_t)timestamp
                                inThread:(nullable TSThread *)thread
                             messageBody:(nullable NSString *)body
                           attachmentIds:(NSArray<NSString *> *)attachmentIds
                        expiresInSeconds:(uint32_t)expiresInSeconds
                         expireStartedAt:(uint64_t)expireStartedAt
                           quotedMessage:(nullable TSQuotedMessage *)quotedMessage NS_DESIGNATED_INITIALIZER;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

- (BOOL)hasAttachments;
- (nullable TSAttachment *)attachmentWithTransaction:(YapDatabaseReadTransaction *)transaction;

// *** USE WITH CAUTION ***  Risk of leaving orphaned attachments in the file system.  Intended only for monitor message send completion.
-(void)removeKeepingAttachments:(BOOL)keepAttachments;
-(void)removeKeepingAttachments:(BOOL)keepAttachments withTransaction:(YapDatabaseReadWriteTransaction *)transaction;

- (void)setQuotedMessageThumbnailAttachmentStream:(TSAttachmentStream *)attachmentStream;

- (BOOL)shouldStartExpireTimerWithTransaction:(YapDatabaseReadTransaction *)transaction;

// JSON body handlers
@property (nonatomic, strong) NSDictionary *forstaPayload;
@property (nullable, nonatomic, copy) NSString *plainTextBody;
@property (nullable, nonatomic, copy) NSString *htmlTextBody;
@property (nonatomic, copy) NSString *messageType;
@property BOOL hasAnnotation;
@property (nonatomic, readonly) BOOL isGiphy;
@property (nonatomic, nullable) NSData *giphyImageData;
@property (nonatomic, nullable) NSString *urlString;

// Used for supplemental data for support things like webRTC
@property (nullable, nonatomic) NSDictionary *moreData;

#pragma mark - Update With... Methods

- (void)updateWithExpireStartedAt:(uint64_t)expireStartedAt transaction:(YapDatabaseReadWriteTransaction *)transaction;

@end

NS_ASSUME_NONNULL_END
