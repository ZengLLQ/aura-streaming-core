module aura_stream::stream {
    use std::signer;
    use std::vector;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::table::{Self, Table};
    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};

    /// Error codes
    const EALREADY_INITIALIZED: u64 = 1;
    const ENOT_INITIALIZED: u64 = 2;
    const EINVALID_TIME_RANGE: u64 = 3;
    const EINVALID_DEPOSIT_AMOUNT: u64 = 4;
    const EINVALID_CLIFF: u64 = 5;
    const ESTREAM_NOT_FOUND: u64 = 6;
    const ENOT_RECIPIENT: u64 = 7;
    const ENOT_SENDER: u64 = 8;
    const ENOT_CANCELLABLE: u64 = 9;
    const EAMOUNT_EXCEEDS_WITHDRAWABLE: u64 = 10;
    const EZERO_WITHDRAWAL: u64 = 11;
    const ESTREAM_PAUSED: u64 = 12;
    const ESTREAM_NOT_PAUSED: u64 = 13;
    const ESAME_RECIPIENT: u64 = 14;

    /// Stream data representation
    struct Stream<phantom CoinType> has store {
        sender: address,
        recipient: address,
        deposit_amount: u64,
        claimed_amount: u64,
        start_time: u64,
        stop_time: u64,
        cliff_time: u64,
        cliff_amount: u64,
        cancellable: bool,
        is_paused: bool,
        pause_start_time: u64,
        total_paused_duration: u64,
        escrow: Coin<CoinType>,
    }

    /// Global registry stored at the module publisher's address
    struct StreamRegistry<phantom CoinType> has key {
        stream_counter: u64,
        streams: Table<u64, Stream<CoinType>>,
        sender_streams: Table<address, vector<u64>>,
        recipient_streams: Table<address, vector<u64>>,
        create_stream_events: EventHandle<CreateStreamEvent>,
        withdraw_events: EventHandle<WithdrawEvent>,
        cancel_events: EventHandle<CancelStreamEvent>,
        transfer_events: EventHandle<TransferRecipientEvent>,
    }

    /// Events
    struct CreateStreamEvent has drop, store {
        stream_id: u64,
        sender: address,
        recipient: address,
        deposit_amount: u64,
        start_time: u64,
        stop_time: u64,
        cliff_time: u64,
        cancellable: bool,
    }

    struct WithdrawEvent has drop, store {
        stream_id: u64,
        recipient: address,
        amount: u64,
        withdrawn_at: u64,
    }

    struct CancelStreamEvent has drop, store {
        stream_id: u64,
        sender: address,
        recipient: address,
        recipient_balance: u64,
        sender_refund: u64,
        cancelled_at: u64,
    }

    struct TransferRecipientEvent has drop, store {
        stream_id: u64,
        old_recipient: address,
        new_recipient: address,
    }

    /// Initialize the streaming protocol for a specific CoinType
    public entry fun initialize<CoinType>(account: &signer) {
        let addr = signer::address_of(account);
        assert!(!exists<StreamRegistry<CoinType>>(addr), EALREADY_INITIALIZED);

        move_to(account, StreamRegistry<CoinType> {
            stream_counter: 0,
            streams: table::new(),
            sender_streams: table::new(),
            recipient_streams: table::new(),
            create_stream_events: account::new_event_handle<CreateStreamEvent>(account),
            withdraw_events: account::new_event_handle<WithdrawEvent>(account),
            cancel_events: account::new_event_handle<CancelStreamEvent>(account),
            transfer_events: account::new_event_handle<TransferRecipientEvent>(account),
        });
    }

    /// Create a continuous token stream
    public entry fun create_stream<CoinType>(
        sender: &signer,
        registry_owner: address,
        recipient: address,
        deposit_amount: u64,
        start_time: u64,
        stop_time: u64,
        cliff_time: u64,
        cliff_amount: u64,
        cancellable: bool
    ) acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);
        assert!(deposit_amount > 0, EINVALID_DEPOSIT_AMOUNT);
        assert!(start_time < stop_time, EINVALID_TIME_RANGE);
        assert!(cliff_time >= start_time && cliff_time <= stop_time, EINVALID_CLIFF);
        assert!(cliff_amount <= deposit_amount, EINVALID_CLIFF);

        let sender_addr = signer::address_of(sender);
        let registry = borrow_global_mut<StreamRegistry<CoinType>>(registry_owner);

        let stream_id = registry.stream_counter + 1;
        registry.stream_counter = stream_id;

        // Escrow funds from sender into stream
        let coin_escrow = coin::withdraw<CoinType>(sender, deposit_amount);

        let stream = Stream<CoinType> {
            sender: sender_addr,
            recipient,
            deposit_amount,
            claimed_amount: 0,
            start_time,
            stop_time,
            cliff_time,
            cliff_amount,
            cancellable,
            is_paused: false,
            pause_start_time: 0,
            total_paused_duration: 0,
            escrow: coin_escrow,
        };

        table::add(&mut registry.streams, stream_id, stream);

        // Track sender streams
        if (!table::contains(&registry.sender_streams, sender_addr)) {
            table::add(&mut registry.sender_streams, sender_addr, vector::empty<u64>());
        };
        let s_list = table::borrow_mut(&mut registry.sender_streams, sender_addr);
        vector::push_back(s_list, stream_id);

        // Track recipient streams
        if (!table::contains(&registry.recipient_streams, recipient)) {
            table::add(&mut registry.recipient_streams, recipient, vector::empty<u64>());
        };
        let r_list = table::borrow_mut(&mut registry.recipient_streams, recipient);
        vector::push_back(r_list, stream_id);

        event::emit_event(&mut registry.create_stream_events, CreateStreamEvent {
            stream_id,
            sender: sender_addr,
            recipient,
            deposit_amount,
            start_time,
            stop_time,
            cliff_time,
            cancellable,
        });
    }

    /// Calculate unlocked streamed amount at current block timestamp
    public fun calculate_streamed_amount<CoinType>(
        stream: &Stream<CoinType>,
        current_time: u64
    ): u64 {
        if (current_time <= stream.start_time || current_time < stream.cliff_time) {
            return 0
        };

        let effective_time = current_time;
        if (stream.is_paused) {
            effective_time = stream.pause_start_time;
        };

        // Adjust for cumulative paused duration
        if (effective_time <= stream.total_paused_duration + stream.start_time) {
            return 0
        };
        let adjusted_time = effective_time - stream.total_paused_duration;

        if (adjusted_time >= stream.stop_time) {
            return stream.deposit_amount
        };

        // Linear interpolation from cliff to stop time
        let total_vesting_duration = (stream.stop_time - stream.cliff_time as u128);
        if (total_vesting_duration == 0) {
            return stream.deposit_amount
        };

        let time_since_cliff = (adjusted_time - stream.cliff_time as u128);
        let remaining_to_vest = (stream.deposit_amount - stream.cliff_amount as u128);

        let vested_after_cliff = (remaining_to_vest * time_since_cliff) / total_vesting_duration;
        let total_vested = (stream.cliff_amount as u128) + vested_after_cliff;

        (total_vested as u64)
    }

    #[view]
    /// View withdrawable tokens for a stream
    public fun available_to_withdraw<CoinType>(
        registry_owner: address,
        stream_id: u64
    ): u64 acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);
        let registry = borrow_global<StreamRegistry<CoinType>>(registry_owner);
        assert!(table::contains(&registry.streams, stream_id), ESTREAM_NOT_FOUND);

        let stream = table::borrow(&registry.streams, stream_id);
        let current_time = timestamp::now_seconds();
        let streamed = calculate_streamed_amount(stream, current_time);

        if (streamed > stream.claimed_amount) {
            streamed - stream.claimed_amount
        } else {
            0
        }
    }

    /// Withdraw unlocked funds from stream
    public entry fun withdraw<CoinType>(
        recipient: &signer,
        registry_owner: address,
        stream_id: u64,
        amount: u64
    ) acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);
        assert!(amount > 0, EZERO_WITHDRAWAL);

        let recipient_addr = signer::address_of(recipient);
        let registry = borrow_global_mut<StreamRegistry<CoinType>>(registry_owner);
        assert!(table::contains(&registry.streams, stream_id), ESTREAM_NOT_FOUND);

        let stream = table::borrow_mut(&mut registry.streams, stream_id);
        assert!(stream.recipient == recipient_addr, ENOT_RECIPIENT);
        assert!(!stream.is_paused, ESTREAM_PAUSED);

        let current_time = timestamp::now_seconds();
        let streamed = calculate_streamed_amount(stream, current_time);
        assert!(streamed >= stream.claimed_amount, EAMOUNT_EXCEEDS_WITHDRAWABLE);

        let withdrawable = streamed - stream.claimed_amount;
        assert!(amount <= withdrawable, EAMOUNT_EXCEEDS_WITHDRAWABLE);

        stream.claimed_amount = stream.claimed_amount + amount;

        // Transfer funds from escrow to recipient
        let payout = coin::extract(&mut stream.escrow, amount);
        coin::deposit(recipient_addr, payout);

        event::emit_event(&mut registry.withdraw_events, WithdrawEvent {
            stream_id,
            recipient: recipient_addr,
            amount,
            withdrawn_at: current_time,
        });
    }

    /// Cancel a stream, sending streamed portion to recipient and refunding remainder to sender
    public entry fun cancel<CoinType>(
        sender: &signer,
        registry_owner: address,
        stream_id: u64
    ) acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);

        let sender_addr = signer::address_of(sender);
        let registry = borrow_global_mut<StreamRegistry<CoinType>>(registry_owner);
        assert!(table::contains(&registry.streams, stream_id), ESTREAM_NOT_FOUND);

        let stream = table::borrow_mut(&mut registry.streams, stream_id);
        assert!(stream.sender == sender_addr, ENOT_SENDER);
        assert!(stream.cancellable, ENOT_CANCELLABLE);

        let current_time = timestamp::now_seconds();
        let streamed = calculate_streamed_amount(stream, current_time);
        let recipient_owed = if (streamed > stream.claimed_amount) {
            streamed - stream.claimed_amount
        } else {
            0
        };

        let recipient_addr = stream.recipient;
        let sender_refund = stream.deposit_amount - stream.claimed_amount - recipient_owed;

        // Payout recipient owed amount
        if (recipient_owed > 0) {
            let recipient_coin = coin::extract(&mut stream.escrow, recipient_owed);
            coin::deposit(recipient_addr, recipient_coin);
        };

        // Refund sender remainder
        if (sender_refund > 0) {
            let sender_coin = coin::extract(&mut stream.escrow, sender_refund);
            coin::deposit(sender_addr, sender_coin);
        };

        stream.claimed_amount = streamed;

        event::emit_event(&mut registry.cancel_events, CancelStreamEvent {
            stream_id,
            sender: sender_addr,
            recipient: recipient_addr,
            recipient_balance: recipient_owed,
            sender_refund,
            cancelled_at: current_time,
        });
    }

    /// Transfer stream ownership to a new recipient
    public entry fun transfer_recipient<CoinType>(
        recipient: &signer,
        registry_owner: address,
        stream_id: u64,
        new_recipient: address
    ) acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);

        let recipient_addr = signer::address_of(recipient);
        assert!(new_recipient != recipient_addr, ESAME_RECIPIENT);

        let registry = borrow_global_mut<StreamRegistry<CoinType>>(registry_owner);
        assert!(table::contains(&registry.streams, stream_id), ESTREAM_NOT_FOUND);

        let stream = table::borrow_mut(&mut registry.streams, stream_id);
        assert!(stream.recipient == recipient_addr, ENOT_RECIPIENT);

        stream.recipient = new_recipient;

        // Track under new recipient
        if (!table::contains(&registry.recipient_streams, new_recipient)) {
            table::add(&mut registry.recipient_streams, new_recipient, vector::empty<u64>());
        };
        let r_list = table::borrow_mut(&mut registry.recipient_streams, new_recipient);
        vector::push_back(r_list, stream_id);

        event::emit_event(&mut registry.transfer_events, TransferRecipientEvent {
            stream_id,
            old_recipient: recipient_addr,
            new_recipient,
        });
    }

    /// Pause stream (only sender can pause a cancellable stream)
    public entry fun pause<CoinType>(
        sender: &signer,
        registry_owner: address,
        stream_id: u64
    ) acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);

        let sender_addr = signer::address_of(sender);
        let registry = borrow_global_mut<StreamRegistry<CoinType>>(registry_owner);
        assert!(table::contains(&registry.streams, stream_id), ESTREAM_NOT_FOUND);

        let stream = table::borrow_mut(&mut registry.streams, stream_id);
        assert!(stream.sender == sender_addr, ENOT_SENDER);
        assert!(stream.cancellable, ENOT_CANCELLABLE);
        assert!(!stream.is_paused, ESTREAM_PAUSED);

        stream.is_paused = true;
        stream.pause_start_time = timestamp::now_seconds();
    }

    /// Resume stream
    public entry fun resume<CoinType>(
        sender: &signer,
        registry_owner: address,
        stream_id: u64
    ) acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);

        let sender_addr = signer::address_of(sender);
        let registry = borrow_global_mut<StreamRegistry<CoinType>>(registry_owner);
        assert!(table::contains(&registry.streams, stream_id), ESTREAM_NOT_FOUND);

        let stream = table::borrow_mut(&mut registry.streams, stream_id);
        assert!(stream.sender == sender_addr, ENOT_SENDER);
        assert!(stream.is_paused, ESTREAM_NOT_PAUSED);

        let now = timestamp::now_seconds();
        let paused_duration = now - stream.pause_start_time;
        stream.total_paused_duration = stream.total_paused_duration + paused_duration;
        stream.is_paused = false;
        stream.pause_start_time = 0;
    }

    #[view]
    /// View function for stream metadata
    public fun get_stream_details<CoinType>(
        registry_owner: address,
        stream_id: u64
    ): (address, address, u64, u64, u64, u64, u64, u64, bool, bool) acquires StreamRegistry {
        assert!(exists<StreamRegistry<CoinType>>(registry_owner), ENOT_INITIALIZED);
        let registry = borrow_global<StreamRegistry<CoinType>>(registry_owner);
        assert!(table::contains(&registry.streams, stream_id), ESTREAM_NOT_FOUND);

        let stream = table::borrow(&registry.streams, stream_id);
        (
            stream.sender,
            stream.recipient,
            stream.deposit_amount,
            stream.claimed_amount,
            stream.start_time,
            stream.stop_time,
            stream.cliff_time,
            stream.cliff_amount,
            stream.cancellable,
            stream.is_paused
        )
    }
}
