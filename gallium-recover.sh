#!/usr/bin/env bash
# Spend a Gallium escrow with the bank and borrower key backup files.
#
#   ./gallium-recover.sh
#
# One party creates a partially signed payment for an amount and a destination.
# The other party checks that payment and finishes it with their own key.
# Neither party needs the other party's private key.
#
# The script finds Bitcoin Core 27 or newer, or asks before installing 27.1.
# On macOS it signs the binaries. It starts a node on this computer when one
# is not already running. On regtest it asks for the host that already has the
# chain and peers to port 18444. The key file stays on this computer.
#
# Optional, when bitcoin-cli cannot use the node's default cookie:
#   BITCOIN_RPC_HOST BITCOIN_RPC_PORT BITCOIN_RPC_USER BITCOIN_RPC_PASSWORD

set -euo pipefail

SCRIPT_VERSION="2.0.0"
CORE_VERSION="27.1"
CORE_MAJOR=27
INSTALL_ROOT="${HOME}/.gallium-recovery/bitcoin-core-${CORE_VERSION}"

usage() {
  echo "Usage: ./gallium-recover.sh" >&2
  echo "The script asks whether to create a payment or complete one, then asks for your key file." >&2
  exit 1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

prompt_line() {
  local label="$1"
  local answer=""
  if [[ ! -r /dev/tty ]]; then
    echo "A terminal is required to enter ${label}." >&2
    exit 1
  fi
  while [[ -z "${answer}" ]]; do
    read -r -p "${label}: " answer </dev/tty
    answer="$(trim "${answer}")"
  done
  printf '%s' "${answer}"
}

prompt_optional() {
  local label="$1"
  local answer=""
  if [[ ! -r /dev/tty ]]; then
    echo "A terminal is required to enter ${label}." >&2
    exit 1
  fi
  read -r -p "${label}: " answer </dev/tty
  trim "${answer}"
}

confirm() {
  local prompt="$1"
  local answer
  if [[ ! -r /dev/tty ]]; then
    echo "A terminal is required to confirm: ${prompt}" >&2
    exit 1
  fi
  read -r -p "${prompt} [y/N] " answer </dev/tty
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

field_value() {
  local file="$1"
  local label="$2"
  sed -n "s/^${label}: //p" "${file}" | head -n 1
}

next_line() {
  local file="$1"
  local label="$2"
  awk -v label="${label}" '$0 == label { getline; print; exit }' "${file}"
}

replace_all() {
  local input="$1"
  local old="$2"
  local new="$3"
  local out=""
  while [[ "${input}" == *"${old}"* ]]; do
    out="${out}${input%%"${old}"*}${new}"
    input="${input#*"${old}"}"
  done
  printf '%s%s' "${out}" "${input}"
}

load_key_file() {
  local file="$1"
  local prefix="$2"
  local role network gallium xprv origin xpub
  role="$(field_value "${file}" "Role")"
  network="$(field_value "${file}" "Network")"
  gallium="$(next_line "${file}" "Gallium account key:")"
  xprv="$(next_line "${file}" "Account extended private key:")"
  if [[ -z "${role}" || -z "${network}" || -z "${gallium}" || -z "${xprv}" ]]; then
    echo "Could not read a Gallium key backup: ${file}" >&2
    echo "The file must contain Role, Network, Gallium account key, and Account extended private key." >&2
    exit 1
  fi
  case "${xprv}" in
    *[!A-Za-z0-9]*)
      echo "Account extended private key is not a single key in ${file}." >&2
      exit 1
      ;;
  esac
  if [[ "${gallium}" != "["*"]"* ]]; then
    echo "Gallium account key is not an account key in ${file}." >&2
    exit 1
  fi
  origin="${gallium%%]*}"
  xpub="${gallium#*]}"
  if [[ -z "${origin}" || -z "${xpub}" || "${xpub}" == *"/"* ]]; then
    echo "Gallium account key is not an account key in ${file}." >&2
    exit 1
  fi
  printf -v "${prefix}_role" '%s' "${role}"
  printf -v "${prefix}_network" '%s' "${network}"
  printf -v "${prefix}_gallium" '%s' "${gallium}"
  printf -v "${prefix}_origin" '%s' "${origin}"
  printf -v "${prefix}_xpub" '%s' "${xpub}"
  printf -v "${prefix}_xprv" '%s' "${xprv}"
  printf -v "${prefix}_own_xpub" '%s' "$(next_line "${file}" "Account public key (xpub):")"
  printf -v "${prefix}_bank" '%s' "$(next_line "${file}" "Bank account key:")"
  printf -v "${prefix}_borrower" '%s' "$(next_line "${file}" "Borrower account key:")"
}

fill_public_keys() {
  local file="$1"
  local network gallium bank borrower
  network="$(field_value "${file}" "Network")"
  gallium="$(next_line "${file}" "Gallium account key:")"
  bank="$(next_line "${file}" "Bank account key:")"
  borrower="$(next_line "${file}" "Borrower account key:")"
  if [[ -z "${network}" || -z "${gallium}" || -z "${bank}" || -z "${borrower}" ]]; then
    echo "Could not read the escrow public keys: ${file}" >&2
    exit 1
  fi
  if [[ "${network}" != "${NETWORK}" || "${gallium}" != "${GALLIUM}" ]]; then
    echo "Those public keys are not for this key backup's network and Gallium key." >&2
    exit 1
  fi
  if [[ -z "${BANK_XPUB}" ]]; then
    BANK_XPUB="${bank}"
  fi
  if [[ -z "${BORROWER_XPUB}" ]]; then
    BORROWER_XPUB="${borrower}"
  fi
}

use_key_file() {
  local file="$1"
  load_key_file "${file}" OWN
  ROLE="${OWN_role}"
  NETWORK="${OWN_network}"
  GALLIUM="${OWN_gallium}"
  ORIGIN="${OWN_origin}"
  GALLIUM_XPUB="${OWN_xpub}"
  XPRV="${OWN_xprv}"
  BANK_XPUB="${OWN_bank}"
  BORROWER_XPUB="${OWN_borrower}"
  if [[ "${ROLE}" == "Bank" && -z "${BANK_XPUB}" ]]; then
    BANK_XPUB="${OWN_own_xpub}"
  fi
  if [[ "${ROLE}" == "Borrower" && -z "${BORROWER_XPUB}" ]]; then
    BORROWER_XPUB="${OWN_own_xpub}"
  fi
  if [[ -z "${BANK_XPUB}" || -z "${BORROWER_XPUB}" ]]; then
    echo "This key file does not include the other party's public key."
    local public_file
    public_file="$(prompt_line "Path to the escrow public keys file")"
    public_file="${public_file/#\~/${HOME}}"
    if [[ ! -f "${public_file}" ]]; then
      echo "No file was found at that path." >&2
      exit 1
    fi
    fill_public_keys "${public_file}"
  fi
  if [[ -z "${BANK_XPUB}" || -z "${BORROWER_XPUB}" ]]; then
    echo "The bank and borrower public keys are required." >&2
    exit 1
  fi
  require_key_token "Bank account key" "${BANK_XPUB}"
  require_key_token "Borrower account key" "${BORROWER_XPUB}"
  if [[ "${ROLE}" == "Bank" && -n "${OWN_own_xpub}" && "${BANK_XPUB}" != "${OWN_own_xpub}" ]]; then
    echo "The bank public key in this file does not match Account public key (xpub)." >&2
    exit 1
  fi
  if [[ "${ROLE}" == "Borrower" && -n "${OWN_own_xpub}" && "${BORROWER_XPUB}" != "${OWN_own_xpub}" ]]; then
    echo "The borrower public key in this file does not match Account public key (xpub)." >&2
    exit 1
  fi
  if [[ "${BANK_XPUB}" == "${BORROWER_XPUB}" ]]; then
    echo "The bank and borrower public keys are the same." >&2
    exit 1
  fi
  if [[ "${ROLE}" != "Bank" && "${ROLE}" != "Borrower" ]]; then
    echo "Unrecognized key backup role: ${ROLE}" >&2
    exit 1
  fi
  case "${NETWORK}" in
    mainnet | testnet | signet | regtest) ;;
    *)
      echo "Unsupported Bitcoin network: ${NETWORK}" >&2
      exit 1
      ;;
  esac
}

