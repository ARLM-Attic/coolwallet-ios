//
//  CwExchange.m
//  CoolWallet
//
//  Created by 鄭斐文 on 2016/1/12.
//  Copyright © 2016年 MAC-BRYAN. All rights reserved.
//

#import "CwExchangeManager.h"
#import "CwExchangeSettings.h"
#import "CwCard.h"
#import "CwManager.h"
#import "NSString+HexToData.h"
#import "APPData.h"
#import "CwExTx.h"
#import "CwBtc.h"
#import "CwTxin.h"
#import "CwExUnblock.h"
#import "CwExUnclarifyOrder.h"
#import "CwExchange.h"
#import "CwExSellOrder.h"
#import "CwExBuyOrder.h"
#import "CwBase58.h"

#import "NSUserDefaults+RMSaveCustomObject.h"

@interface CwExchangeManager()

@property (readwrite, assign) ExSessionStatus sessionStatus;

@property (readwrite, nonatomic) CwCard *card;
@property (strong, nonatomic) NSString *loginSession;

@property (readwrite, nonatomic) CwExchange *exchange;

@property (strong, nonatomic) NSMutableArray *syncedAccount;
@property (readwrite, nonatomic) BOOL cardInfoSynced;

@property (strong, nonatomic) NSString *txReceiveAddress;
@property (strong, nonatomic) NSData *txLoginHandle;

@end

@implementation CwExchangeManager

+(id)sharedInstance
{
    static dispatch_once_t pred;
    static CwExchangeManager *sharedInstance = nil;
    if (enableExchangeSite) {
        dispatch_once(&pred, ^{
            sharedInstance = [[CwExchangeManager alloc] init];
        });
    }
    return sharedInstance;
}

-(id) init
{
    self = [super init];
    if (self) {
        [self observeConnectedCard];
    }
    
    return self;
}

-(BOOL) isCardLoginEx:(NSString *)cardId
{
    return self.sessionStatus == ExSessionLogin && self.card.cardId == cardId;
}

-(void) observeConnectedCard
{
    @weakify(self)
    CwManager *manager = [CwManager sharedManager];
    RAC(self, card) = [RACObserve(manager, connectedCwCard) filter:^BOOL(CwCard *card) {
        @strongify(self)
        BOOL changed = ![card.cardId isEqualToString:self.card.cardId];
        
        if (changed && self.card.cardId != nil && self.exchange != nil) {
            NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
            [defaults rm_setCustomObject:self.exchange forKey:[NSString stringWithFormat:@"exchange_%@", self.card.cardId]];
        }
        
        return changed;
    }];
    
    [[RACObserve(self, card) distinctUntilChanged] subscribeNext:^(CwCard *card) {
        @strongify(self)
        self.syncedAccount = [NSMutableArray new];
        self.cardInfoSynced = NO;
        
        if (self.sessionStatus != ExSessionNone && self.sessionStatus != ExSessionFail) {
            [self logoutExSession];
        }
        self.sessionStatus = ExSessionNone;
        self.loginSession = nil;
        self.exchange = nil;
    }];
}

-(void) loginExSession
{
    @weakify(self);
    [[self loginSignal] subscribeNext:^(id cardResponse) {
        @strongify(self);
        self.sessionStatus = ExSessionLogin;
    } error:^(NSError *error) {
        @strongify(self);
        NSLog(@"error(%ld): %@", (long)error.code, error);
        self.sessionStatus = ExSessionFail;
        [self logoutExSession];
    }];
    
    __block RACDisposable *disposable = [[[[RACObserve(self, sessionStatus) filter:^BOOL(NSNumber *status) {
        return status.intValue == ExSessionLogin || status.intValue == ExSessionFail;
    }] take:1] delay:0.2] subscribeNext:^(NSNumber *status) {
        if (status.intValue == ExSessionLogin) {
            self.exchange = [[NSUserDefaults standardUserDefaults] rm_customObjectForKey:[NSString stringWithFormat:@"exchange_%@", self.card.cardId]];
            if (self.exchange == nil) {
                self.exchange = [CwExchange new];
            }
            
            [self syncCardInfo];
            [self unblockOrders];
        } else {
            [disposable dispose];
        }
    } error:^(NSError *error) {
        
    }];
}

