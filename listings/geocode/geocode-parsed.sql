INSERT INTO tiger_geocoded
SELECT DISTINCT ON (addy_id)
    addy_id,
    ST_Y((g.geo).geomout)::numeric,
    ST_X((g.geo).geomout)::numeric,
    ST_Transform((g.geo).geomout, 4326),
    (g.geo).rating,
    'postgis-parsed'
FROM (
    SELECT
        addy_id,
        geocode(
        (
            (norm).address,
            (norm).predirabbrev,
            (norm).streetname,
            (norm).streettypeabbrev,
            (norm).postdirabbrev,
            (norm).internal,
            city,
            'FL',
            substr(postcode, 1, 5),
            true
        )::norm_addy) as geo
    FROM (
        SELECT
            a.*,
            normalize_address(house_number || ' ' ||
            street || ', ' ||
            city || ' ' ||
            region || ' ' || postcode) as norm
        FROM sampled_addy a
            LEFT JOIN geocoded c ON c.method = 'postgis-parsed' AND a.addy_id = c.addy_id
        WHERE c.addy_id IS NULL
    ) n
) g
ORDER BY addy_id, (g.geo).rating;