core_archive() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  case "${os}:${arch}" in
    Linux:x86_64)
      ARCHIVE="bitcoin-${CORE_VERSION}-x86_64-linux-gnu.tar.gz"
      SHA256="c9840607d230d65f6938b81deaec0b98fe9cb14c3a41a5b13b2c05d044a48422"
      ;;
    Linux:aarch64)
      ARCHIVE="bitcoin-${CORE_VERSION}-aarch64-linux-gnu.tar.gz"
      SHA256="bb878df4f8ff8fb8acfb94207c50f959c462c39e652f507c2a2db20acc6a1eee"
      ;;
    Darwin:arm64)
      ARCHIVE="bitcoin-${CORE_VERSION}-arm64-apple-darwin.tar.gz"
      SHA256="ad4a3fd484077224a82dd56d194efb6e614467f413ab1dfb8776da4d08a4c227"
      ;;
    Darwin:x86_64)
      ARCHIVE="bitcoin-${CORE_VERSION}-x86_64-apple-darwin.tar.gz"
      SHA256="6d94bde5541a18964c1c36b0f12334004e45e195f244e381fd459827b1fdc395"
      ;;
    *)
      echo "Automatic Bitcoin Core install is not available for ${os} ${arch}." >&2
      echo "Install Bitcoin Core ${CORE_VERSION} or newer, then run this script again." >&2
      exit 1
      ;;
  esac
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

install_core() {
  local archive sha work url
  core_archive
  archive="${ARCHIVE}"
  sha="${SHA256}"
  work="$(mktemp -d)"
  url="https://bitcoincore.org/bin/bitcoin-core-${CORE_VERSION}/${archive}"
  echo "Downloading Bitcoin Core ${CORE_VERSION}..."
  curl -fsSL "${url}" -o "${work}/${archive}"
  if [[ "$(sha256_of "${work}/${archive}")" != "${sha}" ]]; then
    echo "Bitcoin Core download did not match the published checksum." >&2
    rm -rf "${work}"
    exit 1
  fi
  tar -xzf "${work}/${archive}" -C "${work}"
  mkdir -p "${INSTALL_ROOT}"
  rm -rf "${INSTALL_ROOT}/bin"
  mv "${work}/bitcoin-${CORE_VERSION}/bin" "${INSTALL_ROOT}/bin"
  rm -rf "${work}"
  BITCOIN_CLI="${INSTALL_ROOT}/bin/bitcoin-cli"
  echo "Installed Bitcoin Core ${CORE_VERSION} at ${INSTALL_ROOT}."
}

