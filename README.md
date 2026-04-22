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
  - `awk`, `sed`, `mktemp`

Note: macOS typically does not support this workflow natively like Linux.

## Requirements Installation (APT)

Install required system packages:

```bash
sudo apt-get update
sudo apt-get install -y \
  aircrack-ng wireless-tools iw iproute2
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

Examples:

```bash
sudo bash simulate-attack.sh wlan0
sudo bash simulate-attack.sh wlan0 10
```

Parameters:

- `<interface>`: initial Wi-Fi interface name (example: `wlan0`)
- `[deauth_count]`:
  - `0` (default): send continuously until manually stopped (`Ctrl + C`)
  - any other number (e.g. `10`): number of deauth frames per burst

## Script Flow

1. Validate root, OS, and dependencies.
2. Scan networks using `airodump-ng` (default timeout: 20 seconds).
3. Show AP list from scan CSV, then prompt user to select target.
4. Run `airmon-ng start` to enable monitor interface.
5. Set monitor channel to target channel.
6. Run `aireplay-ng --deauth`.
7. Clean up interfaces at the end.

## Additional Configuration

You can change scan duration using an environment variable:

```bash
SCAN_SECONDS=40 sudo bash simulate-attack.sh wlan0 10
```

## Quick Troubleshooting

- `Interface not found`: check interface name with `ip link`.
- `Command not found`: install `aircrack-ng` / `wireless-tools`.
- `No AP detected`: ensure adapter supports monitor mode, move closer to AP, or increase `SCAN_SECONDS`.
- `Cannot detect monitor interface`: check `airmon-ng start <interface>` output manually.

## Disclaimer

This repository is intended for security learning and resilience testing in controlled environments. The user is fully responsible for how this tool is used.
