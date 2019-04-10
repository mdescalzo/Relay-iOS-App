//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "ConversationViewItem.h"
#import "OWSAudioMessageView.h"
#import "OWSMessageCell.h"
#import "OWSMessageHeaderView.h"
#import "OWSSystemMessageCell.h"
#import "Relay-Swift.h"

@import AssetsLibrary;
@import RelayMessaging;
@import RelayServiceKit;
@import Photos;

NS_ASSUME_NONNULL_BEGIN

NSString *NSStringForOWSMessageCellType(OWSMessageCellType cellType)
{
    switch (cellType) {
        case OWSMessageCellType_TextMessage:
            return @"OWSMessageCellType_TextMessage";
        case OWSMessageCellType_OversizeTextMessage:
            return @"OWSMessageCellType_OversizeTextMessage";
        case OWSMessageCellType_StillImage:
            return @"OWSMessageCellType_StillImage";
        case OWSMessageCellType_AnimatedImage:
            return @"OWSMessageCellType_AnimatedImage";
        case OWSMessageCellType_Audio:
            return @"OWSMessageCellType_Audio";
        case OWSMessageCellType_Video:
            return @"OWSMessageCellType_Video";
        case OWSMessageCellType_GenericAttachment:
            return @"OWSMessageCellType_GenericAttachment";
        case OWSMessageCellType_DownloadingAttachment:
            return @"OWSMessageCellType_DownloadingAttachment";
        case MessageCellType_WebPreview:
            return @"MessageCellType_WebPreview";
        case MessageCellType_WebGiphy:
            return @"MessageCellType_WebGiphy";
        case OWSMessageCellType_Unknown:
        default:
            return @"OWSMessageCellType_Unknown";
    }
}

#pragma mark -

@interface ConversationViewItem ()

@property (nonatomic, nullable) NSValue *cachedCellSize;

#pragma mark - OWSAudioPlayerDelegate

@property (nonatomic) AudioPlaybackState audioPlaybackState;
@property (nonatomic) CGFloat audioProgressSeconds;
@property (nonatomic) CGFloat audioDurationSeconds;

#pragma mark - View State

@property (nonatomic) BOOL hasViewState;
@property (nonatomic) OWSMessageCellType messageCellType;
@property (nonatomic, nullable) DisplayableText *displayableBodyText;
@property (nonatomic, nullable) DisplayableText *displayableQuotedText;
@property (nonatomic, nullable) OWSQuotedReplyModel *quotedReply;
@property (nonatomic, readonly, nullable) NSString *quotedAttachmentMimetype;
@property (nonatomic, readonly, nullable) NSString *quotedRecipientId;
@property (nonatomic, nullable) TSAttachmentStream *attachmentStream;
@property (nonatomic, nullable) TSAttachmentPointer *attachmentPointer;
@property (nonatomic) CGSize mediaSize;

@end

#pragma mark -

@implementation ConversationViewItem

- (instancetype)initWithInteraction:(TSInteraction *)interaction
                      isGroupThread:(BOOL)isGroupThread
                        transaction:(YapDatabaseReadTransaction *)transaction
                  conversationStyle:(ConversationStyle *)conversationStyle
{
    OWSAssert(interaction);
    OWSAssert(transaction);
    OWSAssert(conversationStyle);

    self = [super init];

    if (!self) {
        return self;
    }

    _interaction = interaction;
    _isGroupThread = isGroupThread;
    _conversationStyle = conversationStyle;

    [self ensureViewState:transaction];

    return self;
}

- (void)replaceInteraction:(TSInteraction *)interaction transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssert(interaction);

    _interaction = interaction;

    self.hasViewState = NO;
    self.messageCellType = OWSMessageCellType_Unknown;
    self.displayableBodyText = nil;
    self.attachmentStream = nil;
    self.attachmentPointer = nil;
    self.mediaSize = CGSizeZero;
    self.displayableQuotedText = nil;
    self.quotedReply = nil;

    [self clearCachedLayoutState];

    [self ensureViewState:transaction];
}

-(BOOL)hasWebGiphy
{
    TSMessage *message = (TSMessage *)self.interaction;
    return message.isGiphy;
}

-(BOOL)hasUrl
{
    TSMessage *message = (TSMessage *)self.interaction;
    return (message.urlString.length > 0);
}

