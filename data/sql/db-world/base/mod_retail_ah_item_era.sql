-- mod-retail-ah: per-item overrides for the era gate. The worldserver also creates this table at
-- startup, so running this file is optional.
--
-- The module works out on its own which mod-individual-progression state unlocks each item (from
-- where it drops, who sells it, which quest rewards it, which recipe crafts it). A row here
-- replaces that answer for one item:
--   state = 0      always visible, whatever the module worked out
--   state = 1..18  hidden until the player's progression state reaches it
--                  (1 = Molten Core cleared, 3 = BWL cleared, 4 = AQ gates, 6 = AQ40 cleared,
--                   8 = TBC, 13 = WotLK, ... see the README for the full list)
--
-- Rows in mod-ah-progression's mod_ah_progression_item are read too; rows here win.
-- Apply changes in game with `.rah reload`. `.rah item <id>` shows what was decided and why.

CREATE TABLE IF NOT EXISTS `mod_retail_ah_item_era` (
    `entry`   INT UNSIGNED     NOT NULL COMMENT 'item_template.entry',
    `state`   TINYINT UNSIGNED NOT NULL COMMENT 'IP progression state needed to see it (0 = always)',
    `comment` VARCHAR(255)     NOT NULL DEFAULT '',
    PRIMARY KEY (`entry`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='mod-retail-ah era gate overrides';
