#!/bin/bash

#######################################
# Definicao de variaveis
SENHA_DB_POSTGRES=""
SENHA_DB_ZABBIX=""
TIMEZONE="America/Sao_Paulo"
PG_HBA_NETWORK="192.168.61.0/24"
REPO_PGSQL="https://download.postgresql.org/pub/repos/yum/10/redhat/rhel-7-x86_64/pgdg-centos10-10-2.noarch.rpm"
REPO_ZABBIX="https://repo.zabbix.com/zabbix/3.4/rhel/7/x86_64/zabbix-release-3.4-2.el7.noarch.rpm"

# ajusta timezone sistema
timedatectl set-timezone $TIMEZONE

# desativa firewall
systemctl disable firewalld;
systemctl stop firewalld;	
systemctl status firewalld;


# desativa selinux
sed -i '/SELINUX=enforcing/c\SELINUX=disabled' /etc/selinux/config
setenforce 0


######################################
# atualiza e instala pacotes
yum install -y $REPO_PGSQL
yum install -y $REPO_ZABBIX
yum install -y epel-release
yum update -y

yum install -y \
net-tools vim mtr iptraf wget lynx ntpdate net-snmp-utils sysstat iotop htop nmon bind-utils sshpass hping3 whois tcpdump \
postgresql10 postgresql10-server zabbix-agent zabbix-server-pgsql zabbix-web-pgsql



######################################
# configura postgresql

/usr/pgsql-10/bin/postgresql-10-setup initdb
systemctl enable postgresql-10
systemctl start postgresql-10

sudo -u postgres psql -U postgres -d postgres -c "alter user postgres with password '$SENHA_DB_POSTGRES';"
sudo -u postgres psql -c "CREATE USER zabbix WITH PASSWORD '$SENHA_DB_ZABBIX';"
sudo -u postgres createdb -O zabbix zabbix
zcat /usr/share/doc/zabbix-server-pgsql-*/create.sql.gz | sudo -u zabbix psql zabbix

######################################
# configura partition table
QUERY="
DROP SCHEMA IF EXISTS partitions;
CREATE SCHEMA partitions AUTHORIZATION zabbix;
CREATE OR REPLACE FUNCTION trg_partition()
RETURNS trigger AS
\$BODY\$
DECLARE
prefix text := 'partitions.';
timeformat text;
selector text;
_interval interval;
tablename text;
startdate text;
enddate text;
create_table_part text;
create_index_part text;
BEGIN
selector = TG_ARGV[0];
IF selector = 'day' THEN
timeformat := 'YYYY_MM_DD';
ELSIF selector = 'month' THEN
timeformat := 'YYYY_MM';
END IF;
_interval := '1 ' || selector;
tablename :=  TG_TABLE_NAME || '_p' || to_char(to_timestamp(NEW.clock), timeformat);
EXECUTE 'INSERT INTO ' || prefix || quote_ident(tablename) || ' SELECT (\$1).*' USING NEW;
RETURN NULL;
EXCEPTION
WHEN undefined_table THEN
startdate := extract(epoch FROM date_trunc(selector, to_timestamp(NEW.clock)));
enddate := extract(epoch FROM date_trunc(selector, to_timestamp(NEW.clock) + _interval ));
create_table_part:= 'CREATE TABLE IF NOT EXISTS '|| prefix || quote_ident(tablename) || ' (CHECK ((clock >= ' || quote_literal(startdate) || ' AND clock < ' || quote_literal(enddate) || '))) INHERITS ('|| TG_TABLE_NAME || ')';
create_index_part:= 'CREATE INDEX '|| quote_ident(tablename) || '_1 on ' || prefix || quote_ident(tablename) || '(itemid,clock)';
EXECUTE create_table_part;
EXECUTE create_index_part;
EXECUTE 'INSERT INTO ' || prefix || quote_ident(tablename) || ' SELECT (\$1).*' USING NEW;
RETURN NULL;
END;
\$BODY\$
LANGUAGE plpgsql VOLATILE
COST 100;
ALTER FUNCTION trg_partition()
OWNER TO postgres;

CREATE TRIGGER partition_trg BEFORE INSERT ON history FOR EACH ROW EXECUTE PROCEDURE trg_partition('day');
CREATE TRIGGER partition_trg BEFORE INSERT ON history_uint FOR EACH ROW EXECUTE PROCEDURE trg_partition('day');
CREATE TRIGGER partition_trg BEFORE INSERT ON history_str FOR EACH ROW EXECUTE PROCEDURE trg_partition('day');
CREATE TRIGGER partition_trg BEFORE INSERT ON history_text FOR EACH ROW EXECUTE PROCEDURE trg_partition('day');
CREATE TRIGGER partition_trg BEFORE INSERT ON history_log FOR EACH ROW EXECUTE PROCEDURE trg_partition('day');
CREATE TRIGGER partition_trg BEFORE INSERT ON trends FOR EACH ROW EXECUTE PROCEDURE trg_partition('month');
CREATE TRIGGER partition_trg BEFORE INSERT ON trends_uint FOR EACH ROW EXECUTE PROCEDURE trg_partition('month');

