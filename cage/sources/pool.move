module cage::pool {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::clock::{Self, Clock};

    use cage::position::{Self, Position};

    friend cage::operator;

    const STARTED_AT_MS: u64 = 1695712500000u64;
    const ENEDED_AT_MS: u64 = 1699600500000u64;

    const PRECISION: u256 = 1000000u256;

    const E_INSUFFICIENT_AMOUNT: u64 = 0;

    struct Pool has key, store {
        id: UID,
        alloc_point: u64,
        total_token_staked: u64,
        acc_ostr_per_share: u256,
        last_reward_at_ms: u64,
        is_emergency: bool
    }

    fun new(ctx: &mut TxContext): Pool {
        Pool {
            id: object::new(ctx),
            alloc_point: 0,
            total_token_staked: 0,
            acc_ostr_per_share: 0,
            last_reward_at_ms: 0,
            is_emergency: false
        }
    }

    public fun get_multiplier(
        pool: &Pool,
        to: u64
    ): u64 {
        let from = pool.last_reward_at_ms;
        if (from >= ENEDED_AT_MS) {
            return 0
        } else if (to > ENEDED_AT_MS) {
            to = ENEDED_AT_MS;
        };
        (to - from)
    }

    public fun uid(self: &Pool): &UID { &self.id }

    public fun uid_mut(self: &mut Pool): &mut UID { &mut self.id }

    public fun alloc_point(self: &Pool): u64 { self.alloc_point }

    public fun total_token_staked(self: &Pool): u64 { self.total_token_staked }

    public fun acc_ostr_per_share(self: &Pool): u256 { self.acc_ostr_per_share }

    public fun last_reward_at(self: &Pool): u64 { self.last_reward_at_ms }

    public fun is_emergency(self: &Pool): bool { self.is_emergency }

    public fun calc_rewards_for(
        self: &Pool,
        position: &Position
    ): u256 { 
        ((position::value(position) as u256) * self.acc_ostr_per_share / PRECISION)
    }

    public fun calc_pending_rewards(
        self: &Pool,
        position: &Position
    ): u64 {
        let ostr_reward = calc_rewards_for(self, position);
        ((ostr_reward - position::reward_debt(position)) as u64)
    }

    public fun pending_ostr(
        self: &Pool,
        position: &Position,
        total_alloc_point: u64,
        ostr_per_ms: u64,
        clock: &Clock
    ): u64 {
        let now = clock::timestamp_ms(clock);
        let acc_ostr_per_share = self.acc_ostr_per_share;
        if (now > self.last_reward_at_ms && self.total_token_staked != 0) {
            let multiplier = get_multiplier(self, now);
            let ostr_reward = multiplier * ostr_per_ms * self.alloc_point / total_alloc_point;
            acc_ostr_per_share = acc_ostr_per_share + ((ostr_reward as u256) * PRECISION / (self.total_token_staked as u256));
        };
        ((((position::value(position) as u256) * acc_ostr_per_share / PRECISION) - position::reward_debt(position)) as u64)
    }

    public(friend) fun increase_staked_amount(self: &mut Pool, amount: u64) {
        self.total_token_staked = self.total_token_staked + amount;
    }

    #[test_only]
    public fun increase_staked_amount_for_testing(self: &mut Pool, amount: u64) {
        increase_staked_amount(self, amount);
    }

    public(friend) fun decrease_staked_amount(self: &mut Pool, amount: u64) {
        assert!(self.total_token_staked >= amount, E_INSUFFICIENT_AMOUNT);
        self.total_token_staked = self.total_token_staked - amount;
    }

    #[test_only]
    public fun decreae_staked_amount_for_testing(self: &mut Pool, amount: u64) {
        decrease_staked_amount(self, amount);
    }

    public(friend) fun update_pool(
        self: &mut Pool,
        total_alloc_point: u64,
        ostr_per_ms: u64,
        clock: &Clock
    ) {
        if(clock::timestamp_ms(clock) <= self.last_reward_at_ms) {
            return
        };

        if (self.total_token_staked == 0){
            self.last_reward_at_ms = clock::timestamp_ms(clock);
            return
        };

        let multiplier = get_multiplier(self, clock::timestamp_ms(clock));
        let ostr_reward = multiplier * ostr_per_ms * self.alloc_point / total_alloc_point;
        self.acc_ostr_per_share = self.acc_ostr_per_share + ((ostr_reward as u256) * PRECISION / (self.total_token_staked as u256));
        self.last_reward_at_ms = clock::timestamp_ms(clock);
    }

    #[test_only]
    public fun update_pool_for_testing(
        self: &mut Pool,
        total_alloc_point: u64,
        ostr_per_ms: u64,
        clock: &Clock
    ){
        update_pool(self, total_alloc_point, ostr_per_ms, clock);
    }

    public(friend) fun create_pool(
        alloc_point: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Pool {
        let pool = new(ctx);
        pool.alloc_point = alloc_point;
        pool.last_reward_at_ms = if (clock::timestamp_ms(clock) > STARTED_AT_MS) {
            clock::timestamp_ms(clock)
        } else {
            STARTED_AT_MS
        };

        pool
    }

    public(friend) fun set_alloc_point(
        pool: &mut Pool,
        alloc_point: u64
    ) {
        pool.alloc_point = alloc_point;
    }

    public(friend) fun set_emergency(self: &mut Pool) {
        self.is_emergency = true;
    }

    #[test_only]
    public fun create_for_testing(
        alloc_point: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): Pool{
        create_pool(alloc_point, clock, ctx)
    }

    #[test_only]
    public fun set_last_reward_for_testing(pool: &mut Pool, last_reward_at: u64) {
        pool.last_reward_at_ms = last_reward_at;
    }

    #[test_only]
    public fun destroy_for_testing(pool: Pool){
        let Pool { id, alloc_point: _, total_token_staked: _, acc_ostr_per_share: _, last_reward_at_ms: _, is_emergency: _ } = pool;
        object::delete(id);
    }
}

#[test_only]
module cage::test_pool {
    use sui::tx_context;
    use sui::clock;

    use cage::pool;
    
    struct USDT has drop {}

    struct USDC has drop {}


    #[test]
    public fun test_get_multiplier() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let pool = pool::create_for_testing(500, &clock, &mut ctx);

        assert!(pool::get_multiplier(&pool, 0) == 0, 1); 
        assert!(pool::get_multiplier(&pool, 150) == 150, 1); 
        assert!(pool::get_multiplier(&pool, 1100) == 1100, 1);

        //3888000000u64
        pool::set_last_reward_for_testing(&mut pool, 1000);
        assert!(pool::get_multiplier(&pool, 2000) == 1000, 1);

        assert!(pool::get_multiplier(&pool, 3888000001) == 3887999000, 1);

        pool::set_last_reward_for_testing(&mut pool, 3888000000u64);
        assert!(pool::get_multiplier(&pool, 3888000001) == 0, 1);

        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
    }

    #[test]
    public fun test_create_pool(){
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        clock::set_for_testing(&mut clock, 100);

        let pool = pool::create_for_testing(500, &clock, &mut ctx);

        assert!(pool::alloc_point(&pool) == 500, 1);
        assert!(pool::acc_ostr_per_share(&pool) == 0, 1);
        assert!(pool::last_reward_at(&pool) == 100, 1);
        assert!(pool::is_emergency(&pool) == false, 1);

        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
    }

    #[test]
    public fun test_update_pool() {
        let ctx = tx_context::dummy();
        let clock = clock::create_for_testing(&mut ctx);
        let pool = pool::create_for_testing(500, &clock, &mut ctx);

        clock::set_for_testing(&mut clock, 50);
        pool::update_pool_for_testing(&mut pool, 2000, 100, &clock);
        assert!(pool::last_reward_at(&pool) == 50, 1);
        assert!(pool::acc_ostr_per_share(&pool) == 0, 1);

        clock::set_for_testing(&mut clock, 150);
        pool::update_pool_for_testing(&mut pool, 2000, 100, &clock);
        assert!(pool::last_reward_at(&pool) == 150, 1);
        assert!(pool::acc_ostr_per_share(&pool) == 0, 1);

        pool::increase_staked_amount_for_testing(&mut pool, 100);
        clock::set_for_testing(&mut clock, 200);
        pool::update_pool_for_testing(&mut pool, 2000, 100, &clock);
        assert!(pool::last_reward_at(&pool) == 200, 1);
        assert!(pool::acc_ostr_per_share(&pool) == 12500000, 1);

        pool::increase_staked_amount_for_testing(&mut pool, 200);
        clock::set_for_testing(&mut clock, 300);
        pool::update_pool_for_testing(&mut pool, 2000, 100, &clock);
        assert!(pool::last_reward_at(&pool) == 300, 1);
        assert!(pool::acc_ostr_per_share(&pool) == 20833333, 1);

        clock::set_for_testing(&mut clock, 1000);
        pool::update_pool_for_testing(&mut pool, 2000, 100, &clock);
        assert!(pool::last_reward_at(&pool) == 1000, 1);
        assert!(pool::acc_ostr_per_share(&pool) == 79166666, 1);

        clock::set_for_testing(&mut clock, 1500);
        pool::update_pool_for_testing(&mut pool, 2000, 0, &clock);
        assert!(pool::last_reward_at(&pool) == 1500, 1);
        assert!(pool::acc_ostr_per_share(&pool) == 79166666, 1);

        pool::destroy_for_testing(pool);
        clock::destroy_for_testing(clock);
    }
}