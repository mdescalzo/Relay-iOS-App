//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "TSMessage.h"
#import "AppContext.h"
#import "MIMETypeUtil.h"
#import "NSDate+OWS.h"
#import "NSString+SSK.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "TSAttachment.h"
#import "TSAttachmentStream.h"
#import "TSQuotedMessage.h"
#import "TSThread.h"
#import <YapDatabase/YapDatabase.h>
#import <YapDatabase/YapDatabaseTransaction.h>
#import "FLCCSMJSONService.h"

NS_ASSUME_NONNULL_BEGIN

static const NSUInteger OWSMessageSchemaVersion = 4;

#pragma mark -

@interface TSMessage ()

@property (nonatomic) uint32_t expiresInSeconds;
@property (nonatomic) uint64_t expireStartedAt;

/**
 * The version of the model class's schema last used to serialize this model. Use this to manage data migrations during
 * object de/serialization.
 *
 * e.g.
 *
 *    - (id)initWithCoder:(NSCoder *)coder
 *    {
 *      self = [super initWithCoder:coder];
 *      if (!self) { return self; }
 *      if (_schemaVersion < 2) {
 *        _newName = [coder decodeObjectForKey:@"oldName"]
 *      }
 *      ...
 *      _schemaVersion = 2;
 *    }
 */
@property (nonatomic, readonly) NSUInteger schemaVersion;

// The timestamp property is populated by the envelope,
// which is created by the sender.
//
// We typically want to order messages locally by when
// they were received & decrypted, not by when they were sent.
@property (nonatomic) uint64_t receivedAtTimestamp;

@end

#pragma mark -

@implementation TSMessage

@synthesize plainTextBody = _plainTextBody;
@synthesize htmlTextBody = _htmlTextBody;
@synthesize forstaPayload = _forstaPayload;

- (instancetype)initMessageWithTimestamp:(uint64_t)timestamp
                                inThread:(nullable TSThread *)thread
                             messageBody:(nullable NSString *)body
                           attachmentIds:(NSArray<NSString *> *)attachmentIds
                        expiresInSeconds:(uint32_t)expiresInSeconds
                         expireStartedAt:(uint64_t)expireStartedAt
                           quotedMessage:(nullable TSQuotedMessage *)quotedMessage
{
    self = [super initInteractionWithTimestamp:timestamp inThread:thread];

    if (!self) {
        return self;
    }

    _schemaVersion = OWSMessageSchemaVersion;

    _body = body;
    _attachmentIds = attachmentIds ? attachmentIds : @[];
    _expiresInSeconds = expiresInSeconds;
    _expireStartedAt = expireStartedAt;
    [self updateExpiresAt];
    _receivedAtTimestamp = [NSDate ows_millisecondTimeStamp];
    _quotedMessage = quotedMessage;

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    if (_schemaVersion < 2) {
        // renamed _attachments to _attachmentIds
        if (!_attachmentIds) {
            _attachmentIds = [coder decodeObjectForKey:@"attachments"];
        }
    }

    if (_schemaVersion < 3) {
        _expiresInSeconds = 0;
        _expireStartedAt = 0;
        _expiresAt = 0;
    }

    if (_schemaVersion < 4) {
        // Wipe out the body field on these legacy attachment messages.
        //
        // Explantion: Historically, a message sent from iOS could be an attachment XOR a text message,
        // but now we support sending an attachment+caption as a single message.
        //
        // Other clients have supported sending attachment+caption in a single message for a long time.
        // So the way we used to handle receiving them was to make it look like they'd sent two messages:
        // first the attachment+caption (we'd ignore this caption when rendering), followed by a separate
        // message with just the caption (which we'd render as a simple independent text message), for
        // which we'd offset the timestamp by a little bit to get the desired ordering.
        //
        // Now that we can properly render an attachment+caption message together, these legacy "dummy" text
        // messages are not only unnecessary, but worse, would be rendered redundantly. For safety, rather
        // than building the logic to try to find and delete the redundant "dummy" text messages which users
        // have been seeing and interacting with, we delete the body field from the attachment message,
        // which iOS users have never seen directly.
        if (_attachmentIds.count > 0) {
            _body = nil;
        }
    }

    if (!_attachmentIds) {
        _attachmentIds = [NSArray new];
    }

    if (_receivedAtTimestamp == 0) {
        // Upgrade from the older "receivedAtDate" and "receivedAt" properties if
        // necessary.
        NSDate *receivedAtDate = [coder decodeObjectForKey:@"receivedAtDate"];
        if (!receivedAtDate) {
            receivedAtDate = [coder decodeObjectForKey:@"receivedAt"];
        }
        if (receivedAtDate) {
            _receivedAtTimestamp = [NSDate ows_millisecondsSince1970ForDate:receivedAtDate];
        }
    }

    _schemaVersion = OWSMessageSchemaVersion;

    return self;
}

