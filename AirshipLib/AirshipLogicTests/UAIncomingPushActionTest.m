/*
 Copyright 2009-2014 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binaryform must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided withthe distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <XCTest/XCTest.h>
#import "UAIncomingPushAction.h"
#import "UAPush.h"
#import "UAirship+Internal.h"
#import <OCMock/OCMock.h>

@interface UAIncomingPushActionTest : XCTestCase

@property (nonatomic, strong) UAIncomingPushAction *action;
@property (nonatomic, strong) UAActionArguments *arguments;
@property (nonatomic, strong) id mockedPushDelegate;
@property (nonatomic, strong) id mockedAirship;
@property bool backgroundNotificationEnabled;


@end


@implementation UAIncomingPushActionTest

- (void)setUp {
    [super setUp];

    self.backgroundNotificationEnabled = NO;
    self.arguments = [[UAActionArguments alloc] init];
    self.arguments.value = @{ @"aps": @{ @"alert": @"sample alert!", @"badge": @2, @"sound": @"cat" }};

    self.mockedPushDelegate = [OCMockObject niceMockForProtocol:@protocol(UAPushNotificationDelegate)];
    [UAPush shared].pushNotificationDelegate = self.mockedPushDelegate;

    self.mockedAirship = [OCMockObject niceMockForClass:[UAirship class]];
    [[[self.mockedAirship stub] andReturn:self.mockedAirship] shared];
    [[[self.mockedAirship stub] andDo:^(NSInvocation *invocation) {
        [invocation setReturnValue:&_backgroundNotificationEnabled];
    }] backgroundNotificationEnabled];


    self.action = [[UAIncomingPushAction alloc] init];
}

- (void)tearDown {
    [UAPush shared].pushNotificationDelegate = nil;
    [self.mockedPushDelegate stopMocking];
    [self.mockedAirship stopMocking];

    [super tearDown];
}

/*
 * Tests UAIncomingPushAction only accepts push situations and
 * arguments whose value is an NSDictionary
 */
- (void)testAcceptsArguments {
    UASituation validSituations[3] = {
        UASituationForegroundPush,
        UASituationBackgroundPush,
        UASituationLaunchedFromPush
    };

    self.arguments.value = nil;

    // Should not accept any of the valid situations because the value is nil
    for (int i = 0; i < 3; i++) {
        self.arguments.situation = validSituations[i];
        XCTAssertFalse([self.action acceptsArguments:self.arguments], @"Should not accept nil value arguments");
    }

    self.arguments.value = [NSDictionary dictionary];
    self.arguments.situation = UASituationWebViewInvocation;
    XCTAssertFalse([self.action acceptsArguments:self.arguments], @"Should not accept invalid situations");

    // Arguments should be valid
    for (int i = 0; i < 3; i++) {
        self.arguments.situation = validSituations[i];
        XCTAssertTrue([self.action acceptsArguments:self.arguments], @"Should accept valid situation");
    }
}

/**
 * Test running the action with UASituationLaunchedFromPush situation
 */
- (void)testPerformInUASituationLaunchedFromPush {
    __block UAActionResult *runResult;

    self.arguments.situation = UASituationLaunchedFromPush;

    [[self.mockedPushDelegate expect] launchedFromNotification:self.arguments.value];
    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {
        runResult = result;
    }];

    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegate launchedFromNotification: should be called");
    XCTAssertNotNil(runResult, @"Incoming push action should still generate an action result");
    XCTAssertNil(runResult.value, @"Incoming push action should default to an empty result");
    XCTAssertEqual((NSUInteger)runResult.fetchResult, UIBackgroundFetchResultNoData, @"Push action should return the delegate's fetch result");

    // Turn on background notifications
    self.backgroundNotificationEnabled = YES;
    XCTAssertTrue([UAirship shared].backgroundNotificationEnabled, @"Should accept valid situation");

    // Expect the notification and call the block with the delegateResult
    [[self.mockedPushDelegate expect] launchedFromNotification:self.arguments.value fetchCompletionHandler:[OCMArg checkWithBlock:^BOOL(id obj) {
        void(^completionBlock)(UIBackgroundFetchResult) = obj;
        completionBlock(UIBackgroundFetchResultNewData);
        return YES;
    }]];

    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {
        runResult = result;
    }];

    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegate launchedFromNotification:fetchCompletionHandler: should be called");
    XCTAssertNil(runResult.value, @"Value should always be nil");
    XCTAssertEqual((NSUInteger)runResult.fetchResult, UIBackgroundFetchResultNewData, @"Push action should return the delegate's fetch result");
}


/**
 * Test running the action with UASituationBackgroundPush situation
 */
