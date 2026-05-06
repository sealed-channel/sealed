"""
SealedMessage — Algorand AVM Smart Contract (PyTeal)

Purpose: a single, public App ID that an external Algorand event-stream
subscriber can filter on (`txn.apid == SEALED_MESSAGE_APP_ID`) to isolate
Sealed traffic from the TestNet firehose.

Design:

  - Stateful Algorand application with an empty state schema (no boxes,
    no global state, no local state). The empty schema keeps the user tx fee
    at the min-fee tier (1000 µAlgos = 0.001 ALGO per message — same as
    today's payment-tx-with-note path) and keeps the contract auditable.
    Note: this is NOT a stateless contract / LogicSig — it is invoked via
    `ApplicationCallTxn` and routed through the ABI router below.

  - Every method calls `Log(...)` and `Approve()`. The Log bytes are what
    the event-stream subscriber forwards to our Tor Indexer. Today's indexer
    parser (indexer-service/src/chains/algorand/monitor.ts) understands these
    bytes as the ciphertext envelope — they just come from `logs[0]` instead
    of `note`.

  - Split ABI: send_message takes (recipient_tag, ciphertext) as two
    first-class ABI args so a subscriber can pre-filter by tag without
    decoding the payload. ABI `StaticBytes[Literal[32]]` types are length-
    enforced by the ABI decoder before contract logic runs, so we do NOT
    re-assert their length on-chain.

Auth posture:
  - send_message / send_alias_message: open. Anyone can broadcast an
    encrypted envelope to anyone — recipient validates the AEAD on-device.
  - set_username: the username claim is bound to Txn.sender() by logging the
    sender alongside the claim. Clients MUST verify the sender matches the
    address they expect for that username. Squatting is possible at the
    chain layer; resolution is client-side / indexer-side.
  - publish_pq_key: bound to Txn.sender() in the same way. Length is
    constrained to a sane window for ML-KEM-512 (800 bytes) +/- room for
    future schemes; clients verify the key against the sender.

Methods:
  send_message(recipient_tag: byte[32], ciphertext: byte[])
  send_alias_message(channel_id: byte[32], recipient_tag: byte[32], ciphertext: byte[])
  set_username(username: byte[], encryption_pubkey: byte[32], scan_pubkey: byte[32])
  publish_pq_key(pq_pubkey: byte[])

Update / delete: only the creator address.
"""

from typing import Literal

from pyteal import (
    Approve,
    Assert,
    BareCallActions,
    CallConfig,
    Expr,
    Global,
    Int,
    Len,
    Log,
    OnCompleteAction,
    Return,
    Router,
    Seq,
    Txn,
    abi,
    pragma,
)

pragma(compiler_version="^0.27.0")

# =============================================================================
# Constants
# =============================================================================

# ML-KEM-512 public keys are 800 bytes. Allow a small floor/ceiling so future
# PQ schemes (e.g. ML-KEM-768 = 1184 B) can be published without a contract
# upgrade, while still rejecting obviously-bogus payloads.
PQ_PUBKEY_MIN = 32
PQ_PUBKEY_MAX = 2048

# Username byte cap. Display-name normalisation happens client-side; this is
# just a sanity ceiling so the log line doesn't blow up tx size.
USERNAME_MAX = 64

# State schema — all zero. Read by deploy.py when calling ApplicationCreateTxn.
STATE_SCHEMA = {
    'global_ints': 0,
    'global_bytes': 0,
    'local_ints': 0,
    'local_bytes': 0,
}


# =============================================================================
# Router
# =============================================================================

def build_router() -> Router:
    router = Router(
        "SealedMessage",
        bare_calls=BareCallActions(
            no_op=OnCompleteAction.create_only(Approve()),
            update_application=OnCompleteAction.always(
                Return(Txn.sender() == Global.creator_address())
            ),
            delete_application=OnCompleteAction.always(
                Return(Txn.sender() == Global.creator_address())
            ),
        ),
        clear_state=Approve(),
    )

    # --- send_message --------------------------------------------------------
    @router.method(no_op=CallConfig.CALL)
    def send_message(
        recipient_tag: abi.StaticBytes[Literal[32]],  # noqa: F821
        ciphertext: abi.DynamicBytes,
    ) -> Expr:
        """
        Log(ciphertext) so the event-stream subscriber can forward it.
        recipient_tag is a top-level ABI arg — subscribers can filter on it
        without decoding the payload. The ABI decoder enforces the 32-byte
        length of recipient_tag, so no on-chain length assertion is needed.
        """
        return Seq(
            Log(ciphertext.get()),
            Approve(),
        )

    # --- send_alias_message --------------------------------------------------
    @router.method(no_op=CallConfig.CALL)
    def send_alias_message(
        channel_id: abi.StaticBytes[Literal[32]],  # noqa: F821
        recipient_tag: abi.StaticBytes[Literal[32]],  # noqa: F821
        ciphertext: abi.DynamicBytes,
    ) -> Expr:
        """Alias-chat message send. Same shape as send_message + channel_id.
        Both 32-byte fields are length-checked by the ABI decoder."""
        return Seq(
            Log(ciphertext.get()),
            Approve(),
        )

    # --- set_username --------------------------------------------------------
    @router.method(no_op=CallConfig.CALL)
    def set_username(
        username: abi.DynamicBytes,
        encryption_pubkey: abi.StaticBytes[Literal[32]],  # noqa: F821
        scan_pubkey: abi.StaticBytes[Literal[32]],  # noqa: F821
    ) -> Expr:
        """Username claim / key publication. Logs (sender, username, keys) so
        clients can bind the claim to the on-chain Txn.sender() — squatting
        on a username does not impersonate the original sender."""
        return Seq(
            Assert(Len(username.get()) > Int(0)),
            Assert(Len(username.get()) <= Int(USERNAME_MAX)),
            Log(Txn.sender()),
            Log(username.get()),
            Log(encryption_pubkey.get()),
            Log(scan_pubkey.get()),
            Approve(),
        )

    # --- publish_pq_key ------------------------------------------------------
    @router.method(no_op=CallConfig.CALL)
    def publish_pq_key(pq_pubkey: abi.DynamicBytes) -> Expr:
        """Post-quantum public-key publication. Logs (sender, key) so clients
        can verify the key belongs to that address. Length is bounded to a
        sane window covering current and near-future PQ KEM schemes."""
        return Seq(
            Assert(Len(pq_pubkey.get()) >= Int(PQ_PUBKEY_MIN)),
            Assert(Len(pq_pubkey.get()) <= Int(PQ_PUBKEY_MAX)),
            Log(Txn.sender()),
            Log(pq_pubkey.get()),
            Approve(),
        )

    # keep references to silence unused warnings — they are registered via @router
    _ = (send_message, send_alias_message, set_username, publish_pq_key)
    return router


# =============================================================================
# CLI: compile approval + clear TEAL
# =============================================================================

if __name__ == '__main__':
    from pathlib import Path
    from pyteal import OptimizeOptions

    out = Path(__file__).parent
    router = build_router()
    approval, clear, contract = router.compile_program(
        version=8,
        optimize=OptimizeOptions(scratch_slots=True),
    )
    (out / 'sealed_message_approval.teal').write_text(approval)
    (out / 'sealed_message_clear.teal').write_text(clear)
    (out / 'sealed_message_contract.json').write_text(contract.dictify().__repr__())
    print('Wrote approval, clear, and contract artifacts to', out)
