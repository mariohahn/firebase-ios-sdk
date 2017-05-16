/*
 * Copyright 2017 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "Private/FIRUser_Internal.h"

#import "AuthProviders/EmailPassword/FIREmailPasswordAuthCredential.h"
#import "AuthProviders/EmailPassword/FIREmailAuthProvider.h"
#import "AuthProviders/Phone/FIRPhoneAuthCredential_Internal.h"
#import "AuthProviders/Phone/FIRPhoneAuthProvider.h"
#import "Private/FIRAdditionalUserInfo_Internal.h"
#import "FIRAuth.h"
#import "Private/FIRAuthCredential_Internal.h"
#import "Private/FIRAuthDataResult_Internal.h"
#import "Private/FIRAuthErrorUtils.h"
#import "Private/FIRAuthGlobalWorkQueue.h"
#import "Private/FIRAuthSerialTaskQueue.h"
#import "Private/FIRAuth_Internal.h"
#import "FIRSecureTokenService.h"
#import "FIRUserInfoImpl.h"
#import "FIRAuthBackend.h"
#import "FIRDeleteAccountRequest.h"
#import "FIRDeleteAccountResponse.h"
#import "FIRGetAccountInfoRequest.h"
#import "FIRGetAccountInfoResponse.h"
#import "FIRGetOOBConfirmationCodeRequest.h"
#import "FIRGetOOBConfirmationCodeResponse.h"
#import "FIRSetAccountInfoRequest.h"
#import "FIRSetAccountInfoResponse.h"
#import "FIRVerifyAssertionRequest.h"
#import "FIRVerifyAssertionResponse.h"
#import "FIRVerifyCustomTokenRequest.h"
#import "FIRVerifyCustomTokenResponse.h"
#import "FIRVerifyPasswordRequest.h"
#import "FIRVerifyPasswordResponse.h"
#import "FIRVerifyPhoneNumberRequest.h"
#import "FIRVerifyPhoneNumberResponse.h"

NS_ASSUME_NONNULL_BEGIN

/** @var kUserIDCodingKey
    @brief The key used to encode the user ID for NSSecureCoding.
 */
static NSString *const kUserIDCodingKey = @"userID";

/** @var kHasEmailPasswordCredentialCodingKey
    @brief The key used to encode the hasEmailPasswordCredential property for NSSecureCoding.
 */
static NSString *const kHasEmailPasswordCredentialCodingKey = @"hasEmailPassword";

/** @var kAnonymousCodingKey
    @brief The key used to encode the anonymous property for NSSecureCoding.
 */
static NSString *const kAnonymousCodingKey = @"anonymous";

/** @var kEmailCodingKey
    @brief The key used to encode the email property for NSSecureCoding.
 */
static NSString *const kEmailCodingKey = @"email";

/** @var kEmailVerifiedCodingKey
    @brief The key used to encode the isEmailVerified property for NSSecureCoding.
 */
static NSString *const kEmailVerifiedCodingKey = @"emailVerified";

/** @var kDisplayNameCodingKey
    @brief The key used to encode the displayName property for NSSecureCoding.
 */
static NSString *const kDisplayNameCodingKey = @"displayName";

/** @var kPhotoURLCodingKey
    @brief The key used to encode the photoURL property for NSSecureCoding.
 */
static NSString *const kPhotoURLCodingKey = @"photoURL";

/** @var kProviderDataKey
    @brief The key used to encode the providerData instance variable for NSSecureCoding.
 */
static NSString *const kProviderDataKey = @"providerData";

/** @var kAPIKeyCodingKey
    @brief The key used to encode the APIKey instance variable for NSSecureCoding.
 */
static NSString *const kAPIKeyCodingKey = @"APIKey";

/** @var kTokenServiceCodingKey
    @brief The key used to encode the tokenService instance variable for NSSecureCoding.
 */
static NSString *const kTokenServiceCodingKey = @"tokenService";

/** @var kMissingUsersErrorMessage
    @brief The error message when there is no users array in the getAccountInfo response.
 */
static NSString *const kMissingUsersErrorMessage = @"users";

/** @typedef CallbackWithError
    @brief The type for a callback block that only takes an error parameter.
 */
typedef void (^CallbackWithError)(NSError *_Nullable);

/** @typedef CallbackWithUserAndError
    @brief The type for a callback block that takes a user parameter and an error parameter.
 */
typedef void (^CallbackWithUserAndError)(FIRUser *_Nullable, NSError *_Nullable);

/** @typedef CallbackWithUserAndError
    @brief The type for a callback block that takes a user parameter and an error parameter.
 */
typedef void (^CallbackWithAuthDataResultAndError)(FIRAuthDataResult *_Nullable,
                                                   NSError *_Nullable);

/** @var kMissingPasswordReason
    @brief The reason why the @c FIRAuthErrorCodeWeakPassword error is thrown.
    @remarks This error message will be localized in the future.
 */
static NSString *const kMissingPasswordReason = @"Missing Password";

/** @fn callInMainThreadWithError
    @brief Calls a callback in main thread with error.
    @param callback The callback to be called in main thread.
    @param error The error to pass to callback.
 */
static void callInMainThreadWithError(_Nullable CallbackWithError callback,
                                      NSError *_Nullable error) {
  if (callback) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(error);
    });
  }
}

