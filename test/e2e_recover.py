#!/usr/bin/env python3
"""Spend a regtest escrow with the real recovery script.

Starts a private Bitcoin Core, funds a 2-of-3 address from real account keys,
then drives gallium-recover.sh through create and complete. Nothing is mocked.
"""

import json
import os
import pty
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from decimal import Decimal
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LOAN_INDEX = "7"
FUND_AMOUNT = "0.05"
PAY_AMOUNT = "0.02"
WRONG_AMOUNT = "0.03"
RPC_USER = "gallium"
RPC_PASSWORD = "gallium-e2e"
SCRIPT_TIMEOUT = 120
KEY_SCRIPT = r"""
const { HDKey } = require(process.argv[2]);
const { generateMnemonic, mnemonicToSeedSync } = require(process.argv[3]);
const { wordlist } = require(process.argv[4]);
const versions = { private: 0x04358394, public: 0x043587cf };
function party() {
  const mnemonic = generateMnemonic(wordlist);
  const root = HDKey.fromMasterSeed(mnemonicToSeedSync(mnemonic), versions);
  const account = root.derive("m/48'/1'/0'/2'");
  const fingerprint = (root.fingerprint >>> 0).toString(16).padStart(8, "0");
  return {
    mnemonic,
    fingerprint,
    xprv: account.privateExtendedKey,
    xpub: account.publicExtendedKey,
  };
}
process.stdout.write(JSON.stringify({
  gallium: party(),
  bank: party(),
  borrower: party(),
}));
"""


class E2EFailure(Exception):
    pass


def fail(message):
    raise E2EFailure(message)


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def find_core():
    chosen = os.environ.get("BITCOIND", "")
    if chosen != "":
        daemon = Path(chosen)
        cli = daemon.parent / "bitcoin-cli"
        if daemon.is_file() and cli.is_file():
            return str(cli), str(daemon)
        fail(f"BITCOIND is set but {chosen} is not a Bitcoin Core daemon next to bitcoin-cli.")
    found = shutil.which("bitcoind")
    if found:
        cli = str(Path(found).parent / "bitcoin-cli")
        if os.path.isfile(cli):
            return cli, found
    candidates = (
        Path.home() / "Downloads" / "bitcoin-27.1" / "bin" / "bitcoind",
        Path.home() / ".gallium-recovery" / "bitcoin-core-27.1" / "bin" / "bitcoind",
    )
    for daemon in candidates:
        cli = daemon.parent / "bitcoin-cli"
        if daemon.is_file() and cli.is_file():
            return str(cli), str(daemon)
    fail(
        "Bitcoin Core was not found. Install it, or set BITCOIND to bitcoind.\n"
        "This test starts its own regtest node and does not use an existing one."
    )


def rpc(cli, port, args):
    command = [
        cli,
        "-regtest",
        "-rpcconnect=127.0.0.1",
        f"-rpcport={port}",
        f"-rpcuser={RPC_USER}",
        f"-rpcpassword={RPC_PASSWORD}",
    ]
    for arg in args:
        command.append(arg)
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if completed.returncode != 0:
        fail(completed.stdout.rstrip("\n"))
    return completed.stdout


def rpc_json(cli, port, args):
    return json.loads(rpc(cli, port, args), parse_float=Decimal)


