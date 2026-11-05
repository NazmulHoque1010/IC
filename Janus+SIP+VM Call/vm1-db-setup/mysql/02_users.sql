-- MySQL users (no passwords: auth_socket trusts the Linux user of the same name)
CREATE USER 'freeswitch'@'localhost' IDENTIFIED WITH auth_socket;
GRANT SELECT ON ic_sip.* TO 'freeswitch'@'localhost';
CREATE USER 'ic-status'@'localhost' IDENTIFIED WITH auth_socket;
GRANT SELECT, INSERT, UPDATE, DELETE ON ic_sip.sip_users TO 'ic-status'@'localhost';