/** @fn callInMainThreadWithUserAndError
    @brief Calls a callback in main thread with user and error.
    @param callback The callback to be called in main thread.
    @param user The user to pass to callback if there is no error.
    @param error The error to pass to callback.
 */
static void callInMainThreadWithUserAndError(_Nullable CallbackWithUserAndError callback,
                                             FIRUser *_Nonnull user,
                                             NSError *_Nullable error) {
  if (callback) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(error ? nil : user, error);
    });
  }
}

/** @fn callInMainThreadWithUserAndError
    @brief Calls a callback in main thread with user and error.
    @param callback The callback to be called in main thread.
    @param result The result to pass to callback if there is no error.
    @param error The error to pass to callback.
 */
static void callInMainThreadWithAuthDataResultAndError(
    _Nullable CallbackWithAuthDataResultAndError callback,
    FIRAuthDataResult *_Nullable result,
    NSError *_Nullable error) {
  if (callback) {
    dispatch_async(dispatch_get_main_queue(), ^{
      callback(result, error);
    });
  }
}

@interface FIRUserProfileChangeRequest ()

/** @fn initWithUser:
    @brief Designated initializer.
    @param user The user for which we are updating profile information.
 */
- (nullable instancetype)initWithUser:(FIRUser *)user NS_DESIGNATED_INITIALIZER;

@end

@interface FIRUser ()

/** @fn initWithAPIKey:
    @brief Designated initializer
    @param APIKey The client API key for making RPCs.
 */
- (nullable instancetype)initWithAPIKey:(NSString *)APIKey NS_DESIGNATED_INITIALIZER;

@end

@implementation FIRUser {
  /** @var _hasEmailPasswordCredential
      @brief Whether or not the user can be authenticated by using Firebase email and password.
   */
  BOOL _hasEmailPasswordCredential;

  /** @var _providerData
      @brief Provider specific user data.
   */
  NSDictionary<NSString *, FIRUserInfoImpl *> *_providerData;

  /** @var _APIKey
      @brief The application's API Key.
   */
  NSString *_APIKey;

  /** @var _taskQueue
      @brief Used to serialize the update profile calls.
   */
  FIRAuthSerialTaskQueue *_taskQueue;

  /** @var _tokenService
      @brief A secure token service associated with this user. For performing token exchanges and
          refreshing access tokens.
   */
  FIRSecureTokenService *_tokenService;
}

#pragma mark - Properties

// Explicitly @synthesize because these properties are defined in FIRUserInfo protocol.
@synthesize uid = _userID;
@synthesize displayName = _displayName;
@synthesize photoURL = _photoURL;
@synthesize email = _email;
@synthesize phoneNumber = _phoneNumber;

#pragma mark -

+ (void)retrieveUserWithAPIKey:(NSString *)APIKey
                   accessToken:(NSString *)accessToken
     accessTokenExpirationDate:(NSDate *)accessTokenExpirationDate
                  refreshToken:(NSString *)refreshToken
                     anonymous:(BOOL)anonymous
                      callback:(FIRRetrieveUserCallback)callback {
  FIRSecureTokenService *tokenService =
      [[FIRSecureTokenService alloc] initWithAPIKey:APIKey
                                        accessToken:accessToken
                          accessTokenExpirationDate:accessTokenExpirationDate
                                       refreshToken:refreshToken];
  FIRUser *user = [[self alloc] initWithAPIKey:APIKey
                                  tokenService:tokenService];
  [user internalGetTokenWithCallback:^(NSString *_Nullable accessToken, NSError *_Nullable error) {
    if (error) {
      callback(nil, error);
      return;
    }
    FIRGetAccountInfoRequest *getAccountInfoRequest =
        [[FIRGetAccountInfoRequest alloc] initWithAPIKey:APIKey accessToken:accessToken];
    [FIRAuthBackend getAccountInfo:getAccountInfoRequest
                          callback:^(FIRGetAccountInfoResponse *_Nullable response,
                                     NSError *_Nullable error) {
      if (error) {
        callback(nil, error);
        return;
      }
      user->_anonymous = anonymous;
      [user updateWithGetAccountInfoResponse:response];
      callback(user, nil);
    }];
  }];
}

- (nullable instancetype)initWithAPIKey:(NSString *)APIKey {
  self = [super init];
  if (self) {
    _APIKey = [APIKey copy];
    _providerData = @{ };
    _taskQueue = [[FIRAuthSerialTaskQueue alloc] init];
  }
  return self;
}

