//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "SelectRecipientViewController.h"
//#import "CountryCodeViewController.h"
//#import "PhoneNumber.h"
#import "ViewControllerUtils.h"
#import <RelayMessaging/ContactTableViewCell.h>
#import <RelayMessaging/ContactsViewHelper.h>
#import <RelayMessaging/Environment.h>
#import <RelayMessaging/OWSTableViewController.h>
#import <RelayMessaging/RelayMessaging-Swift.h>
#import <RelayMessaging/UIFont+OWS.h>
#import <RelayMessaging/UIUtil.h>
#import <RelayMessaging/UIView+OWS.h>

@import RelayServiceKit;

NS_ASSUME_NONNULL_BEGIN

NSString *const kSelectRecipientViewControllerCellIdentifier = @"kSelectRecipientViewControllerCellIdentifier";

#pragma mark -

@interface SelectRecipientViewController () <ContactsViewHelperDelegate,
    OWSTableViewControllerDelegate,
    UITextFieldDelegate>

@property (nonatomic) UITextField *phoneNumberTextField;

@property (nonatomic) OWSFlatButton *phoneNumberButton;

@property (nonatomic) UILabel *examplePhoneNumberLabel;

@property (nonatomic, readonly) OWSTableViewController *tableViewController;

@property (nonatomic) NSString *callingCode;

@end

#pragma mark -

@implementation SelectRecipientViewController

- (void)loadView
{
    [super loadView];

    self.view.backgroundColor = [Theme backgroundColor];

    _contactsViewHelper = [[ContactsViewHelper alloc] initWithDelegate:self];

    [self createViews];

    if (self.delegate.shouldHideContacts) {
        self.tableViewController.tableView.scrollEnabled = NO;
    }
}

- (void)viewDidLoad
{
    OWSAssert(self.tableViewController);

    [super viewDidLoad];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.tableViewController viewDidAppear:animated];

    if ([self.delegate shouldHideContacts]) {
        [self.phoneNumberTextField becomeFirstResponder];
    }
}

- (void)createViews
{
    OWSAssert(self.delegate);

    _tableViewController = [OWSTableViewController new];
    _tableViewController.delegate = self;
    [self.view addSubview:self.tableViewController.view];
    [_tableViewController.view autoPinWidthToSuperview];
    [_tableViewController.view autoPinToTopLayoutGuideOfViewController:self withInset:0];
    [_tableViewController.view autoPinEdgeToSuperviewEdge:ALEdgeBottom];
    self.tableViewController.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableViewController.tableView.estimatedRowHeight = 60;
    _tableViewController.view.backgroundColor = [Theme backgroundColor];

    [self updateTableContents];

    [self updatePhoneNumberButtonEnabling];
}

- (UILabel *)countryCodeLabel
{
    UILabel *countryCodeLabel = [UILabel new];
    countryCodeLabel.font = [UIFont ows_mediumFontWithSize:18.f];
    countryCodeLabel.textColor = [Theme primaryColor];
    countryCodeLabel.text
        = NSLocalizedString(@"REGISTRATION_DEFAULT_COUNTRY_NAME", @"Label for the country code field");
    return countryCodeLabel;
}

- (UILabel *)phoneNumberLabel
{
    UILabel *phoneNumberLabel = [UILabel new];
    phoneNumberLabel.font = [UIFont ows_mediumFontWithSize:18.f];
    phoneNumberLabel.textColor = [Theme primaryColor];
    phoneNumberLabel.text
        = NSLocalizedString(@"REGISTRATION_PHONENUMBER_BUTTON", @"Label for the phone number textfield");
    return phoneNumberLabel;
}

- (UIFont *)examplePhoneNumberFont
{
    return [UIFont ows_regularFontWithSize:16.f];
}

- (UILabel *)examplePhoneNumberLabel
{
    if (!_examplePhoneNumberLabel) {
        _examplePhoneNumberLabel = [UILabel new];
        _examplePhoneNumberLabel.font = [self examplePhoneNumberFont];
        _examplePhoneNumberLabel.textColor = [Theme secondaryColor];
    }

    return _examplePhoneNumberLabel;
}

