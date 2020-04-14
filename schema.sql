CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

CREATE TYPE team AS ENUM ('Blue', 'Red');

CREATE TYPE class_type AS ENUM ('scout', 'soldier', 'pyro', 'demoman', 'heavyweapons', 'engineer', 'medic', 'sniper', 'spy');

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

CREATE INDEX logs_raw_map_idx
    ON logs_raw USING BTREE ((clean_map_name(json->'info'->>'map')));

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
    games       BIGINT                      NOT NULL,
    heals       BIGINT                      NOT NULL,
    drops       BIGINT                      NOT NULL,
    ubers       BIGINT                      NOT NULL,
    medic_time  BIGINT                      NOT NULL,
    dpu         NUMERIC NOT NULL GENERATED ALWAYS AS (dpx(drops, ubers)) STORED,
    dps         NUMERIC NOT NULL GENERATED ALWAYS AS (dpx(drops, medic_time)) STORED,
    dpg         NUMERIC NOT NULL GENERATED ALWAYS AS (dpx(drops, games)) STORED
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

CREATE INDEX medic_stats_dpu_idx
    ON medic_stats USING BTREE (dpu);

CREATE INDEX medic_stats_dps_idx
    ON medic_stats USING BTREE (dps);

CREATE OR REPLACE FUNCTION dpx(drops BIGINT, x BIGINT) RETURNS NUMERIC AS $$
BEGIN
    IF x = 0 THEN
        return 0;
    ELSE
        return drops::NUMERIC / x::NUMERIC;
    END IF;
END; $$
    LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION update_medic_stats() RETURNS trigger AS $$
BEGIN
    INSERT INTO medic_stats (steam_id, games, heals, drops, ubers, medic_time)
    (SELECT steamid, 1, heals, drops, ubers, length FROM log_medic_stats WHERE id = NEW.id)
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

CREATE VIEW log_medic_stats AS
    SELECT
        id,
        normalize_steam_id(p.key) as steamid,
        (p.value->'drops')::BIGINT AS drops,
        (p.value->'heal')::BIGINT AS heals,
        (p.value->'ubers')::BIGINT AS ubers,
        (json->'info'->'total_length')::BIGINT AS length
    FROM logs_raw, jsonb_each(json->'players') p
    WHERE (p.value->'drops')::BIGINT > 0 OR (p.value->'ubers')::BIGINT > 0;

CREATE VIEW log_player_names AS
SELECT
    id,
    normalize_steam_id(p.key) as steam_id,
    p.value #>> '{}' AS name,
    (json->'info'->'total_length')::INTEGER AS length
FROM logs_raw, jsonb_each(json->'names') p;

CREATE TABLE player_names (
    steam_id    TEXT                        NOT NULL,
    name        TEXT                        NOT NULL,
    count       BIGINT                      NOT NULL,
    use_time    BIGINT                      NOT NULL
);

CREATE UNIQUE INDEX player_names_steam_id_name_idx
    ON player_names USING BTREE (steam_id, name);

CREATE INDEX player_names_search_idx
    ON player_names USING GIN (name gin_trgm_ops);

CREATE OR REPLACE FUNCTION update_player_names() RETURNS trigger AS $$
BEGIN
    INSERT INTO player_names (steam_id, name, count, use_time)
        (SELECT steam_id, name, 1, length FROM log_player_names WHERE id = NEW.id)
    ON CONFLICT (steam_id, name) DO
        UPDATE SET count = player_names.count + 1,
                   use_time = player_names.use_time + (SELECT MAX(length) FROM log_player_names WHERE id = NEW.id AND log_player_names.steam_id = player_names.steam_id);

    RETURN NEW;
END;
$$
    LANGUAGE PLPGSQL;

CREATE TRIGGER update_names_on_log
    AFTER INSERT OR UPDATE ON logs_raw
    FOR EACH ROW
EXECUTE PROCEDURE update_player_names();

CREATE MATERIALIZED VIEW user_names AS
    WITH names AS
         (
             select name, count, steam_id,
                    rank() over (partition by steam_id order by steam_id, count desc) rn
             from player_names
         )
    SELECT steam_id, MAX(name) as name
    FROM names
    WHERE rn = 1
    GROUP BY steam_id;

CREATE UNIQUE INDEX user_names_steam_id_idx
    ON user_names USING BTREE (steam_id);

CREATE MATERIALIZED VIEW global_stats AS
    SELECT SUM(drops)::BIGINT as drops, SUM(ubers)::BIGINT as ubers, SUM(games)::BIGINT as games, SUM(medic_time)::BIGINT as medic_time
    FROM medic_stats;