- (nullable instancetype)initWithAPIKey:(NSString *)APIKey
                           tokenService:(FIRSecureTokenService *)tokenService {
  self = [self initWithAPIKey:APIKey];
  if (self) {
    _tokenService = tokenService;
  }
  return self;
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
  return YES;
}

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder {
  NSString *userID = [aDecoder decodeObjectOfClass:[NSString class] forKey:kUserIDCodingKey];
  BOOL hasAnonymousKey = [aDecoder containsValueForKey:kAnonymousCodingKey];
  BOOL anonymous = [aDecoder decodeBoolForKey:kAnonymousCodingKey];
  BOOL hasEmailPasswordCredential =
      [aDecoder decodeBoolForKey:kHasEmailPasswordCredentialCodingKey];
  NSString *displayName =
      [aDecoder decodeObjectOfClass:[NSString class] forKey:kDisplayNameCodingKey];
  NSURL *photoURL =
      [aDecoder decodeObjectOfClass:[NSURL class] forKey:kPhotoURLCodingKey];
  NSString *email =
      [aDecoder decodeObjectOfClass:[NSString class] forKey:kEmailCodingKey];
  BOOL emailVerified = [aDecoder decodeBoolForKey:kEmailVerifiedCodingKey];
  NSSet *providerDataClasses = [NSSet setWithArray:@[
      [NSDictionary class],
      [NSString class],
      [FIRUserInfoImpl class]
  ]];
  NSDictionary<NSString *, FIRUserInfoImpl *> *providerData =
      [aDecoder decodeObjectOfClasses:providerDataClasses forKey:kProviderDataKey];
  NSString *APIKey =
      [aDecoder decodeObjectOfClass:[NSString class] forKey:kAPIKeyCodingKey];
  FIRSecureTokenService *tokenService =
      [aDecoder decodeObjectOfClass:[FIRSecureTokenService class] forKey:kTokenServiceCodingKey];
  if (!userID || !APIKey || !tokenService) {
    return nil;
  }
  self = [self initWithAPIKey:APIKey];
  if (self) {
    _tokenService = tokenService;
    _userID = userID;
    // Previous version of this code didn't save 'anonymous' bit directly but deduced it from
    // 'hasEmailPasswordCredential' and 'providerData' instead, so here backward compatibility is
    // provided to read old format data.
    _anonymous = hasAnonymousKey ? anonymous : (!hasEmailPasswordCredential && !providerData.count);
    _hasEmailPasswordCredential = hasEmailPasswordCredential;
    _email = email;
    _emailVerified = emailVerified;
    _displayName = displayName;
    _photoURL = photoURL;
    _providerData = providerData;
  }
  return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder {
  [aCoder encodeObject:_userID forKey:kUserIDCodingKey];
  [aCoder encodeBool:_anonymous forKey:kAnonymousCodingKey];
  [aCoder encodeBool:_hasEmailPasswordCredential forKey:kHasEmailPasswordCredentialCodingKey];
  [aCoder encodeObject:_providerData forKey:kProviderDataKey];
  [aCoder encodeObject:_email forKey:kEmailCodingKey];
  [aCoder encodeBool:_emailVerified forKey:kEmailVerifiedCodingKey];
  [aCoder encodeObject:_photoURL forKey:kPhotoURLCodingKey];
  [aCoder encodeObject:_displayName forKey:kDisplayNameCodingKey];
  [aCoder encodeObject:_APIKey forKey:kAPIKeyCodingKey];
  [aCoder encodeObject:_tokenService forKey:kTokenServiceCodingKey];
}

#pragma mark -

- (NSString *)providerID {
  return @"Firebase";
}

- (NSArray<id<FIRUserInfo>> *)providerData {
  return _providerData.allValues;
}

/** @fn getAccountInfoRefreshingCache:
    @brief Gets the users's account data from the server, updating our local values.
    @param callback Invoked when the request to getAccountInfo has completed, or when an error has
        been detected. Invoked asynchronously on the auth global work queue in the future.
 */
- (void)getAccountInfoRefreshingCache:(void(^)(FIRGetAccountInfoResponseUser *_Nullable user,
                                               NSError *_Nullable error))callback {
  [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken, NSError *_Nullable error) {
    if (error) {
      callback(nil, error);
      return;
    }
    FIRGetAccountInfoRequest *getAccountInfoRequest =
        [[FIRGetAccountInfoRequest alloc] initWithAPIKey:_APIKey accessToken:accessToken];
    [FIRAuthBackend getAccountInfo:getAccountInfoRequest
                          callback:^(FIRGetAccountInfoResponse *_Nullable response,
                                     NSError *_Nullable error) {
      if (error) {
        callback(nil, error);
        return;
      }
      [self updateWithGetAccountInfoResponse:response];
      if (![self updateKeychain:&error]) {
        callback(nil, error);
        return;
      }
      callback(response.users.firstObject, nil);
    }];
  }];
}

- (void)updateWithGetAccountInfoResponse:(FIRGetAccountInfoResponse *)response {
  FIRGetAccountInfoResponseUser *user = response.users.firstObject;
  _userID = user.localID;
  _email = user.email;
  _emailVerified = user.emailVerified;
  _displayName = user.displayName;
  _photoURL = user.photoURL;
  _phoneNumber = user.phoneNumber;
  _hasEmailPasswordCredential = user.passwordHash.length > 0;

  NSMutableDictionary<NSString *, FIRUserInfoImpl *> *providerData =
      [NSMutableDictionary dictionary];
  for (FIRGetAccountInfoResponseProviderUserInfo *providerUserInfo in user.providerUserInfo) {
    FIRUserInfoImpl *userInfo =
        [FIRUserInfoImpl userInfoWithGetAccountInfoResponseProviderUserInfo:providerUserInfo];
    if (userInfo) {
      providerData[providerUserInfo.providerID] = userInfo;
    }
  }
  _providerData = [providerData copy];
}

