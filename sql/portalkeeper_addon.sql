-- Optional. Only for realms that hand out addons with Portalkeeper
-- (https://github.com/buildthehomelab/wow-Portalkeeper) through mod-realm-config.
-- Makes the RetailAH addon required for every player. Run it by hand against acore_world.
-- It is kept out of data/sql on purpose: the table belongs to mod-realm-config, and a
-- failing statement there would stop the database import at startup.

DELETE FROM `mod_realm_config_addon` WHERE `addon_key` = 'RetailAH';
INSERT INTO `mod_realm_config_addon`
    (`addon_key`, `name`, `requirement`, `source_type`, `source_url`, `source_ref`, `install_directory`, `sort_order`, `enabled`)
VALUES
    ('RetailAH', 'RetailAH', 'Required', 'GitHub', 'https://github.com/buildthehomelab/wow-mod-retail-ah', 'main', 'RetailAH', 60, 1);