-(void) logoutExSession
{
    if (self.card.mode.integerValue == CwCardModeNormal || self.card.mode.integerValue == CwCardModeAuth) {
        [self.card exSessionLogout];
    }
    
    AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
    [manager GET:ExSessionLogout parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
        
    } failure:^(AFHTTPRequestOperation *operation, NSError *error){
        
    }];
}

-(void) syncCardInfo
{
    self.cardInfoSynced = NO;
    
    [self observeHdwAccountPointer];
    for (CwAccount *account in [self.card.cwAccounts allValues]) {
        if (!account.infoSynced) {
            [self.card getAccountInfo:account.accId];
        }
    }
}

-(void) requestUnclarifyOrders
{
    NSString *url = [NSString stringWithFormat:ExUnclarifyOrders, self.card.cardId];
    AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
    [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSArray *responseObject) {
        NSArray *unclarifyOrders = [RMMapper arrayOfClass:[CwExUnclarifyOrder class] fromArrayOfDictionary:responseObject];
        
        self.exchange.unclarifyOrders = [NSMutableArray arrayWithArray:unclarifyOrders];
    } failure:^(AFHTTPRequestOperation *operation, NSError *error){
        
    }];
}

-(void) requestMatchedOrders
{
    NSString *url = [NSString stringWithFormat:ExGetMatchedOrders, self.card.cardId];
    AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
    [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
        [RMMapper populateObject:self.exchange fromDictionary:responseObject];
    } failure:^(AFHTTPRequestOperation *operation, NSError *error){
        
    }];
}

-(void) requestMatchedOrder:(NSString *)orderId
{
    NSString *url = [NSString stringWithFormat:ExGetMatchedOrders, self.card.cardId];
    [url stringByAppendingFormat:@"/%@", orderId];
    
    AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
    [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
        if ([responseObject objectForKey:@"sell"] != nil) {
            CwExSellOrder *sell = [CwExSellOrder new];
            [RMMapper populateObject:sell fromDictionary:[responseObject objectForKey:@"sell"]];
            [self.exchange.matchedSellOrders addObject:sell];
        } else if ([responseObject objectForKey:@"buy"] != nil) {
            CwExBuyOrder *buy = [CwExBuyOrder new];
            [RMMapper populateObject:buy fromDictionary:[responseObject objectForKey:@"buy"]];
            [self.exchange.matchedBuyOrders addObject:buy];
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error){
        
    }];
}

-(void) blockWithOrderID:(NSString *)hexOrderID withOTP:(NSString *)otp withSuccess:(void(^)(void))successCallback error:(void(^)(NSError *error))errorCallback finish:(void(^)(void))finishCallback
{
    RACSignal *blockSignal = [self signalRequestOrderBlockWithOrderID:hexOrderID withOTP:otp];
    
    [[[[blockSignal flattenMap:^RACStream *(NSString *blockData) {
        return [self signalBlockBTCFromCard:blockData];
    }] flattenMap:^RACStream *(NSDictionary *data) {
        NSString *okToken = [data objectForKey:@"okToken"];
        NSString *unblockToken = [data objectForKey:@"unblockToken"];
        
        return [self signalWriteOKTokenToServer:okToken unblockToken:unblockToken withOrder:hexOrderID];
    }] finally:^() {
        if (finishCallback) {
            finishCallback();
        }
    }]subscribeNext:^(id value) {
        if (self.exchange.unclarifyOrders != nil && self.exchange.unclarifyOrders.count > 0) {
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF.orderId == %@", hexOrderID];
            NSArray *result = [self.exchange.unclarifyOrders filteredArrayUsingPredicate:predicate];
            if (result.count > 0) {
                [self.exchange.unclarifyOrders removeObjectsInArray:result];
            }
        }
        
        if (successCallback) {
            successCallback();
        }
    } error:^(NSError *error) {
        if (errorCallback) {
            errorCallback(error);
        }
    }];
}

