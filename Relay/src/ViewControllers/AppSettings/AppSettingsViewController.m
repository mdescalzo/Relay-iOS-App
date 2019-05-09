//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "AppSettingsViewController.h"
#import "AboutTableViewController.h"
#import "AdvancedSettingsTableViewController.h"
#import "DebugUITableViewController.h"
#import "NotificationSettingsViewController.h"
#import "OWSBackup.h"
#import "OWSBackupSettingsViewController.h"
#import "OWSLinkedDevicesTableViewController.h"
#import "OWSNavigationController.h"
#import "PrivacySettingsTableViewController.h"
#import "PushManager.h"
#import "RegistrationUtils.h"
#import "Relay-Swift.h"

@import RelayServiceKit;
@import RelayMessaging;

@interface AppSettingsViewController ()

@property (nonatomic, readonly) FLContactsManager *contactsManager;

@end

#pragma mark -

@implementation AppSettingsViewController

/**
 * We always present the settings controller modally, from within an OWSNavigationController
 */
+ (OWSNavigationController *)inModalNavigationController
{
    AppSettingsViewController *viewController = [AppSettingsViewController new];
    OWSNavigationController *navController =
    [[OWSNavigationController alloc] initWithRootViewController:viewController];
    
    return navController;
}

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return self;
    }
    
    _contactsManager = [Environment current].contactsManager;
    
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (!self) {
        return self;
    }
    
    _contactsManager = [Environment current].contactsManager;
    
    return self;
}

- (void)loadView
{
    self.tableViewStyle = UITableViewStylePlain;
    [super loadView];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.navigationItem setHidesBackButton:YES];
    
    OWSAssertDebug([self.navigationController isKindOfClass:[OWSNavigationController class]]);
    
    self.navigationItem.leftBarButtonItem =
    [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop
                                                  target:self
                                                  action:@selector(dismissWasPressed:)];
    
    [self observeNotifications];
    
    self.title = NSLocalizedString(@"SETTINGS_NAV_BAR_TITLE", @"Title for settings activity");
    
    [self updateTableContents];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    [self updateTableContents];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];
    
    __weak AppSettingsViewController *weakSelf = self;
    
#ifdef INTERNAL
    OWSTableSection *internalSection = [OWSTableSection new];
    [section addItem:[OWSTableItem softCenterLabelItemWithText:@"Internal Build"]];
    [contents addSection:internalSection];
