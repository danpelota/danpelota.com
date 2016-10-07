INSERT INTO geocoded
SELECT DISTINCT ON (addy_id)
    addy_id,
    ST_Y((g.geo).geomout)::numeric,
    ST_X((g.geo).geomout)::numeric,
    ST_Transform((g.geo).geomout, 4326),
    (g.geo).rating,
    'postgis-freeform'
FROM (
    SELECT
        a.addy_id,
        geocode(house_number || ' ' || street || ', ' || city || ' ' || region || ' ' || postcode) as geo
    FROM sampled_addy a
        LEFT JOIN geocoded c ON c.method = 'postgis-freeform' AND a.addy_id = c.addy_id
    WHERE c.addy_id IS NULL
    ) g
ORDER BY addy_id, (g.geo).rating;
