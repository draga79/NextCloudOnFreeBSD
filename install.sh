#!/bin/sh
# Install NextCloud on FreeBSD
# Tested on FreeBSD 13.x
# https://github.com/theGeeBee/NextCloudOnFreeBSD/

# Check for root privileges
if ! [ $(id -u) = 0 ]; then
   echo "This script must be run with root privileges"
   exit 1
fi

# Set some variable names
HOST_NAME=""
MY_IP=""
NEXTCLOUD_VERSION="23"
COUNTRY_CODE="ZA"
ADMIN_PASSWORD=$(openssl rand -base64 12)
DB_ROOT_PASSWORD=$(openssl rand -base64 16)
DB_PASSWORD=$(openssl rand -base64 16)
DB_NAME="mySQL"

# Install required packages and then start services
kldload linux linux64 linprocfs linsysfs
cat includes/requirements.txt | xargs pkg install -y
service linux start
service mysql-server start
apachectl start
freshclam

# Download NextCloud and replace config files

FILE="latest-${NEXTCLOUD_VERSION}.tar.bz2"
if ! fetch -o /tmp https://download.nextcloud.com/server/releases/"${FILE}" https://download.nextcloud.com/server/releases/"${FILE}".asc https://nextcloud.com/nextcloud.asc
then
	echo "Failed to download Nextcloud"
	exit 1
fi
gpg --import /tmp/nextcloud.asc
if ! gpg --verify /tmp/"${FILE}".asc
then
	echo "GPG Signature Verification Failed!"
	echo "The Nextcloud download is corrupt."
	exit 1
fi
tar xjf /tmp/"${FILE}" -C /usr/local/www/apache24/data
chown -R www:www /usr/local/www/apache24/data

# Copy and edit pre-written config files
cp -f "${PWD}"/includes/php.ini /usr/local/etc/php.ini
sed -i '' "s|MYTIMEZONE|${TIME_ZONE}|" /usr/local/etc/php.ini

cp -f "${PWD}"/includes/www.conf /usr/local/etc/php-fpm.d/

cp -f "${PWD}"/includes/httpd.conf /usr/local/etc/apache24/
sed -i '' "s|MY_IP|${MY_IP}|" /usr/local/etc/apache24/httpd.conf
cp -f "${PWD}"/includes/nextcloud.conf /usr/local/etc/apache24/Includes/
cp -f "${PWD}"/includes/002-headers.conf /usr/local/etc/apache24/modules.d/
cp -f "${PWD}"/includes/php-fpm.conf /usr/local/etc/

openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout /usr/local/etc/apache24/server.key -out /usr/local/etc/apache24/server.crt

sysrc apache24_enable="YES"
sysrc mysql_enable="YES"
sysrc sendmail_enable="YES"
sysrc php_fpm_enable="YES"
sysrc clamav_freshclam_enable="YES"
sysrc linux_enable="YES"

cat "${PWD}"/includes/fstab >> /etc/fstab


#####
#
# NextCloud Install 
touch /var/log/nextcloud.log
chown www /var/log/nextcloud.log

# Secure database, set root password, create Nextcloud DB, user, and password
mysql -u root -e "CREATE DATABASE nextcloud;"
mysql -u root -e "GRANT ALL ON nextcloud.* TO nextcloud@localhost IDENTIFIED BY '${DB_PASSWORD}';"
mysql -u root -e "DELETE FROM mysql.user WHERE User='';"
mysql -u root -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
mysql -u root -e "DROP DATABASE IF EXISTS test;"
mysql -u root -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';"
mysqladmin --user=root password "${DB_ROOT_PASSWORD}" reload
cp -f ${PWD}/includes/my.cnf /root/.my.cnf
sed -i '' "s|MYPASSWORD|${DB_ROOT_PASSWORD}|" /root/.my.cnf

# Save passwords for later reference
echo "${DB_NAME} root password is ${DB_ROOT_PASSWORD}" > /root/${HOST_NAME}_db_password.txt
echo "Nextcloud database password is ${DB_PASSWORD}" >> /root/${HOST_NAME}_db_password.txt
echo "Nextcloud Administrator password is ${ADMIN_PASSWORD}" >> /root/${HOST_NAME}_db_password.txt

# Create Nextcloud log directory
mkdir -p /var/log/nextcloud/
chown www:www /var/log/nextcloud

# CLI installation and configuration of Nextcloud

su -m www -c "php /usr/local/www/apache24/data/occ maintenance:install --database=\"mysql\" --database-name=\"nextcloud\" --database-user=\"nextcloud\" --database-pass=\"${DB_PASSWORD}\" --database-host=\"localhost:/tmp/mysql.sock\" --admin-user=\"admin\" --admin-pass=\"${ADMIN_PASSWORD}\" --data-dir=\"/mnt/files\""
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set mysql.utf8mb4 --type boolean --value=\"true\""
su -m www -c "php /usr/local/www/nextcloud/occ db:add-missing-indices"
su -m www -c "php /usr/local/www/nextcloud/occ db:convert-filecache-bigint --no-interaction"
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set logtimezone --value=\"${TIME_ZONE}\""
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set default_phone_region --value=\"${COUNTRY_CODE}\""
su -m www -c 'php /usr/local/www/nextcloud/occ config:system:set log_type --value="file"'
su -m www -c 'php /usr/local/www/nextcloud/occ config:system:set logfile --value="/var/log/nextcloud/nextcloud.log"'
su -m www -c 'php /usr/local/www/nextcloud/occ config:system:set loglevel --value="2"'
su -m www -c 'php /usr/local/www/nextcloud/occ config:system:set logrotate_size --value="104847600"'
su -m www -c 'php /usr/local/www/nextcloud/occ config:system:set memcache.local --value="\OC\Memcache\APCu"'
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set overwritehost --value=\"${HOST_NAME}\""
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set overwrite.cli.url --value=\"https://${HOST_NAME}/\""
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set overwriteprotocol --value=\"https\""
su -m www -c 'php /usr/local/www/nextcloud/occ config:system:set htaccess.RewriteBase --value="/"'
su -m www -c 'php /usr/local/www/nextcloud/occ maintenance:update:htaccess'
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set trusted_domains 1 --value=\"${HOST_NAME}\""
su -m www -c "php /usr/local/www/nextcloud/occ config:system:set trusted_domains 2 --value=\"${MY_IP}\""
## SERVER SIDE ENCRYPTION 
## Server-side encryption makes it possible to encrypt files which are uploaded to this server.
## This comes with limitations like a performance penalty, so enable this only if needed.
# su -m www -c 'php /usr/local/www/nextcloud/occ app:enable encryption'
# su -m www -c 'php /usr/local/www/nextcloud/occ encryption:enable'
# su -m www -c 'php /usr/local/www/nextcloud/occ encryption:disable'
su -m www -c 'php /usr/local/www/nextcloud/occ background:cron'
su -m www -c 'php -f /usr/local/www/nextcloud/cron.php'
crontab -u www includes/www-crontab

#####
#
# Output results to console
#
#####

# Done!
echo "Installation complete!"
echo "Using your web browser, go to https://${HOST_NAME} or https://${HOST_NAME} to log in"


	echo "Default user is admin, password is ${ADMIN_PASSWORD}"
	echo ""
	echo "Database Information"
	echo "--------------------"
	echo "Database user = nextcloud"
	echo "Database password = ${DB_PASSWORD}"
	echo "The ${DB_NAME} root password is ${DB_ROOT_PASSWORD}"
	echo ""
	echo "All passwords are saved in /root/${JAIL_NAME}_db_password.txt"