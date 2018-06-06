#version=DEVEL
# Keyboard layouts
keyboard 'us'
# Root password
rootpw --iscrypted --lock locked
# System language
lang en_US.UTF-8
# Reboot after installation
reboot
# System timezone
timezone Etc/UTC --isUtc
# Use text mode install
text
# Firewall configuration
firewall --disabled
# Network information
network  --bootproto=dhcp --device=link --activate
# Use network installation
%include fedora-stable-repo.ks
#url --mirrorlist=https://mirrors.fedoraproject.org/mirrorlist?repo=rawhide&arch=$basearch
# System authorization information
auth --useshadow --passalgo=sha512
# SELinux configuration
selinux --enforcing

# System services
services --enabled="sshd,cloud-init,cloud-init-local,cloud-config,cloud-final"
# System bootloader configuration
bootloader --append="no_timer_check net.ifnames=0 console=tty1 console=ttyS0,115200n8" --location=mbr --timeout=1
autopart --type=plain --nohome --noboot --noswap
# Clear the Master Boot Record
zerombr
# Partition clearing information
clearpart --all

%post --erroronfail

# Create grub.conf for EC2. This used to be done by appliance creator but
# anaconda doesn't do it. And, in case appliance-creator is used, we're
# overriding it here so that both cases get the exact same file.
# Note that the console line is different -- that's because EC2 provides
# different virtual hardware, and this is a convenient way to act differently
echo -n "Creating grub.conf for pvgrub"
rootuuid=$( awk '$2=="/" { print $1 };'  /etc/fstab )
mkdir /boot/grub
echo -e 'default=0\ntimeout=0\n\n' > /boot/grub/grub.conf
for kv in $( ls -1v /boot/vmlinuz* |grep -v rescue |sed s/.*vmlinuz-//  ); do
  echo "title Fedora ($kv)" >> /boot/grub/grub.conf
  echo -e "\troot (hd0,0)" >> /boot/grub/grub.conf
  echo -e "\tkernel /boot/vmlinuz-$kv ro root=$rootuuid no_timer_check console=hvc0 LANG=en_US.UTF-8" >> /boot/grub/grub.conf
  echo -e "\tinitrd /boot/initramfs-$kv.img" >> /boot/grub/grub.conf
  echo
done


#link grub.conf to menu.lst for ec2 to work
echo -n "Linking menu.lst to old-style grub.conf for pv-grub"
ln -sf grub.conf /boot/grub/menu.lst
ln -sf /boot/grub/grub.conf /etc/grub.conf

# older versions of livecd-tools do not follow "rootpw --lock" line above
# https://bugzilla.redhat.com/show_bug.cgi?id=964299
passwd -l root

# setup systemd to boot to the right runlevel
echo -n "Setting default runlevel to multiuser text mode"
rm -f /etc/systemd/system/default.target
ln -s /lib/systemd/system/multi-user.target /etc/systemd/system/default.target
echo .

# this is installed by default but we don't need it in virt
# Commenting out the following for #1234504
# rpm works just fine for removing this, no idea why dnf can't cope
echo "Removing linux-firmware package."
rpm -e linux-firmware

# Remove firewalld; was supposed to be optional in F18+, but is pulled in
# in install/image building.
echo "Removing firewalld."
# FIXME! clean_requirements_on_remove is the default with DNF, but may
# not work when package was installed by Anaconda instead of command line.
# Also -- check if this is still even needed with new anaconda -- disabled
# firewall should _not_ pull in this package.
# yum -C -y remove "firewalld*" --setopt="clean_requirements_on_remove=1"
dnf -C -y erase "firewalld*"

# Another one needed at install time but not after that, and it pulls
# in some unneeded deps (like, newt and slang)
echo "Removing authconfig."
dnf -C -y erase authconfig

# instlang hack. (Note! See bug referenced above package list)
find /usr/share/locale -mindepth  1 -maxdepth 1 -type d -not -name en_US -exec rm -rf {} +
localedef --list-archive | grep -v ^en_US | xargs localedef --delete-from-archive
# this will kill a live system (since it's memory mapped) but should be safe offline
mv -f /usr/lib/locale/locale-archive /usr/lib/locale/locale-archive.tmpl
build-locale-archive
echo '%_install_langs C:en:en_US:en_US.UTF-8' >> /etc/rpm/macros.image-language-conf


echo -n "Getty fixes"
# although we want console output going to the serial console, we don't
# actually have the opportunity to login there. FIX.
# we don't really need to auto-spawn _any_ gettys.
sed -i '/^#NAutoVTs=.*/ a\
NAutoVTs=0' /etc/systemd/logind.conf

echo -n "Network fixes"
# initscripts don't like this file to be missing.
# and https://bugzilla.redhat.com/show_bug.cgi?id=1204612
cat > /etc/sysconfig/network << EOF
NETWORKING=yes
NOZEROCONF=yes
DEVTIMEOUT=10
EOF

# simple eth0 config, again not hard-coded to the build hardware
cat > /etc/sysconfig/network-scripts/ifcfg-eth0 << EOF
DEVICE="eth0"
BOOTPROTO="dhcp"
ONBOOT="yes"
TYPE="Ethernet"
PERSISTENT_DHCLIENT="yes"
EOF

# generic localhost names
cat > /etc/hosts << EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6

EOF
echo .


# Because memory is scarce resource in most cloud/virt environments,
# and because this impedes forensics, we are differing from the Fedora
# default of having /tmp on tmpfs.
echo "Disabling tmpfs for /tmp."
systemctl mask tmp.mount

# make sure firstboot doesn't start
echo "RUN_FIRSTBOOT=NO" > /etc/sysconfig/firstboot

# Uncomment this if you want to use cloud init but suppress the creation
# of an "ec2-user" account. This will, in the absence of further config,
# cause the ssh key from a metadata source to be put in the root account.
#cat <<EOF > /etc/cloud/cloud.cfg.d/50_suppress_ec2-user_use_root.cfg
#users: []
#disable_root: 0
#EOF

echo "Removing random-seed so it's not the same in every image."
rm -f /var/lib/systemd/random-seed

echo "Cleaning old dnf repodata."
# FIXME: clear history?
dnf clean all
truncate -c -s 0 /var/log/dnf.log
truncate -c -s 0 /var/log/dnf.rpm.log

echo "Import RPM GPG key"
releasever=$(rpm -q --qf '%{version}\n' fedora-release)
basearch=$(uname -i)
rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-$releasever-$basearch

echo "Packages within this cloud image:"
echo "-----------------------------------------------------------------------"
rpm -qa
echo "-----------------------------------------------------------------------"
# Note that running rpm recreates the rpm db files which aren't needed/wanted
rm -f /var/lib/rpm/__db*

# FIXME: is this still needed?
echo "Fixing SELinux contexts."
touch /var/log/cron
touch /var/log/boot.log
# ignore return code because UEFI systems with vfat filesystems
# that don't support selinux will give us errors
/usr/sbin/fixfiles -R -a restore || true

echo "Zeroing out empty space."
# This forces the filesystem to reclaim space from deleted files
dd bs=1M if=/dev/zero of=/var/tmp/zeros || :
rm -f /var/tmp/zeros
echo "(Don't worry -- that out-of-space error was expected.)"

# When we build the image with oz, dracut is used 
# and sets up a ifcfg-en<whatever> for the device. We don't 
# want to use this, we use eth0 so it is always the same. 
# So we remove all these ifcfg-en<whatever> devices so 
# The 'network' service can come up cleanly.
rm -f /etc/sysconfig/network-scripts/ifcfg-en*

# Enable network service here, as doing it in the services line
# fails due to RHBZ #1369794
/sbin/chkconfig network on

# Remove machine-id on pre generated images
rm -f /etc/machine-id
touch /etc/machine-id

# Anaconda is writing an /etc/resolv.conf from the install environment.
# The system should start out with an empty file, otherwise cloud-init
# will try to use this information and may error:
# https://bugs.launchpad.net/cloud-init/+bug/1670052
truncate -s 0 /etc/resolv.conf

# RDO Customization
# Remove official fedora repositories and configure Fedora Stable one in RDO

rm -f /etc/yum.repos.d/*repo

cat > /etc/yum.repos.d/fedora-stable.repo << EOF
[fedora-stable]
name=fedora
baseurl=https://trunk.rdoproject.org/fedora/stable-base/latest
gpgcheck=0
enabled=1
EOF

%end

%packages
@^cloud-server-environment
kernel-core
systemd-udev
which
cronie
-NetworkManager
-biosdevname
-dracut-config-rescue
-iprutils
-plymouth
-uboot-tools

%end