-(void) prepareTransactionFromSellOrder:(CwExSellOrder *)sellOrder withChangeAddress:(NSString *)changeAddress andAccountId:(NSInteger)accountId
{
    CwExTx *exTx = [CwExTx new];
    exTx.accountId = accountId;
    exTx.amount = [CwBtc BTCWithBTC:sellOrder.amountBTC];
    exTx.changeAddress = changeAddress;
    
    @weakify(self)
    [[[[[self signalGetTrxInfoFromOrder:sellOrder.orderId] flattenMap:^RACStream *(NSDictionary *response) {
        NSLog(@"response: %@", response);
        @strongify(self)
        NSString *loginData = [response objectForKey:@"loginblk"];
        exTx.receiveAddress = [response objectForKey:@"out1addr"];
        
        if (!loginData) {
            return [RACSignal error:[NSError errorWithDomain:NSLocalizedString(@"Exchange site error.",nil) code:1001 userInfo:@{@"error": NSLocalizedString(@"Fail to get transaction data from exchange site.",nil)}]];
        }
        
        return [self signalTrxLogin:loginData];
    }] flattenMap:^RACStream *(NSData *trxHandle) {
        sellOrder.trxHandle = trxHandle;
        
        exTx.loginHandle = trxHandle;
        CwTx *unsignedTx = [self.card getUnsignedTransaction:exTx.amount.satoshi.longLongValue Address:exTx.receiveAddress Change:exTx.changeAddress AccountId:exTx.accountId];
        if (unsignedTx == nil) {
            return [RACSignal error:[NSError errorWithDomain:NSLocalizedString(@"Exchange site error.",nil) code:1002 userInfo:@{@"error": NSLocalizedString(@"Check unsigned data error.",nil)}]];
        } else {
            return [self signalTrxPrepareDataFrom:unsignedTx andExTx:exTx];
        }
    }] finally:^() {
        CwAccount *account = [self.card.cwAccounts objectForKey:[NSString stringWithFormat:@"%ld", exTx.accountId]];
        account.tempUnblockAmount = 0;
    }] subscribeNext:^(id value) {
        NSLog(@"Ex Trx prepairing...");
    } error:^(NSError *error) {
        NSLog(@"Ex Trx prepaire fail: %@", error);
        //TODO: nonce rule?
        if (exTx.loginHandle) {
            NSMutableData *nonce = [NSMutableData dataWithData:exTx.loginHandle];
            [nonce appendData:exTx.loginHandle];
            [nonce appendData:exTx.loginHandle];
            [nonce appendData:exTx.loginHandle];
            [self.card exTrxSignLogoutWithTrxHandle:exTx.loginHandle Nonce:nonce];
        }
        
        if ([self.card.delegate respondsToSelector:@selector(didPrepareTransactionError:)]) {
            if (error.userInfo) {
                [self.card.delegate didPrepareTransactionError:[error.userInfo objectForKey:@"error"]];
            } else {
                [self.card.delegate didPrepareTransactionError:NSLocalizedString(@"Fail to get transaction data from exchange site.",nil)];
            }
        }
    }];
}

-(void) completeTransactionWithOrderId:(NSString *)orderId TxId:(NSString *)txId Handle:(NSData *)trxHandle
{
    if (trxHandle) {
        NSMutableData *nonce = [NSMutableData dataWithData:trxHandle];
        [nonce appendData:trxHandle];
        [nonce appendData:trxHandle];
        [nonce appendData:trxHandle];
        [self.card exTrxSignLogoutWithTrxHandle:trxHandle Nonce:nonce];
    }
    
    NSString *url = [NSString stringWithFormat:ExTrx, orderId];
    NSDictionary *dict = @{@"bcTrxId": txId};
    
    AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
    [manager POST:url parameters:dict success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
        NSLog(@"Success send txId to ex site.");
        
        if (self.exchange.matchedSellOrders != nil && self.exchange.matchedSellOrders.count > 0) {
            NSPredicate *predicate = [NSPredicate predicateWithFormat:@"SELF.orderId == %@", orderId];
            NSArray *result = [self.exchange.matchedSellOrders filteredArrayUsingPredicate:predicate];
            if (result.count > 0) {
                [self.exchange.matchedSellOrders removeObjectsInArray:result];
            }
        }
        
    } failure:^(AFHTTPRequestOperation *operation, NSError *error){
        NSLog(@"Fail send txId to ex site.");
        // TODO: should resend to exchange site?
    }];
}

