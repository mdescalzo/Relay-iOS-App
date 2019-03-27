//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "RegistrationUtils.h"
#import "OWSNavigationController.h"

@import RelayMessaging;
@import RelayServiceKit;

NS_ASSUME_NONNULL_BEGIN

@implementation RegistrationUtils

// TODO: Leverage this utility for Forsta?

+ (void)showReregistrationUIFromViewController:(UIViewController *)fromViewController
{
    UIAlertController *actionSheetController =
        [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    [actionSheetController
        addAction:[UIAlertAction
                      actionWithTitle:NSLocalizedString(@"DEREGISTRATION_REREGISTER_WITH_SAME_PHONE_NUMBER",
                                          @"Label for button that lets users re-register using the same phone number.")
                                style:UIAlertActionStyleDestructive
                              handler:^(UIAlertAction *action) {
                                  [self returnToLogin];
                              }]];

    [actionSheetController addAction:[OWSAlerts cancelAction]];

    [fromViewController presentViewController:actionSheetController animated:YES completion:nil];
}

+(void)returnToLogin
{
    DispatchMainThreadSafe(^{
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Login" bundle:[NSBundle mainBundle]];
        UIViewController *viewController = [storyboard instantiateInitialViewController];
        OWSNavigationController *navigationController = [[OWSNavigationController alloc] initWithRootViewController:viewController];
        navigationController.navigationBarHidden = NO;
        UIApplication.sharedApplication.delegate.window.rootViewController = navigationController;
    });
}

+ (void)reregisterWithFromViewController:(UIViewController *)fromViewController
{
//    DDLogInfo(@"%@ reregisterWithSamePhoneNumber.", self.logTag);
//
//    if (![[TSAccountManager sharedInstance] resetForReregistration]) {
//        OWSFailDebug(@"%@ could not reset for re-registration.", self.logTag);
//        return;
//    }
//
//    [[Environment current].preferences unsetRecordedAPNSTokens];
//
//    [ModalActivityIndicatorViewController
//        presentFromViewController:fromViewController
//                        canCancel:NO
//                  backgroundBlock:^(ModalActivityIndicatorViewController *modalActivityIndicator) {
//                      [TSAccountManager
//                          registerWithPhoneNumber:[TSAccountManager sharedInstance].reregisterationPhoneNumber
//                          success:^{
//                              DDLogInfo(@"%@ re-registering: send verification code succeeded.", self.logTag);
//
//                              dispatch_async(dispatch_get_main_queue(), ^{
//                                  [modalActivityIndicator dismissWithCompletion:^{
//                                      CodeVerificationViewController *viewController =
//                                          [CodeVerificationViewController new];
//
//                                      OWSNavigationController *navigationController =
//                                          [[OWSNavigationController alloc] initWithRootViewController:viewController];
//                                      navigationController.navigationBarHidden = YES;
//
//                                      [UIApplication sharedApplication].delegate.window.rootViewController
//                                          = navigationController;
//                                  }];
//                              });
//                          }
//                          failure:^(NSError *error) {
//                              DDLogError(@"%@ re-registering: send verification code failed.", self.logTag);
//
//                              dispatch_async(dispatch_get_main_queue(), ^{
//                                  [modalActivityIndicator dismissWithCompletion:^{
//                                      if (error.code == 400) {
//                                          [OWSAlerts showAlertWithTitle:NSLocalizedString(@"REGISTRATION_ERROR", nil)
//                                                                message:NSLocalizedString(
//                                                                            @"REGISTRATION_NON_VALID_NUMBER", nil)];
//                                      } else {
//                                          [OWSAlerts showAlertWithTitle:error.localizedDescription
//                                                                message:error.localizedRecoverySuggestion];
//                                      }
//                                  }];
//                              });
//                          }
//                          smsVerification:YES];
//                  }];
}

@end

NS_ASSUME_NONNULL_END
