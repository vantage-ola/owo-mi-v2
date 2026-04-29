#[test_only]
module owomi::saving_tests;


use sui::clock;
use sui::sui::SUI;
use sui::coin;
use sui::test_scenario::{Self as ts};

use std::unit_test::destroy;
use std::string::utf8;

use owomi::saving::{Self, Saving, SavingCap};
use owomi::fund;

// testing different style of writing tests apart from fund

const OWNER: address = @0xA;
const NON_OWNER: address = @0xB;

const ONE_HOUR_MS: u64 = 3_600_000;
const ONE_DAY_MS:  u64 = 86_400_000;


// helpers

fun dummy_clock(ctx: &mut sui::tx_context::TxContext): clock::Clock{
    clock::create_for_testing(ctx)
}

fun make_saving(clock: &clock::Clock, ctx: &mut sui::tx_context::TxContext): (Saving<SUI>, SavingCap) {
    
    let (saving, cap) = saving::new<SUI>(
        utf8(b"saving test"),
        utf8(b"my saving test"),
        option::none(),
        clock,
        ctx
    );
    (saving, cap)
}

/// Test: Create a new Saving without a target
#[test]
fun test_saving_new_without_target() {
    
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 
    let (saving, cap) = make_saving(&clock, ctx);

    assert!(saving::balance_value<SUI>(&saving) == 0, 0); //empty balance
    assert!(saving::authorized_caps_length(&saving) == 1, 1); // new() creates an initial cap , length should be 1

    clock::destroy_for_testing(clock);
    destroy(cap);
    destroy(saving);

}


/// Test: Create a new Saving with a valid target
#[test]
fun test_saving_new_with_target() {
    let ctx = &mut sui::tx_context::dummy();
    let mut clock = dummy_clock(ctx);

    clock::set_for_testing(&mut clock, ONE_DAY_MS);

    let target = saving::new_saving_target(ONE_DAY_MS + ONE_HOUR_MS, 100);

    let (saving, cap) = {
        let (s, c) = saving::new<SUI>(
            utf8(b"Goal Saving"),
            utf8(b"With target"),
            option::some(target),
            &clock,
            ctx
        );
        (s, c)
    };

    clock::destroy_for_testing(clock);
    destroy(cap);
    destroy(saving);
}

/// Test: Create Saving fails with past date target
#[test]
#[expected_failure(abort_code = saving::EInvalidSavingTarget)]
fun test_saving_new_target_past_date() {
    let ctx = &mut sui::tx_context::dummy();
    let mut clock = dummy_clock(ctx);
    clock::set_for_testing(&mut clock, ONE_DAY_MS); 

    let target = saving::new_saving_target(
        ONE_HOUR_MS, // ONE_HOUR_MS < ONE_DAY_MS — this is in the past
        100
    );

    let (saving, cap) = saving::new<SUI>(
        utf8(b"Bad Saving"),
        utf8(b"Past date"),
        option::some(target),
        &clock,
        ctx
    );

    clock::destroy_for_testing(clock);
    destroy(cap);
    destroy(saving);
}

/// Test: Create Saving fails with zero amount target
#[test]
#[expected_failure(abort_code = saving::EInvalidSavingTarget)]
fun test_saving_new_target_zero_amount() {
    let ctx = &mut sui::tx_context::dummy();
    let mut clock = dummy_clock(ctx);
    clock::set_for_testing(&mut clock, ONE_DAY_MS);

    let target = saving::new_saving_target(
        ONE_DAY_MS + ONE_HOUR_MS,
        0 // zero amount
    );

    let (saving, cap) = saving::new<SUI>(
        utf8(b"Bad Saving"),
        utf8(b"Zero amount"),
        option::some(target),
        &clock,
        ctx
    );

    clock::destroy_for_testing(clock);
    destroy(cap);
    destroy(saving);
}

/// Test: Share a Saving and verify it's accessible
#[test]
fun test_saving_share() {
    let mut scenario = ts::begin(OWNER);
    {
        let clock = dummy_clock(scenario.ctx());
        let (saving, cap) = saving::new<SUI>(
            utf8(b"Shared Saving"),
            utf8(b"desc"),
            option::none(),
            &clock,
            scenario.ctx()
        );
        saving::share(saving);
        saving::transfer_cap(cap, OWNER);
        clock::destroy_for_testing(clock);
    };
    scenario.next_tx(OWNER);
    {
        // verify the shared saving is accessible
        let saving = scenario.take_shared<Saving<SUI>>();
        assert!(saving::balance_value<SUI>(&saving) == 0, 0);
        ts::return_shared(saving);
    };
    scenario.end();
}

