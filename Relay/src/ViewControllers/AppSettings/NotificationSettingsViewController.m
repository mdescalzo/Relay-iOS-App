//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "NotificationSettingsViewController.h"
#import "NotificationSettingsOptionsViewController.h"
#import "OWSSoundSettingsViewController.h"
#import <RelayMessaging/Environment.h>
#import <RelayMessaging/OWSPreferences.h>
#import <RelayMessaging/OWSSounds.h>

@implementation NotificationSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self setTitle:NSLocalizedString(@"SETTINGS_NOTIFICATIONS", nil)];

    [self updateTableContents];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    [self updateTableContents];
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];

    __weak NotificationSettingsViewController *weakSelf = self;

    OWSPreferences *prefs = [Environment preferences];
    
    // Sounds section.

    OWSTableSection *soundsSection = [OWSTableSection new];
    soundsSection.headerTitle
        = NSLocalizedString(@"SETTINGS_SECTION_SOUNDS", @"Header Label for the sounds section of settings views.");
    [soundsSection
        addItem:[OWSTableItem disclosureItemWithText:
                                  NSLocalizedString(@"SETTINGS_ITEM_NOTIFICATION_SOUND",
                                      @"Label for settings view that allows user to change the notification sound.")
                                          detailText:[OWSSounds displayNameForSound:[OWSSounds globalNotificationSound]]
                                         actionBlock:^{
                                             OWSSoundSettingsViewController *vc = [OWSSoundSettingsViewController new];
                                             [weakSelf.navigationController pushViewController:vc animated:YES];
                                         }]];

    NSString *inAppSoundsLabelText = NSLocalizedString(@"NOTIFICATIONS_SECTION_INAPP",
        @"Table cell switch label. When disabled, Signal will not play notification sounds while the app is in the "
        @"foreground.");
    [soundsSection addItem:[OWSTableItem switchItemWithText:inAppSoundsLabelText
                                                       isOn:[prefs soundInForeground]
                                                     target:weakSelf
                                                   selector:@selector(didToggleSoundNotificationsSwitch:)]];
    [contents addSection:soundsSection];

    OWSTableSection *backgroundSection = [OWSTableSection new];
    backgroundSection.headerTitle = NSLocalizedString(@"SETTINGS_NOTIFICATION_CONTENT_TITLE", @"table section header");
    [backgroundSection
        addItem:[OWSTableItem
                    disclosureItemWithText:NSLocalizedString(@"NOTIFICATIONS_SHOW", nil)
                                detailText:[prefs nameForNotificationPreviewType:[prefs notificationPreviewType]]
                               actionBlock:^{
                                   NotificationSettingsOptionsViewController *vc =
                                       [NotificationSettingsOptionsViewController new];
                                   [weakSelf.navigationController pushViewController:vc animated:YES];
                               }]];
    backgroundSection.footerTitle
        = NSLocalizedString(@"SETTINGS_NOTIFICATION_CONTENT_DESCRIPTION", @"table section footer");
    [contents addSection:backgroundSection];
    
    // Gravatar section.

    OWSTableSection *gravatarSection = OWSTableSection.new;
    gravatarSection.headerTitle
    = NSLocalizedString(@"INTERFACE_GRAVATAR_SECTION", @"Header Label for the avatars section of settings views.");

    NSString *gravatarCellString = NSLocalizedString(@"INTERFACE_USE_GRAVATARS",
                                                       @"Table cell switch label. Toggles gravatar usage.");
    [gravatarSection addItem:[OWSTableItem switchItemWithText:gravatarCellString
                                                       isOn:prefs.useGravatars
                                                     target:weakSelf
                                                   selector:@selector(didToggleUseGravatarSwitch:)]];
    [contents addSection:gravatarSection];

    
    // Web preview
    OWSTableSection *webPreviewSection = OWSTableSection.new;
    webPreviewSection.headerTitle
    = NSLocalizedString(@"INTERFACE_MESSAGES_SECTION", @"Header Label for the messages section of settings views.");
    
    NSString *webPreviewCellString = NSLocalizedString(@"INTERFACE_SHOW_WEB_PREVIEWS",
                                                     @"Table cell switch label. Toggles gravatar usage.");
    [webPreviewSection addItem:[OWSTableItem switchItemWithText:webPreviewCellString
                                                         isOn:prefs.showWebPreviews
                                                       target:weakSelf
                                                     selector:@selector(didToggleWebPreviewSwitch:)]];
    [contents addSection:webPreviewSection];

    self.contents = contents;
}

#pragma mark - Events

-(void)didToggleWebPreviewSwitch:(UISwitch *)sender
{
    Environment.preferences.showWebPreviews = sender.on;
}

- (void)didToggleSoundNotificationsSwitch:(UISwitch *)sender
{
    Environment.preferences.soundInForeground = sender.on;
}

- (void)didToggleUseGravatarSwitch:(UISwitch *)sender
{
    Environment.preferences.useGravatars = sender.on;
}

@end
