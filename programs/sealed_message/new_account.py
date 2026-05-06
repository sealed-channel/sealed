"""
Generate a fresh Algorand TestNet account for deploying SealedMessage.

Run once:
    python new_account.py

Prints address + mnemonic. Save the mnemonic somewhere safe, then fund the
address at https://dispenser.testnet.aws.algodev.network/ (or Pera TestNet
dispenser). Then run deploy.py with DEPLOYER_MNEMONIC set.
"""

from algosdk import account, mnemonic

private_key, address = account.generate_account()
phrase = mnemonic.from_private_key(private_key)

print("Address :", address)
print("Mnemonic:", phrase)
print()
print("Next:")
print(f"  1. Fund {address} with 0.2 TestNet ALGO:")
print("     https://dispenser.testnet.aws.algodev.network/")
print("  2. export DEPLOYER_MNEMONIC=\"" + phrase + "\"")
print("  3. python deploy.py")