/// Test: Create authorized SavingCap
#[test]
fun test_saving_new_authorized_cap() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let (mut saving, initial_cap) = make_saving(&clock, ctx);

    let extra_cap = saving::new_authorized_cap(&mut saving, ctx);

    // initial cap + new cap = 2
    assert!(saving::authorized_caps_length(&saving) == 2, 0);

    destroy(clock);
    destroy(extra_cap);
    destroy(initial_cap);
    destroy(saving);
}

/// Test: Transfer SavingCap to another address
#[test]
fun test_saving_transfer_cap() {
    let mut scenario = ts::begin(OWNER);
    {
        let clock = dummy_clock(scenario.ctx());
        let (saving, cap) = saving::new<SUI>(
            utf8(b"Transfer Test"),
            utf8(b"desc"),
            option::none(),
            &clock,
            scenario.ctx()
        );
        saving::share(saving);
        saving::transfer_cap(cap, NON_OWNER); // hand cap to non-owner
        clock::destroy_for_testing(clock);
    };
    scenario.next_tx(NON_OWNER);
    {
        //  non-owner can still deposit with a transferred cap
        let mut saving = scenario.take_shared<Saving<SUI>>();
        let cap = scenario.take_from_sender<SavingCap>();
        let coin = coin::mint_for_testing<SUI>(50, scenario.ctx());

        saving::deposit(&mut saving, &cap, coin);
        assert!(saving::balance_value<SUI>(&saving) == 50, 0);

        ts::return_to_sender(&scenario, cap);
        ts::return_shared(saving);
    };
    scenario.end();
}
/// Test: Deposit coins into a Saving
#[test]
fun test_saving_deposit() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 
    let (mut saving, cap) = make_saving(&clock, ctx);

    let coin = coin::mint_for_testing<SUI>(100, ctx);
    saving::deposit(&mut saving, &cap, coin);

    assert!(saving::balance_value<SUI>(&saving) == 100, 0);

    clock::destroy_for_testing(clock);
    destroy(cap);
    destroy(saving);

}

/// Test: Deposit fails with wrong SavingCap
#[test]
#[expected_failure(abort_code = saving::ESavingCapMismatch)]
fun test_saving_deposit_wrong_cap() {
    let ctx = &mut sui::tx_context::dummy();

    let clock = dummy_clock(ctx);
    let (mut saving_a, cap_a) = make_saving(&clock, ctx);
    let (saving_b, cap_b) = make_saving(&clock, ctx);

    let coin = coin::mint_for_testing<SUI>(50, ctx);

    // cap_b does not belong to saving_a... must fail
    saving::deposit(&mut saving_a, &cap_b, coin); 

    clock::destroy_for_testing(clock);
    destroy(cap_a);
    destroy(cap_b);
    destroy(saving_a);
    destroy(saving_b);
}
/// Test: Deposit fails with unauthorized cap
#[test]
#[expected_failure(abort_code = saving::EUnknownAuthorizedCap)]
fun test_saving_deposit_unauthorized_cap() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let (mut saving, cap) = make_saving(&clock, ctx);

    let cap_id = saving::cap_id(&cap);
    saving::revoke_cap(&mut saving, cap_id, ctx); // cap still exists but de-authorized

    let coin = coin::mint_for_testing<SUI>(50, ctx);
    saving::deposit(&mut saving, &cap, coin); // it fails here 

    clock::destroy_for_testing(clock);
    destroy(cap);
    destroy(saving);
}


/// Test: Deposit fails with zero amount
#[test]
#[expected_failure(abort_code = saving::EInvalidDepositAmount)]
fun test_saving_deposit_zero_amount() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let (mut saving, cap) = make_saving(&clock, ctx);

    let zero_coin = coin::mint_for_testing<SUI>(0, ctx);
    saving::deposit(&mut saving, &cap, zero_coin);

    clock::destroy_for_testing(clock);
    destroy(cap);
    destroy(saving);
}

/// Test: Withdraw from Saving without target
#[test]
fun test_saving_withdraw_without_target() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let (mut saving, cap) = make_saving(&clock, ctx);

    saving::deposit(&mut saving, &cap, coin::mint_for_testing<SUI>(100, ctx));
    let withdrawn = saving::withdraw<SUI>(&mut saving, &cap, option::some(40), &clock, ctx);

    assert!(saving::balance_value<SUI>(&saving) == 60, 0);
    assert!(coin::value(&withdrawn) == 40, 1);

    clock::destroy_for_testing(clock);
    destroy(withdrawn);
    destroy(cap);
    destroy(saving);
}

