swapoff /swapfile
swapon --show
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
swapon --show