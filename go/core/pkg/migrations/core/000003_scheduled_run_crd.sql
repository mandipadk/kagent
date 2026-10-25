-- +goose Up
-- The pre-1.0 schedule payload changes from protobuf to a CRD projection. The
-- required columns intentionally reject populated legacy stores, preserving
-- their data rather than silently adopting schedules under the machine caller.
ALTER TABLE scheduled_run
    ADD COLUMN namespace TEXT NOT NULL CHECK (namespace <> ''),
    ADD COLUMN name TEXT NOT NULL CHECK (name <> ''),
    ADD COLUMN generation BIGINT NOT NULL CHECK (generation > 0),
    ADD COLUMN disabled BOOLEAN NOT NULL DEFAULT FALSE,
    DROP COLUMN request_id,
    DROP COLUMN request_hash,
    DROP CONSTRAINT scheduled_run_check,
    ADD CONSTRAINT scheduled_run_check CHECK ((deleted_at IS NULL AND NOT disabled) OR next_execution_time IS NULL);
DROP INDEX scheduled_run_owner_idx;
CREATE UNIQUE INDEX scheduled_run_active_name_idx ON scheduled_run (namespace, name) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX scheduled_run_execution_session_idx ON scheduled_run_execution (session_id)
    WHERE session_id IS NOT NULL;

-- +goose Down
-- Downgrading also requires an empty schedule store: CRD projection payloads
-- cannot be interpreted by the earlier schedule API.
ALTER TABLE scheduled_run
    ADD COLUMN request_id TEXT NOT NULL CHECK (char_length(request_id) BETWEEN 1 AND 128),
    ADD COLUMN request_hash BYTEA NOT NULL CHECK (octet_length(request_hash) = 32),
    ADD UNIQUE (creator, request_id),
    DROP CONSTRAINT scheduled_run_check,
    DROP COLUMN namespace,
    DROP COLUMN name,
    DROP COLUMN generation,
    DROP COLUMN disabled,
    ADD CONSTRAINT scheduled_run_check CHECK (deleted_at IS NULL OR next_execution_time IS NULL);
CREATE INDEX scheduled_run_owner_idx ON scheduled_run (creator, id) WHERE deleted_at IS NULL;
DROP INDEX scheduled_run_execution_session_idx;
