#!/bin/bash
# One-time preparation of the NEW official Debian generic image, not an old VM.
set -euo pipefail
export LC_ALL=C DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/pf-debian-prepare.log /dev/ttyS0) 2>&1
state=/var/lib/linux-flashcard
mkdir -p "$state"
trap 'printf "[PF_DEBIAN_FAILED] line=%s exit=%s\n" "$LINENO" "$?"' ERR
printf '[PF_DEBIAN_PREPARE] %s\n' "$(date -u --iso-8601=seconds)"
. /etc/os-release
[[ $ID == debian && $VERSION_ID == 13 ]]
[[ ! -e $state/desktop-ready ]]
[[ ! -e /usr/sbin/policy-rc.d ]]
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod 755 /usr/sbin/policy-rc.d
cleanup_policy(){
    if [[ -f /usr/sbin/policy-rc.d && $(cat /usr/sbin/policy-rc.d) == $'#!/bin/sh\nexit 101' ]]; then rm /usr/sbin/policy-rc.d; fi
}
trap cleanup_policy EXIT
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer || true
apt-get -o DPkg::Lock::Timeout=180 update
apt-get -y --no-remove --no-install-recommends -o DPkg::Lock::Timeout=180 install \
    xfce4 xfce4-terminal thunar mousepad lightdm lightdm-gtk-greeter \
    xserver-xorg xserver-xorg-input-libinput x11-xserver-utils xauth xinit \
    dbus-x11 xdg-utils shared-mime-info librsvg2-common fonts-dejavu-core adwaita-icon-theme sudo
[[ -z $(dpkg --audit) ]]
install -d /etc/X11/xorg.conf.d /etc/lightdm/lightdm.conf.d /usr/share/xsessions
cat > /etc/xdg/xfce-mimeapps.list <<'EOF'
[Default Applications]
text/plain=org.xfce.mousepad.desktop
application/x-zerosize=org.xfce.mousepad.desktop
EOF
cat > /etc/X11/xorg.conf.d/20-pf-software.conf <<'EOF'
Section "Device"
    Identifier "PF 2D VGA"
    Driver "modesetting"
    Option "AccelMethod" "none"
EndSection
EOF
cat > /etc/lightdm/lightdm.conf.d/50-pf-desktop.conf <<'EOF'
[Seat:*]
greeter-session=lightdm-gtk-greeter
user-session=pf-xfce-x11
allow-guest=false
EOF
cat > /usr/share/xsessions/pf-xfce-x11.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=LinuxFlashcard XFCE (X11)
Exec=/usr/local/bin/pf-start-xfce
TryExec=/usr/local/bin/pf-start-xfce
DesktopNames=XFCE
EOF
cat > /usr/local/bin/pf-start-xfce <<'EOF'
#!/bin/sh
export QT_QUICK_BACKEND=software
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null ||
    xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s false
exec /usr/bin/startxfce4
EOF
chmod 755 /usr/local/bin/pf-start-xfce
[[ -x /usr/local/sbin/pf-configure-usability ]]
bash /usr/local/sbin/pf-configure-usability
install -d -o student -g student /home/student/Desktop
[[ -x /usr/local/sbin/pf-first-password ]]
[[ -f /etc/systemd/system/pf-first-password.service ]]
install -d /etc/systemd/system/lightdm.service.d
cat > /etc/systemd/system/lightdm.service.d/10-first-password.conf <<'EOF'
[Unit]
Requires=pf-first-password.service
After=pf-first-password.service
EOF
# Remove only our own temporary package-start inhibitor in this new image.
[[ $(cat /usr/sbin/policy-rc.d) == $'#!/bin/sh\nexit 101' ]]
rm /usr/sbin/policy-rc.d
systemctl daemon-reload
systemctl enable lightdm.service pf-first-password.service
systemctl mask getty@tty1.service
systemctl set-default graphical.target
touch /etc/cloud/cloud-init.disabled
dpkg-query -W -f='${Package}\t${Version}\n' > "$state/packages.tsv"
touch "$state/desktop-ready"
sync
printf '[PF_DEBIAN_READY] XFCE/X11, LightDM, locked student awaiting local password setup\n'
if [[ ${PF_NO_POWEROFF:-0} != 1 ]]; then systemctl --no-block poweroff; fi
