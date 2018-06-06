#!/bin/bash

FEDORA_RELEASE=28

set -e

if [ $# -eq 1 ]; then
    LOCAL_REPOPATH=$1
fi

sudo yum -y install wget git

# Configure local repository if needed

function prepare_repo(){
    sudo yum install -y httpd
    sudo setsebool httpd_read_user_content=on
    sudo ln -s $LOCAL_REPOPATH /var/www/html/fedora-stable
    pushd $LOCAL_REPOPATH
    sudo mkdir -p images/pxeboot/
    sudo systemctl start httpd
    popd
}

function create_local_fedora_stable_repo(){

    mkdir -p /tmp/temporal-yum.repos.d
    cat > /tmp/temporal-yum.repos.d/delorean-deps.repo<< EOF
[fedora-stable]
name=fedora
baseurl=http://localhost/fedora-stable
gpgcheck=0
enabled=1
EOF

}

if [ -n "$LOCAL_REPOPATH" ]; then
    prepare_repo
    create_local_fedora_stable_repo
else
    mkdir -p /tmp/yum.repos.d/
    wget https://trunk.rdoproject.org/fedora/delorean-deps.repo -O /tmp/yum.repos.d/delorean-deps.repo
    RDO_FEDORA_ELEMENT=rdo-fedora-stable
fi


# Install required software

sudo wget https://trunk.rdoproject.org/centos7-master/delorean-deps.repo -O /etc/yum.repos.d/delorean-deps.repo
sudo wget https://trunk.rdoproject.org/centos7-master/current-passed-ci/delorean.repo -O /etc/yum.repos.d/delorean.repo

sudo yum -y install diskimage-builder

# Clone RDO config repo which provides additional elements

if [ ! -d config ]; then
    git clone https://review.rdoproject.org/r/config
fi

if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -N "" -trsa -f ~/.ssh/id_rsa
fi
sudo mkdir -p /etc/nodepool/scripts
sudo mkdir -p /var/lib/nodepool/.ssh/
sudo cp ~/.ssh/id_rsa.pub /var/lib/nodepool/.ssh/nodepool_rsa.pub

# Build the image

export ELEMENTS_PATH=$PWD/config/nodepool/elements
export DIB_YUM_MINIMAL_BOOTSTRAP_REPOS=/tmp/temporal-yum.repos.d/
export DIB_RELEASE=28

disk-image-create fedora-minimal nodepool-minimal simple-init zuul-cloner-pip jenkins-worker rdo-base $RDO_FEDORA_ELEMENT vm