- (void)setExpiresInSeconds:(uint32_t)expiresInSeconds
{
    uint32_t maxExpirationDuration = [OWSDisappearingMessagesConfiguration maxDurationSeconds];
    if (expiresInSeconds > maxExpirationDuration) {
        OWSFailDebug(@"%@ in %s using `maxExpirationDuration` instead of: %u",
            self.logTag,
            __PRETTY_FUNCTION__,
            maxExpirationDuration);
    }

    _expiresInSeconds = MIN(expiresInSeconds, maxExpirationDuration);
    [self updateExpiresAt];
}

- (void)setExpireStartedAt:(uint64_t)expireStartedAt
{
    if (_expireStartedAt != 0 && _expireStartedAt < expireStartedAt) {
        DDLogDebug(@"%@ in %s ignoring later startedAt time", self.logTag, __PRETTY_FUNCTION__);
        return;
    }

    uint64_t now = [NSDate ows_millisecondTimeStamp];
    if (expireStartedAt > now) {
        DDLogWarn(@"%@ in %s using `now` instead of future time", self.logTag, __PRETTY_FUNCTION__);
    }

    _expireStartedAt = MIN(now, expireStartedAt);
    [self updateExpiresAt];
}

- (BOOL)shouldStartExpireTimerWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    return self.isExpiringMessage;
}

// TODO a downloaded media doesn't start counting until download is complete.
- (void)updateExpiresAt
{
    if (_expiresInSeconds > 0 && _expireStartedAt > 0) {
        _expiresAt = _expireStartedAt + _expiresInSeconds * 1000;
    } else {
        _expiresAt = 0;
    }
}

- (BOOL)hasAttachments
{
    if (self.attachmentIds.count > 0) {
        return YES;
    } else {
        return NO;
    }
}

- (nullable TSAttachment *)attachmentWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    if (!self.hasAttachments) {
        return nil;
    }

    return [TSAttachment fetchObjectWithUniqueID:self.attachmentIds.firstObject transaction:transaction];
}

- (NSString *)debugDescription
{
    if ([self hasAttachments] && self.body.length > 0) {
        NSString *attachmentId = self.attachmentIds[0];
        return [NSString
            stringWithFormat:@"Media Message with attachmentId: %@ and caption: '%@'", attachmentId, self.body];
    } else if ([self hasAttachments]) {
        NSString *attachmentId = self.attachmentIds[0];
        return [NSString stringWithFormat:@"Media Message with attachmentId: %@", attachmentId];
    } else {
        return [NSString stringWithFormat:@"%@ with body: %@", [self class], self.body];
    }
}

// TODO: This method contains view-specific logic and probably belongs in NotificationsManager, not in SSK.
- (NSString *)previewTextWithTransaction:(YapDatabaseReadTransaction *)transaction
{    
    NSString *_Nullable attachmentDescription = nil;
    if ([self hasAttachments]) {
        NSString *attachmentId = self.attachmentIds[0];
        TSAttachment *attachment = [TSAttachment fetchObjectWithUniqueID:attachmentId transaction:transaction];
        if ([OWSMimeTypeOversizeTextMessage isEqualToString:attachment.contentType]) {
            // Handle oversize text attachments.
            if ([attachment isKindOfClass:[TSAttachmentStream class]]) {
                TSAttachmentStream *attachmentStream = (TSAttachmentStream *)attachment;
                NSData *_Nullable data = [NSData dataWithContentsOfFile:attachmentStream.filePath];
                if (data) {
                    NSString *_Nullable text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    if (text) {
                        return text.filterStringForDisplay;
                    }
                }
            }
            
            return @"";
        } else if (attachment) {
            attachmentDescription = attachment.description;
        } else {
            attachmentDescription = NSLocalizedString(@"UNKNOWN_ATTACHMENT_LABEL",
                @"In Inbox view, last message label for thread with corrupted attachment.");
        }
    }

    NSString *_Nullable bodyDescription = nil;
    if (self.plainTextBody.length > 0) {
        bodyDescription = self.plainTextBody;
    }

    if (attachmentDescription.length > 0 && bodyDescription.length > 0) {
        // Attachment with caption.
        if ([CurrentAppContext() isRTL]) {
            return [[bodyDescription stringByAppendingString:@": "] stringByAppendingString:attachmentDescription];
        } else {
            return [[attachmentDescription stringByAppendingString:@": "] stringByAppendingString:bodyDescription];
        }
    } else if (bodyDescription.length > 0) {
        return bodyDescription;
    } else if (attachmentDescription.length > 0) {
        return attachmentDescription;
    } else if ([self.messageType isEqualToString:@"control"]) {
        return @"";
    } else {
        DDLogDebug(@"%@ message has neither body nor attachment.", self.logTag);
        // TODO: We should do better here.
        return @"";
    }
}