/** @fn executeUserUpdateWithChanges:callback:
    @brief Performs a setAccountInfo request by mutating the results of a getAccountInfo response,
        atomically in regards to other calls to this method.
    @param changeBlock A block responsible for mutating a template @c FIRSetAccountInfoRequest
    @param callback A block to invoke when the change is complete. Invoked asynchronously on the
        auth global work queue in the future.
 */
- (void)executeUserUpdateWithChanges:(void(^)(FIRGetAccountInfoResponseUser *,
                                              FIRSetAccountInfoRequest *))changeBlock
                            callback:(nonnull FIRUserProfileChangeCallback)callback {
  [_taskQueue enqueueTask:^(FIRAuthSerialTaskCompletionBlock _Nonnull complete) {
    [self getAccountInfoRefreshingCache:^(FIRGetAccountInfoResponseUser *_Nullable user,
                                          NSError *_Nullable error) {
      if (error) {
        complete();
        callback(error);
        return;
      }
      [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                           NSError *_Nullable error) {
        if (error) {
          complete();
          callback(error);
          return;
        }
        // Mutate setAccountInfoRequest in block:
        FIRSetAccountInfoRequest *setAccountInfoRequest =
            [[FIRSetAccountInfoRequest alloc] initWithAPIKey:_APIKey];
        setAccountInfoRequest.accessToken = accessToken;
        changeBlock(user, setAccountInfoRequest);
        // Execute request:
        [FIRAuthBackend setAccountInfo:setAccountInfoRequest
                              callback:^(FIRSetAccountInfoResponse *_Nullable response,
                                         NSError *_Nullable error) {
          if (error) {
            complete();
            callback(error);
            return;
          }
          if (response.IDToken && response.refreshToken) {
            FIRSecureTokenService *tokenService =
                [[FIRSecureTokenService alloc] initWithAPIKey:_APIKey
                                                  accessToken:response.IDToken
                                    accessTokenExpirationDate:response.approximateExpirationDate
                                                 refreshToken:response.refreshToken];
            [self setTokenService:tokenService callback:^(NSError *_Nullable error) {
              complete();
              callback(error);
            }];
            return;
          }
          complete();
          callback(nil);
        }];
      }];
    }];
  }];
}

/** @fn updateKeychain:
    @brief Updates the keychain for user token or info changes.
    @param error The error if NO is returned.
    @return Wether the operation is successful.
 */
- (BOOL)updateKeychain:(NSError *_Nullable *_Nullable)error {
  return !_auth || [_auth updateKeychainWithUser:self error:error];
}

/** @fn setTokenService:callback:
    @brief Sets a new token service for the @c FIRUser instance.
    @param tokenService The new token service object.
    @param callback The block to be called in the global auth working queue once finished.
    @remarks The method makes sure the token service has access and refresh token and the new tokens
        are saved in the keychain before calling back.
 */
- (void)setTokenService:(FIRSecureTokenService *)tokenService
               callback:(nonnull CallbackWithError)callback {
  [tokenService fetchAccessTokenForcingRefresh:NO
                                      callback:^(NSString *_Nullable token,
                                                 NSError *_Nullable error,
                                                 BOOL tokenUpdated) {
    if (error) {
      callback(error);
      return;
    }
    _tokenService = tokenService;
    if (![self updateKeychain:&error]) {
      callback(error);
      return;
    }
    [_auth notifyListenersOfAuthStateChangeWithUser:self token:token];
    callback(nil);
  }];
}

#pragma mark -

/** @fn updateEmail:password:callback:
    @brief Updates email address and/or password for the current user.
    @remarks May fail if there is already an email/password-based account for the same email
        address.
    @param email The email address for the user, if to be updated.
    @param password The new password for the user, if to be updated.
    @param callback The block called when the user profile change has finished. Invoked
        asynchronously on the auth global work queue in the future.
    @remarks May fail with a @c FIRAuthErrorCodeRequiresRecentLogin error code.
        Call @c reauthentateWithCredential:completion: beforehand to avoid this error case.
 */
- (void)updateEmail:(nullable NSString *)email
           password:(nullable NSString *)password
           callback:(nonnull FIRUserProfileChangeCallback)callback {
  if (password && ![password length]){
    callback([FIRAuthErrorUtils weakPasswordErrorWithServerResponseReason:kMissingPasswordReason]);
    return;
  }
  BOOL hadEmailPasswordCredential = _hasEmailPasswordCredential;
  [self executeUserUpdateWithChanges:^(FIRGetAccountInfoResponseUser *user,
                                       FIRSetAccountInfoRequest *request) {
    if (email) {
      request.email = email;
    }
    if (password) {
      request.password = password;
    }
  }
                            callback:^(NSError *error) {
    if (error) {
      callback(error);
      return;
    }
    if (email) {
      _email = email;
    }
    if (_email && password) {
      _anonymous = NO;
      _hasEmailPasswordCredential = YES;
      if (!hadEmailPasswordCredential) {
        // The list of providers need to be updated for the newly added email-password provider.
        [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                             NSError *_Nullable error) {
          if (error) {
            callback(error);
            return;
          }
          FIRGetAccountInfoRequest *getAccountInfoRequest =
              [[FIRGetAccountInfoRequest alloc] initWithAPIKey:_APIKey accessToken:accessToken];
          [FIRAuthBackend getAccountInfo:getAccountInfoRequest
                                callback:^(FIRGetAccountInfoResponse *_Nullable response,
                                           NSError *_Nullable error) {
            if (error) {
              callback(error);
              return;
            }
            [self updateWithGetAccountInfoResponse:response];
            if (![self updateKeychain:&error]) {
              callback(error);
              return;
            }
            callback(nil);
          }];
        }];
        return;
      }
    }
    if (![self updateKeychain:&error]) {
      callback(error);
      return;
    }
    callback(nil);
  }];
}