//-(nullable NSString *)urlString
//{
//    if (_urlString == nil) {
//        _urlString = @"";
//        TSMessage *message = (TSMessage *)self.interaction;
//        NSString *messageString = [message htmlTextBody];
//        if (messageString.length == 0) {
//            messageString = [message plainTextBody];
//        }
//        if (messageString.length > 0) {
//            NSDataDetector *linkDetector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:nil];
//            NSArray *matches = [linkDetector matchesInString:messageString options:0 range:NSMakeRange(0, messageString.length)];
//
//            for (NSTextCheckingResult *match in matches) {
//
//                if ([match resultType] == NSTextCheckingTypeLink) {
//                    NSString *aString = match.URL.absoluteString;
//                    if ([aString containsString:@"http://"] || [aString containsString:@"https://"]) {
//                        _urlString = [aString stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
//                    }
//                    break;
//                }
//            }
//        }
//    }
//    return _urlString;
//}

- (BOOL)hasBodyText
{
    return _displayableBodyText != nil;
}

- (BOOL)hasQuotedText
{
    return _displayableQuotedText != nil;
}

- (BOOL)hasQuotedAttachment
{
    return self.quotedAttachmentMimetype.length > 0;
}

- (BOOL)isQuotedReply
{
    return self.hasQuotedAttachment || self.hasQuotedText;
}

- (BOOL)isExpiringMessage
{
    if (self.interaction.interactionType != OWSInteractionType_OutgoingMessage
        && self.interaction.interactionType != OWSInteractionType_IncomingMessage) {
        return NO;
    }

    TSMessage *message = (TSMessage *)self.interaction;
    return message.isExpiringMessage;
}

- (BOOL)hasCellHeader
{
    return self.shouldShowDate || self.unreadIndicator;
}

- (void)setShouldShowDate:(BOOL)shouldShowDate
{
    if (_shouldShowDate == shouldShowDate) {
        return;
    }

    _shouldShowDate = shouldShowDate;

    [self clearCachedLayoutState];
}

- (void)setShouldShowSenderAvatar:(BOOL)shouldShowSenderAvatar
{
    if (_shouldShowSenderAvatar == shouldShowSenderAvatar) {
        return;
    }

    _shouldShowSenderAvatar = shouldShowSenderAvatar;

    [self clearCachedLayoutState];
}

- (void)setSenderName:(nullable NSAttributedString *)senderName
{
    if ([NSObject isNullableObject:senderName equalTo:_senderName]) {
        return;
    }

    _senderName = senderName;

    [self clearCachedLayoutState];
}

- (void)setShouldHideFooter:(BOOL)shouldHideFooter
{
    if (_shouldHideFooter == shouldHideFooter) {
        return;
    }

    _shouldHideFooter = shouldHideFooter;

    [self clearCachedLayoutState];
}

- (void)setUnreadIndicator:(nullable OWSUnreadIndicator *)unreadIndicator
{
    if ([NSObject isNullableObject:_unreadIndicator equalTo:unreadIndicator]) {
        return;
    }

    _unreadIndicator = unreadIndicator;

    [self clearCachedLayoutState];
}

- (void)clearCachedLayoutState
{
    self.cachedCellSize = nil;
}

- (CGSize)cellSizeWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssert(transaction);
    OWSAssertIsOnMainThread();
    OWSAssert(self.conversationStyle);

    if (!self.cachedCellSize) {
        ConversationViewCell *_Nullable measurementCell = [self measurementCell];
        measurementCell.viewItem = self;
        measurementCell.conversationStyle = self.conversationStyle;
        CGSize cellSize = [measurementCell cellSizeWithTransaction:transaction];
        self.cachedCellSize = [NSValue valueWithCGSize:cellSize];
        [measurementCell prepareForReuse];
    }
    return [self.cachedCellSize CGSizeValue];
}

