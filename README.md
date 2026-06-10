# Simulate Wi-Fi Deauth Attack (Lab Only)

This project provides a Bash script for **Wi-Fi deauthentication simulation** in an isolated lab environment.

Main script: `simulate-attack.sh`

## Legal and Ethical Warning

Use this only for:

- networks you own, or
- networks where you have explicit written permission to test.

Do not use this on public or unauthorized networks. Misuse may violate the law.

## Project Goals

- Automate a basic deauth testing flow using `aircrack-ng`.
- Simplify target selection from `airodump-ng` scan results.
- Set monitor interface and target channel before sending deauth frames.

## System Requirements

- Linux (pentest/lab distro recommended).
- Wireless adapter that supports monitor mode and packet injection.
- Root privileges (`sudo`).
- Installed dependencies:
  - `airodump-ng`
  - `airmon-ng`
  - `aireplay-ng`
  - `iwconfig`
  - `iw`
  - `ip` (from `iproute2`)
  - `python3` (fallback parser for netxml when CSV is incomplete)

Note: macOS typically does not support this workflow natively like Linux.

## Requirements Installation (APT)

Install required system packages:

```bash
sudo apt-get update
sudo apt-get install -y \
  aircrack-ng wireless-tools iw iproute2 python3
```

## Quick Flow (Driver Installed vs Not Installed)

1) Check the driver:

```bash
lsmod | grep 8814au
```

2) If there is output (driver already installed) -> **go directly to `Usage`**.

3) If there is no output (driver not installed yet) -> follow **Install RTL8814AU Driver**, then run the script.

## Install RTL8814AU Driver (If Not Installed)

This section is for USB adapters using the `rtl8814au` chipset when monitor mode/injection is not working yet.

### 1) Check the driver

```bash
lsmod | grep 8814au
```

If there is no output, continue with driver installation.

### 2) Install the driver

```bash
sudo apt-get update
sudo apt-get install -y git build-essential linux-headers-$(uname -r)
sudo apt install -y gcc make bc linux-headers-$(uname -r) build-essential git dkms rfkill iw openssl mokutil

TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"
git clone https://github.com/morrownr/8814au.git
cd 8814au

# Prevent automatic reboot/shutdown from installer script
sed -i '/reboot/d' install-driver.sh
sed -i '/shutdown/d' install-driver.sh
sed -i '/systemctl reboot/d' install-driver.sh

# Run installer (answers: y then n)
sudo bash install-driver.sh <<< $'y\nn\n'
```

### 3) Configure USB mode (optional but recommended)

```bash
if [ -f "/etc/modprobe.d/8814au.conf" ]; then
  sudo sed -i \
    's/options 8814au rtw_switch_usb_mode=0 rtw_led_ctrl=1/options 8814au rtw_switch_usb_mode=1 rtw_led_ctrl=1/g' \
    /etc/modprobe.d/8814au.conf
fi
```

### 4) Verify

```bash
sudo modprobe 8814au
iw dev
```

If the interface appears, the driver is ready to use.

## Usage

```bash
sudo bash simulate-attack.sh <interface> [deauth_count]
```

Check your interface name first:

```bash
ip link | grep -E 'wlx|wlan'
```

Examples:

```bash
sudo bash simulate-attack.sh wlx00c0cab84bcf
sudo bash simulate-attack.sh wlx00c0cab84bcf 10
sudo SKIP_MODPROBE=1 bash simulate-attack.sh wlan0 10
```

Parameters:

- `<interface>`: initial Wi-Fi interface name (example: `wlx00c0cab84bcf` or `wlan0`)
- `[deauth_count]`:
  - `0` (default): send continuously until manually stopped (`Ctrl + C`)
  - any other number (e.g. `10`): number of deauth frames per burst

Environment variables:

- `SKIP_MODPROBE=1` — skip `modprobe 8814au` reload (non-RTL8814AU adapters)
- `AIRODUMP_BG=1` — background scan with timeout instead of fullscreen UI
- `SCAN_SECONDS=40` — scan timeout when `AIRODUMP_BG=1` (default: 20)

## Script Flow

1. Validate root, OS, and dependencies.
2. Reload `8814au` driver (unless `SKIP_MODPROBE=1`).
3. `airmon-ng start` → scan with `airodump-ng` on monitor interface (Ctrl+C when done).
4. Show AP list from CSV/netxml (PWR, channel, encryption, ESSID), then prompt for target.
5. `airmon-ng stop` → `airmon-ng start` again before deauth.
6. Set monitor channel to target channel.
7. Run `aireplay-ng --deauth`.
8. Clean up interfaces at the end.

## Additional Configuration

Background scan (no fullscreen airodump UI):

```bash
AIRODUMP_BG=1 SCAN_SECONDS=40 sudo bash simulate-attack.sh wlx00c0cab84bcf 10
```

## Quick Troubleshooting

- `Interface not found`: check interface name with `ip link | grep -E 'wlx|wlan'`.
- `Command not found`: install `aircrack-ng` / `wireless-tools`.
- `No AP detected`: run `sudo airmon-ng check kill`, ensure monitor mode works, move closer to AP, or use `AIRODUMP_BG=1 SCAN_SECONDS=60`.
- `Cannot detect monitor interface`: check `airmon-ng start <interface>` output manually.
- Channel hopping during scan: stop NetworkManager with `sudo airmon-ng check kill`.

## Disclaimer

This repository is intended for security learning and resilience testing in controlled environments. The user is fully responsible for how this tool is used.