- (void)updateEmail:(NSString *)email completion:(nullable FIRUserProfileChangeCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [self updateEmail:email password:nil callback:^(NSError *_Nullable error) {
      callInMainThreadWithError(completion, error);
    }];
  });
}

- (void)updatePassword:(NSString *)password
            completion:(nullable FIRUserProfileChangeCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [self updateEmail:nil password:password callback:^(NSError *_Nullable error){
      callInMainThreadWithError(completion, error);
    }];
  });
}

/** @fn internalUpdatePhoneNumberCredential:completion:
    @brief Updates the phone number for the user. On success, the cached user profile data is
        updated.

    @param phoneAuthCredential The new phone number credential corresponding to the phone number
        to be added to the firebaes account, if a phone number is already linked to the account this
        new phone number will replace it.
    @param completion Optionally; the block invoked when the user profile change has finished.
        Invoked asynchronously on the global work queue in the future.
 */
- (void)internalUpdatePhoneNumberCredential:(FIRPhoneAuthCredential *)phoneAuthCredential
                                 completion:(FIRUserProfileChangeCallback)completion {
  [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                       NSError *_Nullable error) {
    if (error) {
      completion(error);
      return;
    }
    FIRVerifyPhoneNumberRequest *request = [[FIRVerifyPhoneNumberRequest alloc]
        initWithVerificationID:phoneAuthCredential.verificationID
              verificationCode:phoneAuthCredential.verificationCode
                        APIKey:_APIKey];
    request.accessToken = accessToken;
    [FIRAuthBackend verifyPhoneNumber:request
                             callback:^(FIRVerifyPhoneNumberResponse *_Nullable response,
                                        NSError *_Nullable error) {
      if (error) {
        completion(error);;
        return;
      }
      // Get account info to update cached user info.
      [self getAccountInfoRefreshingCache:^(FIRGetAccountInfoResponseUser *_Nullable user,
                                            NSError *_Nullable error) {
        if (![self updateKeychain:&error]) {
          completion(error);
          return;
        }
        completion(nil);
      }];
    }];
  }];
}

- (void)updatePhoneNumberCredential:(FIRPhoneAuthCredential *)phoneAuthCredential
                         completion:(nullable FIRUserProfileChangeCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [self internalUpdatePhoneNumberCredential:phoneAuthCredential
                                   completion:^(NSError *_Nullable error) {
       callInMainThreadWithError(completion, error);
    }];
  });
}

- (FIRUserProfileChangeRequest *)profileChangeRequest {
  __block FIRUserProfileChangeRequest *result;
  dispatch_sync(FIRAuthGlobalWorkQueue(), ^{
    result = [[FIRUserProfileChangeRequest alloc] initWithUser:self];
  });
  return result;
}

- (void)setDisplayName:(NSString *)displayName {
  _displayName = [displayName copy];
}

- (void)setPhotoURL:(NSURL *)photoURL {
  _photoURL = [photoURL copy];
}

- (NSString *)rawAccessToken {
  return _tokenService.rawAccessToken;
}

- (NSDate *)accessTokenExpirationDate {
  return _tokenService.accessTokenExpirationDate;
}

#pragma mark -

- (void)reloadWithCompletion:(nullable FIRUserProfileChangeCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [self getAccountInfoRefreshingCache:^(FIRGetAccountInfoResponseUser *_Nullable user,
                                          NSError *_Nullable error) {
      callInMainThreadWithError(completion, error);
    }];
  });
}

#pragma mark -

- (void)reauthenticateWithCredential:(FIRAuthCredential *)credential
                          completion:(nullable FIRUserProfileChangeCallback)completion {
  FIRAuthDataResultCallback callback = ^(FIRAuthDataResult *_Nullable authResult,
                                         NSError *_Nullable error) {
    completion(error);
  };
  [self reauthenticateAndRetrieveDataWithCredential:credential completion:callback];
}

- (void)
    reauthenticateAndRetrieveDataWithCredential:(FIRAuthCredential *) credential
                                     completion:(nullable FIRAuthDataResultCallback) completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [_auth internalSignInAndRetrieveDataWithCredential:credential
                                    isReauthentication:YES
                                              callback:^(FIRAuthDataResult *_Nullable authResult,
                                                         NSError *_Nullable error) {
      if (error) {
        // If "user not found" error returned by backend, translate to user mismatch error which is
        // more accurate.
        if (error.code == FIRAuthErrorCodeUserNotFound) {
          error = [FIRAuthErrorUtils userMismatchError];
        }
        callInMainThreadWithAuthDataResultAndError(completion, authResult, error);
        return;
      }
      if (![authResult.user.uid isEqual:_auth.currentUser.uid]) {
        callInMainThreadWithAuthDataResultAndError(completion, authResult,
                                                   [FIRAuthErrorUtils userMismatchError]);
        return;
      }
      // Successful reauthenticate
      [self setTokenService:authResult.user->_tokenService callback:^(NSError *_Nullable error) {
        callInMainThreadWithAuthDataResultAndError(completion, authResult, error);
      }];
    }];
  });
}

