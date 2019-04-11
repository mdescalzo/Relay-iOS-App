//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

#import "AttachmentSharing.h"
#import "UIUtil.h"

@import RelayServiceKit;
@import SignalCoreKit;

NS_ASSUME_NONNULL_BEGIN

@implementation AttachmentSharing

+ (void)showShareUIForAttachment:(TSAttachmentStream *)stream
{
    OWSAssertDebug(stream);

    [self showShareUIForURL:stream.mediaURL];
}

+ (void)showShareUIForURL:(NSURL *)url
{
    [self showShareUIForURL:url completion:nil];
}

+ (void)showShareUIForURL:(NSURL *)url completion:(nullable AttachmentSharingCompletion)completion
{
    OWSAssertDebug(url);

    [AttachmentSharing showShareUIForActivityItems:@[
        url,
    ]
                                        completion:completion];
}

+ (void)showShareUIForText:(NSString *)text
{
    [self showShareUIForText:text completion:nil];
}

+ (void)showShareUIForText:(NSString *)text completion:(nullable AttachmentSharingCompletion)completion
{
    OWSAssertDebug(text);

    [AttachmentSharing showShareUIForActivityItems:@[
        text,
    ]
                                        completion:completion];
}

#ifdef DEBUG
+ (void)showShareUIForUIImage:(UIImage *)image
{
    OWSAssertDebug(image);

    [AttachmentSharing showShareUIForActivityItems:@[
        image,
    ]
                                        completion:nil];
}
#endif

+ (void)showShareUIForActivityItems:(NSArray *)activityItems completion:(nullable AttachmentSharingCompletion)completion
{
    OWSAssertDebug(activityItems);

    DispatchMainThreadSafe(^{
        UIActivityViewController *activityViewController =
            [[UIActivityViewController alloc] initWithActivityItems:activityItems applicationActivities:@[]];

        [activityViewController setCompletionWithItemsHandler:^(UIActivityType __nullable activityType,
            BOOL completed,
            NSArray *__nullable returnedItems,
            NSError *__nullable activityError) {

            if (activityError) {
                DDLogInfo(@"%@ Failed to share with activityError: %@", self.logTag, activityError);
            } else if (completed) {
                DDLogInfo(@"%@ Did share with activityType: %@", self.logTag, activityType);
            }

            if (completion) {
                DispatchMainThreadSafe(completion);
            }
        }];

        UIViewController *fromViewController = CurrentAppContext().frontmostViewController;
        while (fromViewController.presentedViewController) {
            fromViewController = fromViewController.presentedViewController;
        }
        OWSAssertDebug(fromViewController);
        [fromViewController presentViewController:activityViewController animated:YES completion:nil];
    });
}

@end

NS_ASSUME_NONNULL_END
