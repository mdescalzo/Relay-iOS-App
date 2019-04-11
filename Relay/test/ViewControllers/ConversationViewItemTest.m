//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "ConversationViewItem.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import <RelayMessaging/RelayMessaging-Swift.h>
#import <RelayServiceKit/MIMETypeUtil.h>
#import <RelayServiceKit/SecurityUtils.h>
#import <RelayServiceKit/TSAttachmentStream.h>
#import <RelayServiceKit/TSThread.h>
#import <RelayServiceKit/TSOutgoingMessage.h>
#import <XCTest/XCTest.h>
#import <YapDatabase/YapDatabaseConnection.h>

@interface ConversationViewItemTest : XCTestCase

@property TSThread *thread;
@property ConversationStyle *conversationStyle;

@end

@implementation ConversationViewItemTest

- (void)setUp
{
    [super setUp];
    self.thread = [TSThread getOrCreateThreadWithId:@"+15555555"];
    self.conversationStyle = [[ConversationStyle alloc] initWithThread:self.thread];
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

- (NSString *)fakeTextMessageText
{
    return @"abc";
}

- (ConversationViewItem *)textViewItem
{
    TSOutgoingMessage *message =
        [TSOutgoingMessage outgoingMessageInThread:self.thread messageBody:self.fakeTextMessageText attachmentId:nil];
    [message save];
    __block ConversationViewItem *viewItem = nil;
    [TSYapDatabaseObject.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        viewItem = [[ConversationViewItem alloc] initWithInteraction:message
                                                       isGroupThread:NO
                                                         transaction:transaction
                                                   conversationStyle:self.conversationStyle];
    }];
    return viewItem;
}

- (ConversationViewItem *)viewItemWithAttachmentMimetype:(NSString *)mimeType filename:(NSString *)filename
{
    OWSAssertDebug(filename.length > 0);

    NSString *resourcePath = [[NSBundle bundleForClass:[self class]] resourcePath];
    NSString *filePath = [resourcePath stringByAppendingPathComponent:filename];

    OWSAssertDebug([[NSFileManager defaultManager] fileExistsAtPath:filePath]);

    DataSource *dataSource = [DataSourcePath dataSourceWithFilePath:filePath];
    TSAttachmentStream *attachment = [[TSAttachmentStream alloc] initWithContentType:mimeType
                                                                           byteCount:(UInt32)dataSource.dataLength
                                                                      sourceFilename:nil];
    BOOL success = [attachment writeDataSource:dataSource];
    OWSAssertDebug(success);
    [attachment save];
    TSOutgoingMessage *message =
        [TSOutgoingMessage outgoingMessageInThread:self.thread messageBody:nil attachmentId:attachment.uniqueId];
    [message save];

    __block ConversationViewItem *viewItem = nil;
    [TSYapDatabaseObject.dbReadConnection readWithBlock:^(YapDatabaseReadTransaction *transaction) {
        viewItem = [[ConversationViewItem alloc] initWithInteraction:message
                                                       isGroupThread:NO
                                                         transaction:transaction
                                                   conversationStyle:self.conversationStyle];
    }];

    return viewItem;
}

- (ConversationViewItem *)stillImageViewItem
{
    return [self viewItemWithAttachmentMimetype:OWSMimeTypeImageJpeg filename:@"test-jpg.jpg"];
}

- (ConversationViewItem *)animatedImageViewItem
{
    return [self viewItemWithAttachmentMimetype:OWSMimeTypeImageGif filename:@"test-gif.gif"];
}

- (ConversationViewItem *)videoViewItem
{
    return [self viewItemWithAttachmentMimetype:@"video/mp4" filename:@"test-mp4.mp4"];
}

- (ConversationViewItem *)audioViewItem
{
    return [self viewItemWithAttachmentMimetype:@"audio/mp3" filename:@"test-mp3.mp3"];
}

// Test Delete

- (void)testPerformDeleteEditingActionWithNonMediaMessage
{
    ConversationViewItem *viewItem = self.textViewItem;

    XCTAssertNotNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    [viewItem deleteAction];
    XCTAssertNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
}

- (void)testPerformDeleteActionWithPhotoMessage
{
    ConversationViewItem *viewItem = self.stillImageViewItem;

    XCTAssertEqual((NSUInteger)1, ((TSMessage *)viewItem.interaction).attachmentIds.count);
    NSString *_Nullable attachmentId = ((TSMessage *)viewItem.interaction).attachmentIds.firstObject;
    XCTAssertNotNil(attachmentId);
    TSAttachment *_Nullable attachment = [TSAttachment fetchObjectWithUniqueID:attachmentId];
    XCTAssertTrue([attachment isKindOfClass:[TSAttachmentStream class]]);
    TSAttachmentStream *_Nullable attachmentStream = (TSAttachmentStream *)attachment;
    NSString *_Nullable filePath = attachmentStream.filePath;
    XCTAssertNotNil(filePath);

    XCTAssertNotNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNotNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
    [viewItem deleteAction];
    XCTAssertNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
}

