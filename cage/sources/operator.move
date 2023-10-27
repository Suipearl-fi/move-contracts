module cage::operator {
    use sui::object::{Self, UID};
    use sui::tx_context::{Self, TxContext};

    use sui::coin::{Self, Coin};
    use sui::clock::{Clock};
    use sui::dynamic_field::{Self as df};
    use sui::transfer;

    use cage::custodian::{Self, Custodian};
    use cage::fee_collector::{Self, FeeCollector};
    use cage::state::{Self, State};
    use cage::pool_registry;
    use cage::pool::{Self, Pool};
    use cage::position_registry;
    use cage::position::{Self, Position};

    use oyster::ostr;
    use oyster::ostr_state::{State as OSTRState};
    use oyster::ostr_minter_role::OSTR_MINTER_ROLE;

    use pearl::pearl_minter_role::PEARL_MINTER_ROLE;
    use pearl::prl::{Self, TreasuryManagement as PearlTrearsuryManagement};

    use access_control::access_control::{Role, Member};

    // Track the current version of the module
    const VERSION: u64 = 1;
    const PEARL_PRECISION: u64 = 100;

    const E_WRONG_VERSION: u64 = 999;
    const E_ALREADY_INITIALZED: u64 = 1000;

    const E_INSUFFICIENT_LP_DEPOSITED: u64 = 0;
    const E_IN_EMNERGENCY: u64 = 2;
    const E_NOT_EMNERGENCY: u64 = 1;

    struct VersionDfKey has copy, store, drop {}

    struct InitializeDfKey has copy, store, drop {}

    struct CustodianDfKey has copy, store, drop {}

    struct FeeCollectorDfKey has copy, store, drop {}

    struct AdminCap has key, store {
        id: UID
    }

    fun init(ctx: &mut TxContext) {
        transfer::transfer(AdminCap {
            id: object::new(ctx)
        }, tx_context::sender(ctx));
    }

    fun recalc_reward_debts(pool: &Pool, position: &mut Position) {
        let reward_debt = pool::calc_rewards_for(pool, position);
        position::change_reward_debt(position, reward_debt);
    }

    fun increase_for<StakedToken>(
        pool: &mut Pool,
        position: &mut Position,
        staked: Coin<StakedToken>,
        ctx: &mut TxContext
    ) {
        //Perform depositing
        let staked_amount = coin::value(&staked);
        position::increase(position, staked_amount, ctx);
        custodian::deposit(df::borrow_mut(pool::uid_mut(pool), CustodianDfKey {}), staked);
        pool::increase_staked_amount(pool, staked_amount);
    }

    fun decrease_for<StakedToken>(
        pool: &mut Pool,
        position: &mut Position,
        amount: u64,
        ctx: &mut TxContext
    ) {
        //Perform witdrawing
        position::decrease(position, amount, ctx);
        pool::decrease_staked_amount(pool, amount);
        let withdrawn = custodian::withdraw<StakedToken>(df::borrow_mut(pool::uid_mut(pool), CustodianDfKey {}), amount, ctx);
        transfer::public_transfer(withdrawn, tx_context::sender(ctx));
    }

    fun distribute_pending_rewards(
        pool: &mut Pool,
        position: &Position,
        pearl_ratio: u64,
        ostr_state: &mut OSTRState,
        ostr_minter_role: &Role<OSTR_MINTER_ROLE>,
        ostr_minter_member: &Member<OSTR_MINTER_ROLE>,
        pearl_treasury_management: &mut PearlTrearsuryManagement,
        pearl_minter_role: &Role<PEARL_MINTER_ROLE>,
        pearl_minter_member: &Member<PEARL_MINTER_ROLE>,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let ostr_reward_amount = pool::calc_pending_rewards(pool, position);
        if (ostr_reward_amount > 0) {
            let pearl_reward_amount = ostr_reward_amount * pearl_ratio / PEARL_PRECISION;
            ostr_reward_amount = ostr_reward_amount - pearl_reward_amount;

            if (pearl_reward_amount > 0) {
                prl::mint_and_transfer(
                    pearl_treasury_management, pearl_minter_role, pearl_minter_member, sender, pearl_reward_amount, ctx
                );
            };
            if (ostr_reward_amount > 0) {
                ostr::mint(ostr_state, ostr_minter_role, ostr_minter_member, sender, ostr_reward_amount);
            };
        };
    }

    public fun borrow_staked_token_custodian<StakedToken>(state: &State, pool_index: u64): &Custodian<StakedToken> {
        let pool = pool_registry::borrow_pool(state::borrow_pool_registry(state), pool_index);
        df::borrow(pool::uid(pool), CustodianDfKey {})
    }

    fun mass_update_pool(state: &mut State, clock: &Clock) {
        let (i, num_pools) = (0, pool_registry::num_pools(state::borrow_pool_registry(state)));
        let (total_alloc_point, ostr_per_ms) = (state::total_alloc_point(state), state::ostr_per_ms(state));
        while(i < num_pools) {
            let pool = pool_registry::borrow_mut_pool(state::borrow_mut_pool_registry(state), i);
            assert_version_and_upgrade(pool::uid_mut(pool));
            pool::update_pool(
                pool,
                total_alloc_point,
                ostr_per_ms,
                clock
            );
            i = i + 1;
        };
    }

    #[test_only]
    public fun mass_update_pool_for_testing(state: &mut State, clock: &Clock){
        mass_update_pool(state, clock);
    }

    fun create_pool_internal<StakedToken>(
        state: &mut State,
        alloc_point: u64,
        fee_rate: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        //Force mass update pools
        mass_update_pool(state, clock);
        let pool = pool::create_pool(alloc_point, clock, ctx);
        df::add(pool::uid_mut(&mut pool), VersionDfKey {}, VERSION);
        df::add(pool::uid_mut(&mut pool), CustodianDfKey {}, custodian::new<StakedToken>());
        df::add(pool::uid_mut(&mut pool), FeeCollectorDfKey {}, fee_collector::new<StakedToken>(fee_rate, ctx));
        state::increase_alloc_point(state, alloc_point);
        pool_registry::register(state::borrow_mut_pool_registry(state), pool);
    }

    entry fun setup(
        admin_cap: &mut AdminCap,
        ostr_per_ms: u64,
        pearl_ratio: u64, 
        ctx: &mut TxContext
    ) {
        assert!(!df::exists_(&admin_cap.id, InitializeDfKey {}), E_ALREADY_INITIALZED);
        let state = state::new(ctx);
        state::set_ostr_per_ms(&mut state, ostr_per_ms);
        state::set_pearl_ratio(&mut state, pearl_ratio);
        df::add(&mut admin_cap.id, InitializeDfKey {}, true);
        transfer::public_share_object(state);
    }

    entry fun set_ostr_per_ms(
        _: &AdminCap,
        state: &mut State,
        ostr_per_ms: u64,
        clock: &Clock
    ) {
        mass_update_pool(state, clock);
        state::set_ostr_per_ms(state, ostr_per_ms);
    }

    entry fun set_fee_rate<StakedToken>(
        _: &AdminCap,
        state: &mut State,
        pool_index: u64,
        new_fee_rate: u64
    ) {
        fee_collector::change_fee(
            df::borrow_mut<FeeCollectorDfKey, FeeCollector<StakedToken>>(
                pool::uid_mut(pool_registry::borrow_mut_pool(state::borrow_mut_pool_registry(state), pool_index)),
                FeeCollectorDfKey {}
            ),
            new_fee_rate
        );
    }

    entry fun withdraw_fee<StakedToken>(
        _: &AdminCap,
        state: &mut State,
        pool_index: u64,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let withdrawn = fee_collector::withdraw(
            df::borrow_mut<FeeCollectorDfKey, FeeCollector<StakedToken>>(
                pool::uid_mut(pool_registry::borrow_mut_pool(state::borrow_mut_pool_registry(state), pool_index)),
                FeeCollectorDfKey {}
            ),
            amount,
            ctx
        );
        transfer::public_transfer(withdrawn, tx_context::sender(ctx));
    }

    #[test_only]
    public fun set_ostr_per_ms_for_testing(
        state: &mut State,
        ostr_per_ms: u64,
        clock: &Clock
    ) {
        mass_update_pool(state, clock);
        state::set_ostr_per_ms(state, ostr_per_ms);
    }

    entry fun create_pool<StakedToken>(
        _: &AdminCap,
        state: &mut State,
        alloc_point: u64,
        fee_rate: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
       create_pool_internal<StakedToken>(state, alloc_point, fee_rate, clock, ctx);
    }

    #[test_only]
    public fun create_pool_for_testing<StakedToken>(
        state: &mut State,
        alloc_point: u64,
        fee_rate: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ){
        create_pool_internal<StakedToken>(state, alloc_point, fee_rate, clock, ctx);
    }

    fun set_alloc_point_interanl(
        state: &mut State,
        pool_index: u64,
        alloc_point: u64,
        clock: &Clock
    ) {
        //Force mass update pools
        mass_update_pool(state, clock);
        let pool = pool_registry::borrow_mut_pool(state::borrow_mut_pool_registry(state), pool_index);
        let prev_alloc_point = pool::alloc_point(pool);
        pool::set_alloc_point(pool, alloc_point);
        state::decrease_alloc_point(state, prev_alloc_point);
        state::increase_alloc_point(state, alloc_point);
    }

    public entry fun set_alloc_point(
        _: &AdminCap,
        state: &mut State,
        pool_index: u64,
        alloc_point: u64,
        clock: &Clock
    ) {
        set_alloc_point_interanl(state, pool_index, alloc_point, clock);
    }

    #[test_only]
    public fun set_alloc_point_for_testing(
        state: &mut State,
        pool_index: u64,
        alloc_point: u64,
        clock: &Clock
    ){
        set_alloc_point_interanl(state, pool_index, alloc_point, clock);
    }

    entry fun increase_position<StakedToken>(
        state: &mut State,
        pool_index: u64,
        staked: Coin<StakedToken>,
        ostr_state: &mut OSTRState,
        ostr_minter_role: &Role<OSTR_MINTER_ROLE>,
        pearl_treasury_management: &mut PearlTrearsuryManagement,
        pearl_minter_role: &Role<PEARL_MINTER_ROLE>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let (total_alloc_point, ostr_per_ms, pearl_ratio) = (state::total_alloc_point(state), state::ostr_per_ms(state), state::pearl_ratio(state));
        let (pool_registry, position_registry, ostr_minter_member, pearl_minter_member) = state::borrow_mut_pool_registry_and_position_registry_and_minter(state);

        let pool = pool_registry::borrow_mut_pool(pool_registry, pool_index);
        assert_version_and_upgrade(pool::uid_mut(pool));
        assert_not_emergency(pool);

        if (!position_registry::is_registerd(position_registry, pool_index, sender)) {
            let position = position::new(pool_index, ctx);
            position_registry::register(
                position_registry,
                pool_index,
                sender,
                position
            );
        };

        let position = position_registry::borrow_mut_position(
            position_registry,
            pool_index,
            sender
        );

        //Perform update pool
        pool::update_pool(pool, total_alloc_point, ostr_per_ms, clock);

        //Perform distribute pending reward
        if (position::value(position) > 0) {
            distribute_pending_rewards(
                pool, position, pearl_ratio, ostr_state, ostr_minter_role, ostr_minter_member,
                pearl_treasury_management, pearl_minter_role, pearl_minter_member, ctx
            );
        };

        let staked_amount = coin::value(&staked);
        if (staked_amount > 0) {
             //Peform collect fee
            let fee_amount = fee_collector::fee_amount(
                df::borrow<FeeCollectorDfKey, FeeCollector<StakedToken>>(pool::uid(pool), FeeCollectorDfKey {}),
                staked_amount
            );
            if (fee_amount > 0) {
                fee_collector::deposit(
                    df::borrow_mut(pool::uid_mut(pool), FeeCollectorDfKey {}),
                    coin::split(&mut staked, fee_amount, ctx)
                );
            };
            increase_for<StakedToken>(pool, position, staked, ctx);
        } else {
            coin::destroy_zero(staked);
        };

        recalc_reward_debts(pool, position);
    }

    entry fun decrease_position<StakedToken>(
        state: &mut State,
        pool_index: u64,
        amount: u64,
        ostr_state: &mut OSTRState,
        ostr_minter_role: &Role<OSTR_MINTER_ROLE>,
        pearl_treasury_management: &mut PearlTrearsuryManagement,
        pearl_minter_role: &Role<PEARL_MINTER_ROLE>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let (total_alloc_point, ostr_per_ms, pearl_ratio) = (state::total_alloc_point(state), state::ostr_per_ms(state), state::pearl_ratio(state));
        let (pool_registry, position_registry, ostr_minter_member, pearl_minter_member) = state::borrow_mut_pool_registry_and_position_registry_and_minter(state);

        let pool = pool_registry::borrow_mut_pool(pool_registry, pool_index);
        assert_version_and_upgrade(pool::uid_mut(pool));
        assert_not_emergency(pool);

        let position = position_registry::borrow_mut_position(
            position_registry,
            pool_index,
            tx_context::sender(ctx)
        );

        //Perform update pool
        pool::update_pool(pool, total_alloc_point, ostr_per_ms, clock);

        //Perform distribute pending reward
        if (position::value(position) > 0) {
            distribute_pending_rewards(
                pool, position, pearl_ratio, ostr_state, ostr_minter_role, ostr_minter_member,
                pearl_treasury_management, pearl_minter_role, pearl_minter_member, ctx
            );
        };

        //Perform widrawing
        if(amount > 0) {
            decrease_for<StakedToken>(pool, position, amount, ctx);
        };

        recalc_reward_debts(pool, position);
    }

    entry fun decrease_position_emergency<StakedToken>(
        state: &mut State,
        pool_index: u64,
        ctx: &mut TxContext
    ) {
        let (pool_registry, position_registry, _, _) = state::borrow_mut_pool_registry_and_position_registry_and_minter(state);
        
        let pool = pool_registry::borrow_mut_pool(pool_registry, pool_index);
        assert_version_and_upgrade(pool::uid_mut(pool));
        assert_in_emergency(pool);

        let position = position_registry::borrow_mut_position(
            position_registry,
            pool_index,
            tx_context::sender(ctx)
        );
        
        let amount = position::value(position);
        if(amount > 0) {
            decrease_for<StakedToken>(pool, position, amount, ctx);
        };
    }

    //Stop distributing rewards. This function should only be called when there is a fatal error
    public entry fun stop_reward(_: &AdminCap, state: &mut State) {
        let (i, num_pools) = (0, pool_registry::num_pools(state::borrow_pool_registry(state)));
        while(i < num_pools) {
            let pool = pool_registry::borrow_mut_pool(state::borrow_mut_pool_registry(state), i);
            pool::set_emergency(pool);
            i = i + 1;
        };
        state::set_ostr_per_ms(state, 0);
    }

    fun assert_in_emergency(pool: &Pool) {
        assert!(pool::is_emergency(pool), E_NOT_EMNERGENCY);
    }

    fun assert_not_emergency(pool: &Pool) {
        assert!(!pool::is_emergency(pool), E_IN_EMNERGENCY);
    }

    fun assert_version(pool_id: &UID) {
        let version = df::borrow<VersionDfKey, u64>(pool_id, VersionDfKey {});
        assert!(*version == VERSION, E_WRONG_VERSION);
    }

    fun assert_version_and_upgrade(pool_id: &mut UID) {
        let version = df::borrow_mut<VersionDfKey, u64>(pool_id, VersionDfKey {});

        if (*version < VERSION) {
            *version = VERSION;
        };
        assert_version(pool_id);
    }
}

