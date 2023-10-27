module cage::pool_registry {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::dynamic_field;

    use cage::pool::Pool;

    friend cage::state;
    friend cage::operator;

    const E_UNREGISTED: u64 = 0;

    struct PoolDfKey has copy, store, drop {
        index: u64
    }

    struct PoolRegistry has key, store {
        id: UID,
        num_pools: u64
    }
    

    public(friend) fun new(ctx: &mut TxContext): PoolRegistry {
        PoolRegistry {
            id: object::new(ctx),
            num_pools: 0
        }
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): PoolRegistry {
        new(ctx)
    }

    public fun num_pools(self: &PoolRegistry): u64 { self.num_pools }
    
    public(friend) fun register(
        self: &mut PoolRegistry,
        pool: Pool
    ) {
        let key = PoolDfKey { index: num_pools(self) };
        dynamic_field::add(&mut self.id, key, pool);
        self.num_pools = self.num_pools + 1;
    }

    #[test_only]
    public fun register_for_testing(
        self: &mut PoolRegistry,
        pool: Pool
    ) {
        register(self, pool);
    }

    public fun assert_registered(
        self: &PoolRegistry,
        pool_index: u64
    ) {
        assert!(num_pools(self) > pool_index, E_UNREGISTED);
    }

    public fun borrow_pool(
        self: &PoolRegistry,
        pool_index: u64
    ): &Pool {
        assert_registered(self, pool_index);
        dynamic_field::borrow(&self.id, PoolDfKey { index: pool_index })
    }

    public(friend) fun borrow_mut_pool(
        self: &mut PoolRegistry,
        pool_index: u64
    ): &mut Pool {
        assert_registered(self, pool_index);
        dynamic_field::borrow_mut(&mut self.id, PoolDfKey { index: pool_index })
    }

    #[test_only]
    public fun borrow_mut_pool_for_testing(
        self: &mut PoolRegistry,
        pool_index: u64
    ): &mut Pool {
        assert_registered(self, pool_index);
        dynamic_field::borrow_mut(&mut self.id, PoolDfKey { index: pool_index })
    }

    #[test_only]
    public fun destroy_for_testing(register: PoolRegistry){
        let PoolRegistry {id, num_pools: _ } = register;
        object::delete(id);
    }
}

#[test_only]
module cage::test_pool_registry {
    use sui::tx_context;
    use sui::clock;

    use cage::pool_registry;
    use cage::pool;

    struct USDT has drop {}

    struct USDC has drop {}

    #[test]
    public fun test_register() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);

        let register = pool_registry::create_for_testing(&mut ctx);
        assert!(pool_registry::num_pools(&register) == 0, 0);

        let pool_1 = pool::create_for_testing(500, &clock, &mut ctx);
        pool_registry::register_for_testing(&mut register, pool_1);
        assert!(pool_registry::num_pools(&register) == 1, 0);

        let pool_2 = pool::create_for_testing(500, &clock, &mut ctx);
        pool_registry::register_for_testing(&mut register, pool_2);
        assert!(pool_registry::num_pools(&register) == 2, 0);

        clock::destroy_for_testing(clock);
        pool_registry::destroy_for_testing(register);
    }
}