- (nullable ConversationViewCell *)measurementCell
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.interaction);

    // For performance reasons, we cache one instance of each kind of
    // cell and uses these cells for measurement.
    static NSMutableDictionary<NSNumber *, ConversationViewCell *> *measurementCellCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        measurementCellCache = [NSMutableDictionary new];
    });

    NSNumber *cellCacheKey = @(self.interaction.interactionType);
    ConversationViewCell *_Nullable measurementCell = measurementCellCache[cellCacheKey];
    if (!measurementCell) {
        switch (self.interaction.interactionType) {
            case OWSInteractionType_Unknown:
                OWSFailDebug(@"%@ Unknown interaction type.", self.logTag);
                return nil;
            case OWSInteractionType_IncomingMessage:
            case OWSInteractionType_OutgoingMessage:
                measurementCell = [OWSMessageCell new];
                break;
            case OWSInteractionType_Error:
            case OWSInteractionType_Info:
            case OWSInteractionType_Call:
                measurementCell = [OWSSystemMessageCell new];
                break;
        }

        OWSAssert(measurementCell);
        measurementCellCache[cellCacheKey] = measurementCell;
    }

    return measurementCell;
}

- (CGFloat)vSpacingWithPreviousLayoutItem:(ConversationViewItem *)previousLayoutItem
{
    OWSAssert(previousLayoutItem);

    if (self.hasCellHeader) {
        return OWSMessageHeaderViewDateHeaderVMargin;
    }

    // "Bubble Collapse".  Adjacent messages with the same author should be close together.
    if (self.interaction.interactionType == OWSInteractionType_IncomingMessage
        && previousLayoutItem.interaction.interactionType == OWSInteractionType_IncomingMessage) {
        TSIncomingMessage *incomingMessage = (TSIncomingMessage *)self.interaction;
        TSIncomingMessage *previousIncomingMessage = (TSIncomingMessage *)previousLayoutItem.interaction;
        if ([incomingMessage.authorId isEqualToString:previousIncomingMessage.authorId]) {
            return 2.f;
        }
    } else if (self.interaction.interactionType == OWSInteractionType_OutgoingMessage
        && previousLayoutItem.interaction.interactionType == OWSInteractionType_OutgoingMessage) {
        return 2.f;
    }

    return 12.f;
}

- (ConversationViewCell *)dequeueCellForCollectionView:(UICollectionView *)collectionView
                                             indexPath:(NSIndexPath *)indexPath
{
    OWSAssertIsOnMainThread();
    OWSAssert(collectionView);
    OWSAssert(indexPath);
    OWSAssert(self.interaction);

    switch (self.interaction.interactionType) {
        case OWSInteractionType_IncomingMessage:
        case OWSInteractionType_OutgoingMessage:
            return [collectionView dequeueReusableCellWithReuseIdentifier:[OWSMessageCell cellReuseIdentifier]
                                                             forIndexPath:indexPath];
        case OWSInteractionType_Error:
        case OWSInteractionType_Info:
        case OWSInteractionType_Call:
            return [collectionView dequeueReusableCellWithReuseIdentifier:[OWSSystemMessageCell cellReuseIdentifier]
                                                             forIndexPath:indexPath];
        case OWSInteractionType_Unknown:
        default:
            OWSFailDebug(@"%@ Unknown interaction type.", self.logTag);
            return nil;
    }
}

#pragma mark - OWSAudioPlayerDelegate

- (void)setAudioPlaybackState:(AudioPlaybackState)audioPlaybackState
{
    _audioPlaybackState = audioPlaybackState;

    [self.lastAudioMessageView updateContents];
}

- (void)setAudioProgress:(CGFloat)progress duration:(CGFloat)duration
{
    OWSAssertIsOnMainThread();

    self.audioProgressSeconds = progress;

    [self.lastAudioMessageView updateContents];
}

#pragma mark - Displayable Text

// TODO: Now that we're caching the displayable text on the view items,
//       I don't think we need this cache any more.
- (NSCache *)displayableTextCache
{
    static NSCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        // Cache the results for up to 1,000 messages.
        cache.countLimit = 1000;
    });
    return cache;
}

- (DisplayableText *)displayableBodyTextForText:(NSString *)text interactionId:(NSString *)interactionId
{
    OWSAssert(text);
    OWSAssert(interactionId.length > 0);

    NSString *displayableTextCacheKey = [@"body-" stringByAppendingString:interactionId];

    return [self displayableTextForCacheKey:displayableTextCacheKey
                                  textBlock:^{
                                      return text;
                                  }];
}

