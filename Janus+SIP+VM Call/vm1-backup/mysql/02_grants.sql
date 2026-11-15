GRANT USAGE ON *.* TO `freeswitch`@`localhost`;
GRANT SELECT ON `ic_sip`.* TO `freeswitch`@`localhost`;
GRANT USAGE ON *.* TO `ic-status`@`localhost`;
GRANT SELECT, INSERT, UPDATE, DELETE ON `ic_sip`.`sip_users` TO `ic-status`@`localhost`;