-(void) unblockOrders
{
    [[self signalRequestUnblockInfoWithOrderId:nil] subscribeNext:^(NSArray *unblocks) {
        for (CwExUnblock *unblock in unblocks) {
            [[self signalUnblock:unblock] subscribeNext:^(id value) {
                
            } error:^(NSError *error) {
                
            }];
        }
    }];
}

-(void) unblockOrderWithOrderId:(NSString *)orderId
{
    RACSignal *unblockSignal = [self signalRequestUnblockInfoWithOrderId:orderId];
    
    [[unblockSignal flattenMap:^RACStream *(CwExUnblock *unblock) {
        return [self signalUnblock:unblock];
    }] subscribeNext:^(id value) {
        
    } error:^(NSError *error) {
        
    }];
}

-(void) observeHdwAccountPointer
{
    RACSignal *accountNumberSignal = [[RACObserve(self, card) map:^id(CwCard *card) {
        return RACObserve(card, hdwAcccountPointer);
    }] switchToLatest];
    
    @weakify(self);
    [[[accountNumberSignal distinctUntilChanged] skipUntilBlock:^BOOL(NSNumber *counter) {
        @strongify(self)
        return self.sessionStatus == ExSessionLogin;
    }] subscribeNext:^(NSNumber *counter) {
        @strongify(self);
        NSLog(@"observeHdwAccountPointer: %@", counter);
        for (int index = (int)self.syncedAccount.count; index < counter.intValue; index++) {
            CwAccount *account = [self.card.cwAccounts objectForKey:[NSString stringWithFormat:@"%d", index]];
            if (account) {
                [self observeAccount:account];
                [self observeHdwAccountAddrCount:account];
            }
        }
    }];
}

-(void) observeAccount:(CwAccount *)account
{
    if (self.sessionStatus != ExSessionLogin) {
        return;
    }
    
    @weakify(self);
    RACDisposable *disposable = [[[RACObserve(account, infoSynced) distinctUntilChanged] filter:^BOOL(NSNumber *synced) {
        @strongify(self);
        return synced.boolValue && ![self.syncedAccount containsObject:account];
    }] subscribeNext:^(NSNumber *synced) {
        @strongify(self);
        NSLog(@"account: %ld, synced: %d, self.syncAccountCount = %lu", (long)account.accId, synced.boolValue, (unsigned long)self.syncedAccount.count);
        
        [self.syncedAccount addObject:account];
        
        if (self.syncedAccount.count == self.card.cwAccounts.count) {
            [[self signalSyncCardInfo] subscribeNext:^(NSDictionary *response) {
                NSLog(@"sync: %@", response);
                self.cardInfoSynced = YES;
            } error:^(NSError *error) {
                NSLog(@"sync error: %@", error);
                [self.syncedAccount removeAllObjects];
            }];
        }
        
        [disposable dispose];
    }];
}

-(void) observeHdwAccountAddrCount:(CwAccount *)account
{
    @weakify(self)
    RACSignal *signal = [[[RACSignal combineLatest:@[RACObserve(account, extKeyPointer), RACObserve(account, intKeyPointer)]
                                          reduce:^(NSNumber *extCount, NSNumber *intCount) {
                                              int counter = (extCount.intValue + intCount.intValue);
                                              return @(counter);
                                          }] skipWhileBlock:^BOOL(NSNumber *counter) {
                                              @strongify(self)
                                              return counter.intValue * self.cardInfoSynced <= 0;
                                          }] distinctUntilChanged];
    
    RACDisposable *disposable = [[signal flattenMap:^RACStream *(NSArray *counter) {
        @strongify(self)
        return [self signalSyncAccountInfo:account];
    }] subscribeNext:^(id response) {
        NSLog(@"sync account %ld completed: %@", (long)account.accId, response);
    } error:^(NSError *error) {
        NSLog(@"sync account error: %@", error);
    }];
    
    [account.rac_willDeallocSignal subscribeNext:^(id value) {
        NSLog(@"%@ will dealloc", value);
        [disposable dispose];
    }];
}

