-- ge-mcp permanent read-only role.
--
-- The role ge-mcp connects as. SELECT-only on public, forced read-only at the
-- transaction level so even a server logic bug cannot write.
--
-- Why a dedicated role (not the ingester's ge-data role):
--   1. The only existing role is the ingester's, which is READ/WRITE. ge-mcp is
--      LLM-facing; its whole spec is "never writes." Reusing a write-capable role
--      would void that invariant. A SELECT-only role + default_transaction_read_only
--      enforces read-only at the DB, not just in app code.
--   2. Independent credential: if the MCP's DSN leaks it's revoked/rotated alone,
--      without touching the ingest/write path.
--   3. Attribution + resource control: pg_stat_activity and per-role statement_timeout
--      / connection limits key off the role, so slow research scans can't starve the
--      ingester's pool and are traceable to "ge-mcp".
--
-- Run on eldo as a superuser, once. The DB name is hyphenated -> must be quoted.
-- The password is NOT in this file: set it out-of-band (managed in ~/cfg secret
-- store) and the server reads the full DSN from config (SPEC §5.3, DESIGN §7):
--   ALTER ROLE "ge-mcp" PASSWORD '...';   -- or set via the secret/IaC, never here.
--
-- pg_hba: add a rule in ~/cfg allowing "ge-mcp" from the ge-mcp pod / tailnet host
-- to "ge-data" over the tailnet only (WireGuard-encrypted; DSN uses sslmode=disable).

CREATE ROLE "ge-mcp" LOGIN;                                   -- password set out-of-band


GRANT CONNECT ON DATABASE "ge-data" TO "ge-mcp";
GRANT USAGE  ON SCHEMA public        TO "ge-mcp";

-- Read-only on the three tables the tools touch (and anything else in public).
GRANT SELECT ON ALL TABLES IN SCHEMA public TO "ge-mcp";
-- FOR ROLE "ge-data": default privileges attach to the creating role, and the
-- ingester's ge-data role owns/creates the tables — without this the rule would
-- only cover tables created by whoever runs this file.
ALTER DEFAULT PRIVILEGES FOR ROLE "ge-data" IN SCHEMA public GRANT SELECT ON TABLES TO "ge-mcp";

-- Belt-and-braces: force every transaction this role opens to be read-only.
ALTER ROLE "ge-mcp" SET default_transaction_read_only = on;

-- Optional: a generous statement_timeout backstop. Point tools also set a tighter
-- per-session timeout in code; broad research scans run without a scan-length cap
-- (DESIGN §4: no max-lookback), so keep any role-level timeout generous or unset.
-- ALTER ROLE "ge-mcp" SET statement_timeout = '0';   -- 0 = no limit
