#! /bin/sh
#
# Requires: vagrant VBoxManage qemu-img
#

OBS_PROJECT=isv:ownCloud:community
OBS_MIRRORS=http://download.opensuse.org/repositories

#formats_via_qemu_img_convert="raw qcow2 vhdx"	# raw qcow2 vhdx supported.

test -z "$DEBUG" && DEBUG=true	# true: skip system update, disk sanitation, ... for speedy development.
                        	# false: do everything for production, also disable vagrant user.

mysql_pass=admin		# KEEP in sync with check-init.sh

if [ "$1" == "-h" ]; then
  echo "Usage: $0 [OBS_PROJECT]"
  echo "default OBS_PROJECT is '$OBS_PROJECT'"
  exit 1
fi
test -n "$1" && OBS_PROJECT=$1

cd $(dirname $0)

## An LTS operating system for production.
buildPlatform=xUbuntu_14.04	# matches an OBS target.
vmBoxName=ubuntu/trusty64
vmBoxUrl=https://vagrantcloud.com/ubuntu/boxes/trusty64/versions/14.04/providers/virtualbox.box

## An alternate operating system for testing portability ...
# buildPlatform=xUbuntu_15.04	# matches an OBS target.
# vmBoxName=ubuntu/vivid64
# vmBoxUrl=https://vagrantcloud.com/ubuntu/boxes/vivid64/versions/20150722.0.0/providers/virtualbox.box

OBS_REPO=$OBS_MIRRORS/$(echo $OBS_PROJECT | sed -e 's@:@:/@g')/$buildPlatform
ocVersion=$(curl -s -L $OBS_REPO/Packages | grep -a1 'Package: owncloud$' | grep Version: | head -n 1 | sed -e 's/Version: /owncloud-/')
# ocVersion=ownCloud-8.1.0-6
test -z "$ocVersion" && { echo "ERROR: Cannot find owncloud version in $OBS_REPO/Packages -- Try again later"; exit 1; }
vmName=$(echo $ocVersion | sed -e 's/owncloud/oc8ce/')
imageName=$buildPlatform+$ocVersion
test "$DEBUG" == "true" && imageName=$imageName-DEBUG

cat > Vagrantfile << EOF
# CAUTION: Do not edit. Autogenerated contents.
# This Vagrantfile is created by $0 "$@"
#