read_core_version() {
  local cli="$1"
  local status=0
  local output=""
  CORE_VERSION_STATUS=0
  CORE_VERSION_MAJOR=""
  output="$("${cli}" -version 2>/dev/null)" || status=$?
  CORE_VERSION_STATUS="${status}"
  if [[ "${status}" -ne 0 ]]; then
    return 1
  fi
  output="${output%%$'\n'*}"
  CORE_VERSION_MAJOR="$(sed -n 's/.* v\([0-9][0-9]*\)\..*/\1/p' <<<"${output}")"
  CORE_VERSION_MAJOR="${CORE_VERSION_MAJOR%%$'\n'*}"
  [[ -n "${CORE_VERSION_MAJOR}" ]]
}

sign_dir() {
  local dir="$1"
  local name path
  for name in bitcoind bitcoin-cli bitcoin-tx bitcoin-wallet; do
    path="${dir}/${name}"
    if [[ -x "${path}" ]]; then
      codesign --force -s - "${path}"
    fi
  done
}

accept_cli() {
  local cli="$1"
  local dir
  dir="$(dirname "${cli}")"
  [[ -x "${cli}" && -x "${dir}/bitcoind" ]] || return 1
  if ! read_core_version "${cli}"; then
    if [[ "$(uname -s)" != "Darwin" || -n "${CORE_VERSION_MAJOR}" ]]; then
      return 1
    fi
    echo "macOS is blocking ${cli}."
    echo "The script will run:"
    echo "  codesign --force -s - ${dir}/bitcoind ${dir}/bitcoin-cli"
    confirm "Sign these Bitcoin Core binaries?" || return 1
    sign_dir "${dir}"
    read_core_version "${cli}" || return 1
  fi
  [[ "${CORE_VERSION_MAJOR}" -ge "${CORE_MAJOR}" ]] || return 1
  BITCOIN_CLI="${cli}"
  BITCOIND="${dir}/bitcoind"
}

locate_core() {
  local cli dir
  if [[ -n "${BITCOIN_CLI}" ]]; then
    if ! accept_cli "${BITCOIN_CLI}"; then
      echo "BITCOIN_CLI is set but is not usable Bitcoin Core ${CORE_MAJOR} or newer." >&2
      exit 1
    fi
    return 0
  fi
  if command -v bitcoin-cli >/dev/null 2>&1; then
    accept_cli "$(command -v bitcoin-cli)" && return 0
  fi
  if [[ -x "${INSTALL_ROOT}/bin/bitcoin-cli" ]]; then
    accept_cli "${INSTALL_ROOT}/bin/bitcoin-cli" && return 0
  fi
  shopt -s nullglob
  for dir in "${HOME}/Downloads"/bitcoin-*/bin "${HOME}/.gallium-recovery"/bitcoin-core-*/bin; do
    if [[ -x "${dir}/bitcoin-cli" ]]; then
      if accept_cli "${dir}/bitcoin-cli"; then
        shopt -u nullglob
        return 0
      fi
    fi
  done
  shopt -u nullglob
  for cli in /usr/local/bin/bitcoin-cli /opt/homebrew/bin/bitcoin-cli; do
    if [[ -x "${cli}" ]]; then
      accept_cli "${cli}" && return 0
    fi
  done
  return 1
}

maybe_persist_path() {
  local dir profile line
  dir="$(dirname "${BITCOIN_CLI}")"
  if command -v bitcoin-cli >/dev/null 2>&1 && [[ "$(command -v bitcoin-cli)" == "${BITCOIN_CLI}" ]]; then
    return 0
  fi
  case "${SHELL:-}" in
    */zsh) profile="${HOME}/.zshrc" ;;
    */bash) profile="${HOME}/.bashrc" ;;
    *) profile="${HOME}/.profile" ;;
  esac
  if [[ -f "${profile}" ]] && grep -F "${dir}" "${profile}" >/dev/null 2>&1; then
    return 0
  fi
  line="export PATH=\"${dir}:\$PATH\""
  echo "New terminals cannot see bitcoin-cli yet."
  echo "The script will add this line to ${profile}:"
  echo "  ${line}"
  if confirm "Add Bitcoin Core to ${profile}?"; then
    printf '\n%s\n' "${line}" >> "${profile}"
    echo "Added. This run already uses ${BITCOIN_CLI}."
  fi
}

valid_host() {
  local host="$1"
  [[ -n "${host}" && "${host}" != *[!A-Za-z0-9.:-]* ]]
}

peer_address() {
  local host="$1"
  if [[ "${host}" == *:* ]]; then
    printf '%s' "${host}"
  else
    printf '%s:18444' "${host}"
  fi
}

