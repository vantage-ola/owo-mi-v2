/// Fund Module - A shared treasury that can hold multiple coin types
/// 
/// This module implements a multi-asset fund that acts as a shared treasury.
/// Multiple users can deposit coins, but withdrawals require a FundCap capability.
/// The fund uses a Bag to store different coin types flexibly.
module owomi::fund;

use std::type_name;
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::coin::{Self, Coin};

/// Fund - A shared treasury object that can hold multiple coin types
/// 
/// Key fields:
/// - `balances`: Bag mapping coin type names to Balance<T> values
/// - `authorized_caps`: List of FundCap IDs that are allowed to withdraw
public struct Fund has key {
    id: UID,
    balances: Bag,
    owner: address,
    authorized_caps: vector<ID>
}

/// FundCap - A capability token that authorizes withdrawals from a specific Fund
/// 
/// This can be transferred to other addresses to delegate withdrawal rights.
/// The `fund` field ensures the cap can only be used with its parent Fund.
public struct FundCap has key {
    id: UID,
    fund: ID
}

/// Error codes
const EUnauthorized: u64 = 0;           // Sender is not the fund owner
const EFundCapMismatch: u64 = 0;        // FundCap doesn't match this Fund
const EUnknownCoinType: u64 = 1;        // Coin type not found in fund
const EInsufficientFunds: u64 = 2;      // Not enough balance for withdrawal
const EUnknownAuthorizedCap: u64 = 3;   // Cap ID not in authorized list
const EInvalidFundAuthorization: u64 = 4; // Invalid authorization attempt

/// Creates a new Fund owned by the transaction sender
/// 
/// The Fund is not shared by default - call `share()` after creation
/// to make it accessible to other users.
public fun new(ctx: &mut TxContext): Fund {
    Fund {
        id: object::new(ctx),
        owner: ctx.sender(),
        balances: bag::new(ctx),
        authorized_caps: vector::empty()
    }
}

/// Deposits a Coin into the Fund
/// 
/// Anyone can deposit - no authorization required.
/// The coin type is used as a key in the Bag to organize balances.
/// If the coin type already exists in the bag, it joins the existing balance.
/// Otherwise, it creates a new entry.
public fun deposit<T>(fund: &mut Fund, coin: Coin<T>) {
    // Get the unique type identifier for coin type T
    // with_defining_ids includes module/package info for uniqueness
    let coin_type = type_name::with_defining_ids<T>().into_string().into_bytes();

    if(fund.balances.contains(coin_type)) {
        // Coin type exists - add to existing balance
        let balance = fund.balances.borrow_mut<vector<u8>, Balance<T>>(coin_type);
        balance.join(coin.into_balance());
    } else {
        // First coin of this type - create new balance entry
        fund.balances.add(coin_type, coin.into_balance());
    }
}

/// Withdraws a specified amount of coins from the Fund
/// 
/// Requires a valid FundCap that:
/// 1. References this Fund (cap.fund == fund.id)
/// 2. Is in the authorized_caps list
/// 
/// Returns a Coin<T> with the requested amount.
public fun withdraw<T>(fund: &mut Fund, cap: &FundCap, amount: u64, ctx: &mut TxContext): Coin<T> {
    // Verify the cap belongs to this fund
    assert!(fund.id.to_inner() == cap.fund, EFundCapMismatch);
    
    // Get the coin type identifier
    let coin_type = type_name::with_defining_ids<T>().into_string().into_bytes();

    // Verify this coin type exists in the fund
    assert!(fund.balances.contains(coin_type), EUnknownCoinType);
    
    // Get mutable reference to the balance
    let balance = fund.balances.borrow_mut<vector<u8>, Balance<T>>(coin_type);
    
    // Verify sufficient balance
    assert!(balance.value() >= amount, EInsufficientFunds);

    // Split the requested amount and convert to Coin
    let coin = fund.balances.borrow_mut<vector<u8>, Balance<T>>(coin_type).split(amount);
    coin::from_balance(coin, ctx)
}

