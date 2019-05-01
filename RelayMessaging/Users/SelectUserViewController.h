//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import <RelayMessaging/OWSViewController.h>

NS_ASSUME_NONNULL_BEGIN

@class FLIUser;
@class FLITag;

@protocol SelectRecipientViewControllerDelegate <NSObject>

- (NSString *)contactsSectionTitle;

-(void)relayTagWasSelected:(FLITag *)relayTag;
-(void)relayRecipientWasSelected:(FLIUser *)relayRecipient;

- (BOOL)shouldHideLocalUser;

- (BOOL)shouldHideContacts;

@end

#pragma mark -

@class ContactsViewHelper;

@interface SelectUserViewController : OWSViewController

@property (nonatomic, weak) id<SelectRecipientViewControllerDelegate> delegate;

@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;

@property (nonatomic) BOOL isPresentedInNavigationController;

@end

NS_ASSUME_NONNULL_END