#endif
    
    OWSTableSection *section = [OWSTableSection new];
    [section addItem:[OWSTableItem itemWithCustomCellBlock:^{
        return [weakSelf profileHeaderCell];
    }
                                           customRowHeight:100.f
                                               actionBlock:^{
                                                   // TODO: add access to own fingerprint here
                                               }]];
    
    [section addItem:[OWSTableItem
                      itemWithCustomCellBlock:^{
                          UITableViewCell *cell = [OWSTableItem newCell];
                          cell.textLabel.text = NSLocalizedString(@"NETWORK_STATUS_HEADER", @"");
                          cell.selectionStyle = UITableViewCellSelectionStyleNone;
                          UILabel *accessoryLabel = [UILabel new];
                          accessoryLabel.font = [UIFont ows_regularFontWithSize:18.f];
                          if (TSAccountManager.sharedInstance.isDeregistered) {
                              accessoryLabel.text = NSLocalizedString(@"NETWORK_STATUS_DEREGISTERED",
                                                                      @"Error indicating that this device is no longer registered.");
                              accessoryLabel.textColor = [UIColor FL_mediumRed];
                          } else {
                              switch ([TSSocketManager sharedManager].state) {
                                  case SocketManagerStateClosed:
                                      accessoryLabel.text = NSLocalizedString(@"NETWORK_STATUS_OFFLINE", @"");
                                      accessoryLabel.textColor = [UIColor FL_mediumRed];
                                      break;
                                  case SocketManagerStateConnecting:
                                      accessoryLabel.text = NSLocalizedString(@"NETWORK_STATUS_CONNECTING", @"");
                                      accessoryLabel.textColor = [UIColor FL_mediumYellow];
                                      break;
                                  case SocketManagerStateOpen:
                                      accessoryLabel.text = NSLocalizedString(@"NETWORK_STATUS_CONNECTED", @"");
                                      accessoryLabel.textColor = [UIColor FL_darkGreen];
                                      break;
                              }
                          }
                          [accessoryLabel sizeToFit];
                          cell.accessoryView = accessoryLabel;
                          return cell;
                      }
                      actionBlock:nil]];
    
    
    [section addItem:[OWSTableItem disclosureItemWithText:NSLocalizedString(@"SETTINGS_PRIVACY_TITLE",
                                                                            @"Settings table view cell label")
                                              actionBlock:^{
                                                  [weakSelf showPrivacy];
                                              }]];
    [section addItem:[OWSTableItem disclosureItemWithText:NSLocalizedString(@"SETTINGS_NOTIFICATIONS", nil)
                                              actionBlock:^{
                                                  [weakSelf showNotifications];
                                              }]];
    [section addItem:[OWSTableItem disclosureItemWithText:NSLocalizedString(@"LINKED_DEVICES_TITLE",
                                                                            @"Menu item and navbar title for the device manager")
                                              actionBlock:^{
                                                  [weakSelf showLinkedDevices];
                                              }]];
    [section addItem:[OWSTableItem disclosureItemWithText:NSLocalizedString(@"SETTINGS_ADVANCED_TITLE", @"")
                                              actionBlock:^{
                                                  [weakSelf showAdvanced];
                                              }]];
    // Show backup UI in debug builds OR if backup has already been enabled.
    //
    // NOTE: Backup format is not yet finalized and backups are not yet
    //       properly encrypted, so these debug backups should only be
    //       done on test devices and will not be usable if/when we ship
    //       backup to production.
    //
    // TODO: Always show backup when we go to production.
    //    BOOL isBackupEnabled = [OWSBackup.sharedManager isBackupEnabled];
    //    BOOL showBackup = isBackupEnabled;
    //    SUPPRESS_DEADSTORE_WARNING(showBackup);
    //#ifdef DEBUG
    //    showBackup = YES;
    //#endif
    //    if (showBackup) {
    //        [section addItem:[OWSTableItem disclosureItemWithText:NSLocalizedString(@"SETTINGS_BACKUP",
    //                                                                  @"Label for the backup view in app settings.")
    //                                                  actionBlock:^{
    //                                                      [weakSelf showBackup];
    //                                                  }]];
    //    }
    [section addItem:[OWSTableItem disclosureItemWithText:NSLocalizedString(@"SETTINGS_ABOUT", @"")
                                              actionBlock:^{
                                                  [weakSelf showAbout];
                                              }]];
    
#ifdef USE_DEBUG_UI
    [section addItem:[OWSTableItem disclosureItemWithText:@"Debug UI"
                                              actionBlock:^{
                                                  [weakSelf showDebugUI];
                                              }]];
#endif
    
    if (TSAccountManager.sharedInstance.isDeregistered) {
        [section addItem:[self destructiveButtonItemWithTitle:NSLocalizedString(@"SETTINGS_REREGISTER_BUTTON",
                                                                                @"Label for re-registration button.")
                                                     selector:@selector(reregisterUser)
                                                        color:[UIColor FL_mediumBlue2]]];
        [section addItem:[self destructiveButtonItemWithTitle:NSLocalizedString(@"SETTINGS_DELETE_DATA_BUTTON",
                                                                                @"Label for 'delete data' button.")
                                                     selector:@selector(deleteUnregisterUserData)
                                                        color:[UIColor FL_darkRed]]];
    } else {
        [section addItem:[self destructiveButtonItemWithTitle:NSLocalizedString(@"SETTINGS_DELETE_ACCOUNT_BUTTON", @"")
                                                     selector:@selector(unregisterUser)
                                                        color:[UIColor FL_darkRed]]];
    }
    
    [contents addSection:section];
    
    self.contents = contents;
}

