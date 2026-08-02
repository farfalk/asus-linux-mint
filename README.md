# ASUS Linux Tools Installer for Linux Mint

An automated installation script for [asusctl](https://github.com/OpenGamingCollective/asusctl) on ASUS ROG/TUF laptops running **Linux Mint**.

## 🚀 Features

- **Automated installation** of latest asusctl for Linux Mint
- **Release-tracking updates** packaged as a `.deb`, with rollback support
- **System firmware updates** via fwupd for optimal hardware compatibility
- **Kernel compatibility checking** with automatic upgrade options
- **NVIDIA driver preparation** with nouveau blacklist configuration
- **Comprehensive dependency management** including linux-firmware
- **Proper systemd service configuration** 
- **Comprehensive error handling** with colored output
- **Linux Mint compatibility** for version 22.3
- **Safe uninstallation** with complete cleanup
- **ASUS ROG/TUF hardware support** for all major laptop models

## 📋 Requirements

- **Linux Mint 22.3** (Cinnamon, MATE, or Xfce edition)
- **ASUS ROG/TUF laptop** with compatible hardware
- **Internet connection** for downloading dependencies
- **Sudo privileges** for system modifications

## 🧰 Kernel

- Default: Linux Mint 22.3 ships the HWE kernel 6.14, which is recommended and sufficient for ASUS laptops.
- Optional: If you need newer hardware fixes, you can install a newer mainline kernel and keep 6.14 as fallback.

### 🔧 Optional: Install a newer mainline kernel

If you need bleeding‑edge support or want to test newer kernels, you can install a mainline kernel and retain the distro kernel as a backup:

<details>
<summary>📋 Click to expand mainline kernel installation methods</summary>

**⚠️ Important Warnings:**
- Mainline kernels are experimental and unsigned
- Always keep a working kernel as backup
- You may need to reinstall NVIDIA drivers after kernel updates
- Test thoroughly before relying on mainline kernels

**Option 1: Ubuntu Mainline Kernel Installer**
```bash
# Install the mainline kernel tool
sudo apt install -y wget
wget -qO - https://raw.githubusercontent.com/pimlie/ubuntu-mainline-kernel.sh/master/ubuntu-mainline-kernel.sh | sudo bash

# Install latest stable kernel
sudo ubuntu-mainline-kernel.sh -i
```

**Option 2: Manual Installation**
1. Visit [Ubuntu Mainline Kernels](https://kernel.ubuntu.com/mainline/)
2. Download the latest stable mainline kernel packages for your architecture
3. Install using: `sudo dpkg -i *.deb`

**Option 3: GUI Tool (TuxInvader)**
```bash
sudo add-apt-repository ppa:tuxinvader/mainline
sudo apt update && sudo apt install mainline
# Launch 'mainline' GUI and install latest kernel
```

</details>

## 🛠️ Installation

### Quick Install (Recommended)

```bash
curl -sSL https://raw.githubusercontent.com/andreas-glaser/asus-linux-mint/main/install-asus-linux.sh | bash
```

### Manual Install

```bash
# Download the script
wget https://raw.githubusercontent.com/andreas-glaser/asus-linux-mint/main/install-asus-linux.sh

# Make it executable
chmod +x install-asus-linux.sh

# Run the installer
./install-asus-linux.sh
```

### Custom Build Directory

```bash
# Use custom directory for build files
ASUS_BUILD_DIR="/opt/asus-build" ./install-asus-linux.sh
```

### Optional: Install ROG Control Center (GUI)

By default, the installer includes `rog-control-center` (GUI).

```bash
# Skip the GUI (CLI + daemon only)
ASUS_INSTALL_ROG_GUI=0 ./install-asus-linux.sh
```

## 🔄 Updating

`update-asus-linux.sh` updates an existing installation to the latest **tagged release** of
[asusctl](https://github.com/OpenGamingCollective/asusctl).

Upstream publishes release tags but only ships Arch Linux binaries, so the script builds the
pinned tag from source, then wraps the result in a `.deb` and installs it with apt. dpkg
therefore owns the files, which gives you version tracking, clean upgrades, and rollback.

```bash
# See what's installed and what's available (changes nothing)
./update-asus-linux.sh --check

# Build and install the latest release
./update-asus-linux.sh

# Build a specific release
./update-asus-linux.sh --tag 6.3.10

# Go back to the previously installed version
./update-asus-linux.sh --rollback
```

### Already installed with `install-asus-linux.sh`?

**Run the updater directly. Do not uninstall first.** The first run converts your existing
file-based install into the `asusctl-ogc` package: it removes the leftovers that upstream has
since renamed, and dpkg takes ownership of the rest. Running `uninstall-asus-linux.sh` first
would offer to delete your `/etc/asusd` settings, the build directory and the Rust toolchain,
all of which the updater reuses.

After the conversion:

```bash
dpkg-query -W asusctl-ogc          # which version is installed
sudo apt remove asusctl-ogc        # remove everything the package owns
```

Your settings in `/etc/asusd` (fan curves, profiles, LED settings) are **not** part of the
package and survive upgrades and removal.

> **Once you have converted, stop using `uninstall-asus-linux.sh`.** Deleting package-owned
> files behind dpkg's back leaves the package database inconsistent. Use `apt remove` instead.

### Rolling back

`--rollback` reinstalls a `.deb` from the local cache, so it only works once the updater has
built at least one package. On your **first** update there is nothing cached yet; to go back to
a specific earlier release, rebuild it by tag:

```bash
./update-asus-linux.sh --tag 6.3.8

# Which release is the current install based on?
git -C ~/.local/src/asus-linux/asusctl describe --tags
```

### Optional: weekly update check

```bash
# Notifies when a new release appears; never builds or installs on its own
./update-asus-linux.sh --install-timer
./update-asus-linux.sh --remove-timer
```

> **Note:** the update still compiles asusctl from source, so it needs the Rust toolchain and
> build dependencies installed by `install-asus-linux.sh`, and it takes several minutes.

## 📦 What Gets Installed

### Core Components
- **asusctl** - Primary ASUS laptop control utility
- **Rust toolchain** - Latest stable version via rustup
- **Build dependencies** - All required development packages
- **linux-firmware** - Essential hardware firmware blobs

### System Configuration
- **systemd services** - asusd, and asusd-user
- **udev rules** - Hardware detection and device permissions
- **DBus configuration** - Inter-process communication setup
- **Firmware updates** - Latest BIOS, EC, and device firmware
- **Kernel compatibility** - Ensures minimum required kernel version
- **NVIDIA preparation** - Nouveau driver blacklist for proper GPU switching

### Hardware Features Enabled
- **Fan curve control** - Custom cooling profiles
- **RGB lighting control** - Keyboard and logo lighting
- **Power profiles** - Battery optimization modes
- **GPU switching** - Integrated/Hybrid/Discrete modes
- **Keyboard shortcuts** - Fn key combinations
- **Thermal management** - Advanced cooling control

## 🔧 Usage

### Basic Commands

```bash
# Check ASUS laptop status
asusctl info

# Set fan curve to performance mode
asusctl fan-curve -p performance

# Control RGB lighting
asusctl led-pow -s on
asusctl led-mode static
```

### Service Management

```bash
# Check service status
sudo systemctl status asusd

# Restart services if needed
sudo systemctl restart asusd

# View service logs
sudo journalctl -u asusd.service -f
```

## 🗑️ Uninstallation

If you have updated with `update-asus-linux.sh`, asusctl is a normal package and apt removes
it cleanly:

```bash
sudo apt remove asusctl-ogc
```

The script below is for installations that were never converted to a package, and also removes
the extras the installer configured (nouveau blacklist, build directories, Rust toolchain).

### Quick Uninstall

```bash
curl -sSL https://raw.githubusercontent.com/andreas-glaser/asus-linux-mint/main/uninstall-asus-linux.sh | bash
```

### Manual Uninstall

```bash
# Download the uninstall script
wget https://raw.githubusercontent.com/andreas-glaser/asus-linux-mint/main/uninstall-asus-linux.sh

# Make it executable
chmod +x uninstall-asus-linux.sh

# Run the uninstaller
./uninstall-asus-linux.sh
```

### What Gets Removed
- All ASUS Linux tool binaries and libraries
- System services and configuration files
- Build directories and source code
- Desktop applications and icons
- Optional: nouveau blacklist configuration
- Optional: build directories

### What Gets Preserved
- System firmware updates
- Kernel upgrades
- System packages (linux-firmware, build tools)
- Rust toolchain
- User data and personal settings

## 🔍 Troubleshooting

### Common Issues

**Services not starting:**
```bash
# Check service logs
sudo journalctl -u asusd.service -n 50

# Reload and restart
sudo systemctl daemon-reload
```

**GPU switching not working:**
```bash
# Ensure nouveau is blacklisted
cat /etc/modprobe.d/blacklist-nouveau.conf

# Check GPU status
lspci | grep -i vga

# Reboot after GPU mode changes
sudo reboot
```

**Screen brightness is stuck dim or the slider does nothing (Cinnamon/X11):**
On some hybrid AMD/NVIDIA ASUS laptops, Cinnamon picks the NVIDIA firmware backlight (`nvidia_wmi_ec_backlight`) instead of the real panel backlight (`amdgpu_bl1`).

```bash
# Force Cinnamon to prefer the AMD raw backlight
gsettings set org.cinnamon.settings-daemon.plugins.power backlight-helper-force true
gsettings set org.cinnamon.settings-daemon.plugins.power backlight-helper-preference-order "['raw', 'platform', 'firmware']"
```

Log out and back in, or reboot. If it still fails after reboot, check `/sys/class/backlight/` and consider disabling `nvidia_wmi_ec_backlight` system-wide.

**Permission issues:**
```bash
# Check user groups
groups $USER

# Add user to appropriate groups
sudo usermod -a -G users $USER
```

**Build failures:**
```bash
# Clean and rebuild
rm -rf ~/.local/src/asus-linux
./install-asus-linux.sh

# Check dependencies
sudo apt update && sudo apt upgrade
```

### Support Information

When reporting issues, please include:
- Linux Mint version and edition
- ASUS laptop model
- Kernel version (`uname -r`)
- Graphics hardware (`lspci | grep -i vga`)
- Service status (`sudo systemctl status asusd`)
- Installation logs and error messages

For more help, visit:
- [ASUS Linux Community](https://asus-linux.org/)
- [asusctl GitHub Issues](https://github.com/OpenGamingCollective/asusctl/issues)

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues, feature requests, or pull requests.

## ⚠️ Disclaimer

This script modifies system configurations and installs software that may affect your system's stability. Use at your own risk. Always ensure you have backups before making system changes.