VAGRANTFILE_API_VERSION = "2"

Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
 # Every Vagrant virtual environment requires a box to build off of.
  config.vm.box = "$vmBoxName"
  config.vm.define "$vmName"		# need this, or the name is always 'default'

  # avoids 'stdin: is not a tty' error.
  config.ssh.shell = "bash -c 'BASH_ENV=/etc/profile exec bash'" 

  # The url from where the 'config.vm.box' box will be fetched if it
  # doesn't already exist on the user's system. Normally not needed.
  config.vm.box_url = "$vmBoxUrl"

  # forward http
  config.vm.network :forwarded_port, guest: 80, host: 8888
  # forward https
  config.vm.network :forwarded_port, guest: 443, host: 4443
  # forward ssh (needs the id attribute to not conflict with a default forwarding at build time)
  config.vm.network :forwarded_port, id: 'ssh', guest: 22, host: 2222

  config.vm.provider :virtualbox do |vb|
      vb.name = "$buildPlatform+$ocVersion"
      # speed up: Force the VM to use NAT'd DNS:
      vb.customize [ "modifyvm", :id, "--natdnshostresolver1", "on" ]
      vb.customize [ "modifyvm", :id, "--natdnsproxy1", "on" ]
      vb.customize [ "modifyvm", :id, "--memory", 2048 ]
      vb.customize [ "modifyvm", :id, "--cpus", 1 ]
  end

  ## this is run as user root, apparently. I'd expected user vagrant ...
  config.vm.provision "shell", inline: <<-SCRIPT
		set -x
		userdel --force ubuntu		# backdoor?
		useradd owncloud -m		# group owncloud not yet exists
		useradd admin -m -g admin	# group admin already exists
		/bin/echo -e "root:admin\nadmin:admin\nowncloud:owncloud" | chpasswd
		$DEBUG || rm -f /etc/sudoers.d/vagrant
		echo 'admin ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/admin
		echo 'owncloud ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/owncloud

		# prepare repositories
		wget -q $OBS_REPO/Release.key -O - | apt-key add -
		sh -c "echo 'deb $OBS_REPO /' >> /etc/apt/sources.list.d/owncloud.list"

		# attention: apt-get update is horribly slow when not connected to a tty.
		export DEBIAN_FRONTEND=noninteractive TERM=ansi LC_ALL=C
		apt-get -q -y update

		$DEBUG || aptitude full-upgrade -y
		$DEBUG || apt-get -q -y autoremove

		# install packages.
		apt-get install -q -y language-pack-de figlet

		## Install APCU 4.0.6, using the 14.04 package from isv:ownCloud:community:...
		apt-get install -q -y php5-apcu
		
		# Install apps we want
		# We need unzip to perform this	
		apt-get install unzip -y
		
	  	# Download and install GalleryPlus
                wget https://github.com/owncloud/gallery/archive/master.zip
                unzip master.zip
                rm master.zip
                mkdir -p /var/www/owncloud/apps/galleryplus
                mv gallery-master/ galleryplus/
                mv galleryplus/ /var/www/owncloud/apps

                # Download and install Documents
                wget https://github.com/owncloud/documents/archive/master.zip
                unzip master.zip
                rm master.zip
                mkdir -p /var/www/owncloud/apps/documents
                mv documents-master/ documents/
                mv documents/ /var/www/owncloud/apps
                ## Make it possible to enable MS-document support
		$DEBUG || apt-get install --no-install-recommends libreoffice -q -y
		## Add Libreoffice PPA 
		$DEBUG || sudo apt-add-repository ppa:libreoffice/libreoffice-5-0 -y
		
	 	# Download and install Mail
                wget https://github.com/owncloud/mail/archive/master.zip
                unzip master.zip
                rm master.zip
                mkdir -p /var/www/owncloud/apps/mail
                mv mail-master/ mail/
                mv mail/ /var/www/owncloud/apps
                cd /var/www/owncloud/apps/mail
                curl -sS https://getcomposer.org/installer | php
                php composer.phar install
                # rm composer.phar
                cd /root/
		
		debconf-set-selections <<< 'mysql-server mysql-server/root_password password $mysql_pass'
		debconf-set-selections <<< 'mysql-server mysql-server/root_password_again password $mysql_pass'
		apt-get install -q -y owncloud php5-libsmbclient
		curl -sL localhost/owncloud/ | grep login || { curl -sL localhost/owncloud; exit 1; } # did not start at all??

		## FIXME: the lines below assume we are root. While most other parts of the
		## script assume, we are a regular user and need sudo.

		# hook our scripts. Specifically the check-init.sh upon boot.
		mkdir -p /var/scripts
		cp /vagrant/*.{php,sh} /var/scripts
		chmod a+x /var/scripts/*.{php,sh}
		$DEBUG || echo 'userdel --force vagrant' >> /var/scripts/check-init.sh
		sudo sed -i -e 's@exit@bash -x /var/scripts/check-init.sh; exit@' /etc/rc.local
		echo >> /home/admin/.profile 'test -f /var/scripts/setup-when-admin.sh && sudo bash /var/scripts/setup-when-admin.sh'

		# make things nice.
                mv /var/scripts/index.php /var/www/html/index.php && rm -f /var/www/html/index.html

		echo '<?php phpinfo(); ' > /var/www/owncloud/phpinfo.php
		chmod a+x /var/www/owncloud/phpinfo.php

		# prepare https
		a2enmod ssl headers
		a2dissite default-ssl
                bash /var/scripts/self-signed-ssl.sh
                
                # Set RAMDISK for better performance
                echo 'none /tmp tmpfs,size=6g defaults' >> /etc/fstab

		# "zero out" the drive...
		$DEBUG || dd if=/dev/zero of=/EMPTY bs=1M
		$DEBUG || rm -f /EMPTY
  SCRIPT
end
EOF

# do all vagrant calls from within the working directory, or retrive
# vmID=$(vagrant global-status | grep $vmName | sed -e 's/ .*//')
vagrant up

vagrant halt

## prepare for bridged network
# VBoxManage modifyvm $imageName --nic1 bridged
# VBoxManage modifyvm $imageName --bridgeadapter1 wlan0
# VBoxManage modifyvm $imageName --macaddress1 auto
#
## VBoxManage modifyvm $imageName --resize 40000	# also needs: resize2fs -p -F /dev/DEVICE

## export is much better than copying the disk manually.
rm -f $imageName.* $imageName-*	# or VBoxManage export fails with 'already exists'
VBoxManage export $imageName -o $imageName.ovf
# VBoxImagePath=$(VBoxManage list hdds | grep "/$imageName/")
# #-->Location:       /home/$USER/VirtualBox VMs/ownCloud-8.1.1+xUbuntu_14.04/box-disk1.vmdk
# VBoxImagePath=/${VBoxImagePath#*/}	# delete Location: prefix
# cp "$VBoxImagePath" $imageName.vmdk
vagrant destroy -f




## convert to other formats...
for fmt in $formats_via_qemu_img_convert; do
 qemu-img convert -p -f vmdk oc8ce/$imageName-disk1.vmdk -O $fmt oc8ce/$imageName.$fmt
 $DEBUG || zip $imageName.$fmt.zip $imageName.$fmt
 $DEBUG || rm $imageName.$fmt
done
### sneak preview:
# sudo mount -o loop,ro,offset=$(expr 512 \* 2048) oc8ce/$imageName.raw /mnt

## FIXME: VBoxManage clonehd' looks into ~/.config/VirtualBox and fails with
##  UUID {2d168000-11b2-4f11-8ca2-8bb64c7fbffa} of the medium '...vmdk' does not match...
##  It should not look there at all!

$DEBUG || zip $imageName.vmdk.zip $imageName.vmdk
$DEBUG || rm $imageName.vmdk
