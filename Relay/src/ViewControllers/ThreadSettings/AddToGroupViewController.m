//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "AddToGroupViewController.h"
#import "ContactsViewHelper.h"
#import "Relay-Swift.h"

NS_ASSUME_NONNULL_BEGIN

@interface AddToGroupViewController () <SelectRecipientViewControllerDelegate>

@end

#pragma mark -

@implementation AddToGroupViewController

- (void)loadView
{
    self.delegate = self;

    [super loadView];

    self.title = NSLocalizedString(@"ADD_GROUP_MEMBER_VIEW_TITLE", @"Title for the 'add group member' view.");
}

- (NSString *)phoneNumberSectionTitle
{
    return NSLocalizedString(@"ADD_GROUP_MEMBER_VIEW_PHONE_NUMBER_TITLE",
        @"Title for the 'add by phone number' section of the 'add group member' view.");
}

- (NSString *)phoneNumberButtonText
{
    return NSLocalizedString(@"ADD_GROUP_MEMBER_VIEW_BUTTON",
        @"A label for the 'add by phone number' button in the 'add group member' view");
}

- (NSString *)contactsSectionTitle
{
    return NSLocalizedString(
        @"ADD_GROUP_MEMBER_VIEW_CONTACT_TITLE", @"Title for the 'add contact' section of the 'add group member' view.");
}

- (BOOL)canRecipientBeSelected:(RelayRecipient *)recipient
{
    return ![self.addToGroupDelegate isRecipientGroupMember:recipient.uniqueId];
}

- (void)relayTagWasSelected:(FLTag *)relayTag
{
//    __weak AddToGroupViewController *weakSelf = self;
//    ContactsViewHelper *helper = self.contactsViewHelper;
    
    // TODO: Implement this!
//    if ([self.addToGroupDelegate isRecipientGroupMember:signalAccount.recipientId]) {
//        OWSFail(@"%@ Cannot add user to group member if already a member.", self.logTag);
//        return;
//    }

//    if ([helper isRecipientIdBlocked:signalAccount.recipientId]) {
//        [BlockListUIUtils showUnblockSignalAccountActionSheet:signalAccount
//                                           fromViewController:self
//                                              blockingManager:helper.blockingManager
//                                              contactsManager:helper.contactsManager
//                                              completionBlock:^(BOOL isBlocked) {
//                                                  if (!isBlocked) {
//                                                      [weakSelf addToGroup:signalAccount.recipientId];
//                                                  }
//                                              }];
//        return;
//    }

//    BOOL didShowSNAlert = [SafetyNumberConfirmationAlert
//        presentAlertIfNecessaryWithRecipientId:signalAccount.recipientId
//                              confirmationText:
//                                  NSLocalizedString(@"SAFETY_NUMBER_CHANGED_CONFIRM_ADD_TO_GROUP_ACTION",
//                                      @"button title to confirm adding a recipient to a group when their safety "
//                                      @"number has recently changed")
//                               contactsManager:helper.contactsManager
//                                    completion:^(BOOL didConfirmIdentity) {
//                                        if (didConfirmIdentity) {
//                                            [weakSelf addToGroup:signalAccount.recipientId];
//                                        }
//                                    }];
//    if (didShowSNAlert) {
//        return;
//    }

    [self addTagToGroup:relayTag];
}

-(void)addTagToGroup:(FLTag *)relayTag
{
    for (NSString *recipientId in relayTag.recipientIds) {
        if (![self.addToGroupDelegate isRecipientGroupMember:recipientId]) {
            [self addRecipientToGroup:recipientId];
        }
    }
}

- (void)addRecipientToGroup:(NSString *)recipientId
{
    OWSAssert(recipientId.length > 0);

    [self.addToGroupDelegate recipientIdWasAdded:recipientId];
    [self.navigationController popViewControllerAnimated:YES];
}

- (BOOL)shouldHideLocalNumber
{
    return YES;
}

- (BOOL)shouldHideContacts
{
    return self.hideContacts;
}

- (void)relayRecipientWasSelected:(nonnull RelayRecipient *)relayRecipient { 
    // FIXME:  Implement this
    // Add recipient to a thing
}


- (BOOL)shouldValidatePhoneNumbers
{
    return YES;
}

- (nullable NSString *)accessoryMessageForSignalAccount:(RelayRecipient *)recipient
{
    if ([self.addToGroupDelegate isRecipientGroupMember:recipient.uniqueId]) {
        return NSLocalizedString(@"NEW_GROUP_MEMBER_LABEL", @"An indicator that a user is a member of the new group.");
    }
    return nil;
}

@end

NS_ASSUME_NONNULL_END