def wait_for_node(cli, port, process, log_path):
    started = time.time()
    while time.time() - started < 30:
        if process.poll() is not None:
            fail("bitcoind exited before it accepted RPC.\n" + log_tail(log_path))
        probe = subprocess.run(
            [
                cli,
                "-regtest",
                "-rpcconnect=127.0.0.1",
                f"-rpcport={port}",
                f"-rpcuser={RPC_USER}",
                f"-rpcpassword={RPC_PASSWORD}",
                "getblockcount",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        if probe.returncode == 0:
            height = int(probe.stdout.strip())
            if height != 0:
                fail(f"Refusing to continue. The regtest node is already at height {height}.")
            return
        time.sleep(0.2)
    fail("Bitcoin Core did not accept RPC in time.\n" + log_tail(log_path))


def log_tail(path):
    if not os.path.isfile(path):
        return ""
    lines = Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    kept = lines[-40:]
    return "\n".join(kept)


def start_node(cli, daemon, datadir):
    rpc_port = free_port()
    p2p_port = free_port()
    log_path = str(Path(datadir) / "bitcoind.log")
    log_handle = open(log_path, "w", encoding="utf-8")
    command = [
        daemon,
        "-regtest",
        f"-datadir={datadir}",
        "-rpcbind=127.0.0.1",
        "-rpcallowip=127.0.0.1",
        f"-rpcport={rpc_port}",
        f"-port={p2p_port}",
        f"-bind=127.0.0.1:{p2p_port}",
        f"-rpcuser={RPC_USER}",
        f"-rpcpassword={RPC_PASSWORD}",
        "-fallbackfee=0.0002",
        "-connect=0",
        "-dnsseed=0",
    ]
    process = subprocess.Popen(
        command,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    wait_for_node(cli, rpc_port, process, log_path)
    return process, rpc_port, log_path, log_handle


def stop_node(cli, port, process):
    subprocess.run(
        [
            cli,
            "-regtest",
            "-rpcconnect=127.0.0.1",
            f"-rpcport={port}",
            f"-rpcuser={RPC_USER}",
            f"-rpcpassword={RPC_PASSWORD}",
            "stop",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    started = time.time()
    while process.poll() is None and time.time() - started < 20:
        time.sleep(0.2)
    if process.poll() is None:
        process.kill()
        process.wait(timeout=10)


def scure_modules(temp):
    bundled = REPO.parent / "gallium-ui" / "node_modules"
    if (bundled / "@scure" / "bip32").is_dir() and (bundled / "@scure" / "bip39").is_dir():
        return bundled
    dest = Path(temp) / "keylib"
    completed = subprocess.run(
        ["npm", "install", "--prefix", str(dest), "@scure/bip32@2.2.0", "@scure/bip39@2.2.0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if completed.returncode != 0:
        fail(completed.stdout.rstrip("\n"))
    return dest / "node_modules"


def make_keys(modules, temp):
    script_path = Path(temp) / "make-keys.cjs"
    script_path.write_text(KEY_SCRIPT, encoding="utf-8")
    bip32 = str(Path(modules) / "@scure" / "bip32")
    bip39 = str(Path(modules) / "@scure" / "bip39")
    english = str(Path(modules) / "@scure" / "bip39" / "wordlists" / "english.js")
    completed = subprocess.run(
        ["node", str(script_path), bip32, bip39, english],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if completed.returncode != 0:
        fail(completed.stdout.rstrip("\n"))
    return json.loads(completed.stdout)


def write_backup(path, role, own, gallium, bank_xpub, borrower_xpub):
    gallium_key = f"[{gallium['fingerprint']}/48h/1h/0h/2h]{gallium['xpub']}"
    lines = [
        "GALLIUM ESCROW KEY BACKUP",
        "==========================",
        "",
        f"Role: {role}",
        "Loan: LN-E2E",
        "Network: regtest",
        "Derivation: m/48'/1'/0'/2'",
        "",
        "Recovery phrase (BIP39):",
        own["mnemonic"],
        "",
        "Account public key (xpub):",
        own["xpub"],
        "",
        "Account extended private key:",
        own["xprv"],
        "",
        "Gallium account key:",
        gallium_key,
        "",
        "Bank account key:",
        bank_xpub,
        "",
        "Borrower account key:",
        borrower_xpub,
        "",
        f"Loan index on this page: {LOAN_INDEX}",
        "",
    ]
    Path(path).write_text("\n".join(lines), encoding="utf-8")
    return gallium_key


def deposit_address(cli, port, gallium, bank_xpub, borrower_xpub):
    origin = f"[{gallium['fingerprint']}/48h/1h/0h/2h"
    descriptor = (
        f"wsh(sortedmulti(2,{origin}/{LOAN_INDEX}]{gallium['xpub']}/{LOAN_INDEX}/0/*,"
        f"{bank_xpub}/{LOAN_INDEX}/0/*,{borrower_xpub}/{LOAN_INDEX}/0/*))"
    )
    info = rpc_json(cli, port, ["getdescriptorinfo", descriptor])
    checksum = info["checksum"]
    addresses = rpc_json(cli, port, ["deriveaddresses", f"{descriptor}#{checksum}", "[0,0]"])
    if len(addresses) != 1 or addresses[0] == "":
        fail("Bitcoin Core did not derive the escrow deposit address.")
    return addresses[0]


def fund_escrow(cli, port, address):
    rpc(cli, port, ["createwallet", "faucet"])
    mine_to = rpc(cli, port, ["-rpcwallet=faucet", "getnewaddress"]).strip()
    rpc_json(cli, port, ["-rpcwallet=faucet", "generatetoaddress", "101", mine_to])
    destination = rpc(cli, port, ["-rpcwallet=faucet", "getnewaddress"]).strip()
    rpc(cli, port, ["-rpcwallet=faucet", "sendtoaddress", address, FUND_AMOUNT])
    rpc_json(cli, port, ["-rpcwallet=faucet", "generatetoaddress", "1", mine_to])
    scanned = rpc_json(cli, port, ["scantxoutset", "start", json.dumps([f"addr({address})"])])
    total = scanned.get("total_amount")
    if Decimal(str(total)) != Decimal(FUND_AMOUNT):
        fail(f"Escrow deposit address holds {total} BTC after funding.")
    return destination


def child_env(home, cli, port):
    env = {}
    for key, value in os.environ.items():
        if key.startswith("BITCOIN_"):
            continue
        env[key] = value
    env["HOME"] = home
    env["BITCOIN_CLI"] = cli
    env["BITCOIN_RPC_HOST"] = "127.0.0.1"
    env["BITCOIN_RPC_PORT"] = str(port)
    env["BITCOIN_RPC_USER"] = RPC_USER
    env["BITCOIN_RPC_PASSWORD"] = RPC_PASSWORD
    env["PATH"] = str(Path(cli).parent) + os.pathsep + env.get("PATH", "")
    return env


class ScriptChild:
    def __init__(self, pid, fd):
        self.pid = pid
        self.fd = fd
        self.reaped = False
        self.code = None

    def poll(self):
        if self.reaped:
            return self.code
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if pid == 0:
            return None
        self.reaped = True
        self.code = os.waitstatus_to_exitcode(status)
        return self.code

    def kill(self):
        if self.poll() is not None:
            return
        os.kill(self.pid, 15)
        started = time.time()
        while self.poll() is None and time.time() - started < 5:
            time.sleep(0.1)
        if self.poll() is None:
            os.kill(self.pid, 9)
            self.poll()


def read_some(child, buf):
    ready, _, _ = select.select([child.fd], [], [], 0.2)
    if child.fd not in ready:
        return buf
    try:
        chunk = os.read(child.fd, 4096)
    except OSError:
        return buf
    if chunk:
        buf += chunk.decode("utf-8", "replace")
    return buf


def read_until(child, needle, buf, timeout):
    deadline = time.time() + timeout
    while needle not in buf and child.poll() is None and time.time() < deadline:
        buf = read_some(child, buf)
    return buf


def wait_done(child, buf, timeout):
    deadline = time.time() + timeout
    while child.poll() is None and time.time() < deadline:
        buf = read_some(child, buf)
    if child.poll() is None:
        child.kill()
        fail("The recovery script did not finish.\n" + tail(buf))
    while True:
        ready, _, _ = select.select([child.fd], [], [], 0.1)
        if child.fd not in ready:
            break
        previous = buf
        buf = read_some(child, buf)
        if buf == previous:
            break
    return child.code, buf


def tail(buf):
    lines = buf.splitlines()
    kept = lines[-80:]
    return "\n".join(kept)


def run_script(home, cli, port, cwd, steps, timeout):
    script = str(REPO / "gallium-recover.sh")
    env = child_env(home, cli, port)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe(script, [script], env)
    child = ScriptChild(pid, fd)
    buf = ""
    try:
        for needle, reply in steps:
            buf = read_until(child, needle, buf, timeout)
            if needle not in buf:
                child.kill()
                fail(f"Did not see the prompt {needle!r}.\n" + tail(buf))
            os.write(fd, (reply + "\n").encode())
        code, buf = wait_done(child, buf, timeout)
    finally:
        if child.poll() is None:
            child.kill()
        os.close(fd)
    return code, buf


def create_steps(key_path, destination):
    return (
        ("example: create)", "create"),
        ("gallium-bank-key-LN-1.txt)", key_path),
        ("example: 7)", LOAN_INDEX),
        ("bc1qexampleaddress)", destination),
        ("example: 0.01)", PAY_AMOUNT),
    )


def complete_steps(key_path, payment_path, destination, amount):
    return (
        ("example: create)", "complete"),
        ("gallium-bank-key-LN-1.txt)", key_path),
        ("gallium-recovery-7.psbt.txt)", payment_path),
        ("example: 7)", LOAN_INDEX),
        ("bc1qexampleaddress)", destination),
        ("example: 0.01)", amount),
    )


def assert_not_spent(cli, port, address):
    scanned = rpc_json(cli, port, ["scantxoutset", "start", json.dumps([f"addr({address})"])])
    total = Decimal(str(scanned.get("total_amount")))
    if total != Decimal(FUND_AMOUNT):
        fail(f"Escrow no longer holds {FUND_AMOUNT} BTC before broadcast. It holds {total}.")
    mempool = rpc_json(cli, port, ["getrawmempool"])
    if len(mempool) != 0:
        fail("A transaction was broadcast before the second party confirmed.")


def received_by(cli, port, destination):
    raw = rpc(cli, port, ["-rpcwallet=faucet", "getreceivedbyaddress", destination, "1"]).strip()
    return Decimal(raw)


def main():
    if os.name == "nt" or not hasattr(os, "fork"):
        sys.stderr.write("This end-to-end test drives the terminal script on macOS and Linux.\n")
        return 2
    cli, daemon = find_core()
    work = tempfile.mkdtemp(prefix="gallium-recovery-e2e-")
    datadir = str(Path(work) / "datadir")
    home = str(Path(work) / "home")
    os.makedirs(datadir)
    os.makedirs(home)
    process = None
    log_handle = None
    port = None
    try:
        print("Starting a private regtest node.", flush=True)
        process, port, _log_path, log_handle = start_node(cli, daemon, datadir)
        modules = scure_modules(work)
        keys = make_keys(modules, work)
        bank_path = str(Path(work) / "bank-key.txt")
        borrower_path = str(Path(work) / "borrower-key.txt")
        write_backup(bank_path, "Bank", keys["bank"], keys["gallium"], keys["bank"]["xpub"], keys["borrower"]["xpub"])
        write_backup(
            borrower_path,
            "Borrower",
            keys["borrower"],
            keys["gallium"],
            keys["bank"]["xpub"],
            keys["borrower"]["xpub"],
        )
        deposit = deposit_address(cli, port, keys["gallium"], keys["bank"]["xpub"], keys["borrower"]["xpub"])
        print("Funding the escrow deposit address.", flush=True)
        destination = fund_escrow(cli, port, deposit)
        print("Bank creates the payment.", flush=True)
        code, transcript = run_script(home, cli, port, work, create_steps(bank_path, destination), SCRIPT_TIMEOUT)
        if code != 0 or "Nothing has been broadcast." not in transcript:
            fail("Create did not leave an unbroadcast payment.\n" + tail(transcript))
        payment = str(Path(work) / f"gallium-recovery-{LOAN_INDEX}.psbt.txt")
        if not os.path.isfile(payment):
            fail("The payment file was not written.")
        payment_text = Path(payment).read_text(encoding="utf-8")
        if keys["bank"]["xprv"] in payment_text or keys["borrower"]["xprv"] in payment_text:
            fail("The payment file contains an extended private key.")
        assert_not_spent(cli, port, deposit)
        print("Borrower rejects a different amount.", flush=True)
        code, transcript = run_script(
            home,
            cli,
            port,
            work,
            complete_steps(borrower_path, payment, destination, WRONG_AMOUNT),
            SCRIPT_TIMEOUT,
        )
        if code == 0 or "does not match" not in transcript:
            fail("A mismatched amount was accepted.\n" + tail(transcript))
        assert_not_spent(cli, port, deposit)
        print("Borrower checks the fee and broadcasts.", flush=True)
        code, transcript = run_script(
            home,
            cli,
            port,
            work,
            complete_steps(borrower_path, payment, destination, PAY_AMOUNT) + (
                ("Broadcast this payment", "y"),
                ("Mine 1 block now?", "y"),
            ),
            SCRIPT_TIMEOUT,
        )
        if code != 0 or "Broadcast transaction " not in transcript:
            fail("Complete did not broadcast.\n" + tail(transcript))
        txid = ""
        for line in transcript.splitlines():
            if line.startswith("Broadcast transaction "):
                txid = line[len("Broadcast transaction "):].strip()
        if len(txid) != 64:
            fail("Complete did not print a transaction id.\n" + tail(transcript))
        got = received_by(cli, port, destination)
        if got != Decimal(PAY_AMOUNT):
            fail(f"Destination received {got} BTC. The payment was {PAY_AMOUNT} BTC, with the fee on top.")
        print(f"Destination received {PAY_AMOUNT} BTC. Transaction {txid}.", flush=True)
        print("e2e ok", flush=True)
        return 0
    except E2EFailure as exc:
        sys.stderr.write(str(exc) + "\n")
        return 1
    finally:
        if process is not None and port is not None:
            stop_node(cli, port, process)
        if log_handle is not None:
            log_handle.close()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
