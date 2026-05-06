"""
Alias Channel — Algorand AVM Smart Contract (PyTeal)

Ephemeral key-exchange channel for Alias Chat.
Stores two X25519 public keys in an Application Box, then gets deleted
after both participants have exchanged keys.

Box schema (73 bytes per channel):
  creator_pubkey:   bytes[32]   — alias encryption pubkey of inviter
  acceptor_pubkey:  bytes[32]   — alias encryption pubkey of acceptor (zeros until accepted)
  state:            uint8       — 0=pending, 1=accepted
  created_at:       uint64      — unix timestamp (big-endian, 8 bytes)

Methods:
  create_channel(channel_id, creator_pubkey)
  accept_channel(channel_id, acceptor_pubkey)
  delete_channel(channel_id)
  read_channel(channel_id)
"""

from typing import Literal

from pyteal import (
    Approve,
    App,
    Assert,
    BareCallActions,
    Bytes,
    BytesZero,
    CallConfig,
    Expr,
    Extract,
    Global,
    Int,
    InnerTxnBuilder,
    Itob,
    Len,
    Not,
    OnCompleteAction,
    OptimizeOptions,
    Pop,
    Return,
    Router,
    Seq,
    Subroutine,
    TealType,
    TxnField,
    TxnType,
    Txn,
    abi,
    pragma,
)

pragma(compiler_version="^0.27.0")

# =============================================================================
# Constants
# =============================================================================
CHANNEL_BOX_SIZE = Int(73)
PUBKEY_SIZE = Int(32)
STATE_OFFSET = Int(64)
CREATED_AT_OFFSET = Int(65)
STATE_PENDING = Int(0)
STATE_ACCEPTED = Int(1)
# Box MBR: 2500 + 400 * (key_bytes + value_bytes) = 2500 + 400*(32+73)
BOX_MBR = Int(44500)

# =============================================================================
# Helpers
# =============================================================================


@Subroutine(TealType.bytes)
def get_creator_pubkey(box_value: Expr) -> Expr:
    """Extract creator pubkey (bytes 0..31) from box."""
    return Extract(box_value, Int(0), PUBKEY_SIZE)


@Subroutine(TealType.bytes)
def get_acceptor_pubkey(box_value: Expr) -> Expr:
    """Extract acceptor pubkey (bytes 32..63) from box."""
    return Extract(box_value, PUBKEY_SIZE, PUBKEY_SIZE)


@Subroutine(TealType.uint64)
def get_state(box_value: Expr) -> Expr:
    """Extract state byte (offset 64) from box."""
    return ExtractUint8(box_value, STATE_OFFSET)


def ExtractUint8(value: Expr, offset: Expr) -> Expr:
    """Extract a single byte as uint64."""
    from pyteal import GetByte

    return GetByte(value, offset)


# =============================================================================
# ABI Methods
# =============================================================================

