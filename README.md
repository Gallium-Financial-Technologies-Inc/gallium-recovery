# gallium-recovery

Public recovery tool for a Gallium 2-of-3 Bitcoin escrow. It spends the escrow in Bitcoin Core using the bank key backup and the borrower key backup. Those are the files downloaded when each key was created. Gallium does not need to be running, and this tool does not send the private keys anywhere.

The Gallium app pins an exact commit and SHA-256 of `gallium-recover.sh`. It downloads that file and saves it only when the checksum matches. Do not run a copy taken from the moving `main` branch tip unless you have checked that same checksum.

## Run

```bash
chmod +x gallium-recover.sh
./gallium-recover.sh
```

The same two key backups work for every loan. The script asks for four things:

1. Path to the bank key backup file, for example `~/Downloads/gallium-bank-key-LN-1.txt`
2. Path to the borrower key backup file
3. The loan index shown on that loan
4. The Bitcoin address that should receive the funds

## Bitcoin Core

The script runs `bitcoin-cli` from your `PATH`, or from `BITCOIN_CLI` if that variable is a full path to the binary. Extracting the tarball into `~/Downloads` does not put it on `PATH`, so a new terminal still reports that Bitcoin Core is not installed. Core 27 or newer also has to be running on this computer before the script can see the coins.

If `bitcoin-cli` is missing or older than 27, the script asks before downloading 27.1 from [bitcoincore.org](https://bitcoincore.org) into `~/.gallium-recovery/bitcoin-core-27.1`. That install still needs the steps below: a permanent `PATH` entry, a macOS signature, and a running `bitcoind`. The script does not start the node.

### Install and keep `bitcoin-cli` on PATH

Download Bitcoin Core 27.1 or newer from [bitcoincore.org](https://bitcoincore.org/en/download/). These commands assume the 27.1 tarball was extracted to `~/Downloads/bitcoin-27.1`. If the script installed Core for you, use `~/.gallium-recovery/bitcoin-core-27.1` in place of `~/Downloads/bitcoin-27.1`.

On macOS the official binaries are unsigned, so the shell exits with `zsh: killed` as soon as `bitcoind` or `bitcoin-cli` starts. Sign them once:

```bash
codesign --force -s - \
  ~/Downloads/bitcoin-27.1/bin/bitcoind \
  ~/Downloads/bitcoin-27.1/bin/bitcoin-cli \
  ~/Downloads/bitcoin-27.1/bin/bitcoin-tx \
  ~/Downloads/bitcoin-27.1/bin/bitcoin-wallet
```

Add that `bin` directory to the shell startup file so every new terminal can find it.

zsh, the default on macOS:

```bash
echo 'export PATH="$HOME/Downloads/bitcoin-27.1/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
bitcoin-cli -version
```

bash:

```bash
echo 'export PATH="$HOME/Downloads/bitcoin-27.1/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
bitcoin-cli -version
```

`bitcoin-cli -version` prints `Bitcoin Core version v27.1.0` or a newer 27.x or 28.x line. To point only this tool at a binary, put this in the same startup file instead of the `PATH` line:

```bash
export BITCOIN_CLI="$HOME/Downloads/bitcoin-27.1/bin/bitcoin-cli"
```

`bitcoind` still has to be on `PATH`, because you start the node yourself.

### Regtest

Run a regtest node on this computer. When the chain already lives on another machine, peer to it. Leave that machine's RPC port closed, and leave `BITCOIN_RPC_HOST` unset. The key files stay on this computer.

`HOST` is the machine that already has the regtest chain. Its peer port, 18444, must accept connections from your IP.

```bash
bitcoind -regtest -daemon -connect=HOST:18444 -fallbackfee=0.0002
bitcoin-cli -regtest getblockcount
```

When that block count matches the host, run `./gallium-recover.sh`.

After the script prints a transaction id, mine one block on this node so the host records the confirmation:

```bash
bitcoin-cli -regtest createwallet mine >/dev/null 2>&1 || true
bitcoin-cli -regtest -rpcwallet=mine generatetoaddress 1 "$(bitcoin-cli -regtest -rpcwallet=mine getnewaddress)"
bitcoin-cli -regtest stop
```

### Mainnet

Start the node on this computer and wait until it has finished syncing:

```bash
bitcoind -daemon
bitcoin-cli getblockchaininfo
```

Use the same `./gallium-recover.sh` once `initialblockdownload` is false.

When `bitcoin-cli` cannot read the node's default cookie file:

```bash
BITCOIN_RPC_USER=... BITCOIN_RPC_PASSWORD=... ./gallium-recover.sh
```

Optional: `BITCOIN_RPC_HOST`, `BITCOIN_RPC_PORT`. Leave these unset when the node is on this computer.

## Verify the file you downloaded

```bash
shasum -a 256 gallium-recover.sh
```

Compare the result with `SHA256SUMS` in this repository at the commit the Gallium app pinned. A mismatch means the file is not the pinned release. Do not run it.

## What it does

1. Checks that the two files are the bank key backup and the borrower key backup for the same network.
2. Builds the private deposit and change descriptors at the loan index you enter.
3. Asks Bitcoin Core for each descriptor checksum.
4. Imports them into a blank descriptor wallet.
5. Sends the full balance to the destination address.

## Tests

```bash
./gallium-recover.sh --self-test
```
