module cage::state {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::TxContext;
    
    use cage::pool_registry::{Self, PoolRegistry};
    use cage::position_registry::{Self, PositionRegistry};

    use oyster::ostr_minter_role::OSTR_MINTER_ROLE;
    use pearl::pearl_minter_role::PEARL_MINTER_ROLE;

    use access_control::access_control::{Self as ac, Member};

    friend cage::operator;

    struct State has key, store {
        id: UID,
        ///The authorized prl minter role
        pearl_minter: Member<PEARL_MINTER_ROLE>,
        ///The authorized ostr minter role
        ostr_minter: Member<OSTR_MINTER_ROLE>,
        ///The amount of ostr minted per milliseconds
        ostr_per_ms: u64,
        ///Track the current total alloc points
        total_alloc_point: u64,
        ///The ratio of Pearl reward
        pearl_ratio: u64,
        ///The pool registry allows to register new pools
        pool_registry: PoolRegistry,
        ///The position registry allows to register new position
        position_registry: PositionRegistry
    }

    public(friend) fun new(ctx: &mut TxContext): State {
        State {
            id: object::new(ctx),
            pearl_minter: ac::create_member<PEARL_MINTER_ROLE>(ctx),
            ostr_minter: ac::create_member<OSTR_MINTER_ROLE>(ctx),
            ostr_per_ms: 0,
            pearl_ratio: 0,
            total_alloc_point: 0,
            pool_registry: pool_registry::new(ctx),
            position_registry: position_registry::new(ctx)
        }
    }

    public fun ostr_per_ms(self: &State): u64 { self.ostr_per_ms }
    
    public fun total_alloc_point(self: &State): u64 { self.total_alloc_point }

    public fun pearl_ratio(self: &State): u64 { self.pearl_ratio }

    public fun borrow_pool_registry(self: &State): &PoolRegistry {
        &self.pool_registry
    }

    public fun borrow_ostr_minter_id(self: &State): &ID {
        object::borrow_id(&self.ostr_minter)
    }

    public fun borrow_pearl_minter_id(self: &State): &ID {
        object::borrow_id(&self.pearl_minter)
    }

    public(friend) fun borrow_mut_pool_registry(self: &mut State): &mut PoolRegistry {
        &mut self.pool_registry
    }

    #[test_only]
    public fun borrow_mut_pool_registry_for_testing(self: &mut State): &mut PoolRegistry {
        &mut self.pool_registry
    }

    public fun borrow_position_registry(self: &State): &PositionRegistry {
        &self.position_registry
    }

    public(friend) fun borrow_mut_position_registry(self: &mut State): &mut PositionRegistry {
        &mut self.position_registry
    }

    public(friend) fun borrow_mut_pool_registry_and_position_registry_and_minter(
        self: &mut State
    ): (&mut PoolRegistry, &mut PositionRegistry, &Member<OSTR_MINTER_ROLE>, &Member<PEARL_MINTER_ROLE>) {
        (&mut self.pool_registry, &mut self.position_registry, &self.ostr_minter, &self.pearl_minter)
    }

    public(friend) fun increase_alloc_point(self: &mut State, value: u64) {
        self.total_alloc_point = self.total_alloc_point + value;
    }

    public(friend) fun decrease_alloc_point(self: &mut State, value: u64) {
        self.total_alloc_point = self.total_alloc_point - value;
    }

    public(friend) fun set_ostr_per_ms(self: &mut State, value: u64) {
        self.ostr_per_ms = value;
    }

    #[test_only]
    public fun set_ostr_per_ms_for_testing(self: &mut State, value: u64) {
        set_ostr_per_ms(self, value);
    }

    public(friend) fun set_pearl_ratio(self: &mut State, value: u64) {
        self.pearl_ratio = value; 
    }

    #[test_only]
    public fun set_pearl_ratio_for_testing(self: &mut State, value: u64) {
        set_pearl_ratio(self, value);
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): State{
        new(ctx)
    }

    #[test_only]
    public fun destroy_for_testing(state: State) {
        let State { id, pearl_minter, ostr_minter, ostr_per_ms: _, total_alloc_point: _, pearl_ratio: _, pool_registry, position_registry } = state;
        object::delete(id);
        ac::destroy_member_for_testing(pearl_minter);
        ac::destroy_member_for_testing(ostr_minter);
        pool_registry::destroy_for_testing(pool_registry);
        position_registry::destroy_for_testing(position_registry)
    }
}