CREATE FUNCTION clean_map_name(map TEXT) RETURNS TEXT AS $$
        SELECT regexp_replace(map, '(_(a|b|beta|u|r|v|rc|final|comptf|ugc)?[0-9]*[a-z]?$)|([0-9]+[a-z]?$)', '', 'g');
$$ LANGUAGE SQL;

CREATE VIEW log_class_stats AS
SELECT
    id,
    clean_map_name(json->'info'->>'map') as map,
    (json->'team'->'Red'->'score' > json->'team'->'Blue'->'score')::BIGINT AS red_wins,
    (json->'team'->'Red'->'score' < json->'team'->'Blue'->'score')::BIGINT AS red_wins,
    (p.value->'heal')::BIGINT AS heals,
    (p.value->'ubers')::BIGINT AS ubers,
    (json->'info'->'total_length')::BIGINT AS length
FROM logs_raw, jsonb_each(json->'players') p
WHERE (p.value->'drops')::BIGINT > 0 OR (p.value->'ubers')::BIGINT > 0;

CREATE OR REPLACE  FUNCTION map_is_stopwatch(map TEXT) RETURNS BOOLEAN AS $$
BEGIN
    IF map LIKE 'pl_%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_steel%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_gravelpit%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_dustbowl%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_egypt%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_degrootkeep%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_gorge%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_junction%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_mossrock%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_manor%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_snowplow%' THEN
        RETURN true;
    END IF;
    IF map LIKE 'cp_alloy%' THEN
        RETURN true;
    END IF;

    RETURN false;
END;
$$
    LANGUAGE PLPGSQL;

CREATE OR REPLACE  FUNCTION get_team_score(json JSONB, team team) RETURNS BIGINT AS $$
DECLARE
    score BIGINT;
BEGIN
    -- old logs have stopwatch rounds counted differently
    IF NOT (coalesce(json->'info'->>'AD_scoring', 'false') = 'true') AND map_is_stopwatch(json->'info'->>'map') THEN
        IF get_stopwatch_winner(json) = team THEN
            return 1;
        ELSE
            return 0;
        END IF;
    ELSE
        SELECT coalesce((json->'teams'->(team::TEXT)->'score')::BIGINT, 0) INTO score;

        return score;
    END IF;
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION get_stopwatch_winner(json JSONB) RETURNS team AS $$
DECLARE
    first_round_caps BIGINT;
    second_round_caps BIGINT;
    first_round_length BIGINT;
    first_round_full_length BIGINT;
    second_round_length BIGINT;
    second_round_first_event_time BIGINT;
BEGIN
    IF jsonb_path_exists(json, '$.rounds') THEN
        SELECT coalesce(MAX((e.value->>'point')::INT), 0), coalesce(MAX((e.value->>'time')::INT), 0) INTO first_round_caps, first_round_length
            FROM jsonb_array_elements(json->'rounds'->0->'events') e WHERE e.value->>'type' = 'pointcap';
        SELECT coalesce(MAX((e.value->>'point')::INT), 0), coalesce(MAX((e.value->>'time')::INT), 0) INTO second_round_caps, second_round_length
            FROM jsonb_array_elements(json->'rounds'->1->'events') e WHERE (e.value->>'type' = 'pointcap' OR (e.value->>'type' = 'round_win' AND e.value->>'team' = 'Blue'));
        SELECT coalesce(MIN((e.value->>'time')::INT), 0) INTO second_round_first_event_time
            FROM jsonb_array_elements(json->'rounds'->1->'events') e;
        SELECT coalesce(MAX((e.value->>'time')::INT), 0) INTO first_round_full_length
        FROM jsonb_array_elements(json->'rounds'->1->'events') e;

        -- old format doesn't properly log the last cap when last is capped in second round
        IF json->'rounds'->1->>'winner' = 'Blue' AND second_round_caps < first_round_caps THEN
            second_round_caps := second_round_caps + 1;
        END IF;
    ELSE
        SELECT coalesce(MAX((e.value->>'point')::INT), 0), coalesce(MAX((e.value->>'time')::INT), 0) INTO first_round_caps, first_round_length
            FROM jsonb_array_elements(json->'info'->'rounds'->0->'events') e WHERE e.value->>'type' = 'pointcap';
        SELECT coalesce(MAX((e.value->>'point')::INT), 0), coalesce(MAX((e.value->>'time')::INT), 0) INTO second_round_caps, second_round_length
            FROM jsonb_array_elements(json->'info'->'rounds'->1->'events') e WHERE (e.value->>'type' = 'pointcap' OR (e.value->>'type' = 'round_win' AND e.value->>'team' = 'Blue'));
        SELECT coalesce(MIN((e.value->>'time')::INT), 0) INTO second_round_first_event_time
            FROM jsonb_array_elements(json->'info'->'rounds'->1->'events') e;
        SELECT coalesce(MAX((e.value->>'time')::INT), 0) INTO first_round_full_length
        FROM jsonb_array_elements(json->'info'->'rounds'->1->'events') e;

        -- old format doesn't properly log the last cap when last is capped in second round
        IF json->'info'->'rounds'->1->>'winner' = 'Blue' AND second_round_caps < first_round_caps THEN
            second_round_caps := second_round_caps + 1;
        END IF;
    END IF;

    IF second_round_first_event_time > first_round_length THEN
        second_round_length := second_round_length - first_round_full_length;
    END IF;

    -- both teams capped the same number of points
    IF first_round_caps = second_round_caps THEN
        -- first team (counted as blue) capped faster
        IF first_round_length < second_round_length THEN
            return 'Blue';
        ELSE
            return 'Red';
        END IF;
    -- first team capped more
    ELSEIF first_round_caps > second_round_caps THEN
        return 'Blue';
    -- second team capped more
    ELSE
        return 'Red';
    END IF;
