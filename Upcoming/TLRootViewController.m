//
//  TLRootViewController.m
//  Layout Test
//
//  Created by Ash Furrow on 2013-04-12.
//  Copyright (c) 2013 Teehan+Lax. All rights reserved.
//

#import "TLRootViewController.h"

#import "TLUpcomingEventViewController.h"

#import "UIImage+Blur.h"
#import "EKEventManager.h"

#import <ReactiveCocoaLayout.h>

@interface TLRootViewController ()

// Two view controllers: one for the header and one for the day list.
@property (nonatomic, strong) TLHeaderViewController *headerViewController;
@property (nonatomic, strong) TLEventViewController *dayListViewController;
@property (nonatomic, strong) TLUpcomingEventViewController *footerViewController;

// This is an overlay view added to our view hierarchy when the header menu is pulled down.
@property (nonatomic, strong) UIImageView *dayListOverlayView;

// Gesture recognizers to reveal/hide the headeer menu.
@property (nonatomic, strong) UIPanGestureRecognizer *panHeaderDownGestureRecognizer;
@property (nonatomic, strong) UIPanGestureRecognizer *panHeaderUpGestureRecognizer;
@property (nonatomic, strong) UIPanGestureRecognizer *panFooterUpGestureRecognizer;

// A subject used to receive translations from two different gesture recognizers
// It's helpful to have this as a subject so we can access it from the move-up button, as well. 
@property (nonatomic, strong) RACSubject *headerPanSubject;

// Used to receive ratios of translation for changing the alpha of the overlay view which covers the day list view
@property (nonatomic, strong) RACSubject *dayListOverlaySubject;
@property (nonatomic, strong) RACSubject *dayListAndHeaderOverlaySubject;

// Used to enable/disable gesture recognizers and view interactivity
@property (nonatomic, strong) RACSubject *headerFinishedTransitionSubject;


@end

@implementation TLRootViewController

// We have to use #define's here to get the compiler to expand these macros
#define kMaximumHeaderTranslationThreshold (CGRectGetHeight(self.view.bounds))
#define kMaximumFooterTranslationThreshold (-CGRectGetMidY(self.view.bounds) / 4.0f - CGRectGetHeight(self.footerViewController.view.bounds) / 2.0f)

