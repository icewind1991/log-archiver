CREATE TABLE logs_raw (
  id           INTEGER                     NOT NULL,
  json         JSONB                       NOT NULL,
  time         TIMESTAMP WITHOUT TIME ZONE NOT NULL
);

ALTER TABLE ONLY logs_raw
    ALTER COLUMN time SET DEFAULT now();
