#!/bin/bash
set -e

#=== 0. Sudo Permission Check ===#
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root (use sudo)"
  exit 1
fi
#=== 1. Install Scripts & Cron Jobs ===#

chmod +x *.sh
cp ./*.sh /bin
cp .vars /opt/.vars

chmod 644 ./cron_proxy_jobs
sed -i s#ubuntu#$USER# ./cron_proxy_jobs
cp ./cron_proxy_jobs /etc/cron.d/
# sudo service cron restart
systemctl restart cron || true

echo "cron_proxy_jobs installed successfully."