#[test_only]
module cage::test_operator {
    use sui::object;
    use sui::tx_context;
    use sui::clock;
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::test_scenario;

    use cage::state;
    use cage::operator;
    use cage::pool_registry;
    use cage::pool;
    use cage::position;
    use cage::position_registry;
    use cage::custodian;

    use oyster::ostr;
    use oyster::ostr_minter_role::OSTR_MINTER_ROLE;
    use oyster::ostr_state;

    use pearl::prl::{Self, PRL, TreasuryManagement as PearlTrearsuryManagement};
    use pearl::pearl_minter_role::PEARL_MINTER_ROLE;

    use access_control::access_control::{Self as ac, Role, AdminCap as ACAdmintCap};

    struct USDT has drop {}

    #[test]
    public fun test_create_pool() {
        // let alice = @0xa;
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let state = state::create_for_testing(&mut ctx);

        operator::create_pool_for_testing<SUI>(&mut state, 100, 0, &clock, &mut ctx);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0)) == 100, 1);
        assert!(state::total_alloc_point(&state) == 100, 1);

        operator::create_pool_for_testing<SUI>(&mut state, 200, 0, &clock, &mut ctx);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0)) == 100, 1);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1)) == 200, 1);
        assert!(state::total_alloc_point(&state) == 300, 1);

        clock::destroy_for_testing(clock);
        state::destroy_for_testing(state);
    }

    #[test]
    public fun test_set_alloc_point() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let state = state::create_for_testing(&mut ctx);

        operator::create_pool_for_testing<SUI>(&mut state, 100, 0, &clock, &mut ctx);
        operator::create_pool_for_testing<SUI>(&mut state, 200, 0, &clock, &mut ctx);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0)) == 100, 1);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1)) == 200, 1);
        assert!(state::total_alloc_point(&state) == 300, 1);

        operator::set_alloc_point_for_testing(&mut state, 0, 150, &clock);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0)) == 150, 1);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1)) == 200, 1);
        assert!(state::total_alloc_point(&state) == 350, 1);

        operator::set_alloc_point_for_testing(&mut state, 1, 180, &clock);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0)) == 150, 1);
        assert!(pool::alloc_point(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1)) == 180, 1);
        assert!(state::total_alloc_point(&state) == 330, 1);

        clock::destroy_for_testing(clock);
        state::destroy_for_testing(state);
    }

    #[test]
    public fun test_mass_update_pool() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let state = state::create_for_testing(&mut ctx);
        state::set_ostr_per_ms_for_testing(&mut state, 100);

        operator::create_pool_for_testing<SUI>(&mut state, 100, 0, &clock, &mut ctx);
        operator::create_pool_for_testing<SUI>(&mut state, 400, 0, &clock, &mut ctx);

        pool::increase_staked_amount_for_testing(
            pool_registry::borrow_mut_pool_for_testing(state::borrow_mut_pool_registry_for_testing(&mut state), 0),
            1000
        );
        pool::increase_staked_amount_for_testing(
            pool_registry::borrow_mut_pool_for_testing(state::borrow_mut_pool_registry_for_testing(&mut state), 1),
            5000
        );

        clock::set_for_testing(&mut clock, 100);
        operator::mass_update_pool_for_testing(&mut state, &clock);
        assert!(pool::last_reward_at(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0)) == 100, 1);
        assert!(pool::acc_ostr_per_share(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0)) == 2000000, 1);
        assert!(pool::last_reward_at(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1)) == 100, 1);
        assert!(pool::acc_ostr_per_share(pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1)) == 1600000, 1);

        clock::destroy_for_testing(clock);
        state::destroy_for_testing(state);
    }

    #[test]
    public fun test_increase_position(){
        let alice = @0xa;
        let bob = @0xb;
        let ctx = tx_context::dummy();
        
        let clock = clock::create_for_testing(&mut ctx);
        let state = state::create_for_testing(&mut ctx);
        let ostr_state = ostr_state::create_for_testing(&mut ctx);
        state::set_ostr_per_ms_for_testing(&mut state, 100);
        state::set_pearl_ratio_for_testing(&mut state, 10);
        operator::create_pool_for_testing<SUI>(&mut state, 100, 0, &clock, &mut ctx);

        let scenario = test_scenario::begin(alice);

        test_scenario::next_tx(&mut scenario, alice);
        {
            ac::create_for_testing<OSTR_MINTER_ROLE>(test_scenario::ctx(&mut scenario));
            ac::create_for_testing<PEARL_MINTER_ROLE>(test_scenario::ctx(&mut scenario));
            prl::init_for_testing(test_scenario::ctx(&mut scenario));
        };

        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let admin = test_scenario::take_from_sender<ACAdmintCap<OSTR_MINTER_ROLE>>(&scenario);
            ac::grant_role(&admin, &mut ostr_minter_role, object::id_to_address(state::borrow_ostr_minter_id(&state)), test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_to_sender(&scenario, admin);

            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            let pearl_admin = test_scenario::take_from_sender<ACAdmintCap<PEARL_MINTER_ROLE>>(&scenario);
            ac::grant_role(&pearl_admin, &mut pearl_minter_role, object::id_to_address(state::borrow_pearl_minter_id(&state)), test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(pearl_minter_role);
            test_scenario::return_to_sender(&scenario, pearl_admin)
        };

        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(100, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };

        test_scenario::next_tx(&mut scenario, alice);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 100 &&
                pool::total_token_staked(pool) == 100 && pool::last_reward_at(pool) == 0 && pool::acc_ostr_per_share(pool) == 0,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, alice);
            assert!(position::value(pos) == 100 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 0, 0);
            assert!(!ostr_state::is_registerd(&ostr_state, alice), 0);
        };

        clock::set_for_testing(&mut clock, 50);
        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(10, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, alice);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 110 &&
                pool::total_token_staked(pool) == 110 && pool::last_reward_at(pool) == 50 && pool::acc_ostr_per_share(pool) == 50000000,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, alice);
            assert!(position::value(pos) == 110 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 5500, 0);
            assert!(ostr::balance_of(&ostr_state, alice) == 4500, 0);

            assert!(ostr::balance_of(&ostr_state, alice) == 4500, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 500, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 150);
        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(10, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, alice);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 120 &&
                pool::total_token_staked(pool) == 120 && pool::last_reward_at(pool) == 150 && pool::acc_ostr_per_share(pool) == 140909090,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, alice);
            assert!(position::value(pos) == 120 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 16909, 0);

            assert!(ostr::balance_of(&ostr_state, alice) == 13500, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 999, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 200);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(200, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 320 &&
                pool::total_token_staked(pool) == 320 && pool::last_reward_at(pool) == 200 && pool::acc_ostr_per_share(pool) == 182575756,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 200 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 36515, 0);
            assert!(!ostr_state::is_registerd(&ostr_state, bob), 0);
        };

        clock::set_for_testing(&mut clock, 300);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(50, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 370 &&
                pool::total_token_staked(pool) == 370 && pool::last_reward_at(pool) == 300 && pool::acc_ostr_per_share(pool) == 213825756,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 250 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 53456, 0);

            assert!(ostr::balance_of(&ostr_state, bob) == 5625, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 625, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 1300);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(0, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 370 &&
                pool::total_token_staked(pool) == 370 && pool::last_reward_at(pool) == 1300 && pool::acc_ostr_per_share(pool) == 484096026,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 250 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 121024, 0);

            assert!(ostr::balance_of(&ostr_state, bob) == 66437, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 6756, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 1500);
        operator::set_ostr_per_ms_for_testing(&mut state, 0, &clock);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 370 &&
                pool::total_token_staked(pool) == 370 && pool::last_reward_at(pool) == 1500 && pool::acc_ostr_per_share(pool) == 538150080,
                0
            );

            assert!(ostr::balance_of(&ostr_state, bob) == 66437, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 6756, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 2000);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(0, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 370 &&
                pool::total_token_staked(pool) == 370 && pool::last_reward_at(pool) == 2000 && pool::acc_ostr_per_share(pool) == 538150080,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 250 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 134537, 0);

            assert!(ostr::balance_of(&ostr_state, bob) == 78599, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 1351, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 2500);
        operator::set_ostr_per_ms_for_testing(&mut state, 100, &clock);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 370 &&
                pool::total_token_staked(pool) == 370 && pool::last_reward_at(pool) == 2500 && pool::acc_ostr_per_share(pool) == 538150080,
                0
            );
        };

        clock::set_for_testing(&mut clock, 3000);
        operator::create_pool_for_testing<USDT>(&mut state, 400, 500, &clock, &mut ctx);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<USDT>(
                &mut state, 1, coin::mint_for_testing<USDT>(100, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool_0 = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 370 &&
                pool::total_token_staked(pool_0) == 370 && pool::last_reward_at(pool_0) == 3000 && pool::acc_ostr_per_share(pool_0) == 673285215,
                0
            );
            let pool_1 = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<USDT>(&state, 1)) == 95 &&
                pool::total_token_staked(pool_1) == 95 && pool::last_reward_at(pool_1) == 3000 && pool::acc_ostr_per_share(pool_1) == 0,
                0
            );
        };

        clock::set_for_testing(&mut clock, 3500);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<USDT>(
                &mut state, 1, coin::mint_for_testing<USDT>(0, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool_0 = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 370 &&
                pool::total_token_staked(pool_0) == 370 && pool::last_reward_at(pool_0) == 3000 && pool::acc_ostr_per_share(pool_0) == 673285215,
                0
            );
            let pool_1 = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 1);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<USDT>(&state, 1)) == 95 &&
                pool::total_token_staked(pool_1) == 95 && pool::last_reward_at(pool_1) == 3500 && pool::acc_ostr_per_share(pool_1) == 421052631,
                0
            );

            let pos_0 = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos_0) == 250 && position::pool_idx(pos_0) == 0, 0);
            assert!(position::reward_debt(pos_0) == 134537, 0);
            let pos_1 = position_registry::borrow_position(state::borrow_position_registry(&state), 1, bob);
            assert!(position::value(pos_1) == 95 && position::pool_idx(pos_1) == 1, 0);
            assert!(position::reward_debt(pos_1) == 39999, 0);

            assert!(ostr::balance_of(&ostr_state, bob) == 114599, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 3999, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
        state::destroy_for_testing(state);
        ostr_state::destroy_for_testing(ostr_state);
    }

    #[test]
    public fun test_decrease_position(){
        let alice = @0xa;
        let bob = @0xb;
        let ctx = tx_context::dummy();
        
        let clock = clock::create_for_testing(&mut ctx);
        let state = state::create_for_testing(&mut ctx);
        let ostr_state = ostr_state::create_for_testing(&mut ctx);
        state::set_ostr_per_ms_for_testing(&mut state, 100);
        state::set_pearl_ratio_for_testing(&mut state, 10);
        operator::create_pool_for_testing<SUI>(&mut state, 100, 0, &clock, &mut ctx);

        let scenario = test_scenario::begin(alice);

        test_scenario::next_tx(&mut scenario, alice);
        {
            ac::create_for_testing<OSTR_MINTER_ROLE>(test_scenario::ctx(&mut scenario));
            ac::create_for_testing<PEARL_MINTER_ROLE>(test_scenario::ctx(&mut scenario));
            prl::init_for_testing(test_scenario::ctx(&mut scenario));
        };

        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let admin = test_scenario::take_from_sender<ACAdmintCap<OSTR_MINTER_ROLE>>(&scenario);
            ac::grant_role(&admin, &mut ostr_minter_role, object::id_to_address(state::borrow_ostr_minter_id(&state)), test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_to_sender(&scenario, admin);

            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            let pearl_admin = test_scenario::take_from_sender<ACAdmintCap<PEARL_MINTER_ROLE>>(&scenario);
            ac::grant_role(&pearl_admin, &mut pearl_minter_role, object::id_to_address(state::borrow_pearl_minter_id(&state)), test_scenario::ctx(&mut scenario));
            test_scenario::return_shared(pearl_minter_role);
            test_scenario::return_to_sender(&scenario, pearl_admin)
        };

        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(100, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };

        test_scenario::next_tx(&mut scenario, alice);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 100 &&
                pool::total_token_staked(pool) == 100 && pool::last_reward_at(pool) == 0 && pool::acc_ostr_per_share(pool) == 0,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, alice);
            assert!(position::value(pos) == 100 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 0, 0);
            assert!(!ostr_state::is_registerd(&ostr_state, alice), 0);
        };

        clock::set_for_testing(&mut clock, 50);
        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(10, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, alice);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 110 &&
                pool::total_token_staked(pool) == 110 && pool::last_reward_at(pool) == 50 && pool::acc_ostr_per_share(pool) == 50000000,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, alice);
            assert!(position::value(pos) == 110 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 5500, 0);

            assert!(ostr::balance_of(&ostr_state, alice) == 4500, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 500, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 150);
        test_scenario::next_tx(&mut scenario, alice);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::decrease_position<SUI>(
                &mut state, 0, 10, &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, alice);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 100 &&
                pool::total_token_staked(pool) == 100 && pool::last_reward_at(pool) == 150 && pool::acc_ostr_per_share(pool) == 140909090,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, alice);
            assert!(position::value(pos) == 100 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 14090, 0);
            
            assert!(ostr::balance_of(&ostr_state, alice) == 13500, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 999, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 200);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::increase_position<SUI>(
                &mut state, 0, coin::mint_for_testing<SUI>(200, &mut ctx), &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 300 &&
                pool::total_token_staked(pool) == 300 && pool::last_reward_at(pool) == 200 && pool::acc_ostr_per_share(pool) == 190909090,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 200 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 38181, 0);
            assert!(!ostr_state::is_registerd(&ostr_state, bob), 0);
        };

        clock::set_for_testing(&mut clock, 300);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::decrease_position<SUI>(
                &mut state, 0, 50, &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 250 &&
                pool::total_token_staked(pool) == 250 && pool::last_reward_at(pool) == 300 && pool::acc_ostr_per_share(pool) == 224242423,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 150 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 33636, 0);
            
            assert!(ostr::balance_of(&ostr_state, bob) == 6001, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 666, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 1300);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::decrease_position<SUI>(
                &mut state, 0, 0, &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 250 &&
                pool::total_token_staked(pool) == 250 && pool::last_reward_at(pool) == 1300 && pool::acc_ostr_per_share(pool) == 624242423,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 150 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 93636, 0);

            assert!(ostr::balance_of(&ostr_state, bob) == 60001, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 6000, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 1500);
        operator::set_ostr_per_ms_for_testing(&mut state, 0, &clock);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 250 &&
                pool::total_token_staked(pool) == 250 && pool::last_reward_at(pool) == 1500 && pool::acc_ostr_per_share(pool) == 704242423,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 150 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 93636, 0);

            assert!(ostr::balance_of(&ostr_state, bob) == 60001, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 6000, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        clock::set_for_testing(&mut clock, 2000);
        test_scenario::next_tx(&mut scenario, bob);
        {
            let ostr_minter_role = test_scenario::take_shared<Role<OSTR_MINTER_ROLE>>(&scenario);
            let pearl_treasury_management = test_scenario::take_shared<PearlTrearsuryManagement>(&scenario);
            let pearl_minter_role = test_scenario::take_shared<Role<PEARL_MINTER_ROLE>>(&scenario);
            operator::decrease_position<SUI>(
                &mut state, 0, 0, &mut ostr_state, &ostr_minter_role, &mut pearl_treasury_management, &pearl_minter_role, &clock, test_scenario::ctx(&mut scenario)
            );
            test_scenario::return_shared(ostr_minter_role);
            test_scenario::return_shared(pearl_treasury_management);
            test_scenario::return_shared(pearl_minter_role);
        };
        test_scenario::next_tx(&mut scenario, bob);
        {
            let pool = pool_registry::borrow_pool(state::borrow_pool_registry(&state), 0);
            assert!(
                custodian::reserve(operator::borrow_staked_token_custodian<SUI>(&state, 0)) == 250 &&
                pool::total_token_staked(pool) == 250 && pool::last_reward_at(pool) == 2000 && pool::acc_ostr_per_share(pool) == 704242423,
                0
            );

            let pos = position_registry::borrow_position(state::borrow_position_registry(&state), 0, bob);
            assert!(position::value(pos) == 150 && position::pool_idx(pos) == 0, 0);
            assert!(position::reward_debt(pos) == 105636, 0);

            assert!(ostr::balance_of(&ostr_state, bob) == 70801, 0);
            let pearl_earned = test_scenario::take_from_sender<Coin<PRL>>(&scenario);
            assert!(coin::value(&pearl_earned) == 1200, 0);
            test_scenario::return_to_sender(&scenario, pearl_earned);
        };

        test_scenario::end(scenario);
        clock::destroy_for_testing(clock);
        state::destroy_for_testing(state);
        ostr_state::destroy_for_testing(ostr_state);
    }
}