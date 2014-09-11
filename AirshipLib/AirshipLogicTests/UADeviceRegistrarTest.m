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
#import <OCMock/OCMock.h>
#import <OCMock/OCMConstraint.h>
#import "UADeviceAPIClient.h"
#import "UAChannelAPIClient.h"
#import "UADeviceRegistrar+Internal.h"
#import "UAChannelRegistrationPayload.h"
#import "UAHTTPRequest+Internal.h"

@interface UADeviceRegistrarTest : XCTestCase

@property (nonatomic, strong) id mockedDeviceClient;
@property (nonatomic, strong) id mockedChannelClient;
@property (nonatomic, strong) id mockedRegistrarDelegate;

@property (nonatomic, strong) UAHTTPRequest *deviceFailureRequest;
@property (nonatomic, strong) UAHTTPRequest *channelFailureRequest;
@property (nonatomic, strong) NSString *channelCreateSuccessChannelID;
@property (nonatomic, strong) NSString *channelCreateSuccessChannelLocation;


@property (nonatomic, strong) UAChannelRegistrationPayload *payload;
@property (nonatomic, strong) UADeviceRegistrar *registrar;


@end

@implementation UADeviceRegistrarTest

void (^channelUpdateSuccessDoBlock)(NSInvocation *);
void (^channelCreateSuccessDoBlock)(NSInvocation *);
void (^channelUpdateFailureDoBlock)(NSInvocation *);
void (^channelCreateFailureDoBlock)(NSInvocation *);

void (^deviceRegisterSuccessDoBlock)(NSInvocation *);

- (void)setUp {
    [super setUp];

    self.channelCreateSuccessChannelID = @"newChannelID";
    self.channelCreateSuccessChannelLocation = @"newChannelLocation";

    self.mockedDeviceClient = [OCMockObject niceMockForClass:[UADeviceAPIClient class]];
    self.mockedChannelClient = [OCMockObject niceMockForClass:[UAChannelAPIClient class]];

    self.mockedRegistrarDelegate = [OCMockObject niceMockForProtocol:@protocol(UADeviceRegistrarDelegate)];

    self.registrar = [[UADeviceRegistrar alloc] init];
    self.registrar.deviceAPIClient = self.mockedDeviceClient;
    self.registrar.channelAPIClient = self.mockedChannelClient;
    self.registrar.delegate = self.mockedRegistrarDelegate;

    self.payload = [[UAChannelRegistrationPayload alloc] init];
    self.payload.pushAddress = @"someDeviceToken";

    self.channelFailureRequest = [[UAHTTPRequest alloc] init];
    self.deviceFailureRequest = [[UAHTTPRequest alloc] init];

    channelUpdateSuccessDoBlock = ^(NSInvocation *invocation) {
        void *arg;
        [invocation getArgument:&arg atIndex:4];
        UAChannelAPIClientUpdateSuccessBlock successBlock = (__bridge UAChannelAPIClientUpdateSuccessBlock)arg;
        successBlock();
    };

    channelUpdateFailureDoBlock = ^(NSInvocation *invocation) {
        void *arg;
        [invocation getArgument:&arg atIndex:5];
        UAChannelAPIClientFailureBlock failureBlock = (__bridge UAChannelAPIClientFailureBlock)arg;
        failureBlock(self.channelFailureRequest);
    };

    channelCreateSuccessDoBlock = ^(NSInvocation *invocation) {
        void *arg;
        [invocation getArgument:&arg atIndex:3];
        UAChannelAPIClientCreateSuccessBlock successBlock = (__bridge UAChannelAPIClientCreateSuccessBlock)arg;
        successBlock(self.channelCreateSuccessChannelID, self.channelCreateSuccessChannelLocation);
    };

    channelCreateFailureDoBlock = ^(NSInvocation *invocation) {
        void *arg;
        [invocation getArgument:&arg atIndex:4];
        UAChannelAPIClientFailureBlock failureBlock = (__bridge UAChannelAPIClientFailureBlock)arg;
        failureBlock(self.channelFailureRequest);
    };

    deviceRegisterSuccessDoBlock = ^(NSInvocation *invocation) {
        void *arg;
        [invocation getArgument:&arg atIndex:4];
        UADeviceAPIClientSuccessBlock successBlock = (__bridge UADeviceAPIClientSuccessBlock)arg;
        successBlock();
    };
}


- (void)tearDown {
    [super tearDown];
    
    [self.mockedDeviceClient stopMocking];
    [self.mockedChannelClient stopMocking];
    [self.mockedRegistrarDelegate stopMocking];
}

/**
 * Test sucessful register with a channel
 */
