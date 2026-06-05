-- Fully-local stack: create the two WSO2 IS databases + the runtime user.
-- Runs once, on first MySQL container init (empty data dir), BEFORE the
-- version-matched WSO2 schema scripts (10-*, 20-*, 30-*, 40-*) that
-- scripts/local-setup.sh extracts from the released IS image into this dir.
-- See docs/architecture/fully-local-setup-plan.md §4 (Stage 1).

CREATE DATABASE IF NOT EXISTS WSO2_IDENTITY_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE DATABASE IF NOT EXISTS WSO2_SHARED_DB   CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;

CREATE USER IF NOT EXISTS 'wso2carbon'@'%' IDENTIFIED BY 'wso2carbon';
GRANT ALL PRIVILEGES ON WSO2_IDENTITY_DB.* TO 'wso2carbon'@'%';
GRANT ALL PRIVILEGES ON WSO2_SHARED_DB.*   TO 'wso2carbon'@'%';
FLUSH PRIVILEGES;
