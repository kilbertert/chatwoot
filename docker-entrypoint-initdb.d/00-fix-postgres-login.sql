-- pgvector:pg16 默认 postgres NOLOGIN + 官方 entrypoint 只建 POSTGRES_DB 一个库
-- 1. 强制 postgres role 可登录 (NOLOGIN 修复)
-- 2. 同步建 dev/test/兜底库 (database.yml 默认值), 不依赖 POSTGRES_DB env
ALTER USER postgres WITH LOGIN SUPERUSER;

-- psql has no CREATE DATABASE IF NOT EXISTS, so use gexec to keep init idempotent.
SELECT 'CREATE DATABASE chatwoot_dev OWNER postgres ENCODING ''UTF8'' LC_COLLATE ''en_US.utf8'' LC_CTYPE ''en_US.utf8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot_dev')\gexec

SELECT 'CREATE DATABASE chatwoot_test OWNER postgres ENCODING ''UTF8'' LC_COLLATE ''en_US.utf8'' LC_CTYPE ''en_US.utf8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot_test')\gexec

SELECT 'CREATE DATABASE chatwoot OWNER postgres ENCODING ''UTF8'' LC_COLLATE ''en_US.utf8'' LC_CTYPE ''en_US.utf8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot')\gexec
