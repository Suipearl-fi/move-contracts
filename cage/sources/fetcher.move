module cage::fetcher {
    use sui::object::{Self, ID};
    use sui::event;
    use sui::clock::Clock;

    use cage::state::{Self, State};
    use cage::pool;
    use cage::pool_registry;
    use cage::position_registry;

    struct PendingReward has copy, drop {
        position: ID,
        pending_ostr_reward: u64
    }

    public entry fun fetch_pending_reward(
        state: &State,
        pool_index: u64,
        account: address,
        clock: &Clock
    ) {
        let (total_alloc_point, ostr_per_ms) = (state::total_alloc_point(state), state::ostr_per_ms(state));
        let (pool_registry, position_registry) = (state::borrow_pool_registry(state), state::borrow_position_registry(state));

        let position = position_registry::borrow_position(
            position_registry,
            pool_index,
            account
        );

        let pool = pool_registry::borrow_pool(pool_registry, pool_index);
        let pending_ostr_reward = pool::pending_ostr(pool, position, total_alloc_point, ostr_per_ms, clock);

        event::emit(PendingReward {
            position: object::id(position),
            pending_ostr_reward,
        })
    }
}