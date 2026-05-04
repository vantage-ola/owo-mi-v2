/// Saving Module - A goal-oriented savings account for a specific coin type
/// 
/// This module implements enforced savings with optional targets (date + amount).
/// Unlike Fund (which holds multiple coin types), Saving<T> is generic over one type.
/// Withdrawals can be constrained by savings targets to enforce financial discipline.
module owomi::saving;

use std::string::String;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::Clock;

use owomi::fund::{Fund, FundCap};

/// Saving - A savings account for a specific coin type T
/// 
/// Generic over the coin type, providing compile-time type safety.
/// Can have an optional target that enforces withdrawal constraints.
public struct Saving<phantom T> has key {
    id: UID,
    reward: u64,                          // Reserved for future reward system
    name: String,                         // Human-readable name for the saving
    owner: address,                       // Creator of this saving
    created_at_ms: u64,                   // Creation timestamp
    description: String,                  // Description of savings goal
    balance: Balance<T>,                  // The actual coins stored
    target: Option<SavingTarget>,         // Optional goal (date + amount)
    authorized_caps: vector<ID>,          // List of authorized SavingCap IDs
}

/// SavingTarget - A savings goal with date and amount constraints
/// 
/// Has store, drop, copy abilities so it can be easily created and passed around.
/// When a target is set, withdrawals are blocked until:
/// 1. Current time >= target date
/// 2. Balance >= target amount
public struct SavingTarget has store, drop, copy {
    date: u64,      // Target date as Unix timestamp in milliseconds
    amount: u64     // Target amount to save
}

/// SavingCap - A capability token for depositing to and withdrawing from a Saving
/// 
/// Similar to FundCap, this authorizes operations on the Saving.
/// Can be transferred to delegate access to other users.
public struct SavingCap has key {
    id: UID,
    saving: ID      // References the parent Saving object
}

/// Error codes
const EInvalidSavingTarget: u64 = 0;        // Invalid target (past date, zero amount, or early withdrawal)
const EInvalidDepositAmount: u64 = 1;       // Deposit amount must be > 0
const ESavingCapMismatch: u64 = 2;          // Cap doesn't match this Saving
const EInSufficientSavingBalance: u64 = 3;  // Not enough balance for withdrawal
const EInvalidSavingAuthorization: u64 = 4; // Unauthorized operation
const EUnknownAuthorizedCap: u64 = 5;       // Cap ID not in authorized list

/// Creates a new Saving with optional target
/// 
/// Returns a tuple of (Saving, SavingCap) - the initial cap is automatically authorized.
/// The Saving must be shared using `share()` for others to interact.
/// 
/// Validates that if a target is provided:
/// - target.amount > 0
/// - target.date > current time (must be in the future)
public fun new<T>(
    name: String, 
    description: String, 
    target: Option<SavingTarget>, 
    clock: &Clock, 
    ctx: &mut TxContext
): (Saving<T>, SavingCap) {

    // Validate target if provided
    if (target.is_some()) {
        let target = target.borrow();

        // Amount must be positive
        assert!(target.amount > 0, EInvalidSavingTarget);
        // Date must be in the future
        assert!(target.date > clock.timestamp_ms(), EInvalidSavingTarget);
    };

    let id = object::new(ctx);
    let mut saving = Saving<T> {
        id,
        name,
        target,
        reward: 0,
        description,
        owner: ctx.sender(),
        balance: balance::zero(),
        authorized_caps: vector::empty(),
        created_at_ms: clock.timestamp_ms(),
    };

    // Create initial cap and authorize it
    let cap = new_saving_cap(&saving, ctx);
    saving.authorized_caps.push_back(cap.id.to_inner());
    (saving, cap)
}

/// Helper function to create a SavingTarget
/// 
/// Creates a target struct that can be passed to new() as Some(target)
public fun new_saving_target(date: u64, amount: u64): SavingTarget {
    SavingTarget {
        date,
        amount
    }
}

/// Creates a new authorized SavingCap
/// 
/// Only the saving owner can create new caps.
/// The cap is added to authorized_caps, enabling deposit/withdraw operations.
public fun new_authorized_cap<T>(self: &mut Saving<T>, ctx: &mut TxContext): SavingCap {
    // Only owner can create authorized caps
    assert!(self.owner == ctx.sender(), EInvalidSavingAuthorization);
    
    // Create cap and track it
    let cap = self.new_saving_cap(ctx);
    self.authorized_caps.push_back(cap.id.to_inner());

    cap
}

/// Revokes a cap's authorization by its ID
/// 
/// Only the owner can revoke. The cap object still exists but becomes unusable.
public fun revoke_cap<T>(self: &mut Saving<T>, cap:ID, ctx: &mut TxContext) {
    // Only owner can revoke
    assert!(self.owner == ctx.sender(), EInvalidSavingAuthorization);
    
    // Verify cap is authorized
    assert!(self.authorized_caps.contains(&cap), EUnknownAuthorizedCap);

    // Find and remove from authorized list
    let index = self.authorized_cap_index(cap);
    assert!(index.is_some(), EUnknownAuthorizedCap);
    self.authorized_caps.remove(index.destroy_some());
}

/// Deletes a SavingCap and removes it from authorized list
/// 
/// The cap must be passed by value (consumed).
/// Unlike revoke_cap, this destroys the cap object entirely.
public fun delete_cap<T>(self: &mut Saving<T>, cap: SavingCap) {
    // Try to find cap in authorized list
    let index = self.authorized_cap_index(cap.id.to_inner());
    
    // Remove from authorized list if found
    if(index.is_some()) {
        self.authorized_caps.remove(index.destroy_some());
    };

    // Unpack and delete the cap object
    let SavingCap { id, saving: _ } = cap;
    id.delete();
}

