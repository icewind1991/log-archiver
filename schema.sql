CREATE TABLE logs_raw (
  id           INTEGER                     NOT NULL,
  json         JSONB                       NOT NULL,
  time         TIMESTAMP WITHOUT TIME ZONE NOT NULL
);

ALTER TABLE ONLY logs_raw
    ALTER COLUMN time SET DEFAULT now();

CREATE INDEX logs_raw_id_idx
    ON logs_raw USING BTREE (id);

CREATE INDEX logs_raw_success_idx
    ON logs_raw USING BTREE ((json->>'success'));