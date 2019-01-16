//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "ConversationViewCell.h"
#import "ConversationViewItem.h"

@import SignalCoreKit;

NS_ASSUME_NONNULL_BEGIN

@implementation ConversationViewCell

- (void)prepareForReuse
{
    [super prepareForReuse];

    self.viewItem = nil;
    self.delegate = nil;
    self.isCellVisible = NO;
    self.conversationStyle = nil;
}

- (void)loadForDisplayWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAbstractMethod();
}

- (CGSize)cellSizeWithTransaction:(YapDatabaseReadTransaction *)transaction
{
    OWSAbstractMethod();

    return CGSizeZero;
}

- (void)setIsCellVisible:(BOOL)isCellVisible
{
    _isCellVisible = isCellVisible;

    if (isCellVisible) {
        [self layoutIfNeeded];
    }
}

@end

NS_ASSUME_NONNULL_END
