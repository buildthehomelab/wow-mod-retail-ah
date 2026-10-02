-- mod-retail-ah gold ledger. The module also creates this table at startup when RetailAH.Ledger
-- is on, so this file only matters for setups that apply module SQL themselves.
CREATE TABLE IF NOT EXISTS `mod_retail_ah_ledger` (
    `id` INT UNSIGNED NOT NULL AUTO_INCREMENT,
    `guid` INT UNSIGNED NOT NULL,
    `account` INT UNSIGNED NOT NULL,
    `time` INT UNSIGNED NOT NULL,
    `kind` TINYINT UNSIGNED NOT NULL COMMENT '1 sold, 2 bought, 3 expired, 4 cancelled',
    `item` INT UNSIGNED NOT NULL,
    `count` INT UNSIGNED NOT NULL,
    `gross` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'sale or purchase price',
    `fee` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'house cut, or the deposit (and cut) lost',
    `amount` BIGINT NOT NULL COMMENT 'net gold for the character: + earned, - lost',
    `other` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'buyer or seller character guid',
    PRIMARY KEY (`id`),
    KEY `guid_time` (`guid`, `time`),
    KEY `account_time` (`account`, `time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
