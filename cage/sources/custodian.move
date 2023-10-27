module cage::custodian {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::TxContext;

    const E_INSUFFICIENT_RESERVE: u64 = 0;

    struct Custodian<phantom C> has store {
        reserve: Balance<C>
    }
    
    public fun new<C>(): Custodian<C> {
        Custodian {
            reserve: balance::zero<C>()
        }
    }

    public fun reserve<C>(self: &Custodian<C>): u64 {
        balance::value(&self.reserve)
    }

    public fun deposit<C>(
        self: &mut Custodian<C>,
        deposited: Coin<C>
    ) {
        balance::join(&mut self.reserve, coin::into_balance(deposited));
    }

    public fun withdraw<C>(
        self: &mut Custodian<C>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        assert!(balance::value(&self.reserve) >= amount, E_INSUFFICIENT_RESERVE);
        coin::from_balance(balance::split(&mut self.reserve, amount), ctx)
    }

    /// Safe withdraw function, just in case if rounding error causes custodian to not have enough token.
    public fun safe_withdraw<C>(
        self: &mut Custodian<C>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<C> {
        let reserve = reserve(self);
        if (amount > reserve) {
            coin::from_balance(balance::split(&mut self.reserve, reserve), ctx)
        } else {
            coin::from_balance(balance::split(&mut self.reserve, amount), ctx)
        }
    }


    public fun withdraw_all<C>(
        self: &mut Custodian<C>,
        ctx: &mut TxContext
    ): Coin<C> {
        coin::from_balance(balance::withdraw_all(&mut self.reserve), ctx)
    }

    #[test_only]
    public fun destroy_for_testing<C>(custodian: Custodian<C>) {
        let Custodian { reserve } = custodian;
        balance::destroy_for_testing(reserve);
    }
}

#[test_only]
module cage::test_custodian {
    use sui::coin;
    use sui::tx_context;
    use sui::sui::SUI;
    
    use cage::custodian;

    #[test]
    public fun test_deposit() {
        let ctx = &mut tx_context::dummy();

        let custodian = custodian::new<SUI>();

        assert!(custodian::reserve(&custodian) == 0, 0);

        // Deposit once.
        let amount = 500;
        let deposited = coin::mint_for_testing(amount, ctx);
        custodian::deposit(&mut custodian, deposited);
        assert!(custodian::reserve(&custodian) == amount, 0);

        let i = 0;
        while(i < 4) {
            let deposited = coin::mint_for_testing(amount, ctx);
            custodian::deposit(&mut custodian, deposited);
            i = i + 1;
        };
        assert!(custodian::reserve(&custodian) == 5 * amount, 0);

        custodian::destroy_for_testing(custodian);
    }

    #[test]
    public fun test_withdraw() {
        let ctx = &mut tx_context::dummy();

        let custodian = custodian::new<SUI>();

        assert!(custodian::reserve(&custodian) == 0, 0);

        // Deposit once.
        let amount = 500;
        let deposited = coin::mint_for_testing(amount, ctx);
        custodian::deposit(&mut custodian, deposited);
        assert!(custodian::reserve(&custodian) == amount, 0);

        let i = 0;
        while(i < 4) {
            let deposited = coin::mint_for_testing(amount, ctx);
            custodian::deposit(&mut custodian, deposited);
            i = i + 1;
        };
        assert!(custodian::reserve(&custodian) == 5 * amount, 0);

        let withdraw_amount = 2 * amount;
        let withdrawn = custodian::withdraw(&mut custodian, withdraw_amount, ctx);
        assert!(coin::value(&withdrawn) == 2 * amount, 0);
        assert!(custodian::reserve(&custodian) == 3 * amount, 0);

        coin::burn_for_testing(withdrawn);
        custodian::destroy_for_testing(custodian);
    }

    #[test]
    #[expected_failure(abort_code = custodian::E_INSUFFICIENT_RESERVE)]
    public fun test_could_not_withdraw_more_than_reserve() {
        let ctx = &mut tx_context::dummy();

        let custodian = custodian::new<SUI>();

        assert!(custodian::reserve(&custodian) == 0, 0);

        // Deposit once.
        let amount = 500;
        let deposited = coin::mint_for_testing(amount, ctx);
        custodian::deposit(&mut custodian, deposited);
        assert!(custodian::reserve(&custodian) == amount, 0);

        let withdrawn = custodian::withdraw(&mut custodian, amount + 1, ctx);

        coin::burn_for_testing(withdrawn);
        custodian::destroy_for_testing(custodian);

        abort 1
    }
}