- (OWSTableItem *)destructiveButtonItemWithTitle:(NSString *)title selector:(SEL)selector color:(UIColor *)color
{
    return [OWSTableItem
            itemWithCustomCellBlock:^{
                UITableViewCell *cell = [OWSTableItem newCell];
                cell.preservesSuperviewLayoutMargins = YES;
                cell.contentView.preservesSuperviewLayoutMargins = YES;
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                
                const CGFloat kButtonHeight = 40.f;
                OWSFlatButton *button = [OWSFlatButton buttonWithTitle:title
                                                                  font:[OWSFlatButton fontForHeight:kButtonHeight]
                                                            titleColor:[UIColor whiteColor]
                                                       backgroundColor:color
                                                                target:self
                                                              selector:selector];
                [cell.contentView addSubview:button];
                [button autoSetDimension:ALDimensionHeight toSize:kButtonHeight];
                [button autoVCenterInSuperview];
                [button autoPinLeadingAndTrailingToSuperviewMargin];
                
                return cell;
            }
            customRowHeight:90.f
            actionBlock:nil];
}

- (UITableViewCell *)profileHeaderCell
{
    UITableViewCell *cell = [OWSTableItem newCell];
    cell.preservesSuperviewLayoutMargins = YES;
    cell.contentView.preservesSuperviewLayoutMargins = YES;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    
    const NSUInteger kAvatarSize = 68;
    // TODO: Replace this icon.
    UIImage *avatarImage = [self.contactsManager avatarImageRecipientId:[TSAccountManager localUID]];
    if (!avatarImage) {
        avatarImage = [[[OWSContactAvatarBuilder alloc] initWithNonSignalName:TSAccountManager.selfRecipient.fullName
                                                                    colorSeed:TSAccountManager.localUID
                                                                     diameter:kContactCellAvatarSize
                                                              contactsManager:FLContactsManager.shared] build];
    }
    OWSAssertDebug(avatarImage);
    
    AvatarImageView *avatarView = [[AvatarImageView alloc] initWithImage:avatarImage];
    
    [cell.contentView addSubview:avatarView];
    [avatarView autoVCenterInSuperview];
    [avatarView autoPinLeadingToSuperviewMargin];
    [avatarView autoSetDimension:ALDimensionWidth toSize:kAvatarSize];
    [avatarView autoSetDimension:ALDimensionHeight toSize:kAvatarSize];
    
    // TODO: Perhaps allow users to take their own avatar image in the future
    //    if (!localProfileAvatarImage) {
    //        UIImage *cameraImage = [UIImage imageNamed:@"settings-avatar-camera"];
    //        UIImageView *cameraImageView = [[UIImageView alloc] initWithImage:cameraImage];
    //        [cell.contentView addSubview:cameraImageView];
    //        [cameraImageView autoPinTrailingToEdgeOfView:avatarView];
    //        [cameraImageView autoPinEdge:ALEdgeBottom toEdge:ALEdgeBottom ofView:avatarView];
    //    }
    
    UIView *nameView = [UIView containerView];
    [cell.contentView addSubview:nameView];
    [nameView autoVCenterInSuperview];
    [nameView autoPinLeadingToTrailingEdgeOfView:avatarView offset:16.f];
    
    UILabel *titleLabel = [UILabel new];
    NSString *_Nullable localProfileName = [self.contactsManager displayNameForRecipientId:[TSAccountManager localUID]];
    if (localProfileName.length > 0) {
        titleLabel.text = localProfileName;
        titleLabel.textColor = [Theme primaryColor];
        titleLabel.font = [UIFont ows_dynamicTypeTitle2Font];
    } else {
        titleLabel.text = NSLocalizedString(
                                            @"APP_SETTINGS_EDIT_PROFILE_NAME_PROMPT", @"Text prompting user to edit their profile name.");
        titleLabel.textColor = [UIColor FL_mediumBlue2];
        titleLabel.font = [UIFont ows_dynamicTypeHeadlineFont];
    }
    titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [nameView addSubview:titleLabel];
    [titleLabel autoPinEdgeToSuperviewEdge:ALEdgeTop];
    [titleLabel autoPinWidthToSuperview];
    
    const CGFloat kSubtitlePointSize = 12.f;
    UILabel *subtitleLabel = [UILabel new];
    subtitleLabel.textColor = [Theme secondaryColor];
    subtitleLabel.font = [UIFont ows_regularFontWithSize:kSubtitlePointSize];
    subtitleLabel.attributedText = [[NSAttributedString alloc]
                                    initWithString:self.contactsManager.selfRecipient.flTag.orgSlug];
    subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [nameView addSubview:subtitleLabel];
    [subtitleLabel autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:titleLabel];
    [subtitleLabel autoPinLeadingToSuperviewMargin];
    [subtitleLabel autoPinEdgeToSuperviewEdge:ALEdgeBottom];
    
    //    UIImage *disclosureImage = [UIImage imageNamed:(CurrentAppContext().isRTL ? @"NavBarBack" : @"NavBarBackRTL")];
    //    OWSAssertDebug(disclosureImage);
    //    UIImageView *disclosureButton =
    //        [[UIImageView alloc] initWithImage:[disclosureImage imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    //    disclosureButton.tintColor = [UIColor colorWithHex:@"#cccccc"];
    //    [cell.contentView addSubview:disclosureButton];
    //    [disclosureButton autoVCenterInSuperview];
    //    [disclosureButton autoPinTrailingToSuperviewMargin];
    //    [disclosureButton autoPinLeadingToTrailingEdgeOfView:nameView offset:16.f];
    //    [disclosureButton setContentCompressionResistancePriority:(UILayoutPriorityDefaultHigh + 1)
    //                                                      forAxis:UILayoutConstraintAxisHorizontal];
    
    return cell;
}

