module cage::position {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::event;

    friend cage::operator;

    const MAX_U64: u64 = 18_446_744_073_709_551_615u64;

    const E_OVERFLOW: u64 = 0;
    const E_INSUFFICIENT_AMOUNT: u64 = 0;

    struct Position has key, store {
        id: UID,
        pool_idx: u64,
        amount: u64,
        reward_debt: u256
    }

    struct PositionCreated has copy, drop {
        id: ID,
        pool_idx: u64,
        user: address
    }

    struct PositionIncreased has copy, drop {
        id: ID,
        amount: u64,
        user: address
    }

    struct PositionDecreased has copy, drop {
        id: ID,
        amount: u64,
        user: address
    }

    public fun pool_idx(self: &Position): u64 { self.pool_idx }

    public fun value(self: &Position): u64 { self.amount }

    public fun reward_debt(self: &Position): u256 { self.reward_debt }

    public(friend) fun new(pool_idx: u64, ctx: &mut TxContext): Position {
        let position = Position {
            id: object::new(ctx),
            pool_idx,
            amount: 0,
            reward_debt: 0
        };

        event::emit(PositionCreated {
            id: object::id(&position),
            pool_idx,
            user: tx_context::sender(ctx)
        });

        position
    }

    public(friend) fun increase(self: &mut Position, amount: u64, ctx: &mut TxContext) {
        assert!(amount < MAX_U64 - self.amount, E_OVERFLOW);
        self.amount = self.amount + amount;
        
        event::emit(PositionIncreased {
            id: object::id(self),
            amount,
            user: tx_context::sender(ctx)
        });
    }

    #[test_only]
    public fun increase_for_testing(self: &mut Position, amount: u64, ctx: &mut TxContext) {
        increase(self, amount, ctx);
    }

    public(friend) fun decrease(self: &mut Position, amount: u64, ctx: &mut TxContext) {
        assert!(self.amount >= amount, E_INSUFFICIENT_AMOUNT);
        self.amount = self.amount - amount;

        event::emit(PositionDecreased {
            id: object::id(self),
            amount,
            user: tx_context::sender(ctx)
        });
    }

    #[test_only]
    public fun decrease_for_testing(self: &mut Position, amount: u64, ctx: &mut TxContext) {
        decrease(self, amount, ctx);
    }

    public(friend) fun change_reward_debt(self: &mut Position, amount: u256) {
        self.reward_debt = amount;
    }

    #[test_only]
    public fun change_reward_debt_for_testing(self: &mut Position, amount: u256) {
        change_reward_debt(self, amount);
    }

    #[test_only]
    public fun create_for_testing(pool_idx: u64, ctx: &mut TxContext): Position {
        new(pool_idx, ctx)
    }

    #[test_only]
    public fun destroy_for_testing(pos: Position) {
        let Position {id, pool_idx: _, amount: _, reward_debt: _ } = pos;
        object::delete(id);
    }
}