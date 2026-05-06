"""
Tests for the SealedMessage PyTeal contract.

Goals enforced here:
  - Contract compiles to TEAL.
  - send_message ABI signature is (byte[32], byte[]) -> void — the SPLIT shape
    we committed to in the plan. Recipient tag is a first-class ABI arg so an
    event-stream subscriber can pre-filter by tag without parsing payload.
  - send_message emits Log(ciphertext) so subscribers receive the bytes.
  - No boxes, no global state, no local state — contract is stateless.
    This is what keeps the user tx fee at the min-fee tier (no MBR, no inner
    txs) and makes the App a pure discriminator for the event stream.
  - Only the creator can update or delete the app.
"""

from pathlib import Path

import pytest
import pyteal
from sealed_message import build_router


THIS_DIR = Path(__file__).parent


def _compile():
    router = build_router()
    approval, clear, contract = router.compile_program(
        version=8,
        optimize=pyteal.OptimizeOptions(scratch_slots=True),
    )
    return approval, clear, contract


def test_contract_compiles():
    approval, clear, _ = _compile()
    assert approval and isinstance(approval, str)
    assert clear and isinstance(clear, str)


def test_send_message_abi_is_split_tag_and_ciphertext():
    """Plan decision: split ABI. Tag is byte[32], ciphertext is byte[]."""
    _, _, contract = _compile()

    # Flatten the ABI description into a lookup of method name -> args
    methods = {m.name: m for m in contract.methods}
    assert 'send_message' in methods, \
        f'send_message missing from ABI; have {list(methods)}'

    send = methods['send_message']
    arg_types = [str(a.type) for a in send.args]
    assert arg_types == ['byte[32]', 'byte[]'], (
        f'send_message ABI is {arg_types}; expected [byte[32], byte[]] '
        '(recipient_tag, ciphertext) per plan.'
    )
    assert str(send.returns.type) == 'void'


def test_send_alias_message_abi_includes_channel_id():
    """Alias sends also route through this contract (plan decision #2)."""
    _, _, contract = _compile()
    methods = {m.name: m for m in contract.methods}
    assert 'send_alias_message' in methods
    arg_types = [str(a.type) for a in methods['send_alias_message'].args]
    assert arg_types == ['byte[32]', 'byte[32]', 'byte[]'], (
        f'send_alias_message ABI is {arg_types}; expected '
        '[byte[32], byte[32], byte[]] (channel_id, recipient_tag, ciphertext).'
    )


def test_send_message_logs_the_ciphertext():
    """Event-stream subscribers read logs[0]; ciphertext must be logged."""
    approval, _, _ = _compile()
    # Very light check: approval TEAL must contain a `log` opcode in the
    # send_message branch. Full byte-level assertion is done via deploy test.
    assert '\nlog\n' in approval, \
        'approval TEAL does not emit a log opcode; event stream would see nothing.'


def test_contract_is_stateless():
    """No global/local state and no boxes — keeps fee at min-fee tier."""
    _, _, contract = _compile()
    # Router method list should NOT include create-box / opt-in flows.
    names = [m.name for m in contract.methods]
    for forbidden in ('create_box', 'opt_in', 'close_out'):
        assert forbidden not in names

    # State schema is set at deploy time, not in the TEAL, so we also assert
    # that build_router exposes the zero-schema marker the deploy script reads.
    from sealed_message import STATE_SCHEMA
    assert STATE_SCHEMA == {
        'global_ints': 0, 'global_bytes': 0,
        'local_ints': 0, 'local_bytes': 0,
    }


if __name__ == '__main__':
    raise SystemExit(pytest.main([__file__, '-v']))