CREATE OR REPLACE FUNCTION delete_partitions(intervaltodelete interval, tabletype text)
  RETURNS text AS
\$BODY\$
DECLARE
result record ;
prefix text := 'partitions.';
table_timestamp timestamp;
delete_before_date date;
tablename text;

BEGIN
    FOR result IN SELECT * FROM pg_tables WHERE schemaname = 'partitions' LOOP

        table_timestamp := to_timestamp(substring(result.tablename from '[0-9_]*$'), 'YYYY_MM_DD');
        delete_before_date := date_trunc('day', NOW() - intervalToDelete);
        tablename := result.tablename;

    -- Was it called properly?
        IF tabletype != 'month' AND tabletype != 'day' THEN
	    RAISE EXCEPTION 'Please specify month or day instead of %', tabletype;
        END IF;


    --Check whether the table name has a day (YYYY_MM_DD) or month (YYYY_MM) format
        IF length(substring(result.tablename from '[0-9_]*$')) = 10 AND tabletype = 'month' THEN
            --This is a daily partition YYYY_MM_DD
            -- RAISE NOTICE 'Skipping table % when trying to delete % partitions (%)', result.tablename, tabletype, length(substring(result.tablename from '[0-9_]*$'));
            CONTINUE;
        ELSIF length(substring(result.tablename from '[0-9_]*$')) = 7 AND tabletype = 'day' THEN
            --this is a monthly partition
            --RAISE NOTICE 'Skipping table % when trying to delete % partitions (%)', result.tablename, tabletype, length(substring(result.tablename from '[0-9_]*$'));
            CONTINUE;
        ELSE
            --This is the correct table type. Go ahead and check if it needs to be deleted
	    --RAISE NOTICE 'Checking table %', result.tablename;
        END IF;

	IF table_timestamp <= delete_before_date THEN
		RAISE NOTICE 'Deleting table %', quote_ident(tablename);
		EXECUTE 'DROP TABLE ' || prefix || quote_ident(tablename) || ';';
	END IF;
    END LOOP;
RETURN 'OK';

END;

\$BODY\$
  LANGUAGE plpgsql VOLATILE
  COST 100;
ALTER FUNCTION delete_partitions(interval, text)
  OWNER TO postgres;"

sudo -u postgres psql zabbix -c "$QUERY"



######################################
# configura pg_hba.conf
sed -i "$1"' s/^/#/' /var/lib/pgsql/10/data/pg_hba.conf
echo "local all all md5" >> /var/lib/pgsql/10/data/pg_hba.conf
echo "host all all 127.0.0.1/32 md5" >> /var/lib/pgsql/10/data/pg_hba.conf
echo "host all all ::1/128 md5" >> /var/lib/pgsql/10/data/pg_hba.conf

for NETWORK in $PG_HBA_NETWORK
do
        echo "host all all $NETWORK md5" >> /var/lib/pgsql/10/data/pg_hba.conf
done


######################################
sed -i -- "s/#listen_addresses = 'localhost'/listen_addresses = '*'/g" /var/lib/pgsql/10/data/postgresql.conf
chown postgres:postgres /var/lib/pgsql/10/data/postgresql.conf
systemctl restart postgresql-10
echo "127.0.0.1:5432:zabbix:zabbix:$SENHA_DB_ZABBIX" > ~/.pgpass
chmod 0600 ~/.pgpass
echo "SELECT delete_partitions('7 days', 'day');" > cat
echo "SELECT delete_partitions('11 months', 'month');" >> /root/DeletePartition.sql
echo "1 1 * * *       root    /usr/bin/psql -U zabbix -h 127.0.0.1 --dbname zabbix < /root/DeletePartition.sql" >> /etc/crontab
systemctl restart crond


######################################
# configura httpd
TIMEZONE=`echo $TIMEZONE|sed 's/\//\\\\\//g'`
sed -i -- "s/# php_value date.timezone Europe\/Riga/php_value date.timezone $TIMEZONE/g" /etc/httpd/conf.d/zabbix.conf
systemctl enable httpd
systemctl start httpd

######################################
# configura zabbix-server
sed -i -- "s/# DBPassword=/DBPassword=$SENHA_DB_ZABBIX/g" /etc/zabbix/zabbix_server.conf

