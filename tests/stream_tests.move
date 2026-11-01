#[test_only]
module aura_stream::stream_tests {
    use std::signer;
    use std::string;
    use aptos_framework::account;
    use aptos_framework::coin::{Self, MintCapability, BurnCapability};
    use aptos_framework::timestamp;
    use aura_stream::stream;

    struct TestCoin has key {}

    struct Caps has key {
        mint_cap: MintCapability<TestCoin>,
        burn_cap: BurnCapability<TestCoin>,
    }

    fun setup_test(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        timestamp::update_global_time_for_test_secs(1000);

        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(sender));
        account::create_account_for_test(signer::address_of(recipient));

        // Initialize mock coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<TestCoin>(
            admin,
            string::utf8(b"Aura Test Coin"),
            string::utf8(b"ATC"),
            8,
            false
        );
        coin::destroy_freeze_cap(freeze_cap);

        move_to(admin, Caps {
            mint_cap,
            burn_cap,
        });

        // Register coin for accounts
        coin::register<TestCoin>(admin);
        coin::register<TestCoin>(sender);
        coin::register<TestCoin>(recipient);

        // Initialize aura stream protocol
        stream::initialize<TestCoin>(admin);
    }

    fun mint_coins(admin: &signer, to: address, amount: u64) acquires Caps {
        let caps = borrow_global<Caps>(signer::address_of(admin));
        let minted = coin::mint<TestCoin>(amount, &caps.mint_cap);
        coin::deposit(to, minted);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    public fun test_create_and_linear_withdraw(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);

        // Stream: 10,000 coins from t=1000 to t=2000 (1000s duration, rate = 10 coins/sec)
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000, // cliff at start
            0,    // cliff amount
            true  // cancellable
        );

        // At t=1000, withdrawable should be 0
        assert!(stream::available_to_withdraw<TestCoin>(admin_addr, 1) == 0, 101);

        // Advance to t=1500 (halfway)
        timestamp::update_global_time_for_test_secs(1500);

        // Halfway: 5,000 tokens should be withdrawable
        let withdrawable = stream::available_to_withdraw<TestCoin>(admin_addr, 1);
        assert!(withdrawable == 5000, 102);

        // Recipient withdraws 3,000 tokens
        stream::withdraw<TestCoin>(recipient, admin_addr, 1, 3000);
        assert!(coin::balance<TestCoin>(recipient_addr) == 3000, 103);

        // Remaining withdrawable should be 2,000 tokens
        assert!(stream::available_to_withdraw<TestCoin>(admin_addr, 1) == 2000, 104);

        // Advance past completion to t=2500
        timestamp::update_global_time_for_test_secs(2500);
        assert!(stream::available_to_withdraw<TestCoin>(admin_addr, 1) == 7000, 105);

        // Withdraw remainder
        stream::withdraw<TestCoin>(recipient, admin_addr, 1, 7000);
        assert!(coin::balance<TestCoin>(recipient_addr) == 10000, 106);
        assert!(stream::available_to_withdraw<TestCoin>(admin_addr, 1) == 0, 107);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    public fun test_cliff_vesting_stream(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);

        // Stream: 10,000 coins from t=1000 to t=2000. Cliff at t=1250 with 2500 coins upfront.
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1250,
            2500,
            false // non-cancellable
        );

        // Before cliff at t=1200: withdrawable should be 0
        timestamp::update_global_time_for_test_secs(1200);
        assert!(stream::available_to_withdraw<TestCoin>(admin_addr, 1) == 0, 201);

        // At cliff at t=1250: exact cliff amount 2500 unlocked
        timestamp::update_global_time_for_test_secs(1250);
        assert!(stream::available_to_withdraw<TestCoin>(admin_addr, 1) == 2500, 202);

        // Halfway past cliff at t=1625: 2500 + 0.5 * 7500 = 6250
        timestamp::update_global_time_for_test_secs(1625);
        assert!(stream::available_to_withdraw<TestCoin>(admin_addr, 1) == 6250, 203);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    public fun test_cancel_stream_with_refund(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);

        // 10,000 coins over 1000 seconds
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            true
        );

        // Advance to 40% (t=1400)
        timestamp::update_global_time_for_test_secs(1400);

        // Recipient withdraws 1,000
        stream::withdraw<TestCoin>(recipient, admin_addr, 1, 1000);
        assert!(coin::balance<TestCoin>(recipient_addr) == 1000, 301);

        // Cancel stream at t=1400:
        // Streamed = 4000. Recipient claimed 1000 -> recipient gets 3000 more.
        // Sender gets refunded remaining 6000.
        stream::cancel<TestCoin>(sender, admin_addr, 1);

        assert!(coin::balance<TestCoin>(recipient_addr) == 4000, 302);
        assert!(coin::balance<TestCoin>(sender_addr) == 6000, 303);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200, charlie = @0x300)]
    public fun test_transfer_recipient(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer,
        charlie: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);
        account::create_account_for_test(signer::address_of(charlie));
        coin::register<TestCoin>(charlie);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);
        let charlie_addr = signer::address_of(charlie);

        mint_coins(admin, sender_addr, 10000);

        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            true
        );

        // Advance to t=1300
        timestamp::update_global_time_for_test_secs(1300);

        // Recipient transfers ownership of stream to Charlie
        stream::transfer_recipient<TestCoin>(recipient, admin_addr, 1, charlie_addr);

        // Verify details reflect Charlie
        let (_, new_rec, _, _, _, _, _, _, _, _) = stream::get_stream_details<TestCoin>(admin_addr, 1);
        assert!(new_rec == charlie_addr, 401);

        // Charlie withdraws funds
        stream::withdraw<TestCoin>(charlie, admin_addr, 1, 3000);
        assert!(coin::balance<TestCoin>(charlie_addr) == 3000, 402);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    public fun test_pause_and_resume_stream(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);

        // 10,000 coins over 1000s (10 coins/sec) from t=1000 to t=2000
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            true
        );

        // At t=1200 (200s active = 2000 coins), sender pauses the stream
        timestamp::update_global_time_for_test_secs(1200);
        stream::pause<TestCoin>(sender, admin_addr, 1);

        // 300 seconds elapse while paused (t=1500)
        timestamp::update_global_time_for_test_secs(1500);

        // Streamed amount remains frozen at 2000 coins
        let (withdrawable_frozen) = stream::available_to_withdraw<TestCoin>(admin_addr, 1);
        assert!(withdrawable_frozen == 2000, 501);

        // Resume stream at t=1500
        stream::resume<TestCoin>(sender, admin_addr, 1);

        // Advance another 200 seconds to t=1700 (400 active seconds total = 4000 coins)
        timestamp::update_global_time_for_test_secs(1700);
        let withdrawable_resumed = stream::available_to_withdraw<TestCoin>(admin_addr, 1);
        assert!(withdrawable_resumed == 4000, 502);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200, attacker = @0x666)]
    #[expected_failure(abort_code = 7, location = aura_stream::stream)]
    public fun test_unauthorized_withdraw_fails(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer,
        attacker: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);
        account::create_account_for_test(signer::address_of(attacker));
        coin::register<TestCoin>(attacker);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            true
        );

        timestamp::update_global_time_for_test_secs(1500);

        // Attacker attempts to withdraw from someone else's stream -> must abort with ENOT_RECIPIENT (7)
        stream::withdraw<TestCoin>(attacker, admin_addr, 1, 1000);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    #[expected_failure(abort_code = 9, location = aura_stream::stream)]
    public fun test_non_cancellable_cannot_be_cancelled(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            false // Non-cancellable
        );

        timestamp::update_global_time_for_test_secs(1500);

        // Sender attempts to cancel non-cancellable stream -> must abort with ENOT_CANCELLABLE (9)
        stream::cancel<TestCoin>(sender, admin_addr, 1);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    #[expected_failure(abort_code = 10, location = aura_stream::stream)]
    public fun test_withdraw_exceeds_available_fails(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            true
        );

        timestamp::update_global_time_for_test_secs(1200); // 2000 tokens available

        // Recipient attempts to withdraw 5000 -> must abort with EAMOUNT_EXCEEDS_WITHDRAWABLE (10)
        stream::withdraw<TestCoin>(recipient, admin_addr, 1, 5000);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    #[expected_failure(abort_code = 11, location = aura_stream::stream)]
    public fun test_zero_withdrawal_fails(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            true
        );

        timestamp::update_global_time_for_test_secs(1500);

        // Attempt zero withdrawal -> must abort with EZERO_WITHDRAWAL (11)
        stream::withdraw<TestCoin>(recipient, admin_addr, 1, 0);
    }

    #[test(aptos_framework = @0x1, admin = @aura_stream, sender = @0x100, recipient = @0x200)]
    #[expected_failure(abort_code = 14, location = aura_stream::stream)]
    public fun test_same_recipient_transfer_fails(
        aptos_framework: &signer,
        admin: &signer,
        sender: &signer,
        recipient: &signer
    ) acquires Caps {
        setup_test(aptos_framework, admin, sender, recipient);

        let admin_addr = signer::address_of(admin);
        let sender_addr = signer::address_of(sender);
        let recipient_addr = signer::address_of(recipient);

        mint_coins(admin, sender_addr, 10000);
        stream::create_stream<TestCoin>(
            sender,
            admin_addr,
            recipient_addr,
            10000,
            1000,
            2000,
            1000,
            0,
            true
        );

        // Transfer to self -> must abort with ESAME_RECIPIENT (14)
        stream::transfer_recipient<TestCoin>(recipient, admin_addr, 1, recipient_addr);
    }
}