-(id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    if (!(self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil])) {
        return nil;
    }

    // Set up our view controllers.
    self.dayListViewController = [[TLEventViewController alloc] initWithNibName:@"TLEventViewController" bundle:nil];
    self.dayListViewController.delegate = self;
    [self addChildViewController:self.dayListViewController];

    self.headerViewController = [[TLHeaderViewController alloc] initWithNibName:@"TLHeaderViewController" bundle:nil];
    self.headerViewController.delegate = self;
    [self addChildViewController:self.headerViewController];

    self.footerViewController = [[TLUpcomingEventViewController alloc] initWithNibName:@"TLUpcomingEventViewController" bundle:nil];
    [self addChildViewController:self.footerViewController];


    @weakify(self);

    // If there are no remaining events in the day *and* the event occurs the first thing in the
    // day tomorrow (ie: before noon), then move it up.
    RACSignal *filteredUpdateSignal = [[[RACSignal combineLatest:@[[[RACSignal interval:60.0f] startWith:[NSDate date]], [[EKEventManager sharedInstance] eventsSignal]] reduce:^id(NSDate *now, NSArray *eventArray){
        return eventArray;
    }] map:^id (NSArray *eventArray) {
        NSDate *now = [NSDate date];
        NSArray *upcomingEvents = [eventArray filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL (EKEvent *event, NSDictionary *bindings) {
            return [event.startDate isLaterThanDate:now];
        }]];
        return @(upcomingEvents.count == 0);
    }] deliverOn:[RACScheduler mainThreadScheduler]];

    // Have to map - value in the filter block is nil for some reason.
    RACSignal *nextEventSignal = [[[EKEventManager sharedInstance] nextEventSignal] filter:^BOOL (id value) {
        return value != nil;
    }];

    RACSignal *nextApplicableEventSignal = [[RACSignal combineLatest:@[filteredUpdateSignal, nextEventSignal] reduce:^id (NSNumber *noFurtherEventsToday, EKEvent *nextEvent) {
        if (noFurtherEventsToday.boolValue) {
            NSCalendar *calendar = [[EKEventManager sharedInstance] calendar];
            NSDateComponents *components = [calendar components:NSHourCalendarUnit
                                                       fromDate:nextEvent.startDate];
            
            if (components.hour < 12 && [nextEvent.startDate isTomorrow]) {
                return nextEvent;
            }
        }
        
        return nil;
    }] distinctUntilChanged];

    // These subjects are responsible for adding/removing the overlay view to our hierarchy.
    // We're using an explicit subject here because it maintains state (whether or not the overlay view is in the hierarchy).
    self.dayListOverlaySubject = [RACSubject subject];
    [self.dayListOverlaySubject
     subscribeNext:^(id x) {
         @strongify(self);
         
         if ([x boolValue]) {
             // Using 1.0 scale here because after blurring, we won't need the extra (Retina) pixels.
             
             UIGraphicsBeginImageContextWithOptions(self.view.bounds.size, YES, 1);
             [self.dayListViewController.view.layer
              renderInContext:UIGraphicsGetCurrentContext()];
             UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
             UIGraphicsEndImageContext();
             
             self.dayListOverlayView.image = [UIImage darkenedAndBlurredImageForImage:image];
             
             [self.view
              insertSubview:self.dayListOverlayView
              aboveSubview:self.dayListViewController.view];
             [AppDelegate playPullMenuOutSound];
         } else if (self.dayListOverlayView.superview) {
             self.dayListOverlayView.image = nil;
             [self.dayListOverlayView removeFromSuperview];
             [self.headerViewController scrollTableViewToTop];
             [AppDelegate playPushMenuInSound];
         }
     }];
    
    self.dayListAndHeaderOverlaySubject = [RACSubject subject];
    [self.dayListAndHeaderOverlaySubject subscribeNext:^(id x) {
        @strongify(self);
        
        if ([x boolValue]) {
            // Using 1.0 scale here because after blurring, we won't need the extra (Retina) pixels.
            
            // First grab the image of the day list view
            UIGraphicsBeginImageContextWithOptions(self.view.bounds.size, YES, 1);
            [self.dayListViewController.view.layer renderInContext:UIGraphicsGetCurrentContext()];
            UIImage *dayListImage = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            
            // The grab the image of the header view
            UIGraphicsBeginImageContextWithOptions(self.headerViewController.view.bounds.size, NO, 1);
            CGContextConcatCTM(UIGraphicsGetCurrentContext(), CGAffineTransformMakeTranslation(0, -CGRectGetHeight(self.headerViewController.view.bounds) + kHeaderHeight));
            [self.headerViewController.view.layer renderInContext:UIGraphicsGetCurrentContext()];
            UIImage *headerImage = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            
            // Finally, composite the two images together.
            UIGraphicsBeginImageContextWithOptions(self.view.bounds.size, YES, 1);
            [dayListImage drawInRect:self.view.bounds];
            [headerImage drawInRect:self.headerViewController.view.bounds];
            UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
            
            UIGraphicsEndImageContext();
            
            self.dayListOverlayView.image = [UIImage darkenedAndBlurredImageForImage:image];
            
            [self.view insertSubview:self.dayListOverlayView aboveSubview:self.headerViewController.view];
            
            [AppDelegate playPullMenuOutSound];
        } else if (self.dayListOverlayView.superview) {
            self.dayListOverlayView.image = nil;
            [self.dayListOverlayView removeFromSuperview];
            [self.headerViewController scrollTableViewToTop];
            [AppDelegate playPushMenuInSound];
        }
    }];
    
    
    //These subjects are responsible for calculating the frame of the header and footer
    self.headerPanSubject = [RACSubject subject];
    
    RACSignal *headerOpenRatioSubject = [self.headerPanSubject map:^id (NSNumber *translation) {
        CGFloat verticalTranslation = [translation floatValue];
        
        CGFloat effectiveRatio = 0.0f;
        
        if (verticalTranslation <= 0) {
            effectiveRatio = 0.0f;
        } else if (verticalTranslation <= kMaximumHeaderTranslationThreshold) {
            effectiveRatio = fabsf(verticalTranslation / kMaximumHeaderTranslationThreshold);
        } else {
            CGFloat overshoot = verticalTranslation - kMaximumHeaderTranslationThreshold;
            CGFloat y = 2 * sqrtf(overshoot + 1) - 2;
            effectiveRatio = 1.0f + (y / kMaximumHeaderTranslationThreshold);
        }
        
        return @(effectiveRatio);
    }];
    
    RAC(self.headerViewController.arrowRotationRatio) = headerOpenRatioSubject;
    
    RACSignal *headerFrameSignal = [headerOpenRatioSubject map:^id (id value) {
        // This is the ratio of the movement. 0 is closed and 1 is open.
        // Values less than zero are treated as zero.
        // Values greater than one are valid and will be extrapolated beyond the fully open menu.
        CGFloat ratio = [value floatValue];
        
        CGRect headerFrame = CGRectMake(0, -((1.0f - ratio) * kMaximumHeaderTranslationThreshold), CGRectGetWidth(self.view.bounds), kHeaderHeight + kMaximumHeaderTranslationThreshold);
        
        if (ratio < 0) {
            headerFrame = CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), kHeaderHeight);
        }
        
        return [NSValue valueWithCGRect:headerFrame];
    }];
    
    RAC(self.headerViewController.view.frame) = headerFrameSignal;
    
    // These subjects are responsible for mapping this value to other signals and state (ugh).
    self.headerFinishedTransitionSubject = [RACReplaySubject subject];
    [self.headerFinishedTransitionSubject
     subscribeNext:^(NSNumber *menuIsOpenNumber) {
         @strongify(self);
         
         BOOL menuIsOpen = menuIsOpenNumber.boolValue;
         
         if (menuIsOpen) {
             [self.headerViewController flashScrollBars];
         }
         
         if (!menuIsOpen) {
             [self.dayListOverlaySubject
              sendNext:menuIsOpenNumber];
         }
     }];
        
    RACSignal *canOpenMenuSignal = [RACSignal combineLatest:@[[self.headerFinishedTransitionSubject startWith:@(NO)], RACAbleWithStart(self.dayListViewController.touching)] reduce:^(NSNumber *headerIsOpen,  NSNumber *isTouching) {
        return @(!headerIsOpen.boolValue && !isTouching.boolValue);
    }];
    
    RAC(self.panHeaderDownGestureRecognizer.enabled) = canOpenMenuSignal;
    RAC(self.panFooterUpGestureRecognizer.enabled) = canOpenMenuSignal;
    RAC(self.dayListViewController.view.userInteractionEnabled) = canOpenMenuSignal;
    RAC(self.panHeaderUpGestureRecognizer.enabled) = self.headerFinishedTransitionSubject;
    
    // Finally, set up the gesture recognizers
    self.panFooterUpGestureRecognizer = [[UIPanGestureRecognizer alloc] init];
    RACSignal *footerPanSignal = self.panFooterUpGestureRecognizer.rac_gestureSignal;
    [footerPanSignal subscribeNext:^(UIPanGestureRecognizer *recognizer) {
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            [self.dayListAndHeaderOverlaySubject sendNext:@(YES)];
        }
        else if (recognizer.state == UIGestureRecognizerStateEnded) {
            [self.dayListAndHeaderOverlaySubject sendNext:@(NO)];
        }
    }];
    
    
    RACSignal *footerOpenRatioSubject = [footerPanSignal map:^id (UIPanGestureRecognizer *recognizer) {        
        CGFloat verticalTranslation = 0.0f;
        
        if (recognizer.state == UIGestureRecognizerStateChanged) {
            verticalTranslation = [recognizer translationInView:recognizer.view].y;
        }
        
        CGFloat targetTranslation = kMaximumFooterTranslationThreshold;
        CGFloat effectiveRatio = 0.0f;
        
        if (verticalTranslation < targetTranslation) {
            CGFloat overshoot = fabsf(verticalTranslation) - fabsf(targetTranslation);
            CGFloat y = 2 * sqrtf(overshoot + 1) - 2;
            effectiveRatio = 1.0f + (y / fabsf(targetTranslation));
        } else {
            effectiveRatio = verticalTranslation / targetTranslation;
        }
        
        return @(effectiveRatio);
    }];
    
    // This subject is responsible for calculating the alpha value of the overlay view
    RACSignal *dayListBlurSubject = [[RACSignal combineLatest:@[[headerOpenRatioSubject startWith:@(0)], [footerOpenRatioSubject startWith:@(0)]] reduce:^id (NSNumber *headerRatio, NSNumber *footerRatio) {
        return @(MAX(headerRatio.floatValue, footerRatio.floatValue));
    }] map:^id (id value) {
        // This is the ratio of the movement. 0 is full sized and 1 is fully shrunk.
        CGFloat ratio = [value floatValue];
        
        if (ratio > 1.0f) {
            ratio = 1.0f;
        } else if (ratio < 0.0f) {
            ratio = 0.0f;
        }
        
        return @(ratio);
    }];
    
    RAC(self.dayListOverlayView.alpha) = [dayListBlurSubject animateWithDuration:0.1f];
    
    
    // Need to combine latest on the two signals since the footer moves with both
    RACSignal *footerFrameSignal = [[[RACSignal combineLatest:@[[headerOpenRatioSubject startWith:@(0)], [footerOpenRatioSubject startWith:@(0)], [nextApplicableEventSignal startWith:nil], RACAbleWithStart(self.dayListViewController.touching)] reduce:^id (NSNumber *headerRatio, NSNumber *footerRatio, EKEvent *nextEvent, NSNumber *touchingEventList) {
        if (touchingEventList.boolValue) {
            return @(0.0f);
        }
        if (headerRatio.floatValue > 0) {
            return @(-headerRatio.floatValue);
        }
        if (footerRatio.floatValue > 0) {
            return footerRatio;
        }
        if (nextEvent) {
            return @(0.25f);    // We have an event tomorrow we'd like to highlight. 0.25 seems reasonable.
        }
        
        return @(0);
    }] map:^id (id value) {
        @strongify(self);
        
        // This is the ratio of the movement. 0 is closed and 1 is open.
        // Values less than zero are treated as zero.
        // Values greater than one are valid and will be extrapolated beyond the fully open menu.
        CGFloat ratio = [value floatValue];
        
        CGFloat targetTranslation = kMaximumFooterTranslationThreshold;
        CGRect footerFrame = CGRectMake(0, CGRectGetHeight(self.view.bounds) - TLUpcomingEventViewControllerHiddenHeight + ratio * targetTranslation, CGRectGetWidth(self.view.bounds), TLUpcomingEventViewControllerTotalHeight);
        
        return [NSValue valueWithCGRect:footerFrame];
    }] animateWithDuration:0.1f];
    
    RAC(self.footerViewController.view.frame) = footerFrameSignal;
    
    // This is the number of points beyond which the user need to move their finger in order to trigger the menu moving down.
    const CGFloat kMoveDownThreshold = 30.0f;
    
    self.panHeaderDownGestureRecognizer = [[UIPanGestureRecognizer alloc] init];
    [self.panHeaderDownGestureRecognizer.rac_gestureSignal subscribeNext:^(UIPanGestureRecognizer *recognizer) {
        @strongify(self);
        CGPoint translation = [recognizer translationInView:self.view];
        
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            [self.dayListOverlaySubject sendNext:@(YES)];
        } else if (recognizer.state == UIGestureRecognizerStateChanged) {
            [self.headerPanSubject sendNext:@(translation.y)];
        } else if (recognizer.state == UIGestureRecognizerStateEnded) {
            // Determine the direction the finger is moving and ensure if it was moving down, that it exceeds the minimum threshold for opening the menu.
            BOOL movingDown = ([recognizer velocityInView:self.view].y > 0 && translation.y > kMoveDownThreshold);
            
            // Animate the change
            [UIView animateWithDuration:0.25f animations:^{
                if (movingDown) {
                    [self.headerPanSubject sendNext:@(kMaximumHeaderTranslationThreshold)];
                } else {
                    [self.headerPanSubject sendNext:@(0)];
                }
            } completion:^(BOOL finished) {
                [self.headerFinishedTransitionSubject sendNext:@(movingDown)];
            }];
        }
    }];
    
    self.panHeaderUpGestureRecognizer = [[UIPanGestureRecognizer alloc] init];
    [self.panHeaderUpGestureRecognizer.rac_gestureSignal subscribeNext:^(UIPanGestureRecognizer *recognizer) {
        @strongify(self);
        CGPoint translation = [recognizer translationInView:self.view];
        
        if (recognizer.state == UIGestureRecognizerStateChanged) {
            [self.headerPanSubject sendNext:@(kMaximumHeaderTranslationThreshold + translation.y)];
        } else if (recognizer.state == UIGestureRecognizerStateEnded) {
            // Determine the direction the finger is moving
            BOOL movingDown = ([recognizer velocityInView:self.view].y > 0);
            
            // Animate the change
            [UIView animateWithDuration:0.25f animations:^{
                if (movingDown) {
                    [self.headerPanSubject sendNext:@(kMaximumHeaderTranslationThreshold)];
                } else {
                    [self.headerPanSubject sendNext:@(0)];
                }
            } completion:^(BOOL finished) {
                [self.headerFinishedTransitionSubject sendNext:@(movingDown)];
            }];
        }
    }];
    
    // Finally, add our gesture recognizers to their appropriate views. 
    self.panFooterUpGestureRecognizer.delegate = self;
    [self.view addGestureRecognizer:self.panFooterUpGestureRecognizer];
    [self.dayListViewController.touchDown requireGestureRecognizerToFail:self.panFooterUpGestureRecognizer];
    
    self.panHeaderUpGestureRecognizer.delegate = self;
    [self.headerViewController.view addGestureRecognizer:self.panHeaderUpGestureRecognizer];
    
    self.panHeaderDownGestureRecognizer.delegate = self;
    [self.headerViewController.view addGestureRecognizer:self.panHeaderDownGestureRecognizer];
    
    return self;
}

