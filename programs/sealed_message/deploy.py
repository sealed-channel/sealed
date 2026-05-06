"""
Deploy SealedMessage to Algorand testnet (or mainnet).

Usage:
    export ALGOD_URL="https://testnet-api.algonode.cloud"
    export ALGOD_TOKEN=""
    export DEPLOYER_MNEMONIC="word1 word2 ... word25"
    python deploy.py
"""

import os
import base64
from algosdk import account, mnemonic, transaction
from algosdk.v2client import algod

ALGOD_URL = os.environ.get("ALGOD_URL", "https://testnet-api.algonode.cloud")
ALGOD_TOKEN = os.environ.get("ALGOD_TOKEN", "")
DEPLOYER_MNEMONIC = os.environ.get("DEPLOYER_MNEMONIC", "practice wasp half range hour unhappy outer hotel panda shock amount exhaust switch width neck vote flat soft transfer list equal manual ill absorb slight")

APPROVAL_TEAL = "sealed_message_approval.teal"
CLEAR_TEAL = "sealed_message_clear.teal"


def compile_teal(client: algod.AlgodClient, teal_source: str) -> bytes:
    result = client.compile(teal_source)
    return base64.b64decode(result["result"])


def deploy():
    if not DEPLOYER_MNEMONIC:
        raise SystemExit("Set DEPLOYER_MNEMONIC env var to your 25-word mnemonic.")

    private_key = mnemonic.to_private_key(DEPLOYER_MNEMONIC)
    deployer_address = account.address_from_private_key(private_key)
    print(f"Deployer: {deployer_address}")

    client = algod.AlgodClient(ALGOD_TOKEN, ALGOD_URL)

    info = client.account_info(deployer_address)
    balance_algo = info["amount"] / 1_000_000
    print(f"Balance: {balance_algo:.6f} ALGO")
    if info["amount"] < 200_000:
        raise SystemExit(
            "Need at least 0.2 ALGO. Fund at https://dispenser.testnet.aws.algodev.network/"
        )

    with open(APPROVAL_TEAL) as f:
        approval_bin = compile_teal(client, f.read())
    with open(CLEAR_TEAL) as f:
        clear_bin = compile_teal(client, f.read())

    print(f"Approval program: {len(approval_bin)} bytes")
    print(f"Clear program:    {len(clear_bin)} bytes")

    params = client.suggested_params()
    txn = transaction.ApplicationCreateTxn(
        sender=deployer_address,
        sp=params,
        on_complete=transaction.OnComplete.NoOpOC,
        approval_program=approval_bin,
        clear_program=clear_bin,
        # Stateless contract — schema is all zeros.
        global_schema=transaction.StateSchema(num_uints=0, num_byte_slices=0),
        local_schema=transaction.StateSchema(num_uints=0, num_byte_slices=0),
    )

    signed = txn.sign(private_key)
    tx_id = client.send_transaction(signed)
    print(f"Submitted txn: {tx_id}")

    result = transaction.wait_for_confirmation(client, tx_id, wait_rounds=5)
    app_id = result["application-index"]

    network = "testnet" if "testnet" in ALGOD_URL else "mainnet"
    print()
    print(f"✅ Deployed! App ID: {app_id}")
    print(f"  Explorer: https://{network}.explorer.perawallet.app/application/{app_id}/")
    print(f"  Lora:     https://lora.algokit.io/{network}/application/{app_id}")


if __name__ == "__main__":
    deploy()