- (DisplayableText *)displayableBodyTextForOversizeTextAttachment:(TSAttachmentStream *)attachmentStream
                                                    interactionId:(NSString *)interactionId
{
    OWSAssert(attachmentStream);
    OWSAssert(interactionId.length > 0);

    NSString *displayableTextCacheKey = [@"oversize-body-" stringByAppendingString:interactionId];

    return [self displayableTextForCacheKey:displayableTextCacheKey
                                  textBlock:^{
                                      NSData *textData = [NSData dataWithContentsOfURL:attachmentStream.mediaURL];
                                      NSString *text =
                                          [[NSString alloc] initWithData:textData encoding:NSUTF8StringEncoding];
                                      return text;
                                  }];
}

- (DisplayableText *)displayableQuotedTextForText:(NSString *)text interactionId:(NSString *)interactionId
{
    OWSAssert(text);
    OWSAssert(interactionId.length > 0);

    NSString *displayableTextCacheKey = [@"quoted-" stringByAppendingString:interactionId];

    return [self displayableTextForCacheKey:displayableTextCacheKey
                                  textBlock:^{
                                      return text;
                                  }];
}

- (DisplayableText *)displayableTextForCacheKey:(NSString *)displayableTextCacheKey
                                      textBlock:(NSString * (^_Nonnull)(void))textBlock
{
    OWSAssert(displayableTextCacheKey.length > 0);

    DisplayableText *_Nullable displayableText = [[self displayableTextCache] objectForKey:displayableTextCacheKey];
    if (!displayableText) {
        NSString *text = textBlock();
        displayableText = [DisplayableText displayableText:text];
        [[self displayableTextCache] setObject:displayableText forKey:displayableTextCacheKey];
    }
    return displayableText;
}

#pragma mark - View State

- (nullable TSAttachment *)firstAttachmentIfAnyOfMessage:(TSMessage *)message
                                             transaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAssert(transaction);

    if (message.attachmentIds.count == 0) {
        return nil;
    }
    NSString *_Nullable attachmentId = message.attachmentIds.firstObject;
    if (attachmentId.length == 0) {
        return nil;
    }
    return [TSAttachment fetchObjectWithUniqueID:attachmentId transaction:transaction];
}

