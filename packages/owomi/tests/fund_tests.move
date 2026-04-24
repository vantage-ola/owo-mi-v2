#[test_only]
module owomi::fund_tests;

use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario;

use std::unit_test;

use owomi::fund;
use owomi::fund::EInsufficientFunds;
use owomi::fund::EUnknownCoinType;
use owomi::fund::EFundCapMismatch;
use owomi::fund::EUnauthorized;


/// Test: Create a new Fund and verify initial state
#[test]
fun test_fund_new() {
    // - Create a new Fund
    let ctx = &mut sui::tx_context::dummy();
    let fund = fund::new(ctx);

    assert!(fund.authorized_caps_length() == 0, 0);
    assert!(fund.balance<SUI>() == 0 , 1);

    unit_test::destroy(fund);
}

/// Test: Share a Fund and verify it's accessible
#[test]
fun test_fund_share() {

    let ctx = &mut sui::tx_context::dummy();
    let fund = fund::new(ctx);
    
    fund::share(fund);
}

/// Test: Deposit coins into a Fund
#[test]
fun test_fund_deposit() {
    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);
    
    let coin = coin::mint_for_testing<SUI>(100, ctx);
    fund::deposit(&mut fund, coin);
    
    let balance = fund.balance<SUI>();

    assert!(balance == 100, 0);
    unit_test::destroy(fund);

}

/// Test: Deposit multiple coin types into a Fund
#[test]
fun test_fund_deposit_multiple_types() {

    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);
    
    let sui = coin::mint_for_testing<SUI>(100, ctx);
    let usdc = mint_fake_usdc(99, ctx);
    let usdt = mint_fake_usdt(98, ctx);

    // - Deposit another coin type (if available)
    fund::deposit(&mut fund, sui);
    fund::deposit(&mut fund, usdc);
    fund::deposit(&mut fund, usdt);

    // - Verify both balances are tracked separately
    assert!(fund::balance<SUI>(&fund) == 100, 0);
    assert!(fund::balance<FAKE_USDC>(&fund) == 99, 1);
    assert!(fund::balance<FAKE_USDT>(&fund) == 98, 2);
    

    unit_test::destroy(fund);
}

/// Test: Deposit same coin type multiple times
#[test]
fun test_fund_deposit_same_type_twice() {
    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);
    
    let sui = coin::mint_for_testing<SUI>(50, ctx);
    let sui2 = coin::mint_for_testing<SUI>(50, ctx);

    fund::deposit(&mut fund, sui);
    fund::deposit(&mut fund, sui2);

    // - Verify balance is sum of both deposits
    assert!(fund::balance<SUI>(&fund) == 100, 0);

    unit_test::destroy(fund);
}

/// Test: Create an authorized FundCap
#[test]
fun test_fund_new_authorized_cap() {

    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let cap_id = fund::cap_id(&cap);

    let index = fund::authorized_cap_index(&fund, cap_id);
    
    assert!(index == option::some(0), 0);     // expect index 0.
    assert!(fund::authorized_caps_length(&fund) == 1, 1);

    unit_test::destroy(cap);
    unit_test::destroy(fund);

}

/// Test: Transfer FundCap to another address
#[test]
fun test_fund_transfer_cap() {
 
    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let sui = coin::mint_for_testing<SUI>(50, ctx);
    fund::deposit(&mut fund, sui);

    let withdrawn_coin = fund::withdraw<SUI>(&mut fund, &cap, 1, ctx);

    assert!(fund::balance<SUI>(&fund) == 49, 0);
    assert!(coin::value(&withdrawn_coin) == 1, 1);

    unit_test::destroy(withdrawn_coin);
    unit_test::destroy(cap);
    unit_test::destroy(fund);
}

/// Test: Withdraw coins with a valid FundCap
#[test]
fun test_fund_withdraw() {

    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let sui = coin::mint_for_testing<SUI>(50, ctx);
    fund::deposit(&mut fund, sui);

    let withdrawn_coin = fund::withdraw<SUI>(&mut fund, &cap, 1, ctx);

    assert!(fund::balance<SUI>(&fund) == 49, 0);
    assert!(coin::value(&withdrawn_coin) == 1, 1);

    unit_test::destroy(withdrawn_coin);
    unit_test::destroy(cap);
    unit_test::destroy(fund);
}

/// Test: Withdraw fails with wrong FundCap
#[test]
#[expected_failure(abort_code=EFundCapMismatch)]
fun test_fund_withdraw_wrong_cap() {

    let ctx = &mut sui::tx_context::dummy();
    let mut fund1 = fund::new(ctx);
    let mut fund2 = fund::new(ctx);

    let coin = coin::mint_for_testing<SUI>(1000, ctx);
    fund::deposit(&mut fund1, coin);

    let cap = fund::new_authorized_cap(&mut fund2, ctx);
    
    // it should fail here, wrong fund cap
    let withdrawn = fund::withdraw<SUI>(&mut fund1, &cap, 500, ctx);
    
    coin::destroy_zero(withdrawn);

    unit_test::destroy(cap);
    unit_test::destroy(fund1);
    unit_test::destroy(fund2);

}

