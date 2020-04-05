CREATE TABLE logs_raw (
  id           INTEGER                     NOT NULL,
  json         JSONB                       NOT NULL,
  time         TIMESTAMP WITHOUT TIME ZONE NOT NULL
);

ALTER TABLE ONLY logs_raw
    ALTER COLUMN time SET DEFAULT now();

CREATE UNIQUE INDEX logs_raw_id_idx
    ON logs_raw USING BTREE (id);

CREATE INDEX logs_raw_json_player_idx
    ON logs_raw USING GIN ((json->'players'));

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

-- get an array of the normalized steamids of all medics in a log

CREATE FUNCTION extract_medics(log JSONB) RETURNS TEXT[] AS $$
BEGIN
    return ARRAY(SELECT p.key FROM jsonb_each(log->'players') p WHERE (p.value->'drops')::INTEGER > 0 OR (p.value->'ubers')::INTEGER > 0);
END; $$
    LANGUAGE PLPGSQL IMMUTABLE;

CREATE INDEX logs_raw_medics_idx
    ON logs_raw USING GIN (extract_medics(json));

-- usage: select id from logs_raw where extract_players(json) @> ARRAY['[U:1:64229260]'];


-- convert a normalized steamid into the format used in the provided json

CREATE FUNCTION un_normalize_steam_id(steamid TEXT, log JSONB) RETURNS TEXT AS $$
DECLARE
    player TEXT;
BEGIN
    FOR player in SELECT jsonb_object_keys(log->'players')
        LOOP
            IF normalize_steam_id(player) = steamid THEN RETURN player; END IF;
        END LOOP;
    RETURN '';
END; $$
    LANGUAGE PLPGSQL IMMUTABLE;

-- example: SELECT id, json->'players'->un_normalize_steam_id('[U:1:64229260]', json)->'drops' from logs_raw where extract_players(json) @> ARRAY['[U:1:64229260]'];

CREATE FUNCTION extract_medics(log JSONB) RETURNS TEXT[] AS $$
BEGIN
    return ARRAY(SELECT p.key FROM jsonb_each(log->'players') p WHERE (p.value->'drops')::INTEGER > 0 OR (p.value->'ubers')::INTEGER > 0);
END; $$
    LANGUAGE PLPGSQL IMMUTABLE;

CREATE TABLE medic_stats (
    steam_id    TEXT                        NOT NULL,
    games       INTEGER                     NOT NULL,
    heals       INTEGER                     NOT NULL,
    drops       INTEGER                     NOT NULL,
    ubers       INTEGER                     NOT NULL,
    medic_time  INTEGER                     NOT NULL
);

CREATE UNIQUE INDEX medic_stats_steam_id_idx
    ON medic_stats USING BTREE (steam_id);

CREATE INDEX medic_stats_drops_idx
    ON medic_stats USING BTREE (drops);

CREATE INDEX medic_stats_heals_idx
    ON medic_stats USING BTREE (games);

CREATE INDEX medic_stats_ubers_idx
    ON medic_stats USING BTREE (ubers);

CREATE INDEX medic_stats_medic_time_idx
    ON medic_stats USING BTREE (medic_time);

CREATE OR REPLACE FUNCTION update_medic_stats() RETURNS trigger AS $$
BEGIN
    INSERT INTO medic_stats (steam_id, games, heals, drops, ubers, medic_time)
    (SELECT steamid, 1, heals, drops, ubers, length FROM log_medic_stats WHERE id = NEW.id LIMIT 1)
    ON CONFLICT (steam_id) DO
        UPDATE SET games = medic_stats.games + 1,
                   heals = medic_stats.heals + (SELECT SUM(heals) FROM log_medic_stats WHERE id = NEW.id AND log_medic_stats.steamid = medic_stats.steam_id),
                   ubers = medic_stats.ubers + (SELECT SUM(ubers) FROM log_medic_stats WHERE id = NEW.id AND log_medic_stats.steamid = medic_stats.steam_id),
                   drops = medic_stats.drops + (SELECT SUM(drops) FROM log_medic_stats WHERE id = NEW.id AND log_medic_stats.steamid = medic_stats.steam_id),
                   medic_time = medic_stats.medic_time + (SELECT MAX(length) FROM log_medic_stats WHERE id = NEW.id AND log_medic_stats.steamid = medic_stats.steam_id);

    RETURN NEW;
END;
$$
    LANGUAGE PLPGSQL;

CREATE TRIGGER update_stats_on_log
    AFTER INSERT OR UPDATE ON logs_raw
    FOR EACH ROW
EXECUTE PROCEDURE update_medic_stats();

-- 722426

CREATE VIEW log_medic_stats AS
    SELECT
        id,
        normalize_steam_id(p.key) as steamid,
        (p.value->'drops')::INTEGER AS drops,
        (p.value->'heal')::INTEGER AS heals,
        (p.value->'ubers')::INTEGER AS ubers,
        (json->'info'->'total_length')::INTEGER AS length
    FROM logs_raw, jsonb_each(json->'players') p
    WHERE (p.value->'drops')::INTEGER > 0 OR (p.value->'ubers')::INTEGER > 0;

CREATE INDEX logs_medic_steamid_idx
    ON log_medic_stats USING BTREE (steamid);