- (void)testRegisterWithChannel {
    // Expect the channel client to update channel and call the update block
    [[[self.mockedChannelClient expect] andDo:channelUpdateSuccessDoBlock] updateChannelWithLocation:@"someLocation"
                                                                        withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                          onSuccess:OCMOCK_ANY
                                                                          onFailure:OCMOCK_ANY];

    // Expect the delegate to be called
    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];

    [self.registrar registerWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Registering should always cancel current and pending requests.");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering should always cancel all requests and call updateChannel with passed payload and channel id.");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called.");
}

/**
 * Test failed register with a channnel
 */
- (void)testRegisterWithChannelFail {
    // Expect the channel client to update channel and call the update block
    [[[self.mockedChannelClient expect] andDo:channelUpdateFailureDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];

    // Expect the delegate to be called
    [[self.mockedRegistrarDelegate expect] registrationFailedWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];


    [self.registrar registerWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Registering should always cancel current and pending requests.");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering should always cancel all requests and call updateChannel with passed payload and channel id.");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called on failure");
}

/**
 * Test register with a channel ID with the same payload as the last successful
 * registration payload.
 */
- (void)testRegisterWithChannelDuplicate {
    // Expect the channel client to update channel and call the update block
    [[[self.mockedChannelClient expect] andDo:channelUpdateSuccessDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];

    // Add a successful request
    [self.registrar registerWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];

    // Expect it again when we call run it forcefully
    [[[self.mockedChannelClient expect] andDo:channelUpdateSuccessDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];

    // Expect the delegate to be called
    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];

    // Run it again forcefully
    [self.registrar registerWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:YES];
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering forcefully should not care about previous requests.");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called");


    // Run it normally, it should not call update
    [[self.mockedChannelClient reject] updateChannelWithLocation:OCMOCK_ANY
                                                withPayload:OCMOCK_ANY
                                                  onSuccess:OCMOCK_ANY
                                                  onFailure:OCMOCK_ANY];

    // Delegate should still be called
    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:self.payload];

    [self.registrar registerWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called on success");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering with a payload that is already registered should skip");
}

/**
 * Test register without a channel creates a channel
 */
- (void)testRegisterNoChannel {
    // Expect the channel client to create a channel and call success block
    [[[self.mockedChannelClient expect] andDo:channelCreateSuccessDoBlock] createChannelWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                     onSuccess:OCMOCK_ANY
                                                                                     onFailure:OCMOCK_ANY];

    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];
    [[self.mockedRegistrarDelegate expect] channelCreated:self.channelCreateSuccessChannelID channelLocation:self.channelCreateSuccessChannelLocation];


    [self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Device should clear any pending requests");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Channel client should create a new create request");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called on success");
}

/**
 * Test that registering registering when a request is in progress 
 * does not attempt to register again
 */
- (void)testRegisterRequestInProgress {
    // Expect the channel client to create a channel and not call either block so the
    // request stays pending
    [[self.mockedChannelClient expect] createChannelWithPayload:OCMOCK_ANY
                                                 onSuccess:OCMOCK_ANY
                                                 onFailure:OCMOCK_ANY];

    // Make a pending request
    [self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO];

    // Reject any registration requests
    [[self.mockedChannelClient reject] updateChannelWithLocation:OCMOCK_ANY withPayload:OCMOCK_ANY onSuccess:OCMOCK_ANY onFailure:OCMOCK_ANY];
    [[self.mockedChannelClient reject] createChannelWithPayload:OCMOCK_ANY onSuccess:OCMOCK_ANY onFailure:OCMOCK_ANY];
    [[self.mockedDeviceClient reject] registerDeviceToken:OCMOCK_ANY withPayload:OCMOCK_ANY onSuccess:OCMOCK_ANY onFailure:OCMOCK_ANY];
    [[self.mockedDeviceClient reject] unregisterDeviceToken:OCMOCK_ANY onSuccess:OCMOCK_ANY onFailure:OCMOCK_ANY];

    XCTAssertNoThrow([self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO], @"A pending request should ignore any further requests.");
    XCTAssertNoThrow([self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:YES], @"A pending request should ignore any further requests.");
    XCTAssertNoThrow([self.registrar registerPushDisabledWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO], @"A pending request should ignore any further requests.");
    XCTAssertNoThrow([self.registrar registerPushDisabledWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:YES], @"A pending request should ignore any further requests.");
}

/**
 * Test a succesful register when push is disabled with a channel
 */
- (void)testRegisterPushDisabledWithChannel {
    [[[self.mockedChannelClient expect] andDo:channelUpdateSuccessDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];

    // Expect the delegate to be called
    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];


    [self.registrar registerPushDisabledWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];
    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Registering should always cancel current and pending requests.");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering should always cancel all requests and call updateChannel with passed payload and channel id.");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called on success");
}

/**
 * Test a failed register when push is disabled with a channel
 */