- (void)ensureViewState:(YapDatabaseReadTransaction *)transaction
{
    OWSAssertIsOnMainThread();
    OWSAssert(transaction);
    OWSAssert(!self.hasViewState);

    if (![self.interaction isKindOfClass:[TSOutgoingMessage class]]
        && ![self.interaction isKindOfClass:[TSIncomingMessage class]]) {
        // Only text & attachment messages have "view state".
        return;
    }

    self.hasViewState = YES;

    TSMessage *message = (TSMessage *)self.interaction;
    TSAttachment *_Nullable attachment = [self firstAttachmentIfAnyOfMessage:message transaction:transaction];
    if (attachment) {
        if ([attachment isKindOfClass:[TSAttachmentStream class]]) {
            self.attachmentStream = (TSAttachmentStream *)attachment;

            if ([attachment.contentType isEqualToString:OWSMimeTypeOversizeTextMessage]) {
                self.messageCellType = OWSMessageCellType_OversizeTextMessage;
                self.displayableBodyText = [self displayableBodyTextForOversizeTextAttachment:self.attachmentStream
                                                                                interactionId:message.uniqueId];
            } else if ([self.attachmentStream isAnimated] || [self.attachmentStream isImage] ||
                [self.attachmentStream isVideo]) {
                if ([self.attachmentStream isAnimated]) {
                    self.messageCellType = OWSMessageCellType_AnimatedImage;
                } else if ([self.attachmentStream isImage]) {
                    self.messageCellType = OWSMessageCellType_StillImage;
                } else if ([self.attachmentStream isVideo]) {
                    self.messageCellType = OWSMessageCellType_Video;
                } else {
                    OWSFailDebug(@"%@ unexpected attachment type.", self.logTag);
                    self.messageCellType = OWSMessageCellType_GenericAttachment;
                    return;
                }
                self.mediaSize = [self.attachmentStream imageSize];
                if (self.mediaSize.width <= 0 || self.mediaSize.height <= 0) {
                    self.messageCellType = OWSMessageCellType_GenericAttachment;
                }
            } else if ([self.attachmentStream isAudio]) {
                CGFloat audioDurationSeconds = [self.attachmentStream audioDurationSeconds];
                if (audioDurationSeconds > 0) {
                    self.audioDurationSeconds = audioDurationSeconds;
                    self.messageCellType = OWSMessageCellType_Audio;
                } else {
                    self.messageCellType = OWSMessageCellType_GenericAttachment;
                }
            } else {
                self.messageCellType = OWSMessageCellType_GenericAttachment;
            }
        } else if ([attachment isKindOfClass:[TSAttachmentPointer class]]) {
            self.messageCellType = OWSMessageCellType_DownloadingAttachment;
            self.attachmentPointer = (TSAttachmentPointer *)attachment;
        } else {
            OWSFailDebug(@"%@ Unknown attachment type", self.logTag);
        }
    } else if (self.hasWebGiphy) {
        self.messageCellType = MessageCellType_WebGiphy;
        if (message.giphyImageData == nil) {
            self.mediaSize = [UIImage imageNamed:@"giphy_logo"].size;
        } else {
            UIImage *image = [UIImage imageWithData:message.giphyImageData];
            if (image != nil) {
                self.mediaSize = image.size;
            } else {
                self.mediaSize = [UIImage imageNamed:@"giphy_logo"].size;
            }
        }
    } else if (self.hasUrl && Environment.preferences.showWebPreviews) {
        self.messageCellType = MessageCellType_WebPreview;
    }

    // Ignore message body for oversize text attachments.
    if (message.plainTextBody.length > 0) {
        if (self.hasBodyText) {
            OWSFailDebug(@"%@ oversize text message has unexpected caption.", self.logTag);
        }

        // If we haven't already assigned an attachment type at this point, message.body isn't a caption,
        // it's a stand-alone text message.
        if (self.messageCellType == OWSMessageCellType_Unknown) {
//            OWSAssert(message.attachmentIds.count == 0);
            self.messageCellType = OWSMessageCellType_TextMessage;
        }
        self.displayableBodyText = [self displayableBodyTextForText:message.plainTextBody interactionId:message.uniqueId];
        OWSAssert(self.displayableBodyText);
    }

    if (self.messageCellType == OWSMessageCellType_Unknown) {
        // Messages of unknown type (including messages with missing attachments)
        // are rendered like empty text messages, but without any interactivity.
        DDLogWarn(@"%@ Treating unknown message as empty text message: %@ %llu", self.logTag, message.class, message.timestamp);
        self.messageCellType = OWSMessageCellType_TextMessage;
        self.displayableBodyText = [[DisplayableText alloc] initWithFullText:@"" displayText:@"" isTextTruncated:NO];
    }

    if (message.quotedMessage) {
        self.quotedReply =
            [[OWSQuotedReplyModel alloc] initWithQuotedMessage:message.quotedMessage transaction:transaction];

        if (self.quotedReply.body.length > 0) {
            self.displayableQuotedText =
                [self displayableQuotedTextForText:self.quotedReply.body interactionId:message.uniqueId];
        }
    }
}

- (nullable NSString *)quotedAttachmentMimetype
{
    return self.quotedReply.contentType;
}

- (nullable NSString *)quotedRecipientId
{
    return self.quotedReply.authorId;
}

- (OWSMessageCellType)messageCellType
{
    OWSAssertIsOnMainThread();

    return _messageCellType;
}

- (nullable DisplayableText *)displayableBodyText
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.hasViewState);

    OWSAssert(_displayableBodyText);
    OWSAssert(_displayableBodyText.displayText);
    OWSAssert(_displayableBodyText.fullText);

    return _displayableBodyText;
}

- (nullable TSAttachmentStream *)attachmentStream
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.hasViewState);

    return _attachmentStream;
}

- (nullable TSAttachmentPointer *)attachmentPointer
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.hasViewState);

    return _attachmentPointer;
}

- (CGSize)mediaSize
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.hasViewState);

    return _mediaSize;
}

- (nullable DisplayableText *)displayableQuotedText
{
    OWSAssertIsOnMainThread();
    OWSAssert(self.hasViewState);

    OWSAssert(_displayableQuotedText);
    OWSAssert(_displayableQuotedText.displayText);
    OWSAssert(_displayableQuotedText.fullText);

    return _displayableQuotedText;
}