- (UITextField *)phoneNumberTextField
{
    if (!_phoneNumberTextField) {
        _phoneNumberTextField = [UITextField new];
        _phoneNumberTextField.font = [UIFont ows_mediumFontWithSize:18.f];
        _phoneNumberTextField.textAlignment = _phoneNumberTextField.textAlignmentUnnatural;
        _phoneNumberTextField.textColor = [UIColor FL_mediumBlue2];
        _phoneNumberTextField.placeholder = NSLocalizedString(
            @"REGISTRATION_ENTERNUMBER_DEFAULT_TEXT", @"Placeholder text for the phone number textfield");
        _phoneNumberTextField.keyboardType = UIKeyboardTypeNumberPad;
        _phoneNumberTextField.delegate = self;
        [_phoneNumberTextField addTarget:self
                                  action:@selector(textFieldDidChange:)
                        forControlEvents:UIControlEventEditingChanged];
    }

    return _phoneNumberTextField;
}

//- (OWSFlatButton *)phoneNumberButton
//{
//    if (!_phoneNumberButton) {
//        const CGFloat kButtonHeight = 40;
//        OWSFlatButton *button = [OWSFlatButton buttonWithTitle:[self.delegate phoneNumberButtonText]
//                                                          font:[OWSFlatButton fontForHeight:kButtonHeight]
//                                                    titleColor:[UIColor whiteColor]
//                                               backgroundColor:[UIColor FL_mediumBlue2]
//                                                        target:self
//                                                      selector:@selector(phoneNumberButtonPressed)];
//        _phoneNumberButton = button;
//        [button autoSetDimension:ALDimensionWidth toSize:140];
//        [button autoSetDimension:ALDimensionHeight toSize:kButtonHeight];
//    }
//    return _phoneNumberButton;
//}

- (UIView *)createRowWithHeight:(CGFloat)height
                    previousRow:(nullable UIView *)previousRow
                      superview:(nullable UIView *)superview
{
    UIView *row = [UIView containerView];
    [superview addSubview:row];
    [row autoPinLeadingAndTrailingToSuperviewMargin];
    if (previousRow) {
        [row autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:previousRow withOffset:0];
    } else {
        [row autoPinEdgeToSuperviewEdge:ALEdgeTop];
    }
    [row autoSetDimension:ALDimensionHeight toSize:height];
    return row;
}

#pragma mark - Country


- (void)updateCountryWithName:(NSString *)countryName
                  callingCode:(NSString *)callingCode
                  countryCode:(NSString *)countryCode
{
//    _callingCode = callingCode;
//
//    NSString *titleFormat = (CurrentAppContext().isRTL ? @"(%2$@) %1$@" : @"%1$@ (%2$@)");
//    NSString *title = [NSString stringWithFormat:titleFormat, callingCode, countryCode.localizedUppercaseString];
//    [self.countryCodeButton setTitle:title forState:UIControlStateNormal];
//    [self.countryCodeButton layoutSubviews];
//
//    self.examplePhoneNumberLabel.text =
//        [ViewControllerUtils examplePhoneNumberForCountryCode:countryCode callingCode:callingCode];
//    [self.examplePhoneNumberLabel.superview layoutSubviews];
}

- (void)setCallingCode:(NSString *)callingCode
{
    _callingCode = callingCode;

    [self updatePhoneNumberButtonEnabling];
}

#pragma mark - Actions

- (void)showCountryCodeView:(nullable id)sender
{
//    CountryCodeViewController *countryCodeController = [CountryCodeViewController new];
//    countryCodeController.countryCodeDelegate = self;
//    countryCodeController.isPresentedInNavigationController = self.isPresentedInNavigationController;
//    if (self.isPresentedInNavigationController) {
//        [self.navigationController pushViewController:countryCodeController animated:YES];
//    } else {
//        OWSNavigationController *navigationController =
//            [[OWSNavigationController alloc] initWithRootViewController:countryCodeController];
//        [self presentViewController:navigationController animated:YES completion:nil];
//    }
}

//- (void)phoneNumberButtonPressed
//{
//    [self tryToSelectPhoneNumber];
//}