- (void)testRegisterPushDisabledWithChannelFail {
    [[[self.mockedChannelClient expect] andDo:channelUpdateFailureDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];
    // Expect the delegate to be called
    [[self.mockedRegistrarDelegate expect] registrationFailedWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];


    [self.registrar registerPushDisabledWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];
    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Registering should always cancel current and pending requests.");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering should always cancel all requests and call updateChannel with passed payload and channel id.");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called on failure");
}


/**
 * Test register push disabled with the same payload as the
 * previous successful payload.
 */
- (void)testRegisterPushDisabledWithChannelDuplicate {
    // Expect the channel client to update channel and call the update block
    [[[self.mockedChannelClient expect] andDo:channelUpdateSuccessDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];

    // Add a successful request
    [self.registrar registerPushDisabledWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];

    // Expect it again when we call run it forcefully
    [[[self.mockedChannelClient expect] andDo:channelUpdateSuccessDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];




    // Run it again forcefully
    [self.registrar registerPushDisabledWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:YES];
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering forcefully should not care about previous requests.");


    // Run it normally, it should not call update
    [[self.mockedChannelClient reject] updateChannelWithLocation:OCMOCK_ANY
                                                withPayload:OCMOCK_ANY
                                                  onSuccess:OCMOCK_ANY
                                                  onFailure:OCMOCK_ANY];


    [self.registrar registerPushDisabledWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedChannelClient verify], @"Registering with a payload that is already registered should skip.");
}

/**
 * Test that register push disabeld without a channel attempts to create a channel
 */
- (void)testRegisterPushDisabledNoChannelID {
    // Expect the channel client to create a channel and call success block
    [[[self.mockedChannelClient expect] andDo:channelCreateSuccessDoBlock] createChannelWithPayload:OCMOCK_ANY
                                                                                     onSuccess:OCMOCK_ANY
                                                                                     onFailure:OCMOCK_ANY];


    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];

    [self.registrar registerPushDisabledWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedChannelClient verify], @"Channel client should create a new create request");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Registration delegate should be notified of the successful registration");
}

/**
 * Test that registering with a nil channel id first tries to create a channel 
 * and falls back to registering the device token.
 */
- (void)testRegisterNoChannelFallback {
    self.payload.pushAddress = @"some-device-token";
    self.registrar.isDeviceTokenRegistered  = NO;

    // Set up failure with 501 so we fallback
    self.channelFailureRequest.response = [[NSHTTPURLResponse alloc] initWithURL:nil statusCode:501 HTTPVersion:nil headerFields:nil];

    //Expect the channel client to create a channel and fail with 501
    [[[self.mockedChannelClient expect] andDo:channelCreateFailureDoBlock] createChannelWithPayload:OCMOCK_ANY
                                                                                     onSuccess:OCMOCK_ANY
                                                                                     onFailure:OCMOCK_ANY];


    [[[self.mockedDeviceClient expect] andDo:deviceRegisterSuccessDoBlock] registerDeviceToken:self.payload.pushAddress
                                                                              withPayload:OCMOCK_ANY
                                                                                onSuccess:OCMOCK_ANY
                                                                                onFailure:OCMOCK_ANY];

    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];

    [self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Device client should be called to register the device token");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Channel client should attempt to create a channel id");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Registration delegate should be notified of the successful registration");
    XCTAssertFalse(self.registrar.isUsingChannelRegistration, @"Failing to create a channel with a 501 should fallback to device token registration");

    // Reject any more unregister calls
    [[self.mockedDeviceClient reject] registerDeviceToken:OCMOCK_ANY
                                         withPayload:OCMOCK_ANY
                                           onSuccess:OCMOCK_ANY
                                           onFailure:OCMOCK_ANY];

    XCTAssertNoThrow( [self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO], @"Registrar should not register the device token twice");


    self.payload.pushAddress = nil;
    self.registrar.isDeviceTokenRegistered  = NO;
    XCTAssertNoThrow([self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO], @"Registrar should not try to register a nil device token");
}

/**
 * Test device fallback when trying to register push disabled.
 */