-(void)loadView {
    [super loadView];
    
    // We'll set up the shadow for the day list view controller here, before it has to shrink.
    self.dayListViewController.view.frame = CGRectMake(0, 0, CGRectGetWidth(self.view.bounds), CGRectGetHeight(self.view.bounds));
    self.dayListViewController.view.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    // Add the day list view controller's view to our hierarchy
    [self.view addSubview:self.dayListViewController.view];
    
    // Add the header view controller's view to our hierarchy
    self.headerViewController.view.frame = CGRectMake(0, -kMaximumHeaderTranslationThreshold, CGRectGetWidth(self.view.bounds), kHeaderHeight + kMaximumHeaderTranslationThreshold);
    [self.view addSubview:self.headerViewController.view];
    
    self.footerViewController.view.frame = CGRectMake(0, CGRectGetHeight(self.view.bounds) - TLUpcomingEventViewControllerHiddenHeight, CGRectGetWidth(self.view.bounds), TLUpcomingEventViewControllerTotalHeight);
    [self.view addSubview:self.footerViewController.view];
    
    self.dayListOverlayView = [[UIImageView alloc] init];
    self.dayListOverlayView.backgroundColor = [UIColor colorWithWhite:0.0f alpha:0.4f];
    self.dayListOverlayView.frame = self.view.frame;
    self.dayListOverlayView.alpha = 0.0f;
    self.dayListOverlayView.userInteractionEnabled = YES; //this will absorb any interaction while in the view hierarchy
}