/// Returns the total balance of a specific coin type in the Fund
/// 
/// Read-only function - doesn't require any authorization.
public fun balance<T>(fund: &Fund): u64 {
    let coin_type = type_name::with_defining_ids<T>().into_string().into_bytes();
    
    // If coin type doesn't exist, balance is 0
    if (!fund.balances.contains(coin_type)) return 0;

    // Return the balance value
    fund.balances.borrow<vector<u8>, Balance<T>>(coin_type).value()   
}

/// Internal function to create a new FundCap
/// 
/// Creates a cap that references this fund but doesn't add it to
/// authorized_caps - that's done by new_authorized_cap()
fun new_cap(fund: &Fund, ctx: &mut TxContext): FundCap {
    FundCap {
        id: object::new(ctx),
        fund: fund.id.to_inner()
    }
}

/// Shares the Fund object, making it accessible to all users
/// 
/// Required for other users to interact with the Fund.
/// Uses #[allow(lint(share_owned))] to suppress the ownership warning.
#[allow(lint(share_owned))]
public fun share(self: Fund) {
    transfer::share_object(self)
}

/// Transfers a FundCap to another address
/// 
/// This allows delegating withdrawal rights to another user.
public fun transfer_cap(cap: FundCap, recipient: address) {
    transfer::transfer(cap, recipient)
}

/// Creates a new authorized FundCap
/// 
/// Only the fund owner can call this.
/// The cap is automatically added to authorized_caps, enabling withdrawals.
/// Use transfer_cap() to send it to another address.
public fun new_authorized_cap(fund: &mut Fund, ctx: &mut TxContext): FundCap {
    // Only owner can create authorized caps
    assert!(fund.owner == ctx.sender(), EUnauthorized);
    
    // Create the cap and track it
    let cap = fund.new_cap(ctx);
    fund.authorized_caps.push_back(cap.id.to_inner());

    cap
}

/// Finds the index of a cap ID in the authorized_caps list
/// 
/// Returns Some(index) if found, None otherwise.
/// Used internally for cap management.
public fun authorized_cap_index(self: &Fund, cap: ID): Option<u64> {
    let (mut i, len) = (0, self.authorized_caps.length());
    
    // Linear search through authorized caps
    while (i < len){
        let authorized_cap = self.authorized_caps[i];
        if(authorized_cap == cap) {
            return option::some(i)
        };

        i = i + 1;
    };

    option::none()
}

/// Revokes a cap's authorization without destroying it
/// 
/// Only the owner can revoke caps.
/// The cap object still exists but can no longer be used to withdraw.
/// The cap must exist in authorized_caps.
public fun revoke_cap(self: &mut Fund, cap: ID, ctx: &mut TxContext) {
    // Only owner can revoke
    assert!(self.owner == ctx.sender(), EInvalidFundAuthorization);
    
    // Verify cap is in authorized list
    assert!(self.authorized_caps.contains(&cap), EUnknownAuthorizedCap);

    // Find and remove the cap from authorized list
    let index = self.authorized_cap_index(cap);
    assert!(index.is_some(), EUnknownAuthorizedCap);

    self.authorized_caps.remove(index.destroy_some());

}

/// Deletes a FundCap and removes it from authorized list
/// 
/// Unlike revoke_cap, this destroys the cap object entirely.
/// The cap must be passed by value (consumed).
public fun delete_cap(self: &mut Fund, cap: FundCap) {
    // Verify cap is authorized
    assert!(self.authorized_caps.contains(cap.id.as_inner()), EUnknownAuthorizedCap);

    // Find and remove from authorized list
    let index = self.authorized_cap_index(cap.id.to_inner());
    assert!(index.is_some(), EUnknownAuthorizedCap);

    self.authorized_caps.remove(index.destroy_some());
    
    // Unpack and delete the cap object
    let FundCap {id, fund: _ } = cap;
    id.delete(); 
}
