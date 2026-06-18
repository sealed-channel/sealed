# circuits/

Sealed Groth16 SNARK circuits. See:

- Spec: `internal/specs/SPEC-snark-redeem-B.md`
- ADR (backend lock): `internal/docs/adr/0001-snark-prover-backend.md`
- Plan: `internal/specs/PLAN-snark-redeem-B.md`

## Files

- `redeem.circom` — production circuit for `redeemWithProof`. Body complete (no open TODO markers): h=16 Poseidon Merkle path, leaf hash = `Poseidon(preimage)`. 9,254 total constraints (4,397 non-linear), 4 public inputs (root, nullifier, recipient, denomination).
- `keys/` — ceremony artifacts, **gitignored** (large binaries; fetch or regenerate locally). Currently holds the DEV ceremony output of 2026-05-21 (single contributor, intentionally weak entropy): `redeem_dev.zkey`, `vk_dev.json`, `pot14_final.ptau`. See `keys/ceremony-dev-log.md`.
- `build/` — circom outputs (`.r1cs`, `.wasm`, witness generator). Gitignored.

## Status

Dev trusted setup complete (2026-05-21). `vk_dev.json` is **DEV-ONLY — never deploy to mainnet**: a single contributor ran the ceremony, so one compromise equals total proof-forgery capability. The production multi-party ceremony has NOT been run and is a mainnet blocker — see `keys/PRODUCTION-CEREMONY-TODO.md`.

Golden vectors generated against the dev artifacts live in `programs/sealed/test/snark-vectors/`.

## Build

```bash
cd circuits
npm install
# Drop a powersoftau file into keys/pot.ptau (snarkjs publishes pre-generated ones).
npm run ptau:download   # prints instructions
npm run compile
npm run info             # verify constraint count fits ptau size
npm run setup
npm run contribute       # repeat per ceremony participant
npm run export-vk
```

## Constraint budget

Target ≤ 2^16 = 65,536 constraints to keep prove time < 6s on iPhone 11 Pro (ADR 0001 reversal threshold). Actual: 9,254 total / 4,397 non-linear — fits the 2^14 ptau (`pot14_final.ptau`) with large headroom.

## TODO (before mainnet)

- [ ] Freeze `redeem.circom` — any further edit invalidates ceremony artifacts and requires a full re-run.
- [ ] Run the multi-party production ceremony per `keys/PRODUCTION-CEREMONY-TODO.md`; publish production `vk.json` + ceremony log.
- [ ] Regenerate golden vectors in `programs/sealed/test/snark-vectors/` against the production zkey.

## Do NOT

- Commit `keys/*.zkey` or `*.ptau` — large binaries, gitignored; contributors fetch them directly.
- Commit `build/` — regeneratable, large.
- Reuse existing `keys/` artifacts after ANY change to `redeem.circom` — a changed circuit needs a fresh trusted setup.
- Deploy `vk_dev.json` (or any dev artifact) to mainnet.
