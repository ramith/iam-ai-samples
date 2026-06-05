-- Fully-local stack: create the two WSO2 IS databases + the runtime user.
-- Runs once, on first MySQL container init (empty data dir), BEFORE the
-- version-matched WSO2 schema scripts (10-*, 20-*, 30-*, 40-*) that
-- scripts/local-setup.sh extracts from the released IS image into this dir.
-- See docs/architecture/fully-local-setup-plan.md §4 (Stage 1).

-- latin1, NOT utf8mb4: the WSO2 7.3.0 mysql.sql scripts size composite indexes
-- (e.g. IDN_OAUTH2_REVOKED_TOKENS on TOKEN_IDENTIFIER VARCHAR(2048)) assuming a
-- 1-byte charset. utf8mb4 (4 bytes/char) blows past InnoDB's 3072-byte key limit
-- ("ERROR 1071: Specified key was too long"). IDN_BASE_TABLE in the script
-- itself declares DEFAULT CHARACTER SET latin1 — that is the intended charset.
CREATE DATABASE IF NOT EXISTS WSO2_IDENTITY_DB CHARACTER SET latin1;
CREATE DATABASE IF NOT EXISTS WSO2_SHARED_DB   CHARACTER SET latin1;
-- Dedicated DB for the Agent identity userstore ([datasource.AgentIdentity];
-- default ships as H2 WSO2AGENTIDENTITY_DB). Schema = identity/agent/mysql.sql.
CREATE DATABASE IF NOT EXISTS WSO2_AGENT_DB    CHARACTER SET latin1;

CREATE USER IF NOT EXISTS 'wso2carbon'@'%' IDENTIFIED BY 'wso2carbon';
GRANT ALL PRIVILEGES ON WSO2_IDENTITY_DB.* TO 'wso2carbon'@'%';
GRANT ALL PRIVILEGES ON WSO2_SHARED_DB.*   TO 'wso2carbon'@'%';
GRANT ALL PRIVILEGES ON WSO2_AGENT_DB.*    TO 'wso2carbon'@'%';
FLUSH PRIVILEGES;
