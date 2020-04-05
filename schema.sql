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

-- convert STEAM_0:X:YYYYYYYY and [U:1:XXXXXXX] into only [U:1:XXXXXXX]

CREATE FUNCTION normalize_steam_id(val TEXT) RETURNS TEXT AS $$
BEGIN
    IF substr(val, 0, 6) = 'STEAM' THEN
        return '[U:1:' || (substr(val, 9, 1)::BIGINT + substr(val, 11)::BIGINT * 2)::TEXT || ']';
    ELSE
        return val;
    END IF;
END; $$
    LANGUAGE PLPGSQL;

-- get an array of the normalized steamids of all players in a log

CREATE FUNCTION extract_players(log JSONB) RETURNS TEXT[] AS $$
BEGIN
    return ARRAY(SELECT normalize_steam_id(jsonb_object_keys(log->'players')));
END; $$
    LANGUAGE PLPGSQL IMMUTABLE;

CREATE INDEX logs_raw_players_idx
    ON logs_raw USING GIN (extract_players(json));

-- usage: select id from logs_raw where extract_players(json) @> ARRAY['[U:1:64229260]'];