- (nullable NSString *)refreshToken {
  __block NSString *result;
  dispatch_sync(FIRAuthGlobalWorkQueue(), ^{
    result = _tokenService.refreshToken;
  });
  return result;
}

- (void)getIDTokenWithCompletion:(nullable FIRAuthTokenCallback)completion {
  // |getTokenForcingRefresh:completion:| is also a public API so there is no need to dispatch to
  // global work queue here.
  [self getIDTokenForcingRefresh:NO completion:completion];
}

- (void)getTokenWithCompletion:(nullable FIRAuthTokenCallback)completion {
  [self getIDTokenWithCompletion:completion];
}

- (void)getIDTokenForcingRefresh:(BOOL)forceRefresh
                      completion:(nullable FIRAuthTokenCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [self internalGetTokenForcingRefresh:forceRefresh
                                callback:^(NSString *_Nullable token, NSError *_Nullable error) {
      if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(token, error);
        });
      }
    }];
  });
}

- (void)getTokenForcingRefresh:(BOOL)forceRefresh
                    completion:(nullable FIRAuthTokenCallback)completion {
  [self getIDTokenForcingRefresh:forceRefresh completion:completion];
}

/** @fn internalGetTokenForcingRefresh:callback:
    @brief Retrieves the Firebase authentication token, possibly refreshing it if it has expired.
    @param callback The block to invoke when the token is available. Invoked asynchronously on the
        global work thread in the future.
 */
- (void)internalGetTokenWithCallback:(nonnull FIRAuthTokenCallback)callback {
  [self internalGetTokenForcingRefresh:NO callback:callback];
}

- (void)internalGetTokenForcingRefresh:(BOOL)forceRefresh
                              callback:(nonnull FIRAuthTokenCallback)callback {
  [_tokenService fetchAccessTokenForcingRefresh:forceRefresh
                                       callback:^(NSString *_Nullable token,
                                                  NSError *_Nullable error,
                                                  BOOL tokenUpdated) {
    if (error) {
      callback(nil, error);
      return;
    }
    if (tokenUpdated) {
      if (![self updateKeychain:&error]) {
        callback(nil, error);
        return;
      }
      [_auth notifyListenersOfAuthStateChangeWithUser:self token:token];
    }
    callback(token, nil);
  }];
}

- (void)linkWithCredential:(FIRAuthCredential *)credential
                completion:(nullable FIRAuthResultCallback)completion {
  FIRAuthDataResultCallback callback = ^(FIRAuthDataResult *_Nullable authResult,
                                         NSError *_Nullable error) {
    completion(authResult.user, error);
  };
  [self linkAndRetrieveDataWithCredential:credential completion:callback];
}