- (void)showPrivacy
{
    PrivacySettingsTableViewController *vc = [[PrivacySettingsTableViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showNotifications
{
    NotificationSettingsViewController *vc = [[NotificationSettingsViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showLinkedDevices
{
    OWSLinkedDevicesTableViewController *vc =
    [[UIStoryboard main] instantiateViewControllerWithIdentifier:@"OWSLinkedDevicesTableViewController"];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showAdvanced
{
    AdvancedSettingsTableViewController *vc = [[AdvancedSettingsTableViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showAbout
{
    AboutTableViewController *vc = [[AboutTableViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showBackup
{
    OWSBackupSettingsViewController *vc = [OWSBackupSettingsViewController new];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)showDebugUI
{
    [DebugUITableViewController presentDebugUIFromViewController:self];
}

- (void)dismissWasPressed:(id)sender
{
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Unregister & Re-register

- (void)unregisterUser
{
    [self showDeleteAccountUI:YES];
}

- (void)deleteUnregisterUserData
{
    [self showDeleteAccountUI:NO];
}

- (void)showDeleteAccountUI:(BOOL)isRegistered
{
    UIAlertController *alertController =
    [UIAlertController alertControllerWithTitle:NSLocalizedString(@"CONFIRM_ACCOUNT_DESTRUCTION_TITLE", @"")
                                        message:NSLocalizedString(@"CONFIRM_ACCOUNT_DESTRUCTION_TEXT", @"")
                                 preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"PROCEED_BUTTON", @"")
                                                        style:UIAlertActionStyleDestructive
                                                      handler:^(UIAlertAction *action) {
                                                          [self deleteAccount:isRegistered];
                                                      }]];
    [alertController addAction:[OWSAlerts cancelAction]];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)deleteAccount:(BOOL)isRegistered
{
    if (isRegistered) {
        [ModalActivityIndicatorViewController
         presentFromViewController:self
         canCancel:NO
         backgroundBlock:^(ModalActivityIndicatorViewController *modalActivityIndicator) {
             [TSAccountManager
              unregisterTextSecureWithSuccess:^{
                  [SignalApp resetAppData];
              }
              failure:^(NSError *error) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                      [modalActivityIndicator dismissWithCompletion:^{
                          [OWSAlerts
                           showAlertWithTitle:NSLocalizedString(@"UNREGISTER_SIGNAL_FAIL", @"")];
                      }];
                  });
              }];
         }];
    } else {
        [SignalApp resetAppData];
    }
}

- (void)reregisterUser
{
    [RegistrationUtils showReregistrationUIFromViewController:self];
}

#pragma mark - Socket Status Notifications

- (void)observeNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(socketStateDidChange)
                                                 name:kNSNotification_SocketManagerStateDidChange
                                               object:nil];
}

- (void)socketStateDidChange
{
    OWSAssertIsOnMainThread();
    
    [self updateTableContents];
}

@end