-(void)removeKeepingAttachments:(BOOL)keepAttachments
{
    [[self dbReadWriteConnection] readWriteWithBlock:^(YapDatabaseReadWriteTransaction * _Nonnull transaction) {
        [self removeKeepingAttachments:keepAttachments withTransaction:transaction];
    }];
}

-(void)removeKeepingAttachments:(BOOL)keepAttachments withTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    if (keepAttachments) {
        [super removeWithTransaction:transaction];
    } else {
        [self removeWithTransaction:transaction];
    }
}

- (void)removeWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [super removeWithTransaction:transaction];

    for (NSString *attachmentId in self.attachmentIds) {
        // We need to fetch each attachment, since [TSAttachment removeWithTransaction:] does important work.
        TSAttachment *_Nullable attachment =
            [TSAttachment fetchObjectWithUniqueID:attachmentId transaction:transaction];
        if (!attachment) {
            DDLogDebug(@"%@ couldn't load interaction's attachment for deletion.", self.logTag);
            continue;
        }
        [attachment removeWithTransaction:transaction];
    };

    // Updates inbox thread preview
    [self touchThreadWithTransaction:transaction];
}

- (void)touchThreadWithTransaction:(YapDatabaseReadWriteTransaction *)transaction
{
    [transaction touchObjectForKey:self.uniqueThreadId inCollection:[TSThread collection]];
}

- (BOOL)isExpiringMessage
{
    return self.expiresInSeconds > 0;
}

- (uint64_t)timestampForSorting
{
    if ([self shouldUseReceiptDateForSorting] && self.receivedAtTimestamp > 0) {
        return self.receivedAtTimestamp;
    } else {
        OWSAssert(self.timestamp > 0);
        return self.timestamp;
    }
}

- (BOOL)shouldUseReceiptDateForSorting
{
    return YES;
}


// MARK: Accessors
-(NSDictionary *)forstaPayload
{
    if (_forstaPayload == nil) {
        _forstaPayload = [FLCCSMJSONService payloadDictionaryFromMessageBody:self.body];
    }
    return _forstaPayload;
}

-(void)setPlainTextBody:(nullable NSString *)value
{
    if (![_plainTextBody isEqualToString:value]) {
        _plainTextBody = value;
        
//        // Add the new value to the forstaPayload
//        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
//            if (self->_plainTextBody.length > 0) {
//                NSMutableDictionary *dataDict = [[self.forstaPayload objectForKey:@"data"] mutableCopy];
//                if (!dataDict) {
//                    dataDict = [NSMutableDictionary new];
//                }
//                NSMutableArray *body = [[dataDict objectForKey:@"body"] mutableCopy];
//                if (!body) {
//                    body = [NSMutableArray new];
//                }
//
//                NSDictionary *oldDict = nil;
//                if (body.count > 0) {
//                    for (NSDictionary *dict in body) {
//                        if ([(NSString *)[dict objectForKey:@"type"] isEqualToString:@"text/plain"]) {
//                            oldDict = dict;
//                        }
//                    }
//                }
//                NSDictionary *newDict = @{ @"type" : @"text/plain",
//                                           @"value" : value };
//                [body addObject:newDict];
//
//                if (oldDict) {
//                    [body removeObject:oldDict];
//                }
//
//                [dataDict setObject:body forKey:@"body"];
//                [self.forstaPayload setObject:dataDict forKey:@"data"];
//            } else {
//                // Empty value passed, remove the object from the payload
//                NSMutableDictionary *dataDict = [[self.forstaPayload objectForKey:@"data"] mutableCopy];
//                if (dataDict) {
//                    [dataDict removeObjectForKey:@"body"];
//                    [self.forstaPayload setObject:dataDict forKey:@"data"];
//                }
//            }
//        });
    }
}


-(nullable NSString *)plainTextBody {
    if (_plainTextBody == nil) {
        _plainTextBody = [self plainBodyStringFromPayload];
    }
    return _plainTextBody.filterStringForDisplay;
}

