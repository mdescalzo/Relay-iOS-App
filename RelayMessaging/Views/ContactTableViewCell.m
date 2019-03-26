//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "ContactTableViewCell.h"
#import "ContactCellView.h"
#import "OWSTableViewController.h"
#import "UIFont+OWS.h"
#import "UIView+OWS.h"
#import <RelayMessaging/RelayMessaging-Swift.h>

NS_ASSUME_NONNULL_BEGIN

@interface ContactTableViewCell ()

@property (nonatomic) ContactCellView *cellView;

@end

#pragma mark -

@implementation ContactTableViewCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(nullable NSString *)reuseIdentifier
{
    if (self = [super initWithStyle:style reuseIdentifier:reuseIdentifier]) {
        [self configure];
    }
    return self;
}

+ (NSString *)reuseIdentifier
{
    return NSStringFromClass(self.class);
}

- (void)setAccessoryView:(nullable UIView *)accessoryView
{
    OWSFail(@"%@ use ows_setAccessoryView instead.", self.logTag);
}

- (void)configure
{
    OWSAssert(!self.cellView);

    self.preservesSuperviewLayoutMargins = YES;
    self.contentView.preservesSuperviewLayoutMargins = YES;

    self.cellView = [ContactCellView new];
    [self.contentView addSubview:self.cellView];
    [self.cellView autoPinEdgesToSuperviewMargins];
    self.cellView.userInteractionEnabled = NO;
}

- (void)configureWithTagId:(NSString *)tagId contactsManager:(FLContactsManager *)contactsManager
{
    [OWSTableItem configureCell:self];
    
    [self.cellView configureWithTagId:tagId contactsManager:contactsManager];
    
    // Force layout, since imageView isn't being initally rendered on App Store optimized build.
    [self layoutSubviews];}

- (void)configureWithRecipientId:(NSString *)recipientId contactsManager:(FLContactsManager *)contactsManager
{
    [OWSTableItem configureCell:self];

    [self.cellView configureWithRecipientId:recipientId contactsManager:contactsManager];

    // Force layout, since imageView isn't being initally rendered on App Store optimized build.
    [self layoutSubviews];
}

- (void)configureWithThread:(TSThread *)thread contactsManager:(FLContactsManager *)contactsManager
{
    OWSAssert(thread);

    [OWSTableItem configureCell:self];

    [self.cellView configureWithThread:thread contactsManager:contactsManager];

    // Force layout, since imageView isn't being initally rendered on App Store optimized build.
    [self layoutSubviews];
}

- (void)setAccessoryMessage:(nullable NSString *)accessoryMessage
{
    OWSAssert(self.cellView);

    self.cellView.accessoryMessage = accessoryMessage;
}

- (NSAttributedString *)verifiedSubtitle
{
    return self.cellView.verifiedSubtitle;
}

- (void)setAttributedSubtitle:(nullable NSAttributedString *)attributedSubtitle
{
    [self.cellView setAttributedSubtitle:attributedSubtitle];
}

- (void)prepareForReuse
{
    [super prepareForReuse];

    [self.cellView prepareForReuse];

    self.accessoryType = UITableViewCellAccessoryNone;
}

- (BOOL)hasAccessoryText
{
    return [self.cellView hasAccessoryText];
}

- (void)ows_setAccessoryView:(UIView *)accessoryView
{
    return [self.cellView setAccessoryView:accessoryView];
}

@end

NS_ASSUME_NONNULL_END