/// Shares the Saving object, making it accessible to all users
public fun share<T>(self: Saving<T>) {
    transfer::share_object(self)
}

/// Transfers a SavingCap to another address
/// 
/// Delegates deposit/withdraw rights to another user.
public fun transfer_cap(cap: SavingCap, recipient: address) {
    transfer::transfer(cap, recipient)
}

/// Deposits a Coin into the Saving
/// 
/// Requires a valid, authorized SavingCap.
/// The cap must:
/// 1. Reference this Saving (cap.saving == saving.id)
/// 2. Be in the authorized_caps list
/// 
/// The coin value must be > 0.
public fun deposit<T>(self: &mut Saving<T>, cap: &SavingCap, coin: Coin<T>) {
    // Verify cap belongs to this saving
    assert!(self.id.to_inner() == cap.saving, ESavingCapMismatch);
    
    // Verify cap is authorized
    assert!(self.authorized_caps.contains(cap.id.as_inner()), EUnknownAuthorizedCap);
    
    // Validate deposit amount
    assert!(coin.value() > 0, EInvalidDepositAmount);

    // Convert coin to balance and join with existing balance
    self.balance.join(coin.into_balance());
}

/// Withdraws coins from the Saving
/// 
/// Requires a valid, authorized SavingCap.
/// 
/// If a target is set, enforces withdrawal constraints:
/// 1. Current time >= target.date (can't withdraw before target date)
/// 2. Balance >= target.amount (must reach savings goal)
/// 
/// Amount is optional:
/// - Some(amount): Withdraw specified amount
/// - None: Withdraw entire balance
public fun withdraw<T>(
    self: &mut Saving<T>, 
    cap: &SavingCap, 
    amount: Option<u64>, 
    clock: &Clock, 
    ctx: &mut TxContext
): Coin<T> {
    // Verify cap belongs to this saving
    assert!(self.id.to_inner() == cap.saving, ESavingCapMismatch);
    
    // Verify cap is authorized
    assert!(self.authorized_caps.contains(cap.id.as_inner()), EUnknownAuthorizedCap);

    // Check target constraints if target exists
    if(self.target.is_some()) {
        let target = self.target.borrow();
        
        // Must be past target date
        assert!(clock.timestamp_ms() >= target.date, EInvalidSavingTarget);
        // Must have reached target amount
        assert!(self.balance.value() >= target.amount, EInvalidSavingTarget);
    };
    
    // Determine withdrawal amount
    let amount = if(amount.is_some()){
        // Specific amount requested
        let amount = amount.destroy_some();
        assert!(self.balance.value() >= amount, EInSufficientSavingBalance);
        amount
    } else {
        // Withdraw everything
        self.balance.value()
    };

    // Split and return as Coin
    coin::from_balance(self.balance.split(amount), ctx)
}

/// Deposits into Saving directly from a Fund
/// 
/// This is a convenience function that combines:
/// 1. Withdraw from Fund (requires FundCap)
/// 2. Deposit into Saving (requires SavingCap)
/// 
/// Useful for moving money from shared treasury to personal savings.
public fun deposit_from_fund<T>(
    self: &mut Saving<T>, 
    fund: &mut Fund, 
    saving_cap: &SavingCap, 
    fund_cap: &FundCap, 
    amount: u64, 
    ctx: &mut TxContext
) {
    // Withdraw from fund first
    let deposit = fund.withdraw(fund_cap, amount, ctx);
    
    // Then deposit into saving
    self.deposit(saving_cap, deposit)
}

/// Withdraws from Saving directly to a Fund
/// 
/// Convenience function that combines:
/// 1. Withdraw from Saving (requires SavingCap)
/// 2. Deposit into Fund (no cap needed)
/// 
/// Useful for returning money to shared treasury after reaching goal.
public fun withdraw_to_fund<T>(
    self: &mut Saving<T>, 
    fund: &mut Fund, 
    saving_cap: &SavingCap, 
    amount: Option<u64>, 
    clock: &Clock, 
    ctx: &mut TxContext
) {
    // Withdraw from saving
    let coin = self.withdraw(saving_cap, amount, clock, ctx);
    
    // Deposit into fund
    fund.deposit(coin);
}

// ===== Read only functions =====

/// Finds the index of a cap ID in the authorized_caps list
/// 
/// Returns Some(index) if found, None otherwise.
/// Linear search through the vector.
public fun authorized_cap_index<T>(self: &Saving<T>, cap: ID): Option<u64> {
    let (mut i, len) = (0, self.authorized_caps.length());
    
    while (i < len ){
        let authorized_cap = self.authorized_caps[i];
        if(authorized_cap == cap) {
            return option::some(i)
        };

        i = i + 1;
    };

    option::none()
}

// ===== Private functions =====

/// Internal function to create a new SavingCap
/// 
/// Creates a cap that references this saving.
/// Does NOT add to authorized_caps - caller must do that.
fun new_saving_cap<T>(saving: &Saving<T>, ctx: &mut TxContext): SavingCap {
    SavingCap {
        id: object::new(ctx),
        saving: saving.id.to_inner()
    }
}

// ===== Test Helpers =====

#[test_only]
public fun authorized_caps_length<T>(self: &Saving<T>): u64 {
    self.authorized_caps.length()
}

#[test_only]
public fun cap_id(cap: &SavingCap): ID {
    cap.id.to_inner()
}

#[test_only]
public fun saving_id(cap: &SavingCap): ID {
    cap.saving
}

#[test_only]
public fun balance_value<T>(self: &Saving<T>): u64 {
    self.balance.value()
}