//- (void)tryToSelectPhoneNumber
//{
//    OWSAssert(self.delegate);
//
//    if (![self hasValidPhoneNumber]) {
//        OWSFail(@"Invalid phone number was selected.");
//        return;
//    }
//
//    NSString *rawPhoneNumber = [self.callingCode stringByAppendingString:self.phoneNumberTextField.text.digitsOnly];
//
//    NSMutableArray<NSString *> *possiblePhoneNumbers = [NSMutableArray new];
//    for (PhoneNumber *phoneNumber in
//        [PhoneNumber tryParsePhoneNumbersFromsUserSpecifiedText:rawPhoneNumber
//                                              clientPhoneNumber:[TSAccountManager localUID]]) {
//        [possiblePhoneNumbers addObject:phoneNumber.toE164];
//    }
//    if ([possiblePhoneNumbers count] < 1) {
//        OWSFail(@"Couldn't parse phone number.");
//        return;
//    }
//
//    [self.phoneNumberTextField resignFirstResponder];
//
//    // There should only be one phone number, since we're explicitly specifying
//    // a country code and therefore parsing a number in e164 format.
//    OWSAssert([possiblePhoneNumbers count] == 1);
//
//    if ([self.delegate shouldValidatePhoneNumbers]) {
//        // Show an alert while validating the recipient.
//
//        __weak SelectRecipientViewController *weakSelf = self;
//        [ModalActivityIndicatorViewController
//            presentFromViewController:self
//                            canCancel:YES
//                      backgroundBlock:^(ModalActivityIndicatorViewController *modalActivityIndicator) {
//                          [[ContactsUpdater sharedUpdater] lookupIdentifiers:possiblePhoneNumbers
//                              success:^(NSArray<RelayRecipient *> *recipients) {
//                                  OWSAssertIsOnMainThread();
//                                  if (modalActivityIndicator.wasCancelled) {
//                                      return;
//                                  }
//
//                                  if (recipients.count == 0) {
//                                      [modalActivityIndicator
//                                          dismissViewControllerAnimated:NO
//                                                             completion:^{
//                                                                 NSError *error
//                                                                     = OWSErrorMakeNoSuchSignalRecipientError();
//                                                                 [OWSAlerts showErrorAlertWithMessage:
//                                                                                error.localizedDescription];
//                                                             }];
//                                      return;
//                                  }
//
//                                  NSString *recipientId = recipients[0].uniqueId;
//                                  [modalActivityIndicator
//                                      dismissViewControllerAnimated:NO
//                                                         completion:^{
//                                                             [weakSelf.delegate phoneNumberWasSelected:recipientId];
//                                                         }];
//                              }
//                              failure:^(NSError *error) {
//                                  OWSAssertIsOnMainThread();
//                                  if (modalActivityIndicator.wasCancelled) {
//                                      return;
//                                  }
//                                  [modalActivityIndicator
//                                      dismissViewControllerAnimated:NO
//                                                         completion:^{
//                                                             [OWSAlerts
//                                                                 showErrorAlertWithMessage:error.localizedDescription];
//                                                         }];
//                              }];
//                      }];
//    } else {
//        NSString *recipientId = possiblePhoneNumbers[0];
//        [self.delegate phoneNumberWasSelected:recipientId];
//    }
//}

- (void)textFieldDidChange:(id)sender
{
    [self updatePhoneNumberButtonEnabling];
}

// TODO: We could also do this in registration view.
- (BOOL)hasValidPhoneNumber
{
    if (!self.callingCode) {
        return NO;
    }
    NSString *possiblePhoneNumber =
        [self.callingCode stringByAppendingString:self.phoneNumberTextField.text.digitsOnly];
    NSArray<PhoneNumber *> *parsePhoneNumbers =
        [PhoneNumber tryParsePhoneNumbersFromsUserSpecifiedText:possiblePhoneNumber
                                              clientPhoneNumber:[TSAccountManager localUID]];
    if (parsePhoneNumbers.count < 1) {
        return NO;
    }
    PhoneNumber *parsedPhoneNumber = parsePhoneNumbers[0];
    // It'd be nice to use [PhoneNumber isValid] but it always returns false for some countries
    // (like afghanistan) and there doesn't seem to be a good way to determine beforehand
    // which countries it can validate for without forking libPhoneNumber.
    return parsedPhoneNumber.toE164.length > 1;
}

- (void)updatePhoneNumberButtonEnabling
{
    BOOL isEnabled = [self hasValidPhoneNumber];
    self.phoneNumberButton.enabled = isEnabled;
    [self.phoneNumberButton
        setBackgroundColorsWithUpColor:(isEnabled ? [UIColor FL_mediumBlue1] : [Theme secondaryColor])];
}

#pragma mark - CountryCodeViewControllerDelegate

