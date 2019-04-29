//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <RelayMessaging/OWSViewController.h>

NS_ASSUME_NONNULL_BEGIN

@class RelayRecipient;
@class FLTag;

@protocol SelectRecipientViewControllerDelegate <NSObject>

- (NSString *)contactsSectionTitle;

-(void)relayTagWasSelected:(FLTag *)relayTag;
-(void)relayRecipientWasSelected:(RelayRecipient *)relayRecipient;

- (BOOL)shouldHideLocalNumber;

- (BOOL)shouldHideContacts;

@end

#pragma mark -

@class ContactsViewHelper;

@interface SelectRecipientViewController : OWSViewController

@property (nonatomic, weak) id<SelectRecipientViewControllerDelegate> delegate;

@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;

@property (nonatomic) BOOL isPresentedInNavigationController;

@end

NS_ASSUME_NONNULL_END
