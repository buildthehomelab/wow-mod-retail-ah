-- mod-retail-ah: era overrides for AzerothCore loot data the module would otherwise read wrong.
-- INSERT IGNORE, so a row you have already set for one of these items stays as it is.

-- Duros (12122), a level 60 Alterac Valley creature, shares its skinning table with the
-- level 70/80 copies Duros (1)/(2), so Outland leather drops from it at 0.7%. Without these rows
-- the two would be visible from the start.
INSERT IGNORE INTO `mod_retail_ah_item_era` (`entry`, `state`, `comment`) VALUES
(21887, 8, 'Knothide Leather: Outland skinning (Duros skinning table is shared with TBC copies)'),
(25649, 8, 'Knothide Leather Scraps: Outland skinning (Duros skinning table is shared with TBC copies)');