systemctl enable zabbix-agent
systemctl enable zabbix-server

systemctl start zabbix-agent
systemctl start zabbix-server



######################################
# configura elasticsearch
yum install -y java-1.8.0-openjdk.x86_64
rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch

echo "[elasticsearch-6.x]
name=Elasticsearch repository for 6.x packages
baseurl=https://artifacts.elastic.co/packages/6.x/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md" > /etc/yum.repos.d/elasticsearch.repo

yum install -y elasticsearch
systemctl daemon-reload
systemctl enable elasticsearch
systemctl start elasticsearch

sed -i -- "s/# HistoryStorageURL=/HistoryStorageURL=http:\/\/127.0.0.1:9200/g" /etc/zabbix/zabbix_server.conf
sed -i -- "s/# HistoryStorageTypes=uint,dbl,str,log,text/HistoryStorageTypes=uint,dbl,str,log,text/g" /etc/zabbix/zabbix_server.conf


sed -i -- "s/global $DB;/global $DB, $HISTORY;/g" /etc/zabbix/web/zabbix.conf.php
echo "\$HISTORY['url']   = 'http://127.0.0.1:9200';" >> /etc/zabbix/web/zabbix.conf.php
echo "\$HISTORY['types'] = ['uint', 'dbl', 'text', 'str', 'log'];" >> /etc/zabbix/web/zabbix.conf.php

# https://www.zabbix.org/websvn/wsvn/zabbix.com/branches/3.4/database/elasticsearch/elasticsearch.map

HOST=192.168.254.37
# uint mapping
curl -X PUT http://$HOST:9200/uint -H 'content-type:application/json' -d '
{
   "settings" : {
      "index" : {
         "number_of_replicas" : 1,
         "number_of_shards" : 5
      }
   },
   "mappings" : {
      "values" : {
         "properties" : {
            "itemid" : {
               "type" : "long"
            },
            "clock" : {
               "format" : "epoch_second",
               "type" : "date"
            },
            "value" : {
               "type" : "long"
            }
         }
      }
   }
}'


# dbl mapping
curl -X PUT http://$HOST:9200/dbl -H 'content-type:application/json' -d '
{
   "settings" : {
      "index" : {
         "number_of_replicas" : 1,
         "number_of_shards" : 5
      }
   },
   "mappings" : {
      "values" : {
         "properties" : {
            "itemid" : {
               "type" : "long"
            },
            "clock" : {
               "format" : "epoch_second",
               "type" : "date"
            },
            "value" : {
               "type" : "double"
            }
         }
      }
   }
}'


# str mapping
curl -X PUT http://$HOST:9200/str -H 'content-type:application/json' -d '
{
   "settings" : {
      "index" : {
         "number_of_replicas" : 1,
         "number_of_shards" : 5
      }
   },
   "mappings" : {
      "values" : {
         "properties" : {
            "itemid" : {
               "type" : "long"
            },
            "clock" : {
               "format" : "epoch_second",
               "type" : "date"
            },
            "value" : {
               "fields" : {
                  "analyzed" : {
                     "index" : true,
                     "type" : "text",
                     "analyzer" : "standard"
                  }
               },
               "index" : false,
               "type" : "text"
            }
         }
      }
   }
}'


# text mapping
curl -X PUT http://$HOST:9200/text -H 'content-type:application/json' -d '
{
   "settings" : {
      "index" : {
         "number_of_replicas" : 1,
         "number_of_shards" : 5
      }
   },
   "mappings" : {
      "values" : {
         "properties" : {
            "itemid" : {
               "type" : "long"
            },
            "clock" : {
               "format" : "epoch_second",
               "type" : "date"
            },
            "value" : {
               "fields" : {
                  "analyzed" : {
                     "index" : true,
                     "type" : "text",
                     "analyzer" : "standard"
                  }
               },
               "index" : false,
               "type" : "text"
            }
         }
      }
   }
}'


# log mapping
curl -X PUT http://$HOST:9200/log -H 'content-type:application/json' -d '
{
   "settings" : {
      "index" : {
         "number_of_replicas" : 1,
         "number_of_shards" : 5
      }
   },
   "mappings" : {
      "values" : {
         "properties" : {
            "itemid" : {
               "type" : "long"
            },
            "clock" : {
               "format" : "epoch_second",
               "type" : "date"
            },
            "value" : {
               "fields" : {
                  "analyzed" : {
                     "index" : true,
                     "type" : "text",
                     "analyzer" : "standard"
                  }
               },
               "index" : false,
               "type" : "text"
            }
         }
      }
   }
}'