- (void)testPerformInUASituationBackgroundPush {
    __block UAActionResult *runResult;

    self.arguments.situation = UASituationBackgroundPush;

    [[self.mockedPushDelegate expect] receivedBackgroundNotification:self.arguments.value];
    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {
        runResult = result;
    }];

    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegate receivedBackgroundNotification: should be called");
    XCTAssertNotNil(runResult, @"Incoming push action should still generate an action result");
    XCTAssertNil(runResult.value, @"Incoming push action should default to an empty result");
    XCTAssertEqual((NSUInteger)runResult.fetchResult, UIBackgroundFetchResultNoData, @"Push action should return the delegate's fetch result");

    // Turn on background notifications
    self.backgroundNotificationEnabled = YES;
    XCTAssertTrue([UAirship shared].backgroundNotificationEnabled, @"Should accept valid situation");

    // Expect the notification and call the block with the delegateResult
    [[self.mockedPushDelegate expect] receivedBackgroundNotification:self.arguments.value fetchCompletionHandler:[OCMArg checkWithBlock:^BOOL(id obj) {
        void(^completionBlock)(UIBackgroundFetchResult) = obj;
        completionBlock(UIBackgroundFetchResultNewData);
        return YES;
    }]];

    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {
        runResult = result;
    }];

    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegate receivedBackgroundNotification:fetchCompletionHandler: should be called");
    XCTAssertNil(runResult.value, @"Value should always be nil");
    XCTAssertEqual((NSUInteger)runResult.fetchResult, UIBackgroundFetchResultNewData, @"Push action should return the delegate's fetch result");
}

/**
 * Test running the action with UASituationForegroundPush situation
 */
- (void)testPerformInUASituationForegroundPush {
    __block UAActionResult *runResult;

    self.arguments.situation = UASituationForegroundPush;

    [[self.mockedPushDelegate expect] receivedForegroundNotification:self.arguments.value];

    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {
        runResult = result;
    }];

    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegate receivedForegroundNotification: should be called");
    XCTAssertNotNil(runResult, @"Incoming push action should still generate an action result");
    XCTAssertNil(runResult.value, @"Incoming push action should default to an empty result");
    XCTAssertEqual((NSUInteger)runResult.fetchResult, UIBackgroundFetchResultNoData, @"Push action should return the delegate's fetch result");

    // Turn on background notifications
    self.backgroundNotificationEnabled = YES;
    XCTAssertTrue([UAirship shared].backgroundNotificationEnabled, @"Should accept valid situation");

    // Expect the notification and call the block with the delegateResult
    [[self.mockedPushDelegate expect] receivedForegroundNotification:self.arguments.value fetchCompletionHandler:[OCMArg checkWithBlock:^BOOL(id obj) {
        void(^completionBlock)(UIBackgroundFetchResult) = obj;
        completionBlock(UIBackgroundFetchResultNewData);
        return YES;
    }]];

    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {
        runResult = result;
    }];

    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegate receivedForegroundNotification:fetchCompletionHandler: should be called");
    XCTAssertNil(runResult.value, @"Value should always be nil");
    XCTAssertEqual((NSUInteger)runResult.fetchResult, UIBackgroundFetchResultNewData, @"Push action should return the delegate's fetch result");
}


/**
 * Test running the action with UASituationForegroundPush situation notifies
 * the app delegate of an alert, sound, and badge
 */
- (void)testPerformInUASituationForegroundPushNotifyForegroundAlert {
    self.arguments.situation = UASituationForegroundPush;
    [UAPush shared].autobadgeEnabled = NO;
    
    [[self.mockedPushDelegate expect] playNotificationSound:@"cat"];
    [[self.mockedPushDelegate expect] displayNotificationAlert:@"sample alert!"];
    [[self.mockedPushDelegate expect] handleBadgeUpdate:2];

    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {}];
    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegate should notify the delegate of a foreground notification");

    // Enable auto badge and verify handleBadgeUpdate: is not called
    [UAPush shared].autobadgeEnabled = YES;

    [[self.mockedPushDelegate expect] playNotificationSound:@"cat"];
    [[self.mockedPushDelegate expect] displayNotificationAlert:@"sample alert!"];
    [[self.mockedPushDelegate reject] handleBadgeUpdate:2];

    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {}];
    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegates handleBadgeUpdate should not be called if autobadge is enabled");


    // Set to an empty notification
    self.arguments.value = [NSDictionary dictionary];
    [[self.mockedPushDelegate reject] playNotificationSound:OCMOCK_ANY];
    [[self.mockedPushDelegate reject] displayNotificationAlert:OCMOCK_ANY];
    [[self.mockedPushDelegate reject] handleBadgeUpdate:2];

    [self.action performWithArguments:self.arguments withCompletionHandler:^(UAActionResult *result) {}];
    XCTAssertNoThrow([self.mockedPushDelegate verify], @"Push delegates should not be notified of an empty dictionary");
}



@end
