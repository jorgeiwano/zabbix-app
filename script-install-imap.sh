#!/bin/bash

#######################################
# Definicao de variaveis
URL="https://github.com/RussianFox/imap.git"
BRANCH="Zabbix3.4"

yum install -y git

cd /root
git clone -b $BRANCH $URL
mv /root/imap/zabbix/imap /usr/share/zabbix 
mv /root/imap/zabbix/imap.php /usr/share/zabbix 
cp -rfp /root/imap/zabbix/locale/ru/LC_MESSAGES/imap.* /usr/share/locale/ru/LC_MESSAGES/


#tentar automatizar depois
#sed 's/.*Fedora.*/Cygwin\n&/' file
#sed -i -- "/\$denied_page_requested = false;/require_once dirname(__FILE__).'\/..\/imap/menu3.inc.php';\n&/" menu.inc.php
#sed -i -- "/.*\$denied_page_requested = false;.*/require_once dirname(__FILE__).'\/..\/imap/menu3.inc.php';\n&/" menu.inc.php
rm -rf /root/imap

/usr/bin/psql -U zabbix -h 127.0.0.1 --dbname zabbix < /usr/share/zabbix/imap/tables-postgresql.sql


# imap.js
# settings.js
# file imap.php




