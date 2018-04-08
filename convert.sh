#!/bin/bash

backuppath=$1
subscription=$2

if [ "z"$subscription = "z" ]; then
	echo "Usage: $0 <backuppath> <subscription name>"
	exit 1
fi

if [ ! -d /var/www/vhosts/$subscription ]; then
	echo "Subscription $subscription does not exists"
	exit 1
fi

if [ ! -d $backuppath/backup ]; then
	echo "Invalid backup format for $backuppath"
	exit 1
fi

if [ ! -d $backuppath/domains ]; then
	echo "Invalid backup format for $backuppath"
	exit 1
fi

siteuid=$(stat -c %u /var/www/vhosts/$subscription)
oldusername=$(egrep ^username= $backuppath/backup/user.conf | cut -d= -f2)

echo old username = $oldusername

cd $backuppath/domains
for domain in $(ls -1); do
	if [ "$domain" = "$subscription" ]; then
		echo "subscription domain detected. not creating domain"
		echo "assume /var/www/vhosts/$subscription/httpdocs as docroot"
		docroot=/var/www/vhosts/$subscription/httpdocs
	else
		echo found domain $domain
		plesk bin domain -c $domain -webspace-name $subscription -hosting true -hst_type phys -www-root $domain
		retcode=$?
		if [ $retcode -ne 0 ]; then
			echo "invalid status code for creating domain $domain"
		fi
		docroot=/var/www/vhosts/$subscription/$domain
	fi
	if [ -d $docroot ]; then
		echo "found webroot $docroot"
		chown -R $siteuid $backuppath/domains/$domain/public_html
		rsync -av $backuppath/domains/$domain/public_html/ $docroot
	fi
	if [ -f $backuppath/backup/$domain/email/passwd ]; then
		for emailaccount in $(cat $backuppath/backup/$domain/email/passwd | cut -d: -f1); do
			if [ -d $backuppath/backup/$domain/email/data/imap/$emailaccount/Maildir ]; then
				echo got email $emailaccount@$domain
				plesk bin mail --create $emailaccount@$domain -passwd $(openssl rand -base64 12)
				if [ -d /var/qmail/mailnames/$domain/$emailaccount ]; then
					chown popuser.popuser -R $backuppath/backup/$domain/email/data/imap/$emailaccount/Maildir
					rsync -av $backuppath/backup/$domain/email/data/imap/$emailaccount/Maildir /var/qmail/mailnames/$domain/$emailaccount/
				fi
			fi
		done
	fi
done

cd $backuppath/backup
for dbnamesql in $(ls -1 *.sql); do
	dbname=$(echo $dbnamesql | sed 's/.sql$//g')
	if [ ! -d /var/lib/mysql/$dbname ]; then
		echo creating database $dbname 
		plesk bin database -c $dbname -domain $subscription -server localhost:3306

		echo "grant all privileges on $dbname.* to izrestore_da@localhost identified by 'c8vx4TGHs564'" | mysql -u admin -p$(cat /etc/psa/.psa.shadow)
		mysql -f -u izrestore_da -pc8vx4TGHs564 $dbname < $dbname.sql
		retcode=$?
		echo "drop user izrestore_da@localhost" | mysql -u admin -p$(cat /etc/psa/.psa.shadow)

		if [ $retcode -ne 0 ]; then
			echo mysql data restore fail for $dbname
		fi
		dbusers=$(egrep -v "^(accesshosts|$oldusername|db_collation)=" $dbname.conf | cut -d= -f1)
		for dbuser in $dbusers; do
			dbpasswd=$(egrep ^$dbuser= $dbname.conf | egrep -o 'passwd=[^&]+' | cut -d= -f2)
			echo got $dbuser / $dbpasswd
			plesk bin database --create-dbuser $dbuser -passwd "$dbpasswd" -domain $subscription -server localhost:3306 -database $dbname
			echo "SET PASSWORD FOR $dbuser@'%' = '$dbpasswd'; " | mysql -u admin -p$(cat /etc/psa/.psa.shadow)
		done
	fi
done