- (void)linkAndRetrieveDataWithCredential:(FIRAuthCredential *)credential
                               completion:(nullable FIRAuthDataResultCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    if (_providerData[credential.provider]) {
      callInMainThreadWithAuthDataResultAndError(completion,
                                                 nil,
                                                 [FIRAuthErrorUtils providerAlreadyLinkedError]);
      return;
    }
    FIRAuthDataResult *result =
        [[FIRAuthDataResult alloc] initWithUser:self additionalUserInfo:nil];
    if ([credential isKindOfClass:[FIREmailPasswordAuthCredential class]]) {
      if (_hasEmailPasswordCredential) {
        callInMainThreadWithAuthDataResultAndError(completion,
                                                   nil,
                                                   [FIRAuthErrorUtils providerAlreadyLinkedError]);
        return;
      }
      FIREmailPasswordAuthCredential *emailPasswordCredential =
          (FIREmailPasswordAuthCredential *)credential;
      [self updateEmail:emailPasswordCredential.email
               password:emailPasswordCredential.password
               callback:^(NSError *error) {
        if (error) {
          callInMainThreadWithAuthDataResultAndError(completion, nil, error);
        } else {
          callInMainThreadWithAuthDataResultAndError(completion, result, nil);
        }
      }];
      return;
    }

    if ([credential isKindOfClass:[FIRPhoneAuthCredential class]]) {
      FIRPhoneAuthCredential *phoneAuthCredential = (FIRPhoneAuthCredential *)credential;
      [self internalUpdatePhoneNumberCredential:phoneAuthCredential
                                     completion:^(NSError *_Nullable error) {
        if (error){
          callInMainThreadWithAuthDataResultAndError(completion, nil, error);
        } else {
          callInMainThreadWithAuthDataResultAndError(completion, result, nil);
        }
      }];
      return;
    }

    [_taskQueue enqueueTask:^(FIRAuthSerialTaskCompletionBlock _Nonnull complete) {
      CallbackWithAuthDataResultAndError completeWithError =
          ^(FIRAuthDataResult *result, NSError *error) {
        complete();
        callInMainThreadWithAuthDataResultAndError(completion, result, error);
      };
      [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                           NSError *_Nullable error) {
        if (error) {
          completeWithError(nil, error);
          return;
        }
        FIRVerifyAssertionRequest *request =
          [[FIRVerifyAssertionRequest alloc] initWithAPIKey:_APIKey providerID:credential.provider];
        [credential prepareVerifyAssertionRequest:request];
        request.accessToken = accessToken;
        [FIRAuthBackend verifyAssertion:request
                               callback:^(FIRVerifyAssertionResponse *response, NSError *error) {
          if (error) {
            completeWithError(nil, error);
            return;
          }
          FIRAdditionalUserInfo *additionalUserInfo =
              [FIRAdditionalUserInfo userInfoWithVerifyAssertionResponse:response];
          FIRAuthDataResult *result =
              [[FIRAuthDataResult alloc] initWithUser:self additionalUserInfo:additionalUserInfo];
          // Update the new token and refresh user info again.
          _tokenService =
              [[FIRSecureTokenService alloc] initWithAPIKey:_APIKey
                                                accessToken:response.IDToken
                                  accessTokenExpirationDate:response.approximateExpirationDate
                                               refreshToken:response.refreshToken];
          [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                               NSError *_Nullable error) {
            if (error) {
              completeWithError(nil, error);
              return;
            }
            FIRGetAccountInfoRequest *getAccountInfoRequest =
                [[FIRGetAccountInfoRequest alloc] initWithAPIKey:_APIKey accessToken:accessToken];
            [FIRAuthBackend getAccountInfo:getAccountInfoRequest
                                  callback:^(FIRGetAccountInfoResponse *_Nullable response,
                                             NSError *_Nullable error) {
              if (error) {
                completeWithError(nil, error);
                return;
              }
              _anonymous = NO;
              [self updateWithGetAccountInfoResponse:response];
              if (![self updateKeychain:&error]) {
                completeWithError(nil, error);
                return;
              }
              completeWithError(result, nil);
            }];
          }];
        }];
      }];
    }];
  });
}

- (void)unlinkFromProvider:(NSString *)provider
                completion:(nullable FIRAuthResultCallback)completion {
  [_taskQueue enqueueTask:^(FIRAuthSerialTaskCompletionBlock _Nonnull complete) {
    CallbackWithError completeAndCallbackWithError = ^(NSError *error) {
      complete();
      callInMainThreadWithUserAndError(completion, self, error);
    };
    [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                         NSError *_Nullable error) {
      if (error) {
        completeAndCallbackWithError(error);
        return;
      }
      FIRSetAccountInfoRequest *setAccountInfoRequest =
          [[FIRSetAccountInfoRequest alloc] initWithAPIKey:_APIKey];
      setAccountInfoRequest.accessToken = accessToken;
      BOOL isEmailPasswordProvider = [provider isEqualToString:FIREmailAuthProviderID];
      if (isEmailPasswordProvider) {
        if (!_hasEmailPasswordCredential) {
          completeAndCallbackWithError([FIRAuthErrorUtils noSuchProviderError]);
          return;
        }
        setAccountInfoRequest.deleteAttributes = @[ FIRSetAccountInfoUserAttributePassword ];
      } else {
        if (!_providerData[provider]) {
          completeAndCallbackWithError([FIRAuthErrorUtils noSuchProviderError]);
          return;
        }
        setAccountInfoRequest.deleteProviders = @[ provider ];
      }
      [FIRAuthBackend setAccountInfo:setAccountInfoRequest
                            callback:^(FIRSetAccountInfoResponse *_Nullable response,
                                       NSError *_Nullable error) {
        if (error) {
          completeAndCallbackWithError(error);
          return;
        }
        if (isEmailPasswordProvider) {
          _hasEmailPasswordCredential = NO;
        } else {
          // We can't just use the provider info objects in FIRSetAcccountInfoResponse because they
          // don't have localID and email fields. Remove the specific provider manually.
          NSMutableDictionary *mutableProviderData = [_providerData mutableCopy];
          [mutableProviderData removeObjectForKey:provider];
          _providerData = [mutableProviderData copy];

          // After successfully unlinking a phone auth provider, remove the phone number from the
          // cached user info.
          if ([provider isEqualToString:FIRPhoneAuthProviderID]) {
            _phoneNumber = nil;
          }
        }
        if (response.IDToken && response.refreshToken) {
          FIRSecureTokenService *tokenService =
              [[FIRSecureTokenService alloc] initWithAPIKey:_APIKey
                                                accessToken:response.IDToken
                                  accessTokenExpirationDate:response.approximateExpirationDate
                                               refreshToken:response.refreshToken];
          [self setTokenService:tokenService callback:^(NSError *_Nullable error) {
            completeAndCallbackWithError(error);
          }];
          return;
        }
        if (![self updateKeychain:&error]) {
          completeAndCallbackWithError(error);
          return;
        }
        completeAndCallbackWithError(nil);
      }];
    }];
  }];
}

