//
//  UIViewController+TabTransactionDetailViewController.h
//  CoolWallet
//
//  Created by bryanLin on 2015/7/8.
//  Copyright (c) 2015年 MAC-BRYAN. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "CwManager.h"
#import "CwCard.h"
#import "BaseViewController.h"

@class CwTx;

@interface TabTransactionDetailViewController :BaseViewController

@property (strong, nonatomic) CwTx *tx;

@property (weak, nonatomic) IBOutlet UILabel *lblTxAddr;
@property (weak, nonatomic) IBOutlet UILabel *lblTxAmount;
@property (weak, nonatomic) IBOutlet UILabel *lblTxFiatMoney;
@property (weak, nonatomic) IBOutlet UILabel *lblTxDate;
@property (weak, nonatomic) IBOutlet UILabel *lblTxConfirm;
@property (weak, nonatomic) IBOutlet UILabel *lblTxId;
@property (weak, nonatomic) IBOutlet UILabel *lblTxType;
- (IBAction)btnBlockchain:(id)sender;

@end