//- (void)countryCodeViewController:(CountryCodeViewController *)vc
//             didSelectCountryCode:(NSString *)countryCode
//                      countryName:(NSString *)countryName
//                      callingCode:(NSString *)callingCode
//{
//    OWSAssert(countryCode.length > 0);
//    OWSAssert(countryName.length > 0);
//    OWSAssert(callingCode.length > 0);
//
//    [self updateCountryWithName:countryName callingCode:callingCode countryCode:countryCode];
//
//    // Trigger the formatting logic with a no-op edit.
//    [self textField:self.phoneNumberTextField shouldChangeCharactersInRange:NSMakeRange(0, 0) replacementString:@""];
//}

#pragma mark - UITextFieldDelegate

// TODO: This logic resides in both RegistrationViewController and here.
//       We should refactor it out into a utility function.
- (BOOL)textField:(UITextField *)textField
    shouldChangeCharactersInRange:(NSRange)range
                replacementString:(NSString *)insertionText
{
    [ViewControllerUtils phoneNumberTextField:textField
                shouldChangeCharactersInRange:range
                            replacementString:insertionText
                                  countryCode:_callingCode];

    [self updatePhoneNumberButtonEnabling];

    return NO; // inform our caller that we took care of performing the change
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
//    if ([self hasValidPhoneNumber]) {
//        [self tryToSelectPhoneNumber];
//    }
    return NO;
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];
    __weak SelectRecipientViewController *weakSelf = self;
    ContactsViewHelper *helper = self.contactsViewHelper;

    if (![self.delegate shouldHideContacts]) {
        OWSTableSection *contactsSection = [OWSTableSection new];
        contactsSection.headerTitle = [self.delegate contactsSectionTitle];
        NSArray<FLTag *> *relayTags = helper.relayTags;
        if (relayTags.count == 0) {
            // No Contacts

            [contactsSection
                addItem:[OWSTableItem softCenterLabelItemWithText:
                                          NSLocalizedString(@"SETTINGS_BLOCK_LIST_NO_CONTACTS",
                                              @"A label that indicates the user has no Signal contacts.")]];
        } else {
            // Contacts

            for (FLTag *relayTag in relayTags) {
                [contactsSection
                    addItem:[OWSTableItem
                                itemWithCustomCellBlock:^{
                                    SelectRecipientViewController *strongSelf = weakSelf;
                                    OWSCAssert(strongSelf);

                                    ContactTableViewCell *cell = [ContactTableViewCell new];
//                                    BOOL isBlocked = [helper isRecipientIdBlocked:signalAccount.recipientId];
//                                    if (isBlocked) {
//                                        cell.accessoryMessage = NSLocalizedString(@"CONTACT_CELL_IS_BLOCKED",
//                                            @"An indicator that a contact has been blocked.");
//                                    } else {
                                    // TODO: Implement this!
//                                        cell.accessoryMessage =
//                                            [weakSelf.delegate accessoryMessageForSignalAccount:signalAccount];
//                                    }
                                    [cell configureWithTagId:relayTag.uniqueId
                                                   contactsManager:helper.contactsManager];

                                    // Implement this!
//                                    if (![weakSelf.delegate canSignalAccountBeSelected:signalAccount]) {
//                                        cell.selectionStyle = UITableViewCellSelectionStyleNone;
//                                    }

                                    return cell;
                                }
                                customRowHeight:UITableViewAutomaticDimension
                                actionBlock:^{
//                                    if (![weakSelf.delegate canSignalAccountBeSelected:signalAccount]) {
//                                        return;
//                                    }
                                    [weakSelf.delegate relayTagWasSelected:relayTag];
                                }]];
            }
        }
        [contents addSection:contactsSection];
    }

    self.tableViewController.contents = contents;
}

- (void)phoneNumberRowTouched:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self.phoneNumberTextField becomeFirstResponder];
    }
}

- (void)countryRowTouched:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self showCountryCodeView:nil];
    }
}

#pragma mark - OWSTableViewControllerDelegate

- (void)tableViewWillBeginDragging
{
    [self.phoneNumberTextField resignFirstResponder];
}

#pragma mark - ContactsViewHelperDelegate

- (void)contactsViewHelperDidUpdateContacts
{
    [self updateTableContents];
}

- (BOOL)shouldHideLocalNumber
{
    return [self.delegate shouldHideLocalNumber];
}

@end

NS_ASSUME_NONNULL_END
