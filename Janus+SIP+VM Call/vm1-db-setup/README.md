# VM1: SIP users in MySQL, group codecs, users API

| Repo file | Live path on VM1 |
|---|---|
| freeswitch/scripts/ic_directory.lua | /usr/local/freeswitch/scripts/ |
| freeswitch/conf/vars.xml | /usr/local/freeswitch/conf/ |
| freeswitch/conf/sip_profiles/*.xml | /usr/local/freeswitch/conf/sip_profiles/ |
| freeswitch/conf/dialplan/default.xml | /usr/local/freeswitch/conf/dialplan/ |
| freeswitch/conf/dialplan/default/00_ic_users.xml | /usr/local/freeswitch/conf/dialplan/default/ |
| freeswitch/conf/autoload_configs/lua.conf.xml | /usr/local/freeswitch/conf/autoload_configs/ |
| etc/odbc.ini, etc/odbcinst.ini | /etc/ |
| ic-status/ic_status.py | /opt/ic-status/ |
| ic-status/ic-status.json | /etc/ |
| ic-status/ic-status.service | /etc/systemd/system/ |
| mysql/01_schema.sql, mysql/02_users.sql | run with: sudo mysql < file |

Packages: mysql-server, odbc-mariadb, unixodbc.
Groups: A = PCMU, B = GSM, C = PCMA. App users (Janus) always use OPUS.
Placeholders: __IC_PUBLIC_IP__, __IC_SECRET_DEFAULT_PASSWORD__, __IC_SECRET_ESL_PASSWORD__.