node_responds() {
  RPC_PROBE_STATUS=0
  RPC_PROBE_OUTPUT="$(bitcoin_cli getblockcount 2>&1)" || RPC_PROBE_STATUS=$?
  [[ "${RPC_PROBE_STATUS}" -eq 0 ]]
}

node_is_down() {
  [[ "${RPC_PROBE_OUTPUT}" == *"Could not connect"* || "${RPC_PROBE_OUTPUT}" == *"Connection refused"* ]]
}

node_is_starting() {
  [[ "${RPC_PROBE_OUTPUT}" == *"Loading"* || "${RPC_PROBE_OUTPUT}" == *"Starting"* || "${RPC_PROBE_OUTPUT}" == *"Verifying"* || "${RPC_PROBE_OUTPUT}" == *"-28"* ]]
}

wait_until_ready() {
  local info blocks headers ibd peers started now told=0
  started="$(date +%s)"
  echo "Waiting for Bitcoin Core..."
  while true; do
    if info="$(bitcoin_cli getblockchaininfo 2>/dev/null)"; then
      blocks="$(sed -n 's/.*"blocks": \([0-9][0-9]*\).*/\1/p' <<<"${info}")"
      headers="$(sed -n 's/.*"headers": \([0-9][0-9]*\).*/\1/p' <<<"${info}")"
      ibd="$(sed -n 's/.*"initialblockdownload": \([a-z]*\).*/\1/p' <<<"${info}")"
      blocks="${blocks%%$'\n'*}"
      headers="${headers%%$'\n'*}"
      ibd="${ibd%%$'\n'*}"
      if [[ "${NETWORK}" == "regtest" && -z "${REGTEST_PEER}" && -n "${blocks}" && "${blocks}" == "${headers}" ]]; then
        echo "Bitcoin Core is ready. Block height ${blocks}."
        return 0
      elif [[ "${NETWORK}" == "regtest" && -n "${REGTEST_PEER}" ]]; then
        peers="$(bitcoin_cli getconnectioncount 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "${peers}" =~ ^[0-9]+$ ]] || peers=0
        if [[ "${peers}" -ge 1 && -n "${blocks}" && "${blocks}" -gt 0 && "${blocks}" == "${headers}" ]]; then
          echo "Connected to ${REGTEST_PEER}. Block height ${blocks}."
          return 0
        fi
        echo "Waiting for ${REGTEST_PEER}. Height ${blocks:-0}, peers ${peers}."
        if [[ "${peers}" -eq 0 ]]; then
          now="$(date +%s)"
          if [[ $((now - started)) -gt 90 ]]; then
            echo "Could not connect to ${REGTEST_PEER}." >&2
            echo "Port 18444 on that host must accept connections from this computer." >&2
            exit 1
          fi
        fi
      elif [[ "${ibd}" == "false" && -n "${blocks}" && "${blocks}" == "${headers}" ]]; then
        echo "Bitcoin Core is ready. Block height ${blocks}."
        return 0
      else
        echo "Syncing ${blocks:-0} of ${headers:-0} blocks."
        if [[ "${told}" -eq 0 ]]; then
          echo "Sync can take a long time. Stop this script and run it again later; the node keeps syncing."
          told=1
        fi
      fi
    elif [[ "${NETWORK}" == "regtest" && -n "${REGTEST_PEER}" ]]; then
      now="$(date +%s)"
      if [[ $((now - started)) -gt 90 ]]; then
        echo "Could not connect to ${REGTEST_PEER}." >&2
        echo "Port 18444 on that host must accept connections from this computer." >&2
        exit 1
      fi
    fi
    sleep 2
  done
}

start_node() {
  local args=() host peer
  case "${NETWORK}" in
    mainnet)
      args=(-daemon)
      ;;
    testnet)
      args=(-testnet -daemon)
      ;;
    signet)
      args=(-signet -daemon)
      ;;
    regtest)
      echo "No regtest node is running on this computer."
      echo "If the coins are on another machine, enter that machine's address."
      echo "Its peer port 18444 must accept connections from this computer."
      echo "Leave the address blank to start an empty regtest node on this computer."
      host="$(prompt_optional "Regtest host address")"
      args=(-regtest -daemon -fallbackfee=0.0002)
      if [[ -n "${host}" ]]; then
        if ! valid_host "${host}"; then
          echo "That host address is not valid. Enter an IP address or a hostname." >&2
          exit 1
        fi
        peer="$(peer_address "${host}")"
        REGTEST_PEER="${peer}"
        args+=("-connect=${peer}")
      fi
      ;;
  esac
  echo "The script will run:"
  echo "  ${BITCOIND} ${args[*]}"
  confirm "Start Bitcoin Core?" || exit 1
  if ! "${BITCOIND}" "${args[@]}"; then
    echo "Could not start Bitcoin Core." >&2
    exit 1
  fi
  STARTED_NODE=1
}