- (void)sendEmailVerificationWithCompletion:(nullable FIRSendEmailVerificationCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                         NSError *_Nullable error) {
      if (error) {
        callInMainThreadWithError(completion, error);
        return;
      }
      FIRGetOOBConfirmationCodeRequest *request =
          [FIRGetOOBConfirmationCodeRequest verifyEmailRequestWithAccessToken:accessToken
                                                                       APIKey:_APIKey];
      [FIRAuthBackend getOOBConfirmationCode:request
                                    callback:^(FIRGetOOBConfirmationCodeResponse *_Nullable
                                                   response,
                                               NSError *_Nullable error) {
        callInMainThreadWithError(completion, error);
      }];
    }];
  });
}

- (void)deleteWithCompletion:(nullable FIRUserProfileChangeCallback)completion {
  dispatch_async(FIRAuthGlobalWorkQueue(), ^{
    [self internalGetTokenWithCallback:^(NSString *_Nullable accessToken,
                                         NSError *_Nullable error) {
      if (error) {
        callInMainThreadWithError(completion, error);
        return;
      }
      FIRDeleteAccountRequest *deleteUserRequest =
        [[FIRDeleteAccountRequest alloc] initWithAPIKey:_APIKey
                                                localID:_userID
                                            accessToken:accessToken];
      [FIRAuthBackend deleteAccount:deleteUserRequest callback:^(NSError *_Nullable error) {
        if (error) {
          callInMainThreadWithError(completion, error);
          return;
        }
        if (![[FIRAuth auth] signOutByForceWithUserID:_userID error:&error]) {
          callInMainThreadWithError(completion, error);
          return;
        }
        callInMainThreadWithError(completion, error);
      }];
    }];
  });
}

@end

@implementation FIRUserProfileChangeRequest {
  /** @var _user
      @brief The user associated with the change request.
   */
  FIRUser *_user;

  /** @var _displayName
      @brief The display name value to set if @c _displayNameSet is YES.
   */
  NSString *_displayName;

  /** @var _displayNameSet
      @brief Indicates the display name should be part of the change request.
   */
  BOOL _displayNameSet;

  /** @var _photoURL
      @brief The photo URL value to set if @c _displayNameSet is YES.
   */
  NSURL *_photoURL;

  /** @var _photoURLSet
      @brief Indicates the photo URL should be part of the change request.
   */
  BOOL _photoURLSet;

  /** @var _consumed
      @brief Indicates the @c commitChangesWithCallback: method has already been invoked.
   */
  BOOL _consumed;
}

- (nullable instancetype)initWithUser:(FIRUser *)user {
  self = [super init];
  if (self) {
    _user = user;
  }
  return self;
}

- (nullable NSString *)displayName {
  return _displayName;
}

- (void)setDisplayName:(nullable NSString *)displayName {
  dispatch_sync(FIRAuthGlobalWorkQueue(), ^{
    if (_consumed) {
      [NSException raise:NSInternalInconsistencyException
                  format:@"%@",
                         @"Invalid call to setDisplayName: after commitChangesWithCallback:."];
      return;
    }
    _displayNameSet = YES;
    _displayName = [displayName copy];
  });
}

- (nullable NSURL *)photoURL {
  return _photoURL;
}

- (void)setPhotoURL:(nullable NSURL *)photoURL {
  dispatch_sync(FIRAuthGlobalWorkQueue(), ^{
    if (_consumed) {
      [NSException raise:NSInternalInconsistencyException
                  format:@"%@",
                         @"Invalid call to setPhotoURL: after commitChangesWithCallback:."];
      return;
    }
    _photoURLSet = YES;
    _photoURL = [photoURL copy];
  });
}

/** @fn hasUpdates
    @brief Indicates at least one field has a value which needs to be committed.
 */
- (BOOL)hasUpdates {
  return _displayNameSet || _photoURLSet;
}

- (void)commitChangesWithCompletion:(nullable FIRUserProfileChangeCallback)completion {
  dispatch_sync(FIRAuthGlobalWorkQueue(), ^{
    if (_consumed) {
      [NSException raise:NSInternalInconsistencyException
                  format:@"%@",
                         @"commitChangesWithCallback: should only be called once."];
      return;
    }
    _consumed = YES;
    // Return fast if there is nothing to update:
    if (![self hasUpdates]) {
      callInMainThreadWithError(completion, nil);
      return;
    }
    NSString *displayName = [_displayName copy];
    BOOL displayNameWasSet = _displayNameSet;
    NSURL *photoURL = [_photoURL copy];
    BOOL photoURLWasSet = _photoURLSet;
    [_user executeUserUpdateWithChanges:^(FIRGetAccountInfoResponseUser *user,
                                          FIRSetAccountInfoRequest *request) {
      if (photoURLWasSet) {
        request.photoURL = photoURL;
      }
      if (displayNameWasSet) {
        request.displayName = displayName;
      }
    }
                               callback:^(NSError *_Nullable error) {
      if (error) {
        callInMainThreadWithError(completion, error);
        return;
      }
      if (displayNameWasSet) {
        [_user setDisplayName:displayName];
      }
      if (photoURLWasSet) {
        [_user setPhotoURL:photoURL];
      }
      if (![_user updateKeychain:&error]) {
        callInMainThreadWithError(completion, error);
        return;
      }
      callInMainThreadWithError(completion, nil);
    }];
  });
}

@end

NS_ASSUME_NONNULL_END