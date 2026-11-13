# GODS OF IMD test additions

These tests extend the accepted Ethereum deployment and protocol-vector suites. They require only the existing vendored Solidity dependencies. All accounts, signing keys, tokens and intake responses used by the added tests are synthetic test fixtures; no fork, network, environment variable, FFI or file read is required during a test.

| Suite | Properties exercised |
| --- | --- |
| `RewardsStateMachine.t.sol` | Proposal validation and atomicity; independent Merkle proofs; beneficiary payment; double-claim prevention; per-week limits; canonical boolean answers; cancellation and expiry boundaries; reserved funds unavailable for questions; failed transfer rollback; conservation after partial claims and expiry. |
| `OracleBoundaries.t.sol` | Invalid and duplicate batches; failed intake payment rollback; eight-question groups; callback sender and pending-ID checks; mutation of each of the 15 signed fields; EIP-712 consumer and chain isolation; expiry boundary; ERC-1271 signer validation; owner/director separation and rotation. |
| `InhabitantsFailures.t.sol` | Payment failure after earlier transfers across all paid mint paths; rejecting and reentrant ERC-721 receivers; reserve batch rollback; invalid splits/payees; actual payment conservation and rounding; service-cost boundaries; game permissions; memorial persistence; metadata, royalties and allowlist slot continuity. |
| `invariant/RewardAccounting.t.sol` | Random proposal, approval, rejection, claim, failure, cancellation, expiry, donation, withdrawal and question-purchase sequences against an independent eight-week ledger. |
| `invariant/InhabitantsAccounting.t.sol` | Random public/allowlist/alternate-token mints, reserved batches, transfers, operator transfers, services, phase changes, memorials and fresh/stale reveals across several actors. |

## Invariant design

The five discovery passes in the supplied Pashov reference were applied locally:

1. Conservation: treasury assets cover the sum of all reward liabilities, and every funded token is in the treasury, intake, owner withdrawals or beneficiary payments. NFT supply equals owned tokens; each paid unit reaches the declared recipients.
2. Rounding and round trips: splitting a price conserves the full payment, including one-wei dust; claiming and then expiring a week releases exactly its unclaimed remainder. Transfers cannot reset mint quotas or duplicate a soul.
3. State transitions: the reward model independently records status, remaining amount, timestamps and claim flags. Memorials and revealed Marks persist through transfers and subsequent actions.
4. Adversarial inputs: duplicate hashes, wrong callers, bad proofs, unsigned callbacks, changed signature fields, failing payment tokens and receiver callbacks exercise rollback and authorization. Existing tests continue to cover the full 1,000-token deck and both supply partitions.
5. Protocol properties: the existing canonical oracle vector remains the independent cryptographic oracle; the added tests check domain isolation and signed-field integrity. NFT ownership, approval clearing, supply partitions, soul lookup and the 640/250/100/10 deck are checked against actor/token histories.

The reward ledger derives liabilities from proposals and successful claims rather than reading the contract's reservation counter into its expected values. Both handlers keep a persistent failure flag when an action with valid modeled preconditions reverts, so the default invariant runner cannot silently discard those failures. Each campaign starts with populated state; deterministic handler tests exercise the lifecycle exits as well.

Each invariant campaign runs 256 sequences of 96 calls. The NFT campaign uses fixed prices and two distinct payees, while the stateless split tests vary price and split configuration. It bounds paid mints by the modeled wallet and alternate-token caps and reserved mints by 100. Only handler selectors are targeted; mock mint functions and test cheatcodes are not random targets. Skips are limited to actions that lack a valid state, such as claiming an inactive week or revealing an already revealed token.

The property-based tests use bounded inputs, with explicit examples for zero, one wei, maximum batch length, duplicate values, exact deadlines, and the full uint64 week-identifier domain. No added test asserts exact gas consumption or depends on test order.

## Revision (forge-order reveals, request-bound answers, director-only relays)

The two findings this suite first reported (referral bps vs. listed forge-token burn share; future `issuedAt`) were fixed in the implementation's revision and are no longer reported. The suite was updated to the revised behaviour rather than weakened:

- `RewardsStateMachine.t.sol` settles every rewards week through the intake's 200 000-gas callback for the shrine's own request (`requestOfQuestion`), first without the stipend to surface the revert reason, then through the mock intake.
- `OracleBoundaries.t.sol` relays as the director; a tampered `questionHash` is now refused earlier with `AnswerNotForRequest`.
- `invariant/RewardAccounting.t.sol` checks on every relay attempt that an outsider gets `NotDirector` and the director gets `RewardsAnswerNotRelayable`, and that neither records anything.
- `invariant/InhabitantsAccounting.t.sol` keeps a forge-order model of the reveal queue: an out-of-order reveal must revert `RevealOutOfOrder(id, head)` (or `NotRevealable`) without changing state, and a new invariant checks `nextToReveal()` against the model's head after every call.
- `RevisionEdges.t.sol` covers orphaned rewards requests after unpin/re-propose, callbacks refused for expiry or quorum staying pending and bound, a failure notice leaving cancellation as the only exit, the `issuedAt` tolerance boundary fuzzed through both entry points, a stale head blocking fresh souls, and the serial drain of a stale batch.

`.imd-findings.json` reports one low liveness finding from the revision: a batch whose reveal hashes all expired drains one soul per re-arm, because only the head can be re-armed.

## Reproduction

Run from the repository root:

```sh
forge build --offline
forge test --offline --fuzz-seed 0xafac6a10467d0f616e14402e8a4b5e608e9406ab5a5ab0a50531ae9b9684d54b
forge test --offline --fuzz-seed 0x42 --fuzz-runs 2000
```

Added stateless fuzz suites request 1,000 runs using inline configuration. No project configuration or dependencies are modified. The existing deployment suite rehearses the exact Ethereum arguments, deployment order, explicit owner roles, empty dependency accounts, size limits and protected opcode rules without a fork.

## Local validation

- A fresh export of the 292 tracked or unignored deliverable files, with no build cache or scratch inputs, compiled 79 Solidity files with `forge build --offline`.
- The export passed all 126 Foundry-reported checks with the required seed and again with seed `0x42`: no failures or skips. Foundry groups the seven invariant functions into two campaign results in that count. Each campaign completed 256 runs / 24,576 handler calls with zero reverts on each seed, totaling 98,304 randomized handler calls across the two seeds.
- The second run used `--fuzz-runs 2000` for suites without inline overrides; the added stateless fuzz suites retained their explicit 1,000-run settings.
- `forge fmt --check` passed. Four pre-existing test files received only the formatter's layout/loop-brace changes so the whole-tree check passes.
- Slither was attempted but could not start: `PermissionError: [Errno 13] Permission denied: 'slither'`. Neither the high-severity nor medium-severity static-analysis pass completed. This is not a clean Slither result.
- Source contracts, ABI-defining code, constants, manifest, compiler configuration and dependencies are unchanged. The network worker performs the final staging/commit; the local export checks the files available to that step without writing the Git index.