/// Test: Withdraw from Saving with target after reaching goal
#[test]
fun test_saving_withdraw_after_target_reached() {
    let ctx = &mut sui::tx_context::dummy();
    let mut clock = dummy_clock(ctx);
    clock::set_for_testing(&mut clock, ONE_DAY_MS);

    let target = saving::new_saving_target(ONE_DAY_MS + ONE_HOUR_MS, 50);
    let (mut saving, cap) = saving::new<SUI>(
        utf8(b"Goal"),
        utf8(b"desc"),
        option::some(target),
        &clock,
        ctx
    );

    saving::deposit(&mut saving, &cap, coin::mint_for_testing<SUI>(100, ctx));

    // advance clock past target date
    clock::set_for_testing(&mut clock, ONE_DAY_MS + ONE_HOUR_MS + 1);

    let withdrawn = saving::withdraw<SUI>(&mut saving, &cap, option::some(50), &clock, ctx);
    assert!(coin::value(&withdrawn) == 50, 0);

    clock::destroy_for_testing(clock);
    destroy(withdrawn);
    destroy(cap);
    destroy(saving);
}

/// Test: Withdraw fails before target date
#[test]
#[expected_failure(abort_code = saving::EInvalidSavingTarget)]
fun test_saving_withdraw_before_target_date() {
  let ctx = &mut sui::tx_context::dummy();
    let mut clock = dummy_clock(ctx);
    clock::set_for_testing(&mut clock, ONE_DAY_MS);

    let target = saving::new_saving_target(ONE_DAY_MS + ONE_HOUR_MS, 100);
    let (mut saving, cap) = saving::new<SUI>(
        utf8(b"Goal"),
        utf8(b"desc"),
        option::some(target),
        &clock,
        ctx
    );

    // 40, below the target amount of 100
    saving::deposit(&mut saving, &cap, coin::mint_for_testing<SUI>(40, ctx));

    // advance past target date — but balance is still too low
    clock::set_for_testing(&mut clock, ONE_DAY_MS + ONE_HOUR_MS + 1);

    let withdrawn = saving::withdraw<SUI>(&mut saving, &cap, option::some(40), &clock, ctx);

    clock::destroy_for_testing(clock);
    destroy(withdrawn);
    destroy(cap);
    destroy(saving);
}

/// Test: Withdraw fails when balance below target amount
#[test]
#[expected_failure(abort_code = saving::EInvalidSavingTarget)]
fun test_saving_withdraw_below_target_amount() {
    let ctx = &mut sui::tx_context::dummy();
    let mut clock = dummy_clock(ctx);
    clock::set_for_testing(&mut clock, ONE_DAY_MS);

    let target = saving::new_saving_target(ONE_DAY_MS + ONE_HOUR_MS, 100);
    let (mut saving, cap) = saving::new<SUI>(
        utf8(b"Goal"),
        utf8(b"desc"),
        option::some(target),
        &clock,
        ctx
    );

    // 40, below the target amount of 100
    saving::deposit(&mut saving, &cap, coin::mint_for_testing<SUI>(40, ctx));

    // advance past target date — but balance is still too low
    clock::set_for_testing(&mut clock, ONE_DAY_MS + ONE_HOUR_MS + 1);

    let withdrawn = saving::withdraw<SUI>(&mut saving, &cap, option::some(40), &clock, ctx);

    clock::destroy_for_testing(clock);
    destroy(withdrawn);
    destroy(cap);
    destroy(saving);
}


/// Test: Withdraw specific amount
#[test]
fun test_saving_withdraw_specific_amount() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let (mut saving, cap) = make_saving(&clock, ctx);

    saving::deposit(&mut saving, &cap, coin::mint_for_testing<SUI>(200, ctx));
    let withdrawn = saving::withdraw<SUI>(&mut saving, &cap, option::some(75), &clock, ctx);

    assert!(coin::value(&withdrawn) == 75, 0);
    assert!(saving::balance_value<SUI>(&saving) == 125, 1);

    clock::destroy_for_testing(clock);
    destroy(withdrawn);
    destroy(cap);
    destroy(saving);
}

/// Test: Withdraw all (Option::none)
#[test]
fun test_saving_withdraw_all() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let (mut saving, cap) = make_saving(&clock, ctx);

    saving::deposit(&mut saving, &cap, coin::mint_for_testing<SUI>(150, ctx));
    let withdrawn = saving::withdraw<SUI>(&mut saving, &cap, option::none(), &clock, ctx);

    assert!(coin::value(&withdrawn) == 150, 0);
    assert!(saving::balance_value<SUI>(&saving) == 0, 1);

    clock::destroy_for_testing(clock);
    destroy(withdrawn);
    destroy(cap);
    destroy(saving);
}

/// Test: Withdraw fails with insufficient balance
#[test]
#[expected_failure(abort_code = saving::EInSufficientSavingBalance)]
fun test_saving_withdraw_insufficient_balance() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 
    let (mut saving, cap) = make_saving(&clock, ctx);

    saving::deposit(&mut saving, &cap, coin::mint_for_testing<SUI>(10, ctx));
    let withdrawn = saving::withdraw<SUI>(&mut saving, &cap, option::some(999), &clock, ctx);

    clock::destroy_for_testing(clock);
    destroy(withdrawn);
    destroy(cap);
    destroy(saving);
}