- (void)testRegisterPushDisabledNoChannelFallback {
    self.payload.pushAddress = @"some-device-token";
    self.registrar.isDeviceTokenRegistered  = NO;

    // Set up failure with 501 so we fallback
    self.channelFailureRequest.response = [[NSHTTPURLResponse alloc] initWithURL:nil statusCode:501 HTTPVersion:nil headerFields:nil];

    //Expect the channel client to create a channel and fail with 501
    [[[self.mockedChannelClient expect] andDo:channelCreateFailureDoBlock] createChannelWithPayload:OCMOCK_ANY
                                                                                     onSuccess:OCMOCK_ANY
                                                                                     onFailure:OCMOCK_ANY];


    [[[self.mockedDeviceClient expect] andDo:deviceRegisterSuccessDoBlock] registerDeviceToken:self.payload.pushAddress
                                                                              withPayload:OCMOCK_ANY
                                                                                onSuccess:OCMOCK_ANY
                                                                                onFailure:OCMOCK_ANY];

    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];

    [self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO];

    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Device client should be called to register the device token");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Channel client should attempt to create a channel id");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called on success");
    XCTAssertFalse(self.registrar.isUsingChannelRegistration, @"Failing to create a channel with a 501 should fallback to device token registration");

    // Reject any more unregister calls
    [[self.mockedDeviceClient reject] registerDeviceToken:OCMOCK_ANY
                                         withPayload:OCMOCK_ANY
                                           onSuccess:OCMOCK_ANY
                                           onFailure:OCMOCK_ANY];

    XCTAssertNoThrow( [self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO], @"Registrar should not register the device token twice");


    self.payload.pushAddress = nil;
    self.registrar.isDeviceTokenRegistered  = NO;
    XCTAssertNoThrow([self.registrar registerWithChannelID:nil channelLocation:nil withPayload:self.payload forcefully:NO], @"Registrar should not try to register a nil device token");
}

/**
 * Test cancelAllRequests
 */
- (void)testCancelAllRequests {
    self.registrar.lastSuccessPayload = [[UAChannelRegistrationPayload alloc] init];
    self.registrar.isRegistrationInProgress = NO;
    [[self.mockedChannelClient expect] cancelAllRequests];
    [[self.mockedDeviceClient expect] cancelAllRequests];

    [self.registrar cancelAllRequests];
    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Device client should cancel all of its requests.");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Channel client should cancel all of its requests.");
    XCTAssertNotNil(self.registrar.lastSuccessPayload, @"Last success payload should not be cleared if a request is not in progress.");

    self.registrar.isRegistrationInProgress = YES;
    [[self.mockedChannelClient expect] cancelAllRequests];
    [[self.mockedDeviceClient expect] cancelAllRequests];

    [self.registrar cancelAllRequests];
    XCTAssertNil(self.registrar.lastSuccessPayload, @"Last success payload should be cleared if a request is in progress.");
    XCTAssertNoThrow([self.mockedDeviceClient verify], @"Device client should cancel all of its requests.");
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Channel client should cancel all of its requests.");
}

/**
 * Test that a channel update with a 409 status tries to 
 * create a new channel id.
 */
- (void)testChannelConflictNewChannel {
    self.channelFailureRequest.response = [[NSHTTPURLResponse alloc] initWithURL:nil statusCode:409 HTTPVersion:nil headerFields:nil];

    //Expect the channel client to update channel and call the update block
    [[[self.mockedChannelClient expect] andDo:channelUpdateFailureDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];

    // Expect the create channel to be called, make it successful
    self.channelCreateSuccessChannelID = @"newChannel";
    [[[self.mockedChannelClient expect] andDo:channelCreateSuccessDoBlock] createChannelWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                     onSuccess:OCMOCK_ANY
                                                                                     onFailure:OCMOCK_ANY];


    // Expect the delegate to be called
    [[self.mockedRegistrarDelegate expect] registrationSucceededWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];
    [[self.mockedRegistrarDelegate expect] channelCreated:@"newChannel" channelLocation:self.channelCreateSuccessChannelLocation];


    [self.registrar registerWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Conflict with the channel id should create a new channel");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Registration delegate should be called with the new channel");
}

/**
 * Test that a channel update with a 409 fails to create a new
 * channel.
 */
- (void)testChannelConflictFailed {
    self.channelFailureRequest.response = [[NSHTTPURLResponse alloc] initWithURL:nil statusCode:409 HTTPVersion:nil headerFields:nil];

    //Expect the channel client to update channel and call the update block
    [[[self.mockedChannelClient expect] andDo:channelUpdateFailureDoBlock] updateChannelWithLocation:@"someLocation"
                                                                                    withPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                      onSuccess:OCMOCK_ANY
                                                                                      onFailure:OCMOCK_ANY];

    // Expect the create channel to be called, make it fail
    [[[self.mockedChannelClient expect] andDo:channelCreateFailureDoBlock] createChannelWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]
                                                                                     onSuccess:OCMOCK_ANY
                                                                                     onFailure:OCMOCK_ANY];

    // Expect the delegate to be called
    [[self.mockedRegistrarDelegate expect] registrationFailedWithPayload:[OCMArg checkWithSelector:@selector(isEqualToPayload:) onObject:self.payload]];



    [self.registrar registerWithChannelID:@"someChannel" channelLocation:@"someLocation" withPayload:self.payload forcefully:NO];
    XCTAssertNoThrow([self.mockedChannelClient verify], @"Conflict with the channel id should try to create a new channel");
    XCTAssertNoThrow([self.mockedRegistrarDelegate verify], @"Delegate should be called on failure");
}

@end