// signals

-(RACSignal *)loginSignal
{
    @weakify(self);
    RACSignal *signal = [[[[self signalCreateExSession] flattenMap:^RACStream *(NSDictionary *response) {
        @strongify(self);
        NSString *hexString = [response objectForKey:@"challenge"];
        
        return [self signalInitSessionFromCard:[NSString hexstringToData:hexString]];
    }] flattenMap:^RACStream *(NSDictionary *cardResponse) {
        @strongify(self);
        NSData *seResp = [cardResponse objectForKey:@"seResp"];
        NSData *seChlng = [cardResponse objectForKey:@"seChlng"];
        
        return [self signalEstablishExSessionWithChallenge:seChlng andResponse:seResp];
    }] flattenMap:^RACStream *(NSDictionary *response) {
        @strongify(self);
        NSString *hexString = [response objectForKey:@"response"];
        
        return [self signalEstablishSessionFromCard:[NSString hexstringToData:hexString]];
    }];
    
    return signal;
}

-(RACSignal*)signalCreateExSession {
    __block NSString *url = [NSString stringWithFormat:ExSession, self.card.cardId];
    
    @weakify(self);
    RACSignal *signal = [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            self.loginSession = [operation.response.allHeaderFields objectForKey:@"Set-Cookie"];
            
            NSString *hexString = [responseObject objectForKey:@"challenge"];
            if (hexString.length == 0) {
                [subscriber sendError:[NSError errorWithDomain:NSLocalizedString(@"Not exchange site member.",nil) code:NotRegistered userInfo:nil]];
            } else {
                [subscriber sendNext:responseObject];
                [subscriber sendCompleted];
            }
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }] doNext:^(id value) {
        self.sessionStatus = ExSessionProcess;
    }];
    
    return signal;
}