prepare_node() {
  if ! locate_core; then
    echo "The script will download Bitcoin Core ${CORE_VERSION} from bitcoincore.org into ${INSTALL_ROOT}."
    confirm "Install Bitcoin Core ${CORE_VERSION}?" || exit 1
    install_core
    if [[ "$(uname -s)" == "Darwin" ]]; then
      echo "Signing Bitcoin Core so macOS will run it."
      sign_dir "${INSTALL_ROOT}/bin"
    fi
    if ! read_core_version "${BITCOIN_CLI}"; then
      echo "Bitcoin Core ${CORE_VERSION} is still not available." >&2
      exit 1
    fi
    if [[ "${CORE_VERSION_MAJOR}" -lt "${CORE_MAJOR}" ]]; then
      echo "Bitcoin Core ${CORE_VERSION} is still not available." >&2
      exit 1
    fi
    BITCOIND="${INSTALL_ROOT}/bin/bitcoind"
  fi
  maybe_persist_path
  if node_responds || node_is_starting; then
    wait_until_ready
    return
  fi
  if node_is_down; then
    start_node
    wait_until_ready
    return
  fi
  echo "${RPC_PROBE_OUTPUT}" >&2
  echo "Bitcoin Core is not accepting local commands. The keys stay on this computer." >&2
  exit 1
}

finish_regtest() {
  local address
  [[ "${NETWORK}" == "regtest" ]] || return 0
  echo "The script can mine 1 block so other machines see this payment."
  echo "It will run: ${BITCOIN_CLI} -regtest -rpcwallet=mine generatetoaddress 1 <new address>"
  if confirm "Mine 1 block now?"; then
    if ! bitcoin_cli createwallet mine >/dev/null 2>&1; then
      load_err="$(bitcoin_cli loadwallet mine 2>&1 >/dev/null || true)"
      if [[ -n "${load_err}" && "${load_err}" != *"already loaded"* ]]; then
        echo "${load_err}" >&2
        exit 1
      fi
    fi
    address="$(bitcoin_cli -rpcwallet=mine getnewaddress)"
    bitcoin_cli -rpcwallet=mine generatetoaddress 1 "${address}"
  fi
  if [[ "${STARTED_NODE}" -eq 1 ]]; then
    echo "The script will run: ${BITCOIN_CLI} -regtest stop"
    if confirm "Stop the local regtest node?"; then
      bitcoin_cli stop >/dev/null || true
      echo "Stopped Bitcoin Core."
    fi
  fi
}

bitcoin_cli() {
  local args=()
  if [[ "${NETWORK}" != "mainnet" ]]; then
    args+=("-${NETWORK}")
  fi
  if [[ -n "${BITCOIN_RPC_HOST:-}" ]]; then
    args+=("-rpcconnect=${BITCOIN_RPC_HOST}")
  fi
  if [[ -n "${BITCOIN_RPC_PORT:-}" ]]; then
    args+=("-rpcport=${BITCOIN_RPC_PORT}")
  fi
  if [[ -n "${BITCOIN_RPC_USER:-}" ]]; then
    args+=("-rpcuser=${BITCOIN_RPC_USER}")
  fi
  if [[ -n "${BITCOIN_RPC_PASSWORD:-}" ]]; then
    args+=("-rpcpassword=${BITCOIN_RPC_PASSWORD}")
  fi
  "${BITCOIN_CLI}" "${args[@]}" "$@"
}

