module cage::fee_collector {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::coin::{Self, Coin};

    use cage::custodian::{Self, Custodian};

    const PRECISION: u64 = 10000;

    const E_INCORRECT_FEE: u64 = 0;

    struct FeeCollector<phantom C> has key, store {
        id: UID,
        fee_rate: u64,
        total_collected: u64,
        fee_custodian: Custodian<C>
    }

    public fun new<C>(fee_rate: u64, ctx: &mut TxContext): FeeCollector<C> {
        assert!(fee_rate < PRECISION, E_INCORRECT_FEE);
        FeeCollector {
            id: object::new(ctx),
            fee_rate,
            total_collected: 0,
            fee_custodian: custodian::new<C>()
        }
    }

    public fun fee_amount<C>(self: &FeeCollector<C>, amount: u64): u64 {
        (self.fee_rate * amount / PRECISION)
    }

    public fun value<C>(self: &FeeCollector<C>): u64 {
        custodian::reserve(&self.fee_custodian)
    }

    public fun deposit<C>(self: &mut FeeCollector<C>, fee: Coin<C>) {
        self.total_collected = self.total_collected + coin::value(&fee);
        custodian::deposit(&mut self.fee_custodian, fee);
    }

    public fun withdraw<C>(self: &mut FeeCollector<C>, amount: u64, ctx: &mut TxContext): Coin<C> {
        custodian::withdraw(&mut self.fee_custodian, amount, ctx)
    }

    public fun change_fee<C>(self: &mut FeeCollector<C>, amount: u64) {
        self.fee_rate = amount;
    }

    #[test_only]
    public fun destroy_for_testing<C>(collector: FeeCollector<C>) {
        let FeeCollector { id, fee_rate: _, total_collected: _, fee_custodian } = collector;
        object::delete(id);
        custodian::destroy_for_testing(fee_custodian);
    }
}

#[test_only]
module cage::test_fee_collector {
    use sui::coin;
    use sui::tx_context;
    use sui::sui::SUI;
    
    use cage::fee_collector;
    use cage::custodian;

    #[test]
    public fun test_deposit() {
        let ctx = &mut tx_context::dummy();

        let collector = fee_collector::new<SUI>(5, ctx);

        // Deposit fee once.
        let fee = coin::mint_for_testing(500, ctx);
        fee_collector::deposit(&mut collector, fee);
        assert!(fee_collector::value(&collector) == 500, 0);

        let i = 0;
        while(i < 4) {
            let fee = coin::mint_for_testing<SUI>(500, ctx);
            fee_collector::deposit(&mut collector, fee);
            i = i + 1;
        };
        assert!(fee_collector::value(&collector) == 5 * 500, 0);

        fee_collector::destroy_for_testing(collector);
    }

    #[test]
    public fun test_withdraw() {
        let ctx = &mut tx_context::dummy();

        let fee_rate = 500;
        let collector = fee_collector::new<SUI>(500, ctx);

        let i = 0;
        while(i < 5) {
            let fee = coin::mint_for_testing(fee_rate, ctx);
            fee_collector::deposit(&mut collector, fee);
            i = i + 1;
        };
        assert!(fee_collector::value(&collector) == 5 * fee_rate, 0);

        let withdraw_amount = 2 * fee_rate;
        let withdrawn = fee_collector::withdraw(&mut collector, withdraw_amount, ctx);
        assert!(coin::value(&withdrawn) == 2 * fee_rate, 0);
        assert!(fee_collector::value(&collector) == 3 * fee_rate, 0);

        coin::burn_for_testing(withdrawn);
        fee_collector::destroy_for_testing(collector);
    }

    #[test]
    #[expected_failure(abort_code = custodian::E_INSUFFICIENT_RESERVE)]
    public fun test_could_not_withdraw_more_than_reserve() {
        let ctx = &mut tx_context::dummy();

        let fee_rate = 5;
        let collector = fee_collector::new<SUI>(5, ctx);

        assert!(fee_collector::fee_amount(&collector, 50000) == 25, 0);
        assert!(fee_collector::value(&collector) == 0, 0);

        // Deposit fee once.
        let fee = coin::mint_for_testing(fee_rate, ctx);
        fee_collector::deposit(&mut collector, fee);

        let withdrawn = fee_collector::withdraw(&mut collector, fee_rate + 1, ctx);
        
        coin::burn_for_testing(withdrawn);
        abort 1
    }
}