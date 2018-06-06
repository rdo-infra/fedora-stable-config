#!/bin/bash

FEDORA_RELEASE=28

set -e

if [ $# -eq 1 ]; then
    LOCAL_REPOPATH=$1
fi

# Configure local repository if needed

function prepare_repo(){
    dnf install -y httpd
    setsebool httpd_read_user_content=on
    ln -s $LOCAL_REPOPATH /var/www/html/fedora-stable
    pushd $LOCAL_REPOPATH
    mkdir -p images/pxeboot/
    wget https://kojipkgs.fedoraproject.org/compose/${FEDORA_RELEASE}/latest-Fedora-${FEDORA_RELEASE}/compose/Everything/x86_64/os/images/boot.iso -O images/boot.iso
    wget https://kojipkgs.fedoraproject.org/compose/${FEDORA_RELEASE}/latest-Fedora-${FEDORA_RELEASE}/compose/Everything/x86_64/os/images/install.img -O images/install.img
    wget https://kojipkgs.fedoraproject.org/compose/${FEDORA_RELEASE}/latest-Fedora-${FEDORA_RELEASE}/compose/Everything/x86_64/os/images/pxeboot/initrd.img -O images/pxeboot/initrd.img
    wget https://kojipkgs.fedoraproject.org/compose/${FEDORA_RELEASE}/latest-Fedora-${FEDORA_RELEASE}/compose/Everything/x86_64/os/images/pxeboot/vmlinuz -O images/pxeboot/vmlinuz
    systemctl start httpd
    popd
}

function configure_fedora_stable_repo(){

    cat > fedora-stable-repo.ks<< EOF
repo --name="stable" --baseurl=http://192.168.122.1/fedora-stable
url --url="http://192.168.122.1/fedora-stable"
EOF

}

if [ -n "$LOCAL_REPOPATH" ]; then
    prepare_repo
    configure_fedora_stable_repo
fi


# Install required software

dnf install -y imagefactory* libvirt pykickstart qemu-img
systemctl start libvirtd

# Process kickstart file

ksflatten -c fedora-stable.ks -o fedora-stable-final.ks

# Configure memory to build fedora image, at least 2GB are needed

sed -i 's/\# memory.*/memory = 2048/g' /etc/oz/oz.cfg

# Clean output directory in case old images exist

rm -f /var/lib/imagefactory/storage/*

# Build the image

imagefactory --debug base_image --file-parameter install_script fedora-stable-final.ks fedora-stable-local.xml

# Convert image from raw to qcow2

DATE_VERSION=$(date +%Y%m%d%H%M)

qemu-img convert -c -f raw -O qcow2 /var/lib/imagefactory/storage/*.body Fedora-Cloud-Base-RDO-${FEDORA_RELEASE}-${DATE_VERSION}.x86_64.qcow2


