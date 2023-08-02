#!/bin/bash

# DO NOT CALL ME DIRECTLY!
# This script is called by mk_europe_edition.sh via qemu
set -ex

mount -t proc proc /proc

cd /root/stratux

# Make sure that the upgrade doesn't restart services in the chroot..
mkdir /root/fake
ln -s /bin/true /root/fake/initctl
ln -s /bin/true /root/fake/invoke-rc.d
ln -s /bin/true /root/fake/restart
ln -s /bin/true /root/fake/start
ln -s /bin/true /root/fake/stop
ln -s /bin/true /root/fake/start-stop-daemon
ln -s /bin/true /root/fake/service
ln -s /bin/true /root/fake/deb-systemd-helper
ln -s /bin/true /root/fake/deb-systemd-invoke

# Fake a proc FS for raspberrypi-sys-mods_20170519_armhf... Extend me as needed
mkdir -p /proc/sys/vm/

apt update
apt clean

PATH=/root/fake:$PATH apt install --yes libjpeg62-turbo-dev libconfig9 rpi-update dnsmasq git cmake \
    libusb-1.0-0-dev build-essential autoconf libtool i2c-tools libfftw3-dev libncurses-dev python3-serial jq ifplugd iptables

# Downgrade to older brcm wifi firmware - the new one seems to be buggy in AP+Client mode
# see https://github.com/raspberrypi/firmware/issues/1463
# TODO: disabled again. The old version seems to be even less reliable and drops a lot of packets for some clients on the pi4.
#wget http://archive.raspberrypi.org/debian/pool/main/f/firmware-nonfree/firmware-brcm80211_20190114-1+rpt4_all.deb
#dpkg -i firmware-brcm80211_20190114-1+rpt4_all.deb
#rm firmware-brcm80211_20190114-1+rpt4_all.deb
#apt-mark hold firmware-brcm80211

systemctl enable ssh
systemctl disable dnsmasq # we start it manually on respective interfaces
systemctl disable dhcpcd
systemctl disable hciuart
systemctl disable triggerhappy
systemctl disable wpa_supplicant
systemctl disable systemd-timesyncd # We sync time with GPS. Make sure there is no conflict if we have internet connection


systemctl disable apt-daily.timer
systemctl disable apt-daily-upgrade.timer
systemctl disable man-db.timer

# Run DHCP on eth0 when cable is plugged in
sed -i -e 's/INTERFACES=""/INTERFACES="eth0"/g' /etc/default/ifplugd

# Generate ssh key for all installs. Otherwise it would have to be done on each boot, which takes a couple of seconds
ssh-keygen -A -v
systemctl disable regenerate_ssh_host_keys
# This is usually done by the console-setup service that takes quite long of first boot..
/lib/console-setup/console-setup.sh



cd /root/stratux
cp image/bashrc.txt /root/.bashrc
source /root/.bashrc

# Prepare librtlsdr. The one shipping with buster uses usb_zerocopy, which is extremely slow on newer kernels, so
# we manually compile the osmocom version that disables zerocopy by default..
cd /root/
rm -rf rtl-sdr
git clone https://github.com/osmocom/rtl-sdr.git
cd rtl-sdr
git checkout 0847e93e0869feab50fd27c7afeb85d78ca04631 # Nov. 20, 2020
mkdir build && cd build
cmake .. -DENABLE_ZEROCOPY=0
make -j1
make install
cd /root/
rm -r rtl-sdr

ldconfig

#kalibrate-rtl
cd /root
rm -rf kalibrate-rtl
git clone https://github.com/steve-m/kalibrate-rtl
cd kalibrate-rtl
./bootstrap
./configure
make -j8
make install
cd /root && rm -rf kalibrate-rtl


# Prepare wiringpi for ogn trx via GPIO
cd /root && git clone https://github.com/WiringPi/WiringPi.git
cd WiringPi && ./build
cd /root && rm -r WiringPi

# Debian seems to ship with an invalid pkgconfig for librtlsdr.. fix it:
#sed -i -e 's/prefix=/prefix=\/usr/g' /usr/lib/arm-linux-gnueabihf/pkgconfig/librtlsdr.pc
#sed -i -e 's/libdir=/libdir=${prefix}\/lib\/arm-linux-gnueabihf/g' /usr/lib/arm-linux-gnueabihf/pkgconfig/librtlsdr.pc

# Install golang
cd /root
wget https://go.dev/dl/go1.20.1.linux-arm64.tar.gz
tar xzf go1.20.1.linux-arm64.tar.gz
rm go1.20.1.linux-arm64.tar.gz

# Compile stratux
cd /root/stratux

make clean
make -j8

# Now also prepare the update file..
cd /root/stratux/selfupdate
./makeupdate.sh
mv /root/stratux/work/update-*.sh /root/
rm -r /root/stratux/work
cd /root/stratux

make install
rm -r /root/.cache

##### Some device setup - copy files from image directory ####
cd /root/stratux/image
#motd
cp -f motd /etc/motd

#network default config. TODO: can't we just implement gen_gdl90 -write_network_settings or something to generate them from template?
cp -f stratux-dnsmasq.conf /etc/dnsmasq.d/stratux-dnsmasq.conf
cp -f wpa_supplicant_ap.conf /etc/wpa_supplicant/wpa_supplicant_ap.conf
cp -f interfaces /etc/network/interfaces

#sshd config
cp -f sshd_config /etc/ssh/sshd_config

#debug aliases
cp -f stxAliases.txt /root/.stxAliases

#rtl-sdr setup
cp -f rtl-sdr-blacklist.conf /etc/modprobe.d/

#system tweaks
cp -f modules.txt /etc/modules

#boot settings
cp -f config.txt /boot/

# #Create default pi password as in old times, and disable initial user creation
# systemctl disable userconfig
# echo "pi:raspberry" | chpasswd

#rootfs overlay stuff
# cp -f overlayctl init-overlay /sbin/
# overlayctl install
# # init-overlay replaces raspis initial partition size growing.. Make sure we call that manually (see init-overlay script)
# touch /var/grow_root_part
# mkdir -p /overlay/robase # prepare so we can bind-mount root even if overlay is disabled

# So we can import network settings if needed
touch /boot/.stratux-first-boot

#startup scripts
cp -f rc.local /etc/rc.local

#disable serial console, disable rfkill state restore, enable wifi on boot
sed -i /boot/cmdline.txt -e "s/console=serial0,[0-9]\+ /systemd.restore_state=0 rfkill.default_state=1 /"

#Set the keyboard layout to US.
sed -i /etc/default/keyboard -e "/^XKBLAYOUT/s/\".*\"/\"us\"/"

# Set hostname
echo "stratux" > /etc/hostname
sed -i /etc/hosts -e "s/raspberrypi/stratux/g"

PATH=/root/fake:$PATH apt remove --purge --yes alsa-ucm-conf alsa-topology-conf bluez bluez-firmware cifs-utils cmake cmake-data \
    v4l-utils rsync pigz pi-bluetooth cpp cpp-10  zlib1g-dev

PATH=/root/fake:$PATH apt autoremove --purge --yes

apt clean
rm -rf /var/cache/apt

rm -r /root/fake


umount /proc