END;
$$
    LANGUAGE PLPGSQL;

CREATE OR REPLACE  FUNCTION get_class_kills(json JSONB, class_name class_type) RETURNS BIGINT AS $$
    SELECT coalesce(sum((c.value->>'kills')::BIGINT)::BIGINT, 0) FROM jsonb_each(json->'players') p, jsonb_array_elements(p.value->'class_stats') c WHERE c.value->>'type' = class_name::TEXT AND LENGTH(c.value->>'kills') < 3;
$$ LANGUAGE SQL;

CREATE OR REPLACE  FUNCTION get_class_deaths(json JSONB, class_name class_type) RETURNS BIGINT AS $$
    SELECT coalesce(sum((c.value->>'deaths')::BIGINT)::BIGINT, 0) FROM jsonb_each(json->'players') p, jsonb_array_elements(p.value->'class_stats') c WHERE c.value->>'type' = class_name::TEXT AND LENGTH(c.value->>'deaths') < 3;
$$ LANGUAGE SQL;

CREATE OR REPLACE  FUNCTION get_class_damage(json JSONB, class_name class_type) RETURNS BIGINT AS $$
    SELECT coalesce(sum((c.value->>'dmg')::BIGINT)::BIGINT, 0) FROM jsonb_each(json->'players') p, jsonb_array_elements(p.value->'class_stats') c WHERE c.value->>'type' = class_name::TEXT AND LENGTH(c.value->>'dmg') < 5;
$$ LANGUAGE SQL;

CREATE OR REPLACE FUNCTION get_midfight_wins(json JSONB, team team) RETURNS BIGINT AS $$
    SELECT count(*) FROM jsonb_array_elements(json->'rounds') r WHERE r->>'firstcap' = team::TEXT;
$$ LANGUAGE SQL;

CREATE OR REPLACE  FUNCTION get_other_team(team team) RETURNS team AS $$
BEGIN
    IF team = 'Red' THEN
        return 'Blue';
    ELSE
        return 'Red';
    END IF;
END;
$$
    LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION get_wins(json JSONB, team team) RETURNS BIGINT AS $$
DECLARE
    team_score BIGINT;
    other_score BIGINT;
BEGIN
    team_score := get_team_score(json, team);
    other_score := get_team_score(json, get_other_team(team));

    IF team_score > other_score THEN
        return 1;
    ELSE
        return 0;
    END IF;
END;
$$
    LANGUAGE PLPGSQL;

