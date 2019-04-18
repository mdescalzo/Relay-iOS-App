//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "AdvancedSettingsTableViewController.h"
#import "DebugLogger.h"
#import "OWSCountryMetadata.h"
#import "Pastelog.h"
#import "PushManager.h"
#import "Relay-Swift.h"
#import "TSAccountManager.h"
#import <PromiseKit/AnyPromise.h>
#import <Reachability/Reachability.h>
#import <RelayMessaging/Environment.h>
#import <RelayMessaging/OWSPreferences.h>
#import <RelayServiceKit/OWSSignalService.h>

NS_ASSUME_NONNULL_BEGIN

@interface AdvancedSettingsTableViewController ()

@property (nonatomic) Reachability *reachability;

@end

#pragma mark -

@implementation AdvancedSettingsTableViewController

- (void)loadView
{
    [super loadView];

    self.title = NSLocalizedString(@"SETTINGS_ADVANCED_TITLE", @"");

    self.reachability = [Reachability reachabilityForInternetConnection];

    [self observeNotifications];

    [self updateTableContents];
}

- (void)observeNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(socketStateDidChange)
                                                 name:kNSNotification_SocketManagerStateDidChange
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reachabilityChanged)
                                                 name:kReachabilityChangedNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)socketStateDidChange
{
    OWSAssertIsOnMainThread();

    [self updateTableContents];
}

- (void)reachabilityChanged
{
    OWSAssertIsOnMainThread();

    [self updateTableContents];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];

    [self updateTableContents];
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];

    __weak AdvancedSettingsTableViewController *weakSelf = self;

    OWSTableSection *loggingSection = [OWSTableSection new];
    loggingSection.headerTitle = NSLocalizedString(@"LOGGING_SECTION", nil);
    [loggingSection addItem:[OWSTableItem switchItemWithText:NSLocalizedString(@"SETTINGS_ADVANCED_DEBUGLOG", @"")
                                                        isOn:[OWSPreferences isLoggingEnabled]
                                                      target:weakSelf
                                                    selector:@selector(didToggleEnableLogSwitch:)]];


    if ([OWSPreferences isLoggingEnabled]) {
        [loggingSection
            addItem:[OWSTableItem actionItemWithText:NSLocalizedString(@"SETTINGS_ADVANCED_SUBMIT_DEBUGLOG", @"")
                                         actionBlock:^{
                                             DDLogInfo(@"%@ Submitting debug logs", weakSelf.logTag);
                                             [DDLog flushLog];
                                             [Pastelog submitLogs];
                                         }]];
    }

    [contents addSection:loggingSection];

    OWSTableSection *pushNotificationsSection = [OWSTableSection new];
    pushNotificationsSection.headerTitle
        = NSLocalizedString(@"PUSH_REGISTER_TITLE", @"Used in table section header and alert view title contexts");
    [pushNotificationsSection addItem:[OWSTableItem actionItemWithText:NSLocalizedString(@"REREGISTER_FOR_PUSH", nil)
                                                           actionBlock:^{
                                                               [weakSelf syncPushTokens];
                                                           }]];
    [contents addSection:pushNotificationsSection];


#ifdef THEME_ENABLED
    OWSTableSection *themeSection = [OWSTableSection new];
    themeSection.headerTitle = NSLocalizedString(@"THEME_SECTION", nil);
    [themeSection addItem:[OWSTableItem switchItemWithText:NSLocalizedString(@"SETTINGS_ADVANCED_DARK_THEME",
                                                               @"Label for setting that enables dark theme.")
                                                      isOn:[Theme isDarkThemeEnabled]
                                                    target:weakSelf
                                                  selector:@selector(didToggleThemeSwitch:)]];
    [contents addSection:themeSection];
#endif

    self.contents = contents;
}

#pragma mark - Actions

- (void)syncPushTokens
{
    OWSSyncPushTokensJob *job = [[OWSSyncPushTokensJob alloc] initWithAccountManager:RelayApp.sharedApp.accountManager
                                                                         preferences:[Environment preferences]];
    job.uploadOnlyIfStale = NO;
    [job run]
        .then(^{
            [OWSAlerts showAlertWithTitle:NSLocalizedString(@"PUSH_REGISTER_SUCCESS",
                                              @"Title of alert shown when push tokens sync job succeeds.")];
        })
        .catch(^(NSError *error) {
            [OWSAlerts showAlertWithTitle:NSLocalizedString(@"REGISTRATION_BODY",
                                              @"Title of alert shown when push tokens sync job fails.")];
        });
}

- (void)didToggleEnableLogSwitch:(UISwitch *)sender
{
    if (!sender.isOn) {
        DDLogInfo(@"%@ disabling logging.", self.logTag);
        [[DebugLogger sharedLogger] wipeLogs];
        [[DebugLogger sharedLogger] disableFileLogging];
    } else {
        [[DebugLogger sharedLogger] enableFileLogging];
        DDLogInfo(@"%@ enabling logging.", self.logTag);
    }

    [OWSPreferences setIsLoggingEnabled:sender.isOn];

    [self updateTableContents];
}

#ifdef THEME_ENABLED
- (void)didToggleThemeSwitch:(UISwitch *)sender
{
    [Theme setIsDarkThemeEnabled:sender.isOn];

    [self updateTableContents];

    // TODO: Notify and refresh.
}
#endif

@end

NS_ASSUME_NONNULL_END
