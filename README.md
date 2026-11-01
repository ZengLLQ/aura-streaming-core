# Aura Streaming Core

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Language: Move (Aptos)](https://img.shields.io/badge/Language-Move%20(Aptos)-blue.svg)](https://aptos.dev/)
[![Tests: 10/10 Passed](https://img.shields.io/badge/Tests-10%2F10%20Passed-brightgreen.svg)](#testing--verification)
[![Security: Linear Resource Safety](https://img.shields.io/badge/Security-Resource%20Safety-purple.svg)](#formal-resource-safety)

> High-throughput, continuous token streaming & linear vesting protocol written in **Move on Aptos**. Enables second-by-second programmatic payroll, token vesting schedules, dynamic cliff unlocks, and transferable stream ownership with zero reentrancy hazards.

---

## Architecture & Resource Model

Aura Streaming Core leverages Move's first-class resource semantics. Streams hold non-copyable, non-droppable `Coin<CoinType>` vaults in escrow, guaranteeing that tokens cannot be duplicated, leaked, or drained.

```mermaid
graph TD
    Sender([Sender / Employer])
    Recipient([Recipient / Employee])
    
    subgraph Aura Streaming Protocol (Move on Aptos)
        Registry[StreamRegistry<CoinType><br/><i>Global Stream Catalog & Event Handles</i>]
        StreamObj[Stream<CoinType><br/><i>Escrow Vault, Timestamps, Rates</i>]
        Escrow[(Coin<CoinType> Escrow<br/><i>Linear Asset Vault</i>)]
    end

    Sender -->|create_stream| Registry
    Registry --> StreamObj
    StreamObj --> Escrow
    Recipient -->|withdraw| StreamObj
    StreamObj -->|extract & deposit| Recipient
    Sender -->|cancel / pause / resume| StreamObj
    Recipient -->|transfer_recipient| StreamObj
```

---

## Mathematical Formulation

### 1. Continuous Linear Streaming
Let a stream have total deposit $D$, start timestamp $t_{\text{start}}$, and stop timestamp $t_{\text{stop}}$. For any current timestamp $t$:

$$\text{effective\_time}(t) = \max\left(0, t - t_{\text{start}} - \Delta t_{\text{paused}}\right)$$

$$\text{duration} = t_{\text{stop}} - t_{\text{start}}$$

- If $t \le t_{\text{start}}$ or $t < t_{\text{cliff}}$:
  $$\text{streamed}(t) = 0$$
- If $t \ge t_{\text{stop}} + \Delta t_{\text{paused}}$:
  $$\text{streamed}(t) = D$$
- Otherwise, for $t_{\text{cliff}} \le t < t_{\text{stop}}$:
  $$\text{streamed}(t) = D_{\text{cliff}} + (D - D_{\text{cliff}}) \times \frac{\text{adjusted\_time} - t_{\text{cliff}}}{t_{\text{stop}} - t_{\text{cliff}}}$$

### 2. Available Withdrawable Balance
The amount available for the recipient to claim at any time $t$ is strictly bounded:

$$\text{withdrawable}(t) = \text{streamed}(t) - \text{claimed\_amount}$$

### 3. Mutual Cancellation & Proportional Settlement
When a cancellable stream is cancelled by the sender at timestamp $t$:
- **Recipient Payout:** $\text{owed} = \text{streamed}(t) - \text{claimed\_amount}$
- **Sender Refund:** $\text{refund} = D - \text{claimed\_amount} - \text{owed}$
- **Invariant Conservation:** $\text{claimed\_amount} + \text{owed} + \text{refund} = D$

---

## Key Protocol Features

- **Generic Fungible Asset Support:** Supports any token satisfying Aptos's `CoinType` interface.
- **Cliff Vesting Dynamics:** Configure optional upfront cliff unlock ($t_{\text{cliff}}, D_{\text{cliff}}$) followed by continuous linear tail streaming.
- **Dynamic Recipient Transfer:** Recipients can transfer stream ownership to a new address (enabling transferable salary contracts, stream sales, and DAO routing).
- **Time Dilation via Pause / Resume:** Senders can pause cancellable streams during disputes or performance milestones; the elapsed pause time is accumulated to proportionally extend the stop time.
- **Event-Driven Auditability:** Complete emission of `CreateStreamEvent`, `WithdrawEvent`, `CancelStreamEvent`, and `TransferRecipientEvent`.

---

## Formal Resource Safety

Move provides critical security guarantees over EVM architectures:
1. **Zero Reentrancy Hazards:** Move's execution model and absence of dynamic external callbacks eliminate flash loan reentrancy vectors by design.
2. **Bytecode Resource Verifier:** The `Coin<CoinType>` escrow cannot be deleted or overwritten without explicitly calling `coin::extract` and depositing into an account.
3. **Strict Capability & Ownership Checks:** Only the registered recipient can invoke `withdraw` or `transfer_recipient`, and only the original sender can invoke `cancel` or `pause`.

---

## Testing & Verification

A comprehensive Move unit testing suite with 10 test vectors exercises linear flows, cliff unlocks, time warping, and unauthorized intrusion vectors:

```bash
# Run Move unit test suite
aptos move test

# Compile Move package
aptos move compile
```

### Test Suite Execution
```
Running Move unit tests
[ PASS    ] 0xcafe::stream_tests::test_cancel_stream_with_refund
[ PASS    ] 0xcafe::stream_tests::test_cliff_vesting_stream
[ PASS    ] 0xcafe::stream_tests::test_create_and_linear_withdraw
[ PASS    ] 0xcafe::stream_tests::test_non_cancellable_cannot_be_cancelled
[ PASS    ] 0xcafe::stream_tests::test_pause_and_resume_stream
[ PASS    ] 0xcafe::stream_tests::test_same_recipient_transfer_fails
[ PASS    ] 0xcafe::stream_tests::test_transfer_recipient
[ PASS    ] 0xcafe::stream_tests::test_unauthorized_withdraw_fails
[ PASS    ] 0xcafe::stream_tests::test_withdraw_exceeds_available_fails
[ PASS    ] 0xcafe::stream_tests::test_zero_withdrawal_fails
Test result: OK. Total tests: 10; passed: 10; failed: 0
```

---

## Project Structure

```
aura-streaming-core/
├── Move.toml                 # Package manifest and Aptos Framework dependencies
├── sources/
│   └── stream.move           # Core streaming engine, escrow vault, and entrypoints
├── tests/
│   └── stream_tests.move     # Comprehensive unit tests (10 test vectors)
├── LICENSE                   # MIT License
└── README.md
```

---

## License

This project is licensed under the [MIT License](LICENSE).