CREATE VIEW log_map_stats AS
    SELECT
        id,

        clean_map_name(json->'info'->>'map') as map,
        get_team_score(json, 'Red') AS red_score,
        get_team_score(json, 'Blue') AS blue_score,
        get_wins(json, 'Red') AS red_wins,
        get_wins(json, 'Blue') AS blue_wins,

        get_midfight_wins(json, 'Red') as midfight_red,
        get_midfight_wins(json, 'Blue') as midfight_blue,

        get_class_kills(json, 'scout') as scout_kills,
        get_class_kills(json, 'soldier') as soldier_kills,
        get_class_kills(json, 'pyro') as pyro_kills,
        get_class_kills(json, 'demoman') as demoman_kills,
        get_class_kills(json, 'heavyweapons') as heavy_kills,
        get_class_kills(json, 'engineer') as engineer_kills,
        get_class_kills(json, 'medic') as medic_kills,
        get_class_kills(json, 'sniper') as sniper_kills,
        get_class_kills(json, 'spy') as spy_kills,

        get_class_deaths(json, 'scout') as scout_deaths,
        get_class_deaths(json, 'soldier') as soldier_deaths,
        get_class_deaths(json, 'pyro') as pyro_deaths,
        get_class_deaths(json, 'demoman') as demoman_deaths,
        get_class_deaths(json, 'heavyweapons') as heavy_deaths,
        get_class_deaths(json, 'engineer') as engineer_deaths,
        get_class_deaths(json, 'medic') as medic_deaths,
        get_class_deaths(json, 'sniper') as sniper_deaths,
        get_class_deaths(json, 'spy') as spy_deaths,

        get_class_damage(json, 'scout') as scout_damage,
        get_class_damage(json, 'soldier') as soldier_damage,
        get_class_damage(json, 'pyro') as pyro_damage,
        get_class_damage(json, 'demoman') as demoman_damage,
        get_class_damage(json, 'heavyweapons') as heavy_damage,
        get_class_damage(json, 'engineer') as engineer_damage,
        get_class_damage(json, 'medic') as medic_damage,
        get_class_damage(json, 'sniper') as sniper_damage,
        get_class_damage(json, 'spy') as spy_damage,

        (json->'info'->'total_length')::BIGINT AS length
    FROM logs_raw;

CREATE TABLE map_stats (
     map             TEXT                   NOT NULL,
     count           BIGINT                 NOT NULL,
     red_wins       BIGINT                 NOT NULL,
     blue_wins      BIGINT                 NOT NULL,
     red_score       BIGINT                 NOT NULL,
     blue_score      BIGINT                 NOT NULL,

     midfight_blue   BIGINT                 NOT NULL,
     midfight_red    BIGINT                 NOT NULL,

     scout_kills     BIGINT                 NOT NULL,
     soldier_kills   BIGINT                 NOT NULL,
     pyro_kills      BIGINT                 NOT NULL,
     demoman_kills   BIGINT                 NOT NULL,
     heavy_kills     BIGINT                 NOT NULL,
     engineer_kills  BIGINT                 NOT NULL,
     medic_kills     BIGINT                 NOT NULL,
     sniper_kills    BIGINT                 NOT NULL,
     spy_kills       BIGINT                 NOT NULL,

     scout_deaths    BIGINT                 NOT NULL,
     soldier_deaths  BIGINT                 NOT NULL,
     pyro_deaths     BIGINT                 NOT NULL,
     demoman_deaths  BIGINT                 NOT NULL,
     heavy_deaths    BIGINT                 NOT NULL,
     engineer_deaths BIGINT                 NOT NULL,
     medic_deaths    BIGINT                 NOT NULL,
     sniper_deaths   BIGINT                 NOT NULL,
     spy_deaths      BIGINT                 NOT NULL,

     scout_damage    BIGINT                 NOT NULL,
     soldier_damage  BIGINT                 NOT NULL,
     pyro_damage     BIGINT                 NOT NULL,
     demoman_damage  BIGINT                 NOT NULL,
     heavy_damage    BIGINT                 NOT NULL,
     engineer_damage BIGINT                 NOT NULL,
     medic_damage    BIGINT                 NOT NULL,
     sniper_damage   BIGINT                 NOT NULL,
     spy_damage      BIGINT                 NOT NULL,

     play_time       BIGINT                 NOT NULL
);

CREATE UNIQUE INDEX map_stats_map_idx
    ON map_stats USING BTREE (map);

CREATE INDEX map_stats_count_idx
    ON map_stats USING BTREE (count);