- (void)copyTextAction
{
    switch (self.messageCellType) {
        case MessageCellType_WebPreview:
        case OWSMessageCellType_TextMessage:
        case OWSMessageCellType_OversizeTextMessage:
        case OWSMessageCellType_StillImage:
        case OWSMessageCellType_AnimatedImage:
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_Video:
        case OWSMessageCellType_GenericAttachment: {
            OWSAssertDebug(self.displayableBodyText);
            [UIPasteboard.generalPasteboard setString:self.displayableBodyText.fullText];
            break;
        }
        case MessageCellType_WebGiphy: {
            TSMessage *message = (TSMessage *)self.interaction;
            [UIPasteboard.generalPasteboard setString:message.urlString];
            break;
        }
        case OWSMessageCellType_DownloadingAttachment: {
            OWSFailDebug(@"%@ Can't copy not-yet-downloaded attachment", self.logTag);
            break;
        }
        case OWSMessageCellType_Unknown: {
            OWSFailDebug(@"%@ No text to copy", self.logTag);
            break;
        }
    }
}

- (void)copyMediaAction
{
    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextMessage:
        case OWSMessageCellType_OversizeTextMessage:
        case OWSMessageCellType_StillImage:
        case OWSMessageCellType_AnimatedImage:
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_Video:
        case OWSMessageCellType_GenericAttachment: {
            NSString *utiType = [MIMETypeUtil utiTypeForMIMEType:self.attachmentStream.contentType];
            if (!utiType) {
                OWSFailDebug(@"%@ Unknown MIME type: %@", self.logTag, self.attachmentStream.contentType);
                utiType = (NSString *)kUTTypeGIF;
            }
            NSData *data = [NSData dataWithContentsOfURL:[self.attachmentStream mediaURL]];
            if (!data) {
                OWSFailDebug(@"%@ Could not load attachment data: %@", self.logTag, [self.attachmentStream mediaURL]);
                return;
            }
            [UIPasteboard.generalPasteboard setData:data forPasteboardType:utiType];
            break;
        }
        case MessageCellType_WebPreview:
        case MessageCellType_WebGiphy: {
            TSMessage *message = (TSMessage *)self.interaction;
            [UIPasteboard.generalPasteboard setString:message.urlString];
            break;
        }
        case OWSMessageCellType_DownloadingAttachment: {
            OWSFailDebug(@"%@ Can't copy not-yet-downloaded attachment", self.logTag);
            break;
        }
    }
}

- (void)shareTextAction
{
    switch (self.messageCellType) {
        case OWSMessageCellType_TextMessage:
        case OWSMessageCellType_OversizeTextMessage:
        case OWSMessageCellType_StillImage:
        case OWSMessageCellType_AnimatedImage:
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_Video:
        case OWSMessageCellType_GenericAttachment: {
        case MessageCellType_WebPreview:
        case MessageCellType_WebGiphy:
            OWSAssert(self.displayableBodyText);
            [AttachmentSharing showShareUIForText:self.displayableBodyText.fullText];
            break;
        }
        case OWSMessageCellType_DownloadingAttachment: {
            OWSFailDebug(@"%@ Can't share not-yet-downloaded attachment", self.logTag);
            break;
        }
        case OWSMessageCellType_Unknown: {
            OWSFailDebug(@"%@ No text to share", self.logTag);
            break;
        }
    }
}

- (void)shareMediaAction
{
    switch (self.messageCellType) {
        case MessageCellType_WebPreview:
        case MessageCellType_WebGiphy:
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextMessage:
        case OWSMessageCellType_OversizeTextMessage:
            break;
        case OWSMessageCellType_StillImage:
        case OWSMessageCellType_AnimatedImage:
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_Video:
        case OWSMessageCellType_GenericAttachment:
            [AttachmentSharing showShareUIForAttachment:self.attachmentStream];
            break;
        case OWSMessageCellType_DownloadingAttachment: {
            OWSFailDebug(@"%@ Can't share not-yet-downloaded attachment", self.logTag);
            break;
        }
    }
}

- (BOOL)canSaveMedia
{
    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextMessage:
        case OWSMessageCellType_OversizeTextMessage:
        case OWSMessageCellType_StillImage:
        case OWSMessageCellType_AnimatedImage:
            return YES;
            break;
        case OWSMessageCellType_Audio:
            return NO;
            break;
        case OWSMessageCellType_Video:
            return UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(self.attachmentStream.mediaURL.path);
            break;
        case OWSMessageCellType_GenericAttachment:
        case OWSMessageCellType_DownloadingAttachment:
        case MessageCellType_WebPreview:
        case MessageCellType_WebGiphy:
            return NO;
            break;
    }
}

