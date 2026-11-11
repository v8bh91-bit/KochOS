#!/usr/bin/env bash
# koch OS (Linux edition) - Debian 13 "trixie" + GNOME + Steam/Proton/Wine.
#
# Run on Debian/Ubuntu as root:   sudo ./build-koch-linux.sh
# Optional NVIDIA proprietary driver in the image:  sudo KOCH_NVIDIA=1 ./build-koch-linux.sh
#
# Needs internet, ~25 GB free disk, 30-60 minutes. Result: koch-linux-build/*.iso
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

apt-get update
apt-get install -y live-build debootstrap squashfs-tools xorriso

WORK="${PWD}/koch-linux-build"
mkdir -p "$WORK"
cd "$WORK"

lb clean --purge || true

lb config \
  --distribution trixie \
  --architectures amd64 \
  --archive-areas "main contrib non-free non-free-firmware" \
  --binary-images iso-hybrid \
  --debian-installer none \
  --iso-application "koch OS" \
  --iso-publisher "koch OS project" \
  --iso-volume "KOCH_OS" \
  --image-name "koch-os-gnome" \
  --bootappend-live "boot=live components quiet splash hostname=koch username=koch locales=ru_RU.UTF-8 keyboard-layouts=us,ru"

# ---------------------------------------------------------------- packages
mkdir -p config/package-lists
cat > config/package-lists/koch.list.chroot <<'EOF'
# Desktop
task-gnome-desktop
gdm3
gnome-tweaks
dconf-cli
firefox-esr
file-roller
# Russian
locales
task-russian
task-russian-desktop
# Graphics: Vulkan + OpenGL (64-bit; 32-bit parts are added by the gaming hook)
mesa-vulkan-drivers
libgl1-mesa-dri
vulkan-tools
firmware-misc-nonfree
firmware-amd-graphics
firmware-linux-nonfree
# Windows programs and games
wine
wine64
winbind
winetricks
cabextract
binfmt-support
# Install-to-disk
calamares
calamares-settings-debian
EOF

# ---------------------------------------------------------------- .exe via Wine
mkdir -p config/includes.chroot/etc/binfmt.d
cat > config/includes.chroot/etc/binfmt.d/koch-wine.conf <<'EOF'
:Wine:E::exe::/usr/bin/wine:
:WineMSI:E::msi::/usr/bin/wine:
EOF

# ---------------------------------------------------------------- gaming tweaks
mkdir -p config/includes.chroot/etc/sysctl.d
cat > config/includes.chroot/etc/sysctl.d/99-koch-gaming.conf <<'EOF'
# Many Proton games crash with the Debian default (65530)
vm.max_map_count = 1048576
EOF

# ---------------------------------------------------------------- GNOME defaults
mkdir -p config/includes.chroot/etc/dconf/profile config/includes.chroot/etc/dconf/db/local.d
cat > config/includes.chroot/etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
cat > config/includes.chroot/etc/dconf/db/local.d/00-koch <<'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'

[org/gnome/desktop/input-sources]
sources=[('xkb', 'us'), ('xkb', 'ru')]
xkb-options=['grp:alt_shift_toggle']

[org/gnome/shell]
favorite-apps=['org.gnome.Nautilus.desktop', 'firefox-esr.desktop', 'steam.desktop', 'net.lutris.Lutris.desktop', 'koch-gaming-setup.desktop', 'org.gnome.Terminal.desktop', 'org.gnome.Console.desktop']
EOF

# ---------------------------------------------------------------- first-run helper
mkdir -p config/includes.chroot/usr/local/bin config/includes.chroot/usr/share/applications
cat > config/includes.chroot/usr/local/bin/koch-gaming-setup <<'EOF'
#!/bin/sh
# One-time helper: adds Flathub and ProtonUp-Qt (to install Proton-GE, which
# fixes many games that stock Proton cannot run).
set -e
echo "== koch OS gaming setup =="
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y flathub net.davidotek.pupgui2
cat <<'TXT'

Done. Two manual steps remain (Steam cannot be pre-configured safely):
 1. Steam -> Settings -> Compatibility -> enable
    "Enable Steam Play for all other titles", pick "Proton Experimental".
 2. If a game fails: open ProtonUp-Qt, install the newest "GE-Proton",
    then in the game's Properties -> Compatibility choose it.
Check any game at https://www.protondb.com before buying.
TXT
read -r -p "Press Enter to close..." _
EOF
chmod +x config/includes.chroot/usr/local/bin/koch-gaming-setup
cat > config/includes.chroot/usr/share/applications/koch-gaming-setup.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=koch Gaming Setup
Comment=Install Proton-GE manager and finish Steam configuration
Exec=/usr/local/bin/koch-gaming-setup
Icon=applications-games
Terminal=true
Categories=Game;
EOF

# ---------------------------------------------------------------- hooks (run inside the image)
mkdir -p config/hooks/live

cat > config/hooks/live/0100-koch-gaming.hook.chroot <<'EOF'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive

# Steam and Wine need 32-bit libraries
dpkg --add-architecture i386
apt-get update

echo "steam steam/question select I AGREE" | debconf-set-selections
echo "steam steam/license note" | debconf-set-selections

apt-get install -y steam-installer \
  libc6:i386 libvulkan1:i386 mesa-vulkan-drivers:i386 \
  libgl1-mesa-dri:i386 libglx-mesa0:i386 wine32:i386

# Nice to have; a missing package must not break the whole build
for p in gamemode mangohud lutris flatpak gnome-software-plugin-flatpak; do
  apt-get install -y "$p" || echo "koch: skipped optional package $p"
done
EOF

cat > config/hooks/live/0200-koch-branding.hook.chroot <<'EOF'
#!/bin/sh
set -e
cat > /usr/lib/os-release <<'OSR'
PRETTY_NAME="koch OS"
NAME="koch OS"
VERSION="1.0"
ID=koch
ID_LIKE=debian
HOME_URL="https://example.com/koch-os"
OSR
echo "koch OS \n \l" > /etc/issue
echo "koch OS" > /etc/issue.net

mkdir -p /etc/skel/.config
cat > /etc/skel/.config/mimeapps.list <<'MIME'
[Default Applications]
application/x-ms-dos-executable=wine.desktop
application/x-msdownload=wine.desktop
application/x-msi=wine.desktop
MIME

dconf update || true
systemctl enable systemd-binfmt.service || true
EOF
chmod +x config/hooks/live/*.hook.chroot

# ---------------------------------------------------------------- optional NVIDIA
if [[ "${KOCH_NVIDIA:-0}" == "1" ]]; then
  cat > config/hooks/live/0150-koch-nvidia.hook.chroot <<'EOF'
#!/bin/sh
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y linux-headers-amd64 nvidia-driver nvidia-driver-libs:i386
EOF
  chmod +x config/hooks/live/0150-koch-nvidia.hook.chroot
fi

# ---------------------------------------------------------------- build
lb build

echo
echo "Done. ISO:"
ls -lh "$WORK"/*.iso
