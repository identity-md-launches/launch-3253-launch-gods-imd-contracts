# GODS OF IMD: contracts

The on-chain side of [GODS OF IMD](https://gods.getnightshift.tech), a living NFT world judged by the IMD Oracle.

| Contract | File | What it does |
| --- | --- | --- |
| `GodsOfIMDInhabitants` | `src/GodsOfIMDInhabitants.sol` | ERC-721 "GODS OF IMD Inhabitants" (`SOUL`), with ERC-4906 metadata events and an ERC-2981 royalty. Genesis is 1,000 souls, fixed in the contract. Each soul draws one Mark from a fixed deck (640 Mortal, 250 Blessed, 100 Ascended, 10 Divine) from the hash of the block after its forge. |
| `OracleShrine` | `src/OracleShrine.sol` | The game's treasury and altar. It holds IMD, buys Oracle questions from IMD's Intake, verifies the signed EIP-712 attestations on chain, records the God's judgments and the daily world anchors, and runs the weekly rewards vault. |

## Deploying

Both constructors take addresses only, so IMD's launch (`launch.open` with `onchain: "evm_contracts"`) can deploy them as they are, the shrine first:

```
OracleShrine(address owner_, IIntake intake_, IERC20 imd_, address oracleSigner_, address director_)
GodsOfIMDInhabitants(address owner_, IERC20 imd_, address shrine_, address burnSink_)
```

The exact Ethereum (chain 1) manifest is [launch.json](launch.json). It deploys only the shrine and the inhabitants, in that order, with no token, pool, ETH payment or initialization call. `$owner` is resolved by the launch service; `$contract:OracleShrine` resolves to the shrine deployed first.

| Constructor input | Ethereum address |
| --- | --- |
| IMD Intake v2 | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` |
| Existing IMD token | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` |
| Oracle attester | `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982` |
| Director (game server) | `0xF0CED7f39217FFd0A26686CF660AFA39DfCc699A` |
| IMD burn sink | `0xe29386719C155B6847aD5a4E97C6674f10ffc750` |

Both constructors make no external call and work with these addresses even on an empty EVM. Ownership, initial stewardship, payees, royalties and the existing SHIFT forge-token payee belong to `$owner`; the shrine director is the named game server. Listing the existing SHIFT token does not deploy a token.

After launch, the owner sets the metadata URL (`setBaseURI`), steward (`setSteward`), payees (`setPayees`) and mint phase (`setPhase`) from their wallet. The factory performs none of those calls. The initial phase is Closed, metadata URL empty, and all 1,000 souls remain unminted (900 paid slots and 100 owner reserve slots).

## Audit adaptations and app integration

Existing constructors, function selectors, return tuples, events and constants are preserved. The reproduced audit findings require the behavior changes below; [ADAPTATION.md](ADAPTATION.md) records the evidence and tests.

- Oracle answers must meet the owner's policy: `minPanelSize = 30`, `minQuorum = 20`, `minAgreed = 20` initially. `setPanelMinimums(panelSize, agreed)` and the existing `setMinQuorum(quorum)` configure it. Both callbacks and `record` enforce it. The body is passed through unchanged; its panel fields are not parsed or bound by `questionHash`. Set the policy to at least the panel and agreement required for the questions before asking them. The current global policy applies to pending pins too; paying for a larger panel alone does not raise that policy.
- `rewardsAction` initially equals the unchanged `REWARDS_ACTION` constant (`bytes32("oracle.request@oracle-1")`). The owner can use `setRewardsAction` to migrate future weekly requests to an Intake action version that is actually sold. The existing `setPrice` handles price changes; pending answers keep their original pins.
- A stale `reveal` now succeeds by setting `revealBlock(tokenId)` to the next block and emitting `RevealRearmed`, leaving the Mark unrevealed. Call again after that block. `revealMany` also re-arms stale entries. Watch `MarkRevealed`, or read `markOf`, to determine completion; transaction success alone is not completion. Keep a permissionless reveal bot running promptly: this remains blockhash randomness with a shared deck, not a manipulation-proof random oracle. Reveal ordering, block production and repeatedly letting windows expire remain trust and liveness limitations.
- Soul uniqueness is scoped to the **original minter**. Query `tokenOfSoul(keccak256(abi.encode(originalMinter, rawSoulHash)))`, using standard ABI encoding (address padded to 32 bytes, then bytes32), not packed encoding. Forge inputs, `soulHashOf` and `SoulForged.soulHash` remain the raw character JSON hash; `SoulForged.owner` identifies the original minter even after transfer. Copying someone else's pending hash cannot block their forge. Identical content can still be minted by different wallets; this is not proof of authorship. The server must identify a character instance by its minter and hash or token id, rather than treating a raw hash as globally exclusive.
- Limit automatic list-answer delivery to at most two elements. Longer `address[]` / `bytes32[]` answers exceed the Intake's 200,000-gas callback stipend with cold storage. Obtain the valid signed attestation and relay it using the existing permissionless `record` with sufficient transaction gas. A failed callback leaves its pin unanswered; a successful relay writes the judgment, although its Intake request id remains in `pending`. Rewards use short boolean answers and fit the stipend.

The owner retains the original pricing, payout, signer, withdrawal and policy powers. The director chooses the questions and reward lists. The steward can memorialize characters and refresh metadata. Those powers are trust assumptions, not removed capabilities; see ADAPTATION.md.

## Build and test

```sh
forge build
FOUNDRY_FUZZ_SEED=0xafac6a10467d0f616e14402e8a4b5e608e9406ab5a5ab0a50531ae9b9684d54b forge test
```

Solidity 0.8.30, optimizer 200 runs, EVM `cancun`, `bytecode_hash = "none"`.
Tests are local and require no RPC endpoint, credentials, environment setup or new dependencies.

## Libraries

Vendored as plain files in `lib/`, so the repository builds offline:

- `lib/openzeppelin-contracts`: OpenZeppelin Contracts 5.6.1 (MIT), the `.sol` sources of the npm package.
- `lib/forge-std`: forge-std 1.11.0 (MIT or Apache-2.0), used by the tests only.

## License

MIT. See `LICENSE`.
