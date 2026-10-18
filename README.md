# gallium-recovery

Public recovery tool for a Gallium 2-of-3 Bitcoin escrow. One party creates a partially signed payment. The other party checks the amount, destination, and fee, then broadcasts it. Each person uses only their own key backup. Gallium does not need to be running, and this tool does not send private keys anywhere.

The Gallium app pins an exact commit and SHA-256 of `gallium-recover.sh`. It downloads that file and saves it only when the checksum matches. Do not run a copy taken from the moving `main` branch tip unless you have checked that same checksum.

## Run

```bash
chmod +x gallium-recover.sh
./gallium-recover.sh
```

The same key backup works for every loan belonging to that person. The script first asks whether to `create` a payment or `complete` one.

To create a payment it asks for:

1. Path to your own key backup, for example `~/Downloads/gallium-bank-key-LN-1.txt`
2. The escrow public keys file, only when your key backup does not already contain the other party's public key
3. The loan index shown on that loan
4. The Bitcoin address that should receive the funds
5. The amount that address should receive, in BTC

It writes `gallium-recovery-<loan index>.psbt.txt` in the current folder. Send that file to the other party. It does not contain your private key.

To complete a payment, the other party enters their own key backup, that payment file, the loan index, and the destination and amount they expect. The script rejects the payment unless every input belongs to this escrow and the destination and amount match. It then shows the fee and waits for a yes before broadcasting.

The script sets up Bitcoin Core 27 or newer on this computer. Before it downloads Core, signs binaries, edits your shell startup file, or starts a node, it prints the command and waits for a yes.

On regtest it asks for the address of the machine that already has the chain, then peers to port 18444. That port must accept connections from this computer. Leave the address blank to start an empty local regtest. Regtest uses a fee of 2 sat/vB. On mainnet, Bitcoin Core estimates the fee. After a completed payment on regtest, the script can mine one block so the other machine sees it.

On mainnet it starts Bitcoin Core if needed and waits until the node has finished syncing. A first sync can take a long time. Stopping the script leaves the node running, and the next run continues.

The private keys stay on this computer. Leave `BITCOIN_RPC_HOST` unset.

## Verify the file you downloaded

```bash
shasum -a 256 gallium-recover.sh
```

Compare the result with `SHA256SUMS` in this repository at the commit the Gallium app pinned. A mismatch means the file is not the pinned release. Do not run it.

## What it does

1. Reads your key backup and, when needed, the escrow public keys file.
2. Builds the deposit and change descriptors for that loan index. Your key is the extended private key. Gallium's key and the other party's key stay public.
3. Imports those descriptors into a new descriptor wallet named for the loan index and your role.
4. On create, builds a partially signed payment for the amount you entered and writes it to a file.
5. On complete, checks the inputs, destination, and amount, shows the fee, and broadcasts only after you agree.

## Tests

```bash
./gallium-recover.sh --self-test
```