-(nullable NSString *)plainBodyStringFromPayload
{
    NSString *returnString = nil;
    if (self.forstaPayload) {
        NSDictionary *data = [self.forstaPayload objectForKey:@"data"];
        NSArray *body = [data objectForKey:@"body"];
        for (NSDictionary *dict in body) {
            if ([(NSString *)[dict objectForKey:@"type"] isEqualToString:@"text/plain"]) {
                returnString = (NSString *)[dict objectForKey:@"value"];
            }
        }
    }
    return returnString;
}

//-(NSAttributedString *)attributedTextBody
//{
//    if (self.forstaPayload) {
//        NSString *htmlString = [self htmlBodyStringFromPayload];
//
//        if (htmlString.length > 0) {
//            // hack to deal with appended <br> on strings from web client
//            if (htmlString.length > 4) {
//                NSString *tailString = [htmlString substringWithRange:NSMakeRange(htmlString.length-4, 4)];
//                if ([tailString isEqualToString:[NSString stringWithFormat:@"<br>"]]) {
//                    htmlString = [htmlString substringToIndex:htmlString.length-4];
//                }
//            }
//            _attributedTextBody = [NSAttributedString attributedStringFromHTML:htmlString
//                                                                    normalFont:[UIFont ows_regularFontWithSize:FLMessageViewFontSize]
//                                                                      boldFont:[UIFont ows_boldFontWithSize:FLMessageViewFontSize]
//                                                                    italicFont:[UIFont ows_italicFontWithSize:FLMessageViewFontSize]];
//        }
//    }
//    // Couldn't parse the html string so fall back to plain
//    if (_attributedTextBody.length == 0 && self.plainTextBody.length > 0) {
//        _attributedTextBody = [NSAttributedString attributedStringFromHTML:self.plainTextBody
//                                                                normalFont:[UIFont ows_regularFontWithSize:FLMessageViewFontSize]
//                                                                  boldFont:[UIFont ows_boldFontWithSize:FLMessageViewFontSize]
//                                                                italicFont:[UIFont ows_italicFontWithSize:FLMessageViewFontSize]];
//    }
//    // hack to deal with appended newline on attributedStrings
//    if (_attributedTextBody.length > 0) {
//        NSString *lastChar = [_attributedTextBody.string substringFromIndex:_attributedTextBody.string.length-1];
//        if ([lastChar isEqualToString:[NSString stringWithFormat:@"\n"]]) {
//            _attributedTextBody = [_attributedTextBody attributedSubstringFromRange:NSMakeRange(0, _attributedTextBody.string.length-1)];
//        }
//    }
//    return _attributedTextBody;
//}

-(void)setHtmlTextBody:(nullable NSString *)value
{
    if (![_htmlTextBody isEqualToString:value]) {
        _htmlTextBody = value;
    }
}


-(nullable NSString *)htmlTextBody {
    if (_htmlTextBody == nil) {
        _htmlTextBody = [self htmlBodyStringFromPayload];
    }
    return _htmlTextBody.filterStringForDisplay;
}

-(NSString *)htmlBodyStringFromPayload;
{
    NSString *returnString = nil;
    if (self.forstaPayload) {
        NSDictionary *data = [self.forstaPayload objectForKey:@"data"];
        NSArray *body = [data objectForKey:@"body"];
        for (NSDictionary *dict in body) {
            if ([(NSString *)[dict objectForKey:@"type"] isEqualToString:@"text/html"]) {
                returnString = (NSString *)[dict objectForKey:@"value"];
            }
        }
    }
    return returnString;
}
- (void)setQuotedMessageThumbnailAttachmentStream:(TSAttachmentStream *)attachmentStream
{
    OWSAssert([attachmentStream isKindOfClass:[TSAttachmentStream class]]);
    OWSAssert(self.quotedMessage);
    OWSAssert(self.quotedMessage.quotedAttachments.count == 1);

    [self.quotedMessage setThumbnailAttachmentStream:attachmentStream];
}

#pragma mark - Update With... Methods

- (void)applyChangeToSelfAndLatestCopy:(YapDatabaseReadWriteTransaction *)transaction
                           changeBlock:(void (^)(id))changeBlock
{
    OWSAssert(transaction);

    [super applyChangeToSelfAndLatestCopy:transaction changeBlock:changeBlock];
    [self touchThreadWithTransaction:transaction];
}

- (void)updateWithExpireStartedAt:(uint64_t)expireStartedAt transaction:(YapDatabaseReadWriteTransaction *)transaction
{
    OWSAssert(expireStartedAt > 0);

    [self applyChangeToSelfAndLatestCopy:transaction
                             changeBlock:^(TSMessage *message) {
                                 [message setExpireStartedAt:expireStartedAt];
                             }];
}

@end

NS_ASSUME_NONNULL_END