- (void)testPerformDeleteEditingActionWithAnimatedMessage
{
    ConversationViewItem *viewItem = self.animatedImageViewItem;

    XCTAssertEqual((NSUInteger)1, ((TSMessage *)viewItem.interaction).attachmentIds.count);
    NSString *_Nullable attachmentId = ((TSMessage *)viewItem.interaction).attachmentIds.firstObject;
    XCTAssertNotNil(attachmentId);
    TSAttachment *_Nullable attachment = [TSAttachment fetchObjectWithUniqueID:attachmentId];
    XCTAssertTrue([attachment isKindOfClass:[TSAttachmentStream class]]);
    TSAttachmentStream *_Nullable attachmentStream = (TSAttachmentStream *)attachment;
    NSString *_Nullable filePath = attachmentStream.filePath;
    XCTAssertNotNil(filePath);

    XCTAssertNotNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNotNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
    [viewItem deleteAction];
    XCTAssertNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
}

- (void)testPerformDeleteEditingActionWithVideoMessage
{
    ConversationViewItem *viewItem = self.videoViewItem;

    XCTAssertEqual((NSUInteger)1, ((TSMessage *)viewItem.interaction).attachmentIds.count);
    NSString *_Nullable attachmentId = ((TSMessage *)viewItem.interaction).attachmentIds.firstObject;
    XCTAssertNotNil(attachmentId);
    TSAttachment *_Nullable attachment = [TSAttachment fetchObjectWithUniqueID:attachmentId];
    XCTAssertTrue([attachment isKindOfClass:[TSAttachmentStream class]]);
    TSAttachmentStream *_Nullable attachmentStream = (TSAttachmentStream *)attachment;
    NSString *_Nullable filePath = attachmentStream.filePath;
    XCTAssertNotNil(filePath);

    XCTAssertNotNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNotNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
    [viewItem deleteAction];
    XCTAssertNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
}

- (void)testPerformDeleteEditingActionWithAudioMessage
{
    ConversationViewItem *viewItem = self.audioViewItem;

    XCTAssertEqual((NSUInteger)1, ((TSMessage *)viewItem.interaction).attachmentIds.count);
    NSString *_Nullable attachmentId = ((TSMessage *)viewItem.interaction).attachmentIds.firstObject;
    XCTAssertNotNil(attachmentId);
    TSAttachment *_Nullable attachment = [TSAttachment fetchObjectWithUniqueID:attachmentId];
    XCTAssertTrue([attachment isKindOfClass:[TSAttachmentStream class]]);
    TSAttachmentStream *_Nullable attachmentStream = (TSAttachmentStream *)attachment;
    NSString *_Nullable filePath = attachmentStream.filePath;
    XCTAssertNotNil(filePath);

    XCTAssertNotNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNotNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
    [viewItem deleteAction];
    XCTAssertNil([TSMessage fetchObjectWithUniqueID:viewItem.interaction.uniqueId]);
    XCTAssertNil([TSAttachment fetchObjectWithUniqueID:attachmentId]);
    XCTAssertFalse([[NSFileManager defaultManager] fileExistsAtPath:filePath]);
}

// Test Copy

- (void)testPerformCopyEditingActionWithNonMediaMessage
{
    // Reset the pasteboard.
    UIPasteboard.generalPasteboard.items = @[];
    XCTAssertNil(UIPasteboard.generalPasteboard.string);

    ConversationViewItem *viewItem = self.textViewItem;
    [viewItem copyTextAction];
    XCTAssertEqualObjects(self.fakeTextMessageText, UIPasteboard.generalPasteboard.string);
}

- (void)testPerformCopyEditingActionWithStillImageMessage
{
    // Reset the pasteboard.
    UIPasteboard.generalPasteboard.items = @[];
    XCTAssertNil(UIPasteboard.generalPasteboard.image);
    XCTAssertNil([UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeJPEG]);

    ConversationViewItem *viewItem = self.stillImageViewItem;
    [viewItem copyMediaAction];
    NSData *_Nullable copiedData = [UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeJPEG];
    XCTAssertTrue(copiedData.length > 0);
}

- (void)testPerformCopyEditingActionWithAnimatedImageMessage
{
    // Reset the pasteboard.
    UIPasteboard.generalPasteboard.items = @[];
    XCTAssertNil(UIPasteboard.generalPasteboard.image);
    XCTAssertNil([UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeGIF]);

    ConversationViewItem *viewItem = self.animatedImageViewItem;
    [viewItem copyMediaAction];
    NSData *_Nullable copiedData = [UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeGIF];
    XCTAssertTrue(copiedData.length > 0);
}

- (void)testPerformCopyEditingActionWithVideoMessage
{
    // Reset the pasteboard.
    UIPasteboard.generalPasteboard.items = @[];
    XCTAssertNil([UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeMPEG4]);

    ConversationViewItem *viewItem = self.videoViewItem;
    [viewItem copyMediaAction];
    NSData *_Nullable copiedData = [UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeMPEG4];
    XCTAssertTrue(copiedData.length > 0);
}

- (void)testPerformCopyEditingActionWithMp3AudioMessage
{
    // Reset the pasteboard.
    UIPasteboard.generalPasteboard.items = @[];
    XCTAssertNil([UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeMP3]);

    ConversationViewItem *viewItem = self.audioViewItem;
    [viewItem copyMediaAction];
    NSData *_Nullable copiedData = [UIPasteboard.generalPasteboard dataForPasteboardType:(NSString *)kUTTypeMP3];
    XCTAssertTrue(copiedData.length > 0);
}

- (void)unknownAction:(id)sender
{
    // It's easier to create this stub method than to suppress the "unknown selector" build warnings.
}

@end