checksum_for() {
  local info sum
  if ! info="$(bitcoin_cli getdescriptorinfo "$1" 2>&1)"; then
    echo "${info}" >&2
    echo "Bitcoin Core on this computer did not accept the descriptor." >&2
    exit 1
  fi
  sum="$(sed -n 's/.*"checksum": "\([^"]*\)".*/\1/p' <<<"${info}")"
  sum="${sum%%$'\n'*}"
  if [[ -z "${sum}" ]]; then
    echo "Bitcoin Core did not return a descriptor checksum." >&2
    exit 1
  fi
  printf '%s' "${sum}"
}

signing_key() {
  local which="$1"
  local xpub
  if [[ "${which}" == "Bank" ]]; then
    xpub="${BANK_XPUB}"
  else
    xpub="${BORROWER_XPUB}"
  fi
  if [[ "${ROLE}" == "${which}" ]]; then
    printf '%s' "${XPRV}"
  else
    printf '%s' "${xpub}"
  fi
}

prepare_descriptor() {
  local bank borrower descriptor
  bank="$(signing_key "Bank")"
  borrower="$(signing_key "Borrower")"
  descriptor="wsh(sortedmulti(2,${ORIGIN}/${LOAN_INDEX}]${GALLIUM_XPUB}/${LOAN_INDEX}/<0;1>/*,${bank}/${LOAN_INDEX}/<0;1>/*,${borrower}/${LOAN_INDEX}/<0;1>/*))"
  EXTERNAL="$(replace_all "${descriptor}" "/<0;1>/*" "/0/*")"
  CHANGE="$(replace_all "${descriptor}" "/<0;1>/*" "/1/*")"
}

valid_amount() {
  [[ "$1" =~ ^[0-9]+([.][0-9]{1,8})?$ ]] || return 1
  awk -v amount="$1" 'BEGIN { exit !(amount + 0 > 0) }'
}

valid_destination() {
  [[ "$1" =~ ^[A-Za-z0-9]+$ ]]
}

require_key_token() {
  local label="$1"
  local value="$2"
  case "${value}" in
    *[!A-Za-z0-9]*)
      echo "${label} is not a single key." >&2
      exit 1
      ;;
  esac
}

read_psbt_bundle() {
  local file="$1"
  local seen=0 line
  PSBT_BODY=""
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${seen}" -eq 1 ]]; then
      PSBT_BODY="${PSBT_BODY}${line}"
    fi
    if [[ "${line}" == "PSBT:" ]]; then
      seen=1
    fi
  done < "${file}"
  if [[ -z "${PSBT_BODY}" ]]; then
    echo "That file does not contain a Gallium recovery PSBT." >&2
    exit 1
  fi
}

open_wallet() {
  local slug
  slug="$(printf '%s' "${ROLE}" | tr '[:upper:]' '[:lower:]')"
  WALLET="gallium-recovery-${LOAN_INDEX}-${slug}"
  FRESH_WALLET=0
  if bitcoin_cli -named createwallet "wallet_name=${WALLET}" blank=true descriptors=true >/dev/null 2>&1; then
    FRESH_WALLET=1
  else
    load_err="$(bitcoin_cli loadwallet "${WALLET}" 2>&1 >/dev/null || true)"
    if [[ -n "${load_err}" && "${load_err}" != *"already loaded"* ]]; then
      echo "${load_err}" >&2
      exit 1
    fi
  fi
  if [[ "${FRESH_WALLET}" -eq 1 ]]; then
    EXTERNAL_SUM="$(checksum_for "${EXTERNAL}")"
    CHANGE_SUM="$(checksum_for "${CHANGE}")"
    IMPORT="$(bitcoin_cli -rpcwallet="${WALLET}" importdescriptors "[{\"desc\":\"${EXTERNAL}#${EXTERNAL_SUM}\",\"active\":true,\"internal\":false,\"range\":[0,20],\"timestamp\":0},{\"desc\":\"${CHANGE}#${CHANGE_SUM}\",\"active\":true,\"internal\":true,\"range\":[0,20],\"timestamp\":0}]")"
    SUCCESS_COUNT="$(printf '%s' "${IMPORT}" | grep -o '"success": *true' | wc -l | tr -d ' ' || true)"
    if [[ "${SUCCESS_COUNT}" != "2" ]]; then
      echo "Bitcoin Core rejected the recovery descriptors." >&2
      echo "${IMPORT}" >&2
      exit 1
    fi
  fi
}

derived_addresses() {
  local receive change
  if [[ -z "${EXTERNAL_SUM:-}" ]]; then
    EXTERNAL_SUM="$(checksum_for "${EXTERNAL}")"
    CHANGE_SUM="$(checksum_for "${CHANGE}")"
  fi
  receive="$(bitcoin_cli deriveaddresses "${EXTERNAL}#${EXTERNAL_SUM}" "[0,20]")"
  change="$(bitcoin_cli deriveaddresses "${CHANGE}#${CHANGE_SUM}" "[0,20]")"
  printf '{"receive":%s,"change":%s}' "${receive}" "${change}"
}

check_psbt() {
  local decoded addresses
  decoded="$(bitcoin_cli decodepsbt "${PSBT_BODY}")"
  addresses="$(derived_addresses)"
  DECODED_JSON="${decoded}" ADDRESS_JSON="${addresses}" EXPECT_DESTINATION="${DESTINATION}" EXPECT_AMOUNT="${AMOUNT}" python3 - <<'PY'
import json, os, sys
from decimal import Decimal

decoded = json.loads(os.environ["DECODED_JSON"], parse_float=Decimal)
payload = json.loads(os.environ["ADDRESS_JSON"])
expect_destination = os.environ["EXPECT_DESTINATION"]
expect_amount = Decimal(os.environ["EXPECT_AMOUNT"])
allowed = set(payload["receive"])
for address in payload["change"]:
    allowed.add(address)

scale = Decimal("100000000")
payment = None
for output in decoded["tx"]["vout"]:
    script = output.get("scriptPubKey") or {}
    address = script.get("address")
    value = output.get("value")
    if not address or value is None:
        sys.stderr.write("The payment has an output Bitcoin Core could not identify.\n")
        sys.exit(1)
    if address in allowed:
        continue
    if payment is not None:
        sys.stderr.write("The payment has more than one destination.\n")
        sys.exit(1)
    payment = (address, value)

if payment is None:
    sys.stderr.write("The payment does not pay the destination from this escrow.\n")
    sys.exit(1)
paid_sats = (payment[1] * scale).to_integral_value()
expect_sats = (expect_amount * scale).to_integral_value()
if payment[0] != expect_destination or paid_sats != expect_sats:
    sys.stderr.write("The payment destination or amount does not match what you entered.\n")
    sys.stderr.write(f"PSBT pays {payment[1]} BTC to {payment[0]}.\n")
    sys.exit(1)

for item in decoded.get("inputs", []):
    witness = item.get("witness_utxo") or {}
    script = witness.get("scriptPubKey") or {}
    address = script.get("address")
    if address not in allowed:
        sys.stderr.write("The payment spends a coin that is not in this escrow.\n")
        sys.exit(1)

fee = decoded.get("fee")
if fee is None:
    sys.stderr.write("Bitcoin Core did not report a fee for this payment.\n")
    sys.exit(1)
print(fee)
PY
}

require_python() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to read the payment." >&2
    exit 1
  fi
}

json_string_field() {
  local field="$1"
  python3 -c '
import json, sys
data = json.load(sys.stdin)
value = data.get(sys.argv[1])
if not isinstance(value, str) or value == "":
    sys.stderr.write("Bitcoin Core did not return the payment.\n")
    sys.exit(1)
sys.stdout.write(value)
' "${field}"
}

signed_transaction_hex() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
if data.get("complete") is not True:
    sys.stderr.write("The payment still needs another signature.\n")
    sys.exit(1)
value = data.get("hex")
if not isinstance(value, str) or value == "":
    sys.stderr.write("Bitcoin Core did not return a signed transaction.\n")
    sys.exit(1)
sys.stdout.write(value)
'
}

write_psbt_file() {
  local path="$1"
  local fee="$2"
  if [[ -e "${path}" ]]; then
    echo "A file named ${path} already exists in this folder. Move it, then run this again." >&2
    exit 1
  fi
  {
    echo "Gallium recovery payment"
    echo "Network: ${NETWORK}"
    echo "Loan index: ${LOAN_INDEX}"
    echo "Amount: ${AMOUNT} BTC"
    echo "Destination: ${DESTINATION}"
    echo "Fee: ${fee} BTC"
    echo "PSBT:"
    echo "${PSBT_BODY}"
  } >"${path}"
}

build_psbt() {
  local result
  if [[ "${NETWORK}" == "regtest" ]]; then
    result="$(bitcoin_cli -rpcwallet="${WALLET}" -named send "outputs={\"${DESTINATION}\":${AMOUNT}}" fee_rate=2 psbt=true)"
  else
    result="$(bitcoin_cli -rpcwallet="${WALLET}" -named send "outputs={\"${DESTINATION}\":${AMOUNT}}" psbt=true)"
  fi
  PSBT_BODY="$(printf '%s' "${result}" | json_string_field psbt)"
}

validate_payment_fields() {
  if [[ ! "${LOAN_INDEX}" =~ ^[0-9]+$ ]]; then
    echo "Loan index must be the number shown on the loan." >&2
    exit 1
  fi
  if ! valid_destination "${DESTINATION}"; then
    echo "Destination address is invalid." >&2
    exit 1
  fi
  if ! valid_amount "${AMOUNT}"; then
    echo "Amount must be a positive number of BTC with at most 8 decimal places." >&2
    exit 1
  fi
}

self_test() {
  local dir
  dir="$(mktemp -d)"
  cat >"${dir}/bank.txt" <<EOF
Role: Bank
Loan: LN-1
Network: regtest
Gallium account key:
[aa/48h/1h/0h/2h]tpubGallium
Account extended private key:
tprvBank
Account public key (xpub):
tpubBank
Borrower account key:
tpubBorrower
EOF
  use_key_file "${dir}/bank.txt"
  LOAN_INDEX=7
  prepare_descriptor
  [[ "${EXTERNAL}" == 'wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/0/*,tprvBank/7/0/*,tpubBorrower/7/0/*))' ]]
  [[ "${CHANGE}" == 'wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/1/*,tprvBank/7/1/*,tpubBorrower/7/1/*))' ]]
  [[ "${BANK_XPUB}" == "tpubBank" ]]

  cat >"${dir}/borrower.txt" <<EOF
Role: Borrower
Network: regtest
Gallium account key:
[aa/48h/1h/0h/2h]tpubGallium
Account extended private key:
tprvBorrower
Account public key (xpub):
tpubBorrower
Bank account key:
tpubBank
EOF
  use_key_file "${dir}/borrower.txt"
  prepare_descriptor
  [[ "${EXTERNAL}" == 'wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/0/*,tpubBank/7/0/*,tprvBorrower/7/0/*))' ]]
  [[ "${CHANGE}" == 'wsh(sortedmulti(2,[aa/48h/1h/0h/2h/7]tpubGallium/7/1/*,tpubBank/7/1/*,tprvBorrower/7/1/*))' ]]

  cat >"${dir}/own-only.txt" <<EOF
Role: Bank
Network: regtest
Gallium account key:
[aa/48h/1h/0h/2h]tpubGallium
Account extended private key:
tprvBank
Account public key (xpub):
tpubFromOwn
Borrower account key:
tpubBorrower
EOF
  use_key_file "${dir}/own-only.txt"
  [[ "${BANK_XPUB}" == "tpubFromOwn" ]]

  cat >"${dir}/partial.txt" <<EOF
Role: Borrower
Network: regtest
Gallium account key:
[aa/48h/1h/0h/2h]tpubGallium
Account extended private key:
tprvBorrower
EOF
  load_key_file "${dir}/partial.txt" OWN
  NETWORK="${OWN_network}"
  GALLIUM="${OWN_gallium}"
  BANK_XPUB=""
  BORROWER_XPUB="tpubKeep"
  cat >"${dir}/public.txt" <<EOF
Network: regtest
Gallium account key:
[aa/48h/1h/0h/2h]tpubGallium
Bank account key:
tpubBankPublic
Borrower account key:
tpubBorrowerPublic
EOF
  fill_public_keys "${dir}/public.txt"
  [[ "${BANK_XPUB}" == "tpubBankPublic" ]]
  [[ "${BORROWER_XPUB}" == "tpubKeep" ]]

  cat >"${dir}/wrong-public.txt" <<EOF
Network: signet
Gallium account key:
[aa/48h/1h/0h/2h]tpubGallium
Bank account key:
tpubBankPublic
Borrower account key:
tpubBorrowerPublic
EOF
  if ( fill_public_keys "${dir}/wrong-public.txt" ) >/dev/null 2>&1; then
    echo "expected a mismatched public key file to be rejected" >&2
    exit 1
  fi

  printf '%s\n' "Gallium recovery payment" "PSBT:" "cHNidP8BAH" >"${dir}/pay.txt"
  read_psbt_bundle "${dir}/pay.txt"
  [[ "${PSBT_BODY}" == "cHNidP8BAH" ]]

  if ! valid_amount "1.5" || ! valid_amount "0.00000001"; then
    echo "a positive BTC amount was rejected" >&2
    exit 1
  fi
  if valid_amount "0" || valid_amount "0.0" || valid_amount "1.123456789" || valid_amount "1 BTC"; then
    echo "an invalid BTC amount was accepted" >&2
    exit 1
  fi
  if ! valid_destination "bcrt1qexampleaddress"; then
    echo "a destination address was rejected" >&2
    exit 1
  fi
  if valid_destination "not an address" || valid_destination ""; then
    echo "an invalid destination was accepted" >&2
    exit 1
  fi
  valid_host "203.0.113.10"
  if valid_host "not a host"; then
    echo "an invalid host was accepted" >&2
    exit 1
  fi
  [[ "$(peer_address "203.0.113.10")" == "203.0.113.10:18444" ]]
  [[ "$(peer_address "127.0.0.1:18444")" == "127.0.0.1:18444" ]]
  rm -rf "${dir}"
  echo "self-test ok"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test
  exit 0
fi

if [[ "$#" -ne 0 ]]; then
  usage
fi

echo "gallium-recover.sh ${SCRIPT_VERSION}"
echo "One party creates a payment. The other party checks it and broadcasts it."
echo "Each person uses their own key file. The private key stays on this computer."
MODE="$(prompt_line "Type create or complete")"
MODE="$(printf '%s' "${MODE}" | tr '[:upper:]' '[:lower:]')"
if [[ "${MODE}" != "create" && "${MODE}" != "complete" ]]; then
  echo "Type create or complete." >&2
  exit 1
fi

KEY_FILE="$(prompt_line "Path to your key backup file")"
KEY_FILE="${KEY_FILE/#\~/${HOME}}"
if [[ ! -f "${KEY_FILE}" ]]; then
  echo "No file was found at that path." >&2
  exit 1
fi
use_key_file "${KEY_FILE}"

PSBT_FILE=""
if [[ "${MODE}" == "complete" ]]; then
  PSBT_FILE="$(prompt_line "Path to the payment file")"
  PSBT_FILE="${PSBT_FILE/#\~/${HOME}}"
  if [[ ! -f "${PSBT_FILE}" ]]; then
    echo "No file was found at that path." >&2
    exit 1
  fi
fi

LOAN_INDEX="$(prompt_line "Loan index")"
DESTINATION="$(prompt_line "Bitcoin address that receives the funds")"
AMOUNT="$(prompt_line "Amount the recipient receives, in BTC")"
validate_payment_fields
require_python

BITCOIN_CLI="${BITCOIN_CLI:-}"
BITCOIND=""
STARTED_NODE=0
REGTEST_PEER=""

prepare_descriptor
prepare_node
open_wallet

if [[ "${MODE}" == "create" ]]; then
  build_psbt
  FEE="$(check_psbt)"
  OUT_FILE="gallium-recovery-${LOAN_INDEX}.psbt.txt"
  write_psbt_file "${OUT_FILE}" "${FEE}"
  echo "Wrote ${OUT_FILE}"
  echo "Fee: ${FEE} BTC. Nothing has been broadcast."
  echo "Send that file to the other party. It contains a partially signed payment, not your private key."
else
  read_psbt_bundle "${PSBT_FILE}"
  FEE="$(check_psbt)"
  echo "Loan index ${LOAN_INDEX} on ${NETWORK}"
  echo "Pay ${AMOUNT} BTC to ${DESTINATION}"
  echo "Fee: ${FEE} BTC"
  if ! confirm "Broadcast this payment"; then
    echo "Stopped. Nothing was broadcast."
    exit 0
  fi
  processed="$(bitcoin_cli -rpcwallet="${WALLET}" walletprocesspsbt "${PSBT_BODY}")"
  signed="$(printf '%s' "${processed}" | json_string_field psbt)"
  final="$(bitcoin_cli finalizepsbt "${signed}")"
  hex="$(printf '%s' "${final}" | signed_transaction_hex)"
  txid="$(bitcoin_cli sendrawtransaction "${hex}")"
  echo "Broadcast transaction ${txid}"
  finish_regtest
fi