/// Test: Withdraw fails with unauthorized cap
#[test]
#[expected_failure(abort_code=EFundCapMismatch)]
fun test_fund_withdraw_unauthorized_cap() {

    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let sui = coin::mint_for_testing<SUI>(50, ctx);
    let cap_id = fund::cap_id(&cap);

    fund::deposit(&mut fund, sui);
    fund::revoke_cap(&mut fund, cap_id, ctx);

    // this will fail
    let withdraw_coin = fund::withdraw<SUI>(&mut fund, &cap, 50, ctx);
    
    unit_test::destroy(withdraw_coin);
    unit_test::destroy(cap);
    unit_test::destroy(fund);

}

/// Test: Withdraw fails with insufficient balance
#[test]
#[expected_failure(abort_code=EInsufficientFunds)]
fun test_fund_withdraw_insufficient_balance() {

    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let sui = coin::mint_for_testing<SUI>(50, ctx);

    fund::deposit(&mut fund, sui);

    // this will fail
    let withdraw = fund::withdraw<SUI>(&mut fund, &cap, 51, ctx);

    coin::destroy_zero(withdraw);

    unit_test::destroy(cap);
    unit_test::destroy(fund);

}

/// Test: Withdraw fails with unknown coin type
#[test]
#[expected_failure(abort_code=EUnknownCoinType)]
fun test_fund_withdraw_unknown_coin_type() {
    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let sui = coin::mint_for_testing<SUI>(50, ctx);

    fund::deposit(&mut fund, sui);

    // this will fail
    let withdraw = fund::withdraw<FAKE_USDC>(&mut fund, &cap, 51, ctx);

    coin::destroy_zero(withdraw);

    unit_test::destroy(cap);
    unit_test::destroy(fund);

}

/// Test: Revoke a FundCap
#[test]
fun test_fund_revoke_cap() {
    // TODO: Implement test
    // - Create Fund and authorized cap
    // - Revoke the cap
    // - Verify cap is removed from authorized_caps
    // - Verify cap no longer works for withdrawal

    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let cap_id = fund::cap_id(&cap);

    fund::revoke_cap(&mut fund, cap_id, ctx);

    assert!(fund::authorized_cap_index(&fund, cap_id) == option::none(), 0);

    unit_test::destroy(cap);
    unit_test::destroy(fund);
}

/// Test: Delete a FundCap
#[test]
fun test_fund_delete_cap() {
    // TODO: Implement test
    // - Create Fund and authorized cap
    // - Delete the cap
    // - Verify cap is removed from authorized_caps
    // - Verify cap object is destroyed
    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let cap = fund::new_authorized_cap(&mut fund, ctx);
    let cap_id = fund::cap_id(&cap);


    fund::delete_cap(&mut fund, cap);
    
    assert!(fund::authorized_cap_index(&fund, cap_id) == option::none(), 0);

    unit_test::destroy(fund);
}

/// Test: Only owner can create authorized caps
#[test]
#[expected_failure(abort_code=EUnauthorized)]
fun test_fund_only_owner_can_create_cap() {
    let owner = @0xA;
    let non_owner = @0xB;

    let mut scenario = test_scenario::begin(owner);
    {
        let fund = fund::new(scenario.ctx());
        fund::share(fund);
    };
    scenario.next_tx(non_owner); // use scenario to mock different sender
    {
        let mut fund = scenario.take_shared<fund::Fund>();
        let cap = fund::new_authorized_cap(&mut fund, scenario.ctx()); // aborts here ✅
        fund::transfer_cap(cap, non_owner);
        test_scenario::return_shared(fund);
    };
    scenario.end();

}

/// Test: Read balance function
#[test]
fun test_fund_balance() {
    // TODO: Implement test
    // - Create Fund and deposit coins
    // - Call balance<T>() function
    // - Verify it returns correct amount
    let ctx = &mut sui::tx_context::dummy();
    let mut fund = fund::new(ctx);

    let coin = coin::mint_for_testing<SUI>(100, ctx);

    fund::deposit<SUI>(&mut fund, coin);
    let balance = fund::balance<SUI>(&fund);
    assert!(balance == 100, 0);

    // fund::share(fund); resolve the fund object or destroy below with unittest::destroy
    unit_test::destroy(fund);

}


// ============================================================
// HELPER FUNCTIONS 
// ============================================================

public struct FAKE_USDT has drop {}
public struct FAKE_USDC has drop {}

#[test_only]
fun mint_fake_usdt(amount: u64, ctx: &mut TxContext): Coin<FAKE_USDT> {
    coin::mint_for_testing<FAKE_USDT>(amount, ctx)
}
#[test_only]
public fun mint_fake_usdc(amount: u64, ctx: &mut TxContext): Coin<FAKE_USDC> {
    coin::mint_for_testing<FAKE_USDC>(amount, ctx)
}