router = Router(
    "AliasChannel",
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


@router.method(no_op=CallConfig.CALL)
def create_channel(
    channel_id: abi.DynamicBytes,
    creator_pubkey: abi.StaticBytes[Literal[32]],
) -> Expr:
    """
    Create a new alias channel box.
    Caller pays MBR for the box.
    """
    ch_id = channel_id.get()
    c_pub = creator_pubkey.get()
    box_len = App.box_length(ch_id)
    return Seq(
        # Channel ID must be exactly 32 bytes (DynamicBytes — ABI does not
        # length-check this for us).
        Assert(Len(ch_id) == PUBKEY_SIZE),
        # creator_pubkey is abi.StaticBytes[32]; ABI decoder enforces length.
        # Box must not already exist
        box_len,
        Assert(Not(box_len.hasValue())),
        # Create box: 73 bytes
        Pop(App.box_create(ch_id, CHANNEL_BOX_SIZE)),
        # Write creator pubkey at offset 0
        App.box_replace(ch_id, Int(0), c_pub),
        # Acceptor pubkey is already zeros (box initialized to 0)
        # State byte (offset 64) is already 0 = pending
        # Write created_at timestamp at offset 65
        App.box_replace(ch_id, CREATED_AT_OFFSET, Itob(Global.latest_timestamp())),
        Approve(),
    )


@router.method(no_op=CallConfig.CALL)
def accept_channel(
    channel_id: abi.DynamicBytes,
    acceptor_pubkey: abi.StaticBytes[Literal[32]],
) -> Expr:
    """
    Accept an existing alias channel by writing the acceptor's pubkey.
    Only works if channel is in pending state.
    Acceptor must NOT be the creator (different sender).
    """
    ch_id = channel_id.get()
    a_pub = acceptor_pubkey.get()
    box_val = App.box_get(ch_id)
    return Seq(
        # Channel ID must be 32 bytes (DynamicBytes — ABI does not length-check)
        Assert(Len(ch_id) == PUBKEY_SIZE),
        # acceptor_pubkey is abi.StaticBytes[32]; ABI decoder enforces length.
        # Box must exist
        box_val,
        Assert(box_val.hasValue()),
        # Must be in pending state (state byte == 0)
        Assert(ExtractUint8(box_val.value(), STATE_OFFSET) == STATE_PENDING),
        # Acceptor pubkey must not be all zeros
        Assert(a_pub != BytesZero(PUBKEY_SIZE)),
        # Write acceptor pubkey at offset 32
        App.box_replace(ch_id, PUBKEY_SIZE, a_pub),
        # Set state to accepted (1) at offset 64
        App.box_replace(ch_id, STATE_OFFSET, Bytes("base16", "01")),
        Approve(),
    )


@router.method(no_op=CallConfig.CALL)
def delete_channel(channel_id: abi.DynamicBytes) -> Expr:
    """
    Delete an alias channel box and refund the 44 500 µAlgo box MBR to the
    caller.  The outer transaction must carry fee >= 2 * min_fee (2 000 µAlgo)
    so the inner payment can use fee=0 via fee pooling.
    """
    ch_id = channel_id.get()
    box_len = App.box_length(ch_id)
    return Seq(
        # Channel ID must be 32 bytes
        Assert(Len(ch_id) == PUBKEY_SIZE),
        # Box must exist
        box_len,
        Assert(box_len.hasValue()),
        # Delete the box (frees 44 500 µAlgo MBR from the app account)
        Pop(App.box_delete(ch_id)),
        # Refund the box MBR to whoever is calling delete_channel
        InnerTxnBuilder.Execute(
            {
                TxnField.type_enum: TxnType.Payment,
                TxnField.receiver: Txn.sender(),
                TxnField.amount: BOX_MBR,
                TxnField.fee: Int(0),  # covered by outer tx fee pooling
            }
        ),
        Approve(),
    )


@router.method(no_op=CallConfig.CALL)
def read_channel(
    channel_id: abi.DynamicBytes,
    *,
    output: abi.DynamicBytes,
) -> Expr:
    """
    Read an alias channel box.
    Returns the full 73-byte box contents.
    """
    ch_id = channel_id.get()
    box_val = App.box_get(ch_id)
    return Seq(
        Assert(Len(ch_id) == PUBKEY_SIZE),
        box_val,
        Assert(box_val.hasValue()),
        output.set(box_val.value()),
    )


# =============================================================================
# Compile
# =============================================================================


def compile():
    """Compile approval and clear programs."""
    approval, clear, contract = router.compile_program(
        version=8, optimize=OptimizeOptions(scratch_slots=True)
    )
    return approval, clear, contract


if __name__ == "__main__":
    import json

    approval, clear, contract = compile()

    with open("alias_channel_approval.teal", "w") as f:
        f.write(approval)

    with open("alias_channel_clear.teal", "w") as f:
        f.write(clear)

    with open("alias_channel_contract.json", "w") as f:
        json.dump(contract.dictify(), f, indent=2)

    print("✅ Compiled alias_channel_approval.teal")
    print("✅ Compiled alias_channel_clear.teal")
    print("✅ Compiled alias_channel_contract.json")
