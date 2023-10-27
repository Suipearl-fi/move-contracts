module cage::fee_collector_registry {
    use sui::object::{Self, UID, ID};
    use sui::tx_context::TxContext;
    use sui::dynamic_field;

    use cage::fee_collector::FeeCollector;

    friend cage::state;
    friend cage::operator;

    const E_UNREGISTED: u64 = 0;

    struct FeeCollectorRegistry has key, store {
        id: UID
    }

    public(friend) fun new(ctx: &mut TxContext): FeeCollectorRegistry {
        FeeCollectorRegistry {
            id: object::new(ctx)
        }
    }

    #[test_only]
    public fun create_for_testing(ctx: &mut TxContext): FeeCollectorRegistry {
        new(ctx)
    }
    
    public(friend) fun register<C>(
        self: &mut FeeCollectorRegistry,
        fee_collector: FeeCollector<C>
    ) {
        let key = object::id(&fee_collector);
        dynamic_field::add(&mut self.id, key, fee_collector);
    }

    #[test_only]
    public fun register_for_testing<C>(
        self: &mut FeeCollectorRegistry,
        fee_collector: FeeCollector<C>
    ) {
        register(self, fee_collector);
    }

    public fun assert_registered(
        self: &FeeCollectorRegistry,
        key: ID
    ) {
        assert!(dynamic_field::exists_(&self.id, key), E_UNREGISTED);
    }

    public fun borrow_fee_collector<C>(
        self: &FeeCollectorRegistry,
        key: ID
    ): &FeeCollector<C> {
        assert_registered(self, key);
        dynamic_field::borrow(&self.id, key)
    }

    public(friend) fun borrow_mut_fee_collector<C>(
        self: &mut FeeCollectorRegistry,
        key: ID
    ): &mut FeeCollector<C> {
        assert_registered(self, key);
        dynamic_field::borrow_mut(&mut self.id, key)
    }

    #[test_only]
    public fun borrow_mut_fee_collector_for_testing<C>(
        self: &mut FeeCollectorRegistry,
        key: ID
    ): &mut FeeCollector<C> {
        assert_registered(self, key);
        dynamic_field::borrow_mut(&mut self.id, key)
    }

    #[test_only]
    public fun destroy_for_testing(register: FeeCollectorRegistry){
        let FeeCollectorRegistry { id } = register;
        object::delete(id);
    }
}

#[test_only]
module cage::test_fee_collector_registry {
    use sui::tx_context;
    use sui::sui::SUI;

    use cage::fee_collector_registry;
    use cage::fee_collector;

    #[test]
    public fun test_register() {
        let ctx = tx_context::dummy();

        let registry = fee_collector_registry::create_for_testing(&mut ctx);

        let fee_collector = fee_collector::new<SUI>(100, &mut ctx);
        let key = sui::object::id(&fee_collector);
        fee_collector_registry::register_for_testing(&mut registry, fee_collector);
        fee_collector_registry::assert_registered(&registry, key);

        fee_collector_registry::destroy_for_testing(registry);
    }
}