-(BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer == self.panHeaderUpGestureRecognizer) {
        // Only allow the pan up to take place on the header section of the header menu.
        return CGRectContainsPoint(CGRectMake(0, CGRectGetHeight(self.headerViewController.view.bounds) - kHeaderHeight - kUpperHeaderHeight, CGRectGetWidth(self.view.bounds), kHeaderHeight), [touch locationInView:self.view]);
    } else if (gestureRecognizer == self.panFooterUpGestureRecognizer) {
        CGFloat headerTapHeight = 44.0f;
        return CGRectContainsPoint(CGRectMake(0, CGRectGetHeight(self.view.bounds) - headerTapHeight, CGRectGetWidth(self.view.bounds), headerTapHeight), [touch locationInView:self.view]);
    } else {
        // Otherwise return YES.
        return YES;
    }
}

#pragma mark - TLDayListViewControllerDelegate Methods

-(void)userDidBeginInteractingWithDayListViewController:(TLEventViewController *)controller {
    [self.headerViewController hideHeaderView];
}

-(void)userDidEndInteractingWithDayListViewController:(TLEventViewController *)controller {
    [self.headerViewController showHeaderView];
}

-(void)userDidInteractWithDayListView:(TLEventViewController *)controller updateTimeHour:(NSInteger)hour minute:(NSInteger)minute eventViewModel:(TLEventViewModel *)eventViewModel {
    [self.headerViewController updateHour:hour minute:minute event:eventViewModel];
}

#pragma mark -TLHeaderViewControllerDelegate Methods

-(void)userDidTapDismissHeaderButton {
    [UIView animateWithDuration:0.5f animations:^{
        [self.headerPanSubject sendNext:@(0)];
    } completion:^(BOOL finished) {
        [self.headerFinishedTransitionSubject sendNext:@(NO)];
    }];
}

@end