-(RACSignal *)signalInitSessionFromCard:(NSData *)srvChlng
{
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        [self.card exSessionInit:srvChlng withComplete:^(NSData *seResp, NSData *seChlng) {
            NSLog(@"seResp: %@, seChlng: %@", seResp, seChlng);
            
            [subscriber sendNext:@{@"seResp": seResp, @"seChlng": seChlng}];
            [subscriber sendCompleted];
        } withError:^(NSInteger errorCode) {
            [subscriber sendError:[self cardCmdError:errorCode errorMsg:NSLocalizedString(@"Card init session fail.",nil)]];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal*)signalEstablishExSessionWithChallenge:(NSData *)challenge andResponse:(NSData *)response {
    __block NSString *url = [NSString stringWithFormat:ExSession, self.card.cardId];
    __block NSDictionary *dict = @{@"challenge": [NSString dataToHexstring:challenge], @"response": [NSString dataToHexstring:response]};
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager POST:url parameters:dict success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            [subscriber sendNext:responseObject];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalEstablishSessionFromCard:(NSData *)svrResp
{
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        [self.card exSessionEstab:svrResp withComplete:^() {
            [subscriber sendNext:nil];
            [subscriber sendCompleted];
        } withError:^(NSInteger errorCode) {
            NSError *error = [NSError errorWithDomain:NSLocalizedString(@"Card Cmd Error",nil) code:errorCode userInfo:nil];
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal*)signalSyncCardInfo {
    __block NSString *url = [NSString stringWithFormat:ExSyncCardInfo, self.card.cardId];
    
    __block NSMutableDictionary *dict = [NSMutableDictionary new];
    [dict setObject:@"ios" forKey:@"devType"];
    [dict setObject:[APPData sharedInstance].deviceToken forKey:@"token"];
    
    NSMutableArray *accountDatas = [NSMutableArray new];
    for (CwAccount *account in [self.card.cwAccounts allValues]) {
        [accountDatas addObject:[self getAccountInfo:account]];
    }
    [dict setObject:accountDatas forKey:@"accounts"];
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager POST:url parameters:dict success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            [subscriber sendNext:responseObject];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal*)signalSyncAccountInfo:(CwAccount *)account {
    __block NSString *url = [NSString stringWithFormat:ExSyncAccountInfo, self.card.cardId, (long)account.accId];
    
    __block NSDictionary *dict = [self getAccountInfo:account];
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager POST:url parameters:dict success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            [subscriber sendNext:responseObject];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalRequestOrderBlockWithOrderID:(NSString *)hexOrder withOTP:(NSString *)otp
{
    __block NSString *url = [NSString stringWithFormat:ExRequestOrderBlock, hexOrder, otp];
    
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            
            NSString *blockData = [responseObject objectForKey:@"block_btc"];
            [subscriber sendNext:blockData];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalBlockBTCFromCard:(NSString *)blockData
{
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        [self.card exBlockBtc:blockData withComplete:^(NSData *okToken, NSData *unblockToken) {
            NSDictionary *data = @{
                                   @"okToken": [NSString dataToHexstring:okToken],
                                   @"unblockToken": [NSString dataToHexstring:unblockToken],
                                   };
            [subscriber sendNext:data];
            [subscriber sendCompleted];
        } error:^(NSInteger errorCode) {
            [subscriber sendError:[self cardCmdError:errorCode errorMsg:NSLocalizedString(@"Block fail.",nil)]];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalWriteOKTokenToServer:(NSString *)okToken unblockToken:(NSString *)unblockToken withOrder:(NSString *)orderId
{
    __block NSString *url = [NSString stringWithFormat:ExWriteOKToken, orderId];
    __block NSDictionary *dict = @{
                           @"okToken": okToken,
                           @"unblockToken": unblockToken,
                           };
    
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager POST:url parameters:dict success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            [subscriber sendNext:nil];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalTrxLogin:(NSString *)logingData
{
    @weakify(self)
    RACSignal *signal = [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        NSData *okToken = [NSString hexstringToData:[logingData substringWithRange:NSMakeRange(8, 8)]];
        NSData *accountData = [NSString hexstringToData:[logingData substringWithRange:NSMakeRange(48, 8)]];
        NSInteger accId = *(int32_t *)[accountData bytes];
        
        [self.card exBlockInfo:okToken withComplete:^(NSNumber *blockAmount) {
            CwAccount *account = [self.card.cwAccounts objectForKey:[NSString stringWithFormat:@"%ld", accId]];
            account.tempUnblockAmount = blockAmount.longLongValue;
            
            [subscriber sendNext:logingData];
            [subscriber sendCompleted];
        } withError:^(NSInteger errorCode) {
            [subscriber sendError:[self cardCmdError:errorCode errorMsg:NSLocalizedString(@"Get block info fail.",nil)]];
        }];
        
        return nil;
    }] flattenMap:^RACStream *(NSString *loginHexData) {
        RACSignal *loginSignal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
            @strongify(self);
            [self.card exTrxSignLogin:loginHexData withComplete:^(NSData *loginHandle) {
                [subscriber sendNext:loginHandle];
                [subscriber sendCompleted];
            } error:^(NSInteger errorCode) {
                [subscriber sendError:[self cardCmdError:errorCode errorMsg:NSLocalizedString(@"Transaction login fail.",nil)]];
            }];
            
            return nil;
        }];
        
        return loginSignal;
    }];
    
    return signal;
}

-(RACSignal*)signalGetTrxInfoFromOrder:(NSString *)orderId
{
    __block NSString *url = [NSString stringWithFormat:ExGetTrxInfo, orderId];
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            [subscriber sendNext:responseObject];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalTrxPrepareDataFrom:(CwTx *)unsignedTx andExTx:(CwExTx *)exTx
{
    __block NSString *url = ExGetTrxPrepareBlocks;
    
    NSMutableArray *inputBlocks = [NSMutableArray new];
    for (int index=0; index < unsignedTx.inputs.count; index++) {
        CwTxin *txin = unsignedTx.inputs[index];
        NSData *inputData = [self composePrepareInputData:index KeyChainId:txin.kcId AccountId:txin.accId KeyId:txin.kId receiveAddress:exTx.receiveAddress changeAddress:exTx.changeAddress SignatureMateiral:txin.hashForSign];
        [inputBlocks addObject:@{@"idx": @(index), @"blk": [NSString dataToHexstring:inputData]}];
    }
    __block NSDictionary *dict = @{@"blks": inputBlocks};
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager POST:url parameters:dict success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            NSArray *blocks = [responseObject objectForKey:@"blks"];
            for (NSDictionary *blockData in blocks) {
                NSInteger index = (NSInteger)[blockData objectForKey:@"idx"];
                NSString *block = [blockData objectForKey:@"blk"];
                NSMutableData *inputData = [NSMutableData dataWithData:exTx.loginHandle];
                [inputData appendData:[NSString hexstringToData:block]];
                
                [self.card exTrxSignPrepareWithInputId:index withInputData:inputData];
            }
            
            [subscriber sendNext:responseObject];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalRequestUnblockInfoWithOrderId:(NSString *)orderId
{
    __block NSString *url = ExUnblockOrders;
    if (orderId != nil) {
        url = [url stringByAppendingFormat:@"/%@", orderId];
    }
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, id responseObject) {
            if ([responseObject isKindOfClass:[NSArray class]]) {
                NSArray *unblockOrders = [RMMapper arrayOfClass:[CwExUnblock class] fromArrayOfDictionary:responseObject];
                
                [subscriber sendNext:unblockOrders];
                [subscriber sendCompleted];
            } else if ([responseObject isKindOfClass:[NSDictionary class]]) {
                CwExUnblock *unblock = [RMMapper objectWithClass:[CwExUnblock class] fromDictionary:responseObject];
                if (unblock.orderID == nil) {
                    unblock.orderID = [NSString hexstringToData:orderId];
                }
                
                [subscriber sendNext:unblock];
                [subscriber sendCompleted];
            } else {
                NSError *error = [NSError errorWithDomain:NSLocalizedString(@"Exchange Site Error.",nil) code:1003 userInfo:@{@"error": NSLocalizedString(@"Can't recognize unblock info.",nil)}];
                [subscriber sendError:error];
            }
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalUnblock:(CwExUnblock *)unblock
{
    @weakify(self);
    RACSignal *signal = [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        [self.card exBlockCancel:unblock.orderID OkTkn:unblock.okToken EncUblkTkn:unblock.unblockToken Mac1:unblock.mac Nonce:unblock.nonce withComplete:^() {
            [subscriber sendNext:nil];
            [subscriber sendCompleted];
        } withError:^(NSInteger errorCode) {
            NSError *error = [self cardCmdError:errorCode errorMsg:NSLocalizedString(@"CoolWallet card unblock fail.",nil)];
            [subscriber sendError:error];
        }];
        
        return nil;
    }] flattenMap:^RACStream *(id value) {
        return [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
            @strongify(self);
            
            NSString *url = [ExUnblockOrders stringByAppendingFormat:@"/%@", [NSString dataToHexstring:unblock.orderID]];
            
            AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
            [manager DELETE:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
                [subscriber sendNext:nil];
                [subscriber sendCompleted];
            } failure:^(AFHTTPRequestOperation *operation, NSError *error){
                [subscriber sendError:error];
            }];
            
            return nil;
        }];
    }];
        
    return signal;
}

-(RACSignal *)signalGetOpenOrderCount
{
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager GET:ExOpenOrderCount parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            NSNumber *count = [responseObject objectForKey:@"open"];
            
            [subscriber sendNext:count];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalCancelOrders:(NSString *)orderId
{
    __block NSString *url = [NSString stringWithFormat:ExCancelOrder, orderId];
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSDictionary *responseObject) {
            [subscriber sendNext:nil];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(RACSignal *)signalRequestUnclarifyOrders
{
    __block NSString *url = [NSString stringWithFormat:ExUnclarifyOrders, self.card.cardId];
    
    @weakify(self);
    RACSignal *signal = [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
        @strongify(self);
        
        AFHTTPRequestOperationManager *manager = [self defaultJsonManager];
        [manager GET:url parameters:nil success:^(AFHTTPRequestOperation *operation, NSArray *responseObject) {
            NSArray *unclarifyOrders = [RMMapper arrayOfClass:[CwExUnclarifyOrder class] fromArrayOfDictionary:responseObject];
            
            [subscriber sendNext:unclarifyOrders];
            [subscriber sendCompleted];
        } failure:^(AFHTTPRequestOperation *operation, NSError *error){
            [subscriber sendError:error];
        }];
        
        return nil;
    }];
    
    return signal;
}

-(NSData *) composePrepareInputData:(NSInteger)inputId KeyChainId:(NSInteger)keyChainId AccountId:(NSInteger)accountId KeyId:(NSInteger)keyId receiveAddress:(NSString *)receiveAddress changeAddress:(NSString *)changeAddress SignatureMateiral:(NSData *)signatureMaterial
{
    NSData *out1Address = [CwBase58 base58ToData:receiveAddress];
    NSData *out2Address = [CwBase58 base58ToData:changeAddress];
    
    NSMutableData *inputData = [[NSMutableData alloc] init];
    [inputData appendBytes:&accountId length:4];
    [inputData appendBytes:&keyChainId length:1];
    [inputData appendBytes: &keyId length: 4];
    [inputData appendBytes:[out1Address bytes] length:25];
    [inputData appendBytes:[out2Address bytes] length:25];
    [inputData appendBytes:[signatureMaterial bytes] length:32];
    
    return inputData;
}

-(NSError *) cardCmdError:(NSInteger)errorCode errorMsg:(NSString *)errorMsg
{
    NSError *error = [NSError errorWithDomain:NSLocalizedString(@"Card Cmd Error",nil) code:errorCode userInfo:@{@"error": errorMsg}];
    
    return error;
}

-(NSDictionary *) getAccountInfo:(CwAccount *)account
{
    NSNumber *accId = [NSNumber numberWithInteger:account.accId];
    NSNumber *extKeyPointer = [NSNumber numberWithInteger:account.extKeyPointer];
    NSNumber *intKeyPointer = [NSNumber numberWithInteger:account.intKeyPointer];
    
    NSDictionary *data = @{
                           @"id": accId,
                           @"extn": @{
                                   @"num": extKeyPointer,
                                   @"pub": account.externalKeychain.hexPublicKey == nil ? @"" : account.externalKeychain.hexPublicKey,
                                   @"chaincode": account.externalKeychain.hexChainCode == nil ? @"" : account.externalKeychain.hexChainCode
                                   },
                           @"intn": @{
                                   @"num": intKeyPointer,
                                   @"pub": account.internalKeychain.hexPublicKey == nil ? @"" : account.internalKeychain.hexPublicKey,
                                   @"chaincode": account.internalKeychain.hexChainCode == nil ? @"" : account.internalKeychain.hexChainCode
                                   }
                           };
    return data;
}

-(AFHTTPRequestOperationManager *) defaultJsonManager
{
    AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
    manager.responseSerializer = [AFJSONResponseSerializer serializer];
    manager.requestSerializer=[AFJSONRequestSerializer serializer];
    if (self.loginSession != nil) {
        [manager.requestSerializer setValue:self.loginSession forHTTPHeaderField:@"Set-Cookie"];
    }
    
    return manager;
}

- (void)dealloc
{
    // implement -dealloc & remove abort() when refactoring for
    // non-singleton use.
    abort();
}

@end