CREATE OR REPLACE FUNCTION update_map_stats() RETURNS trigger AS $$
BEGIN
    INSERT INTO map_stats (
            map,
            count,
            red_wins,
            blue_wins,
            red_score,
            blue_score,
            midfight_blue,
            midfight_red,
            scout_kills,
            soldier_kills,
            pyro_kills,
            demoman_kills,
            heavy_kills,
            engineer_kills,
            medic_kills,
            sniper_kills,
            spy_kills,
            scout_deaths,
            soldier_deaths,
            pyro_deaths,
            demoman_deaths,
            heavy_deaths,
            engineer_deaths,
            medic_deaths,
            sniper_deaths,
            spy_deaths,
            scout_damage,
            soldier_damage,
            pyro_damage,
            demoman_damage,
            heavy_damage,
            engineer_damage,
            medic_damage,
            sniper_damage,
            spy_damage,
            play_time)
        (SELECT
             map,
             1,
             red_wins,
             blue_wins,
             red_score,
             blue_score,
             midfight_red,
             midfight_blue,
             scout_kills,
             soldier_kills,
             pyro_kills,
             demoman_kills,
             heavy_kills,
             engineer_kills,
             medic_kills,
             sniper_kills,
             spy_kills,
             scout_deaths,
             soldier_deaths,
             pyro_deaths,
             demoman_deaths,
             heavy_deaths,
             engineer_deaths,
             medic_deaths,
             sniper_deaths,
             spy_deaths,
             scout_damage,
             soldier_damage,
             pyro_damage,
             demoman_damage,
             heavy_damage,
             engineer_damage,
             medic_damage,
             sniper_damage,
             spy_damage,
             length as play_time
        FROM log_map_stats WHERE id = NEW.id AND map != '')
    ON CONFLICT (map) DO
        UPDATE SET count = map_stats.count + 1,
                   red_wins = map_stats.red_wins + EXCLUDED.red_wins,
                   blue_wins = map_stats.blue_wins + EXCLUDED.blue_wins,
                   red_score = map_stats.red_score + EXCLUDED.red_score,
                   blue_score = map_stats.blue_score + EXCLUDED.blue_score,
                   midfight_blue = map_stats.midfight_blue + EXCLUDED.midfight_blue,
                   midfight_red = map_stats.midfight_red + EXCLUDED.midfight_red,
                   scout_kills = map_stats.scout_kills + EXCLUDED.scout_kills,
                   soldier_kills = map_stats.soldier_kills + EXCLUDED.soldier_kills,
                   pyro_kills = map_stats.pyro_kills + EXCLUDED.pyro_kills,
                   demoman_kills = map_stats.demoman_kills + EXCLUDED.demoman_kills,
                   heavy_kills = map_stats.heavy_kills + EXCLUDED.heavy_kills,
                   engineer_kills = map_stats.engineer_kills + EXCLUDED.engineer_kills,
                   medic_kills = map_stats.medic_kills + EXCLUDED.medic_kills,
                   sniper_kills = map_stats.sniper_kills + EXCLUDED.sniper_kills,
                   spy_kills = map_stats.spy_kills + EXCLUDED.spy_kills,
                   scout_deaths = map_stats.scout_deaths + EXCLUDED.scout_deaths,
                   soldier_deaths = map_stats.soldier_deaths + EXCLUDED.soldier_deaths,
                   pyro_deaths = map_stats.pyro_deaths + EXCLUDED.pyro_deaths,
                   demoman_deaths = map_stats.demoman_deaths + EXCLUDED.demoman_deaths,
                   heavy_deaths = map_stats.heavy_deaths + EXCLUDED.heavy_deaths,
                   engineer_deaths = map_stats.engineer_deaths + EXCLUDED.engineer_deaths,
                   medic_deaths = map_stats.medic_deaths + EXCLUDED.medic_deaths,
                   sniper_deaths = map_stats.sniper_deaths + EXCLUDED.sniper_deaths,
                   spy_deaths = map_stats.spy_deaths + EXCLUDED.spy_deaths,
                   scout_damage = map_stats.scout_damage + EXCLUDED.scout_damage,
                   soldier_damage = map_stats.soldier_damage + EXCLUDED.soldier_damage,
                   pyro_damage = map_stats.pyro_damage + EXCLUDED.pyro_damage,
                   demoman_damage = map_stats.demoman_damage + EXCLUDED.demoman_damage,
                   heavy_damage = map_stats.heavy_damage + EXCLUDED.heavy_damage,
                   engineer_damage = map_stats.engineer_damage + EXCLUDED.engineer_damage,
                   medic_damage = map_stats.medic_damage + EXCLUDED.medic_damage,
                   sniper_damage = map_stats.sniper_damage + EXCLUDED.sniper_damage,
                   spy_damage = map_stats.spy_damage + EXCLUDED.spy_damage,
                   play_time = map_stats.play_time + EXCLUDED.play_time;
    RETURN NEW;
END;
$$
    LANGUAGE PLPGSQL;

CREATE TRIGGER update_map_stats_on_log
    AFTER INSERT OR UPDATE ON logs_raw
    FOR EACH ROW
EXECUTE PROCEDURE update_map_stats();