CREATE DATABASE IF NOT EXISTS ic_sip CHARACTER SET utf8mb4;
USE ic_sip;

CREATE TABLE IF NOT EXISTS sip_users (
  name VARCHAR(32)       NOT NULL PRIMARY KEY,
  grp  ENUM('A','B','C') NOT NULL,
  CONSTRAINT chk_name CHECK (REGEXP_LIKE(name, '^[a-z][a-z0-9._-]{1,31}$', 'c'))
);