- (void)saveMediaAction
{
    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextMessage:
        case OWSMessageCellType_OversizeTextMessage:
        case MessageCellType_WebGiphy:
        case MessageCellType_WebPreview:
            OWSFailDebug(@"%@ Cannot save text data.", self.logTag);
            break;
        case OWSMessageCellType_StillImage:
        case OWSMessageCellType_AnimatedImage: {
            __block NSURL *mediaUrl = [self.attachmentStream mediaURL];
            
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:mediaUrl];
            } completionHandler:^(BOOL success, NSError * _Nullable error) {
                NSString *message = nil;
                UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:^(UIAlertAction * _Nonnull action) {
                                                                     // Nothin'
                                                                 }];
                if (success) {
                    message = NSLocalizedString(@"IMAGE_SAVE_SUCCESSFUL", @"Alert message for successfuly saved image attachment.");
                } else {
                    NSString *format = NSLocalizedString(@"IMAGE_SAVE_FAILED", @"Alert message for successfuly saved image attachment.");
                    message = [NSString stringWithFormat:format, error.localizedDescription];
                    DDLogWarn(@"Error Saving image to photo album: %@", error);
                }
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                               message:message
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:okAction];
                DispatchMainThreadSafe(^{
                    [[UIApplication.sharedApplication findFrontmostViewControllerWithIgnoringAlerts:YES] presentViewController:alert animated:YES completion:nil];
                });
            }];
        }
            break;
        case OWSMessageCellType_Audio:
            OWSFailDebug(@"%@ Cannot save media data.", self.logTag);
            break;
        case OWSMessageCellType_Video: {
            __block NSURL *mediaUrl = self.attachmentStream.mediaURL;
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:mediaUrl];
            } completionHandler:^(BOOL success, NSError * _Nullable error) {
                NSString *message = nil;
                UIAlertAction *okAction = [UIAlertAction actionWithTitle:NSLocalizedString(@"OK", nil)
                                                                   style:UIAlertActionStyleDefault
                                                                 handler:^(UIAlertAction * _Nonnull action) {
                                                                     // Nothin'
                                                                 }];
                if (success) {
                    message = NSLocalizedString(@"IMAGE_SAVE_SUCCESSFUL", @"Alert message for successfuly saved image attachment.");
                } else {
                    NSString *format = NSLocalizedString(@"IMAGE_SAVE_FAILED", @"Alert message for successfuly saved image attachment.");
                    message = [NSString stringWithFormat:format, error.localizedDescription];
                    DDLogWarn(@"Error Saving image to photo album: %@", error);
                }
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                               message:message
                                                                        preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:okAction];
                DispatchMainThreadSafe(^{
                    [[UIApplication.sharedApplication findFrontmostViewControllerWithIgnoringAlerts:YES] presentViewController:alert animated:YES completion:nil];
                });
            }];
        }
            break;
        case OWSMessageCellType_GenericAttachment:
            OWSFailDebug(@"%@ Cannot save media data.", self.logTag);
            break;
        case OWSMessageCellType_DownloadingAttachment: {
            OWSFailDebug(@"%@ Can't save not-yet-downloaded attachment", self.logTag);
            break;
        }
    }
}

- (void)deleteAction
{
    [self.interaction remove];
}

- (BOOL)hasBodyTextActionContent
{
    return self.hasBodyText && self.displayableBodyText.fullText.length > 0;
}

- (BOOL)hasMediaActionContent
{
    switch (self.messageCellType) {
        case OWSMessageCellType_Unknown:
        case OWSMessageCellType_TextMessage:
        case MessageCellType_WebPreview:
        case MessageCellType_WebGiphy:
        case OWSMessageCellType_OversizeTextMessage:
        case OWSMessageCellType_StillImage:
        case OWSMessageCellType_AnimatedImage:
        case OWSMessageCellType_Audio:
        case OWSMessageCellType_Video:
        case OWSMessageCellType_GenericAttachment:
            return self.attachmentStream != nil;
        case OWSMessageCellType_DownloadingAttachment: {
            return NO;
        }
    }
}

@end

NS_ASSUME_NONNULL_END