/// Test: Revoke a SavingCap
#[test]
fun test_saving_revoke_cap() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 
    let (mut saving, cap) = make_saving(&clock, ctx);

    let cap_id = saving::cap_id(&cap);
    saving::revoke_cap(&mut saving, cap_id, ctx);

    assert!(saving::authorized_caps_length(&saving) == 0, 0);

    clock::destroy_for_testing(clock);
    destroy(cap); // cap object still exists, just de-authorized
    destroy(saving);
}


/// Test: Delete a SavingCap
#[test]
fun test_saving_delete_cap() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let (mut saving, cap) = make_saving(&clock, ctx);

    saving::delete_cap(&mut saving, cap); // cap object is consumed and destroyed

    assert!(saving::authorized_caps_length(&saving) == 0, 0);

    clock::destroy_for_testing(clock);
    destroy(saving);
}


/// Test: Only owner can create authorized caps
#[test]
#[expected_failure(abort_code = saving::EInvalidSavingAuthorization)]
fun test_saving_only_owner_can_create_cap() {
    let mut scenario = ts::begin(OWNER);
    {
        let clock = dummy_clock(scenario.ctx());
        let (saving, cap) = saving::new<SUI>(
            utf8(b"Owner Saving"),
            utf8(b"desc"),
            option::none(),
            &clock,
            scenario.ctx()
        );
        saving::share(saving);
        saving::transfer_cap(cap, OWNER);
        clock::destroy_for_testing(clock);
    };
    scenario.next_tx(NON_OWNER); // genuinely different sender
    {
        let mut saving = scenario.take_shared<Saving<SUI>>();
        // NON_OWNER is not the owner — must abort
        let cap = saving::new_authorized_cap(&mut saving, scenario.ctx());
        saving::transfer_cap(cap, NON_OWNER);
        ts::return_shared(saving);
    };
    scenario.end();
}

// ============================================================
// FUND-SAVING INTEGRATION TESTS
// ============================================================

/// Test: Deposit from Fund to Saving
#[test]
fun test_deposit_from_fund() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    // Set up fund
    let mut f = fund::new(ctx);
    let fund_cap = fund::new_authorized_cap(&mut f, ctx);
    fund::deposit(&mut f, coin::mint_for_testing<SUI>(200, ctx));

    // Set up saving
    let (mut saving, saving_cap) = make_saving(&clock, ctx);

    saving::deposit_from_fund<SUI>(&mut saving, &mut f, &saving_cap, &fund_cap, 80, ctx);

    assert!(fund::balance<SUI>(&f) == 120, 0);
    assert!(saving::balance_value<SUI>(&saving) == 80, 1);

    clock::destroy_for_testing(clock);
    destroy(fund_cap);
    destroy(saving_cap);
    destroy(saving);
    destroy(f);
}
/// Test: Withdraw from Saving to Fund
#[test]
fun test_withdraw_to_fund() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let mut f = fund::new(ctx);
    let (mut saving, saving_cap) = make_saving(&clock, ctx);

    saving::deposit(&mut saving, &saving_cap, coin::mint_for_testing<SUI>(150, ctx));
    saving::withdraw_to_fund<SUI>(&mut saving, &mut f, &saving_cap, option::some(100), &clock, ctx);

    assert!(saving::balance_value<SUI>(&saving) == 50, 0);
    assert!(fund::balance<SUI>(&f) == 100, 1);

    destroy(clock);
    destroy(saving_cap);
    destroy(saving);
    destroy(f);
}

/// Test: Round trip - Fund -> Saving -> Fund
#[test]
fun test_fund_saving_round_trip() {
    let ctx = &mut sui::tx_context::dummy();
    let clock = clock::create_for_testing(ctx); 

    let mut f = fund::new(ctx);
    let fund_cap = fund::new_authorized_cap(&mut f, ctx);
    fund::deposit(&mut f, coin::mint_for_testing<SUI>(500, ctx));

    let (mut saving, saving_cap) = make_saving(&clock, ctx);

    // Fund → Saving
    saving::deposit_from_fund<SUI>(&mut saving, &mut f, &saving_cap, &fund_cap, 300, ctx);
    assert!(fund::balance<SUI>(&f) == 200, 0);
    assert!(saving::balance_value<SUI>(&saving) == 300, 1);

    // Saving → Fund
    saving::withdraw_to_fund<SUI>(&mut saving, &mut f, &saving_cap, option::none(), &clock, ctx);
    assert!(saving::balance_value<SUI>(&saving) == 0, 2);
    assert!(fund::balance<SUI>(&f) == 500, 3); // back to original

    destroy(clock);
    destroy(fund_cap);
    destroy(saving_cap);
    destroy(saving);
    destroy(f);
}