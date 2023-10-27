module cage::position_registry {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::dynamic_field;

    use cage::position::Position;

    friend cage::state;
    friend cage::operator;

    const E_UNREGISTED: u64 = 0;

    struct PositionDfKey has drop, copy, store {
        pool_idx: u64,
        addr: address
    }

    struct PositionRegistry has key, store {
        id: UID,
        num_positions: u64
    }

    public(friend) fun new(ctx: &mut TxContext): PositionRegistry {
        PositionRegistry {
            id: object::new(ctx),
            num_positions: 0
        }
    }

    public fun is_registerd(
        self: &PositionRegistry,
        pool_index: u64,
        account: address
    ): bool {
        dynamic_field::exists_(&self.id, PositionDfKey { pool_idx: pool_index, addr: account })
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): PositionRegistry {
        new(ctx)
    }

    public fun num_positions(self: &PositionRegistry): u64 { self.num_positions }
    
    public(friend) fun register(
        self: &mut PositionRegistry,
        pool_index: u64,
        account: address,
        position: Position
    ) {
        dynamic_field::add(&mut self.id, PositionDfKey { pool_idx: pool_index, addr: account }, position);
        self.num_positions = self.num_positions + 1;
    }

    #[test_only]
    public fun register_for_testing(
        self: &mut PositionRegistry,
        pool_index: u64,
        account: address,
        position: Position
    ) {
        register(self, pool_index, account, position);
    }

    public fun assert_registered(
        self: &PositionRegistry,
        pool_index: u64,
        account: address
    ) {
        assert!(dynamic_field::exists_(&self.id, PositionDfKey { pool_idx: pool_index, addr: account }), E_UNREGISTED);
    }

    public fun borrow_position(
        self: &PositionRegistry,
        pool_index: u64,
        account: address
    ): &Position {
        assert_registered(self, pool_index, account);
        dynamic_field::borrow(&self.id, PositionDfKey { pool_idx: pool_index, addr: account })
    }

    public(friend) fun borrow_mut_position(
        self: &mut PositionRegistry,
        pool_index: u64,
        account: address
    ): &mut Position {
        assert_registered(self, pool_index, account);
        dynamic_field::borrow_mut(&mut self.id, PositionDfKey { pool_idx: pool_index, addr: account })
    }

    #[test_only]
    public fun borrow_mut_position_for_testing(
        self: &mut PositionRegistry,
        pool_index: u64,
        account: address
    ): &mut Position {
        borrow_mut_position(self, pool_index, account)
    }

    #[test_only]
    public fun destroy_for_testing(register: PositionRegistry){
        let PositionRegistry {id, num_positions: _ } = register;
        object::delete(id);
    }
}

#[test_only]
module cage::test_position_registry {
    use sui::tx_context;

    use cage::position_registry;
    use cage::position;

    #[test]
    public fun test_register() {
        let ctx = tx_context::dummy();
        let alice = @0xa;

        let registry = position_registry::create_for_testing(&mut ctx);
        assert!(position_registry::num_positions(&registry) == 0, 0);

        let pos_1 = position::create_for_testing(0, &mut ctx);
        position_registry::register_for_testing(&mut registry, 0, alice, pos_1);
        assert!(position_registry::num_positions(&registry) == 1, 0);

        let pos_2 = position::create_for_testing(2, &mut ctx);
        position_registry::register_for_testing(&mut registry, 1, alice, pos_2);
        assert!(position_registry::num_positions(&registry) == 2, 0);

        position_registry::destroy_for_testing(registry);
    }

    #[test]
    #[expected_failure(abort_code = position_registry::E_UNREGISTED)]
    public fun cannot_borrow_unregistered_position() {
        let ctx = tx_context::dummy();
        let alice = @0xa;

        let registry = position_registry::create_for_testing(&mut ctx);
        assert!(position_registry::num_positions(&registry) == 0, 0);

        position_registry::borrow_position(&registry, 0, alice);

        position_registry::destroy_for_testing(registry);
    }

    #[test]
    #[expected_failure(abort_code = sui::dynamic_field::EFieldAlreadyExists)]
    public fun cannot_register_if_already_registerd() {
        let ctx = tx_context::dummy();
        let alice = @0xa;

        let registry = position_registry::create_for_testing(&mut ctx);
        assert!(position_registry::num_positions(&registry) == 0, 0);

        let pos_1 = position::create_for_testing(0, &mut ctx);
        position_registry::register_for_testing(&mut registry, 0, alice, pos_1);
        assert!(position_registry::num_positions(&registry) == 1, 0);

        let pos_2 = position::create_for_testing(2, &mut ctx);
        position_registry::register_for_testing(&mut registry, 0, alice, pos_2);
        assert!(position_registry::num_positions(&registry) == 2, 0);

        position_registry::destroy_for_testing(registry);
    }
}