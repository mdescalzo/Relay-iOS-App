//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "SelectThreadViewController.h"
#import "ContactTableViewCell.h"
#import "ContactsViewHelper.h"
#import "Environment.h"
#import "OWSTableViewController.h"
#import "ThreadViewHelper.h"
#import "UIFont+OWS.h"
#import "UIView+OWS.h"
#import <RelayMessaging/RelayMessaging-Swift.h>

@import RelayStorage
@import SignalCoreKit

NS_ASSUME_NONNULL_BEGIN

@interface SelectThreadViewController () <OWSTableViewControllerDelegate,
    ThreadViewHelperDelegate,
    ContactsViewHelperDelegate,
    UISearchBarDelegate>

@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;
@property (nonatomic, readonly) ConversationSearcher *conversationSearcher;
@property (nonatomic, readonly) ThreadViewHelper *threadViewHelper;
@property (nonatomic, readonly) YapDatabaseConnection *uiDatabaseConnection;

@property (nonatomic, readonly) OWSTableViewController *tableViewController;

@property (nonatomic, readonly) UISearchBar *searchBar;

@end

#pragma mark -

@implementation SelectThreadViewController

- (void)loadView
{
    [super loadView];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemStop
                                                      target:self
                                                      action:@selector(dismissPressed:)];

    self.view.backgroundColor = [UIColor whiteColor];

    _contactsViewHelper = [[ContactsViewHelper alloc] initWithDelegate:self];
    _conversationSearcher = ConversationSearcher.shared;
    _threadViewHelper = [ThreadViewHelper new];
    _threadViewHelper.delegate = self;

    _uiDatabaseConnection = [[OWSPrimaryStorage sharedManager] newDatabaseConnection];
#ifdef DEBUG
    _uiDatabaseConnection.permittedTransactions = YDB_AnyReadTransaction;
#endif
    [_uiDatabaseConnection beginLongLivedReadTransaction];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(yapDatabaseModified:)
                                                 name:YapDatabaseModifiedNotification
                                               object:OWSPrimaryStorage.sharedManager.dbNotificationObject];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(yapDatabaseModifiedExternally:)
                                                 name:YapDatabaseModifiedExternallyNotification
                                               object:nil];

    [self createViews];

    [self updateTableContents];
}

- (void)createViews
{
    OWSAssertDebug(self.selectThreadViewDelegate);

    // Search
    UISearchBar *searchBar = [UISearchBar new];
    _searchBar = searchBar;
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    searchBar.delegate = self;
    searchBar.placeholder = NSLocalizedString(@"SEARCH_BYNAMEORNUMBER_PLACEHOLDER_TEXT", @"");
    searchBar.backgroundColor = [UIColor whiteColor];
    [searchBar sizeToFit];

    UIView *header = [self.selectThreadViewDelegate createHeaderWithSearchBar:searchBar];
    if (!header) {
        header = searchBar;
    }
    [self.view addSubview:header];
    [header autoPinWidthToSuperview];
    [header autoPinToTopLayoutGuideOfViewController:self withInset:0];
    [header setCompressionResistanceVerticalHigh];
    [header setContentHuggingVerticalHigh];

    // Table
    _tableViewController = [OWSTableViewController new];
    _tableViewController.delegate = self;
    [self.view addSubview:self.tableViewController.view];
    [_tableViewController.view autoPinWidthToSuperview];
    [_tableViewController.view autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:header];
    [_tableViewController.view autoPinEdgeToSuperviewEdge:ALEdgeBottom];
    self.tableViewController.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableViewController.tableView.estimatedRowHeight = 60;
}

- (void)yapDatabaseModifiedExternally:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();
    
    DDLogVerbose(@"%@ %s", self.logTag, __PRETTY_FUNCTION__);
    
    [self.uiDatabaseConnection beginLongLivedReadTransaction];
    [self updateTableContents];
}

- (void)yapDatabaseModified:(NSNotification *)notification
{
    OWSAssertIsOnMainThread();
    
    [self.uiDatabaseConnection beginLongLivedReadTransaction];
    [self updateTableContents];
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    [self updateTableContents];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [self updateTableContents];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    [self updateTableContents];
}

- (void)searchBarResultsListButtonClicked:(UISearchBar *)searchBar
{
    [self updateTableContents];
}

- (void)searchBar:(UISearchBar *)searchBar selectedScopeButtonIndexDidChange:(NSInteger)selectedScope
{
    [self updateTableContents];
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    __weak SelectThreadViewController *weakSelf = self;
    ContactsViewHelper *helper = self.contactsViewHelper;
    OWSTableContents *contents = [OWSTableContents new];

    // Existing threads are listed first, ordered by most recently active
    OWSTableSection *recentChatsSection = [OWSTableSection new];
    recentChatsSection.headerTitle = NSLocalizedString(
        @"SELECT_THREAD_TABLE_RECENT_CHATS_TITLE", @"Table section header for recently active conversations");
    for (FLIThread *thread in [self filteredThreadsWithSearchText]) {
        [recentChatsSection
            addItem:[OWSTableItem
                        itemWithCustomCellBlock:^{
                            SelectThreadViewController *strongSelf = weakSelf;
                            OWSCAssertDebug(strongSelf);

                            // To be consistent with the threads (above), we use ContactTableViewCell
                            // instead of HomeViewCell to present contacts and threads.
                            ContactTableViewCell *cell = [ContactTableViewCell new];
                            [cell configureWithThread:thread contactsManager:helper.contactsManager];

                            if (!cell.hasAccessoryText) {
                                // Don't add a disappearing messages indicator if we've already added a "blocked" label.
                                __block OWSDisappearingMessagesConfiguration *disappearingMessagesConfiguration;
                                [self.uiDatabaseConnection
                                    readWithBlock:^(YapDatabaseReadTransaction *_Nonnull transaction) {
                                        disappearingMessagesConfiguration = [OWSDisappearingMessagesConfiguration
                                            fetchObjectWithUniqueID:thread.uniqueId
                                                        transaction:transaction];
                                    }];

                                if (disappearingMessagesConfiguration && disappearingMessagesConfiguration.isEnabled) {
                                    DisappearingTimerConfigurationView *disappearingTimerConfigurationView =
                                        [[DisappearingTimerConfigurationView alloc]
                                            initWithDurationSeconds:disappearingMessagesConfiguration.durationSeconds];

                                    disappearingTimerConfigurationView.tintColor =
                                        [UIColor colorWithWhite:0.5f alpha:1.f];
                                    [disappearingTimerConfigurationView autoSetDimensionsToSize:CGSizeMake(44, 44)];

                                    [cell ows_setAccessoryView:disappearingTimerConfigurationView];
                                }
                            }

                            return cell;
                        }
                        customRowHeight:UITableViewAutomaticDimension
                        actionBlock:^{
                            typeof(self) strongSelf = weakSelf;
                            if (!strongSelf) {
                                return;
                            }
                            [strongSelf.selectThreadViewDelegate threadWasSelected:thread];
                        }]];
    }

    if (recentChatsSection.itemCount > 0) {
        [contents addSection:recentChatsSection];
    }

    // Contacts who don't yet have a thread are listed last
    OWSTableSection *otherContactsSection = [OWSTableSection new];
    otherContactsSection.headerTitle = NSLocalizedString(
        @"SELECT_THREAD_TABLE_OTHER_CHATS_TITLE", @"Table section header for conversations you haven't recently used.");
    NSArray<FLITag *> *filteredRelayTags = [self filteredRelayTagsWithSearchText];
    for (FLITag *relayTag in filteredRelayTags) {
        [otherContactsSection
            addItem:[OWSTableItem
                        itemWithCustomCellBlock:^{
                            SelectThreadViewController *strongSelf = weakSelf;
                            OWSCAssertDebug(strongSelf);

                            ContactTableViewCell *cell = [ContactTableViewCell new];
                            [cell configureWithTagId:relayTag.uniqueId
                                           contactsManager:helper.contactsManager];
                            return cell;
                        }
                        customRowHeight:UITableViewAutomaticDimension
                        actionBlock:^{
                            [weakSelf relayTagWasSelected:relayTag];
                        }]];
    }

    if (otherContactsSection.itemCount > 0) {
        [contents addSection:otherContactsSection];
    }

    if (recentChatsSection.itemCount + otherContactsSection.itemCount < 1) {
        OWSTableSection *emptySection = [OWSTableSection new];
        [emptySection
            addItem:[OWSTableItem
                        softCenterLabelItemWithText:NSLocalizedString(@"SETTINGS_BLOCK_LIST_NO_CONTACTS",
                                                        @"A label that indicates the user has no Signal contacts.")]];
        [contents addSection:emptySection];
    }

    self.tableViewController.contents = contents;
}

-(void)relayTagWasSelected:(FLITag *)relayTag
{
    OWSAssertDebug(relayTag);
    OWSAssertDebug(self.selectThreadViewDelegate);
    
    __block FLIThread *thread = nil;
    __block NSCountedSet<NSString *> *participants = [relayTag recipientIds];
    [participants addObject:[TSAccountManager localUID]];
    [OWSPrimaryStorage.dbReadWriteConnection readWriteWithBlock:^(YapDatabaseReadWriteTransaction *transaction) {
        thread = [FLIThread getOrCreateThreadWithParticipants:[participants allObjects] transaction:transaction];
    }];
    OWSAssertDebug(thread);
    
    [self.selectThreadViewDelegate threadWasSelected:thread];
}

#pragma mark - Filter

- (NSArray<FLIThread *> *)filteredThreadsWithSearchText
{
    NSString *searchTerm = [[self.searchBar text] ows_stripped];

    return [self.conversationSearcher filterThreads:self.threadViewHelper.threads withSearchText:searchTerm];
}

- (NSArray<FLITag *> *)filteredRelayTagsWithSearchText
{
    NSString *searchString = self.searchBar.text;
    
    NSArray<FLITag *>*matchingTags = [self.contactsViewHelper relayTagsMatchingSearchString:searchString];
    
    return matchingTags;
}

#pragma mark - Events

- (void)dismissPressed:(id)sender
{
    [self.searchBar resignFirstResponder];
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - OWSTableViewControllerDelegate

- (void)tableViewWillBeginDragging
{
    [self.searchBar resignFirstResponder];
}

#pragma mark - ThreadViewHelperDelegate

- (void)threadListDidChange
{
    [self updateTableContents];
}

#pragma mark - ContactsViewHelperDelegate

- (void)contactsViewHelperDidUpdateContacts
{
    [self updateTableContents];
}

- (BOOL)shouldHideLocalNumber
{
    return NO;
}

@end

NS_ASSUME_NONNULL_END
