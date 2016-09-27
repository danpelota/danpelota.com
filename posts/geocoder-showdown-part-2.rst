.. title: Geocoder Showdown Part 2: Geocoding Benchmark Data
.. slug: geocoder-showdown-part-2
.. date: 2016-09-23 19:53:44 UTC-04:00
.. tags: draft
.. category: 
.. link: 
.. description: 
.. type: text

.. contents ::

In `Part 1`_ I covered the installation and configuration of the PostGIS, Open
Addresses, and Nominatim geocoders. In this article we'll download and geocode
some reference data for evaluation.

.. _Part 1: link:/posts/geocoder-showdown-part-1

OpenAddresses Data
------------------

OpenAddresses.io is an effort to aggregate and standardize a global collection
of address data. We'll be using the Florida extract of the OpenAddresses.io
data. Download it to get started::

    wget http://s3.amazonaws.com/data.openaddresses.io/openaddr-collected-us_south.zip
    unzip openaddr-collected-us_south.zip
    cd us/fl

Create our table to hold the data::

    psql << EOF
    CREATE TABLE addresses (
        lon float,
        lat float,
        house_number text,
        street text,
        unit text,
        city text,
        district text,
        region text,
        postcode text,
        id text,
        hash text);
    EOF

Now copy in all CSV files. There is some overlapping coverage, but we'll deal
with that later::

    for FILE in *.csv
    do
        echo "Loading $FILE"
        psql -c "\copy addresses FROM $FILE CSV HEADER"
    done

Pop open ``psql`` and let's take a look!

::

    SELECT count(*) FROM addresses;
      count
    ----------
     20558789

20 million addresses, ripe for geocoding! However, the OpenAddresses data is
based on aggregated data from public sources, which often incomplete. Let's
check the coverage of the address fields::

    SELECT
       count(*) AS total,
       count(house_number) AS h_number,
       count(street) AS street,
       count(city) AS city,
       count(postcode) AS postcode,
       count(COALESCE(city, postcode)) AS city_or_post,
       count(house_number || street || city || postcode) AS all
    FROM
       addresses;

    -[ RECORD 1 ]+---------
    total        | 20558789
    h_number     | 18432928
    street       | 20538609
    city         | 17411392
    postcode     | 10488002
    city_or_post | 20223850
    all          |  7610472

It looks like only half of all addresses have a zip code, 17.4 million
have a city, and 7.6 million have all address components. Instead of
dropping those without all address components, we'll classify each address
based on the availability of the address components to see how the
geocoders stand up to missing data::

    ALTER TABLE addresses ADD COLUMN components TEXT;

    -- Consider "unincorporated" to be a missing city component
    UPDATE addresses SET city = NULL WHERE city = 'Unincorporated';

    UPDATE ADDRESSES
    SET components =
        CASE
            -- We won't even try to geocode these
            WHEN house_number || street IS NULL THEN 'bad'
            WHEN city || postcode IS NOT NULL THEN 'all'
            WHEN city IS NOT NULL then 'city only'
            WHEN postcode IS NOT NULL THEN 'postcode only'
            ELSE 'street only'
        END;

    SELECT components, COUNT(*) FROM addresses GROUP BY 1;

      components   |  count
    ---------------+---------
     bad           | 2131815
     all           | 7019191
     postcode only | 3390495
     street only   |  327029
     city only     | 7690259

Let's create a stratified random sample of these addresses:

    * 35,000 (70%) with all address components
    * 7,500 (15%) with postcode only
    * 7,500 (15%) with city only

::

    SELECT setseed(0.5);
    CREATE TABLE sampled_addy AS
    (
        SELECT *
        FROM addresses
        WHERE components = 'all'
        ORDER BY random()
        LIMIT 35000
    )
    UNION ALL
    (
        SELECT *
        FROM addresses
        WHERE components = 'postcode only'
        ORDER BY random()
        LIMIT 7500
    )
    UNION ALL
    (
        SELECT *
        FROM addresses
        WHERE components = 'city only'
        ORDER BY random()
        LIMIT 7500
    );

    ALTER TABLE sampled_addy ADD COLUMN addy_id SERIAL PRIMARY KEY;

Now that we have a more manageable test set, let's do a little additional
hygiene::

    UPDATE sampled_addy
    SET
        street = upper(street),
        unit = upper(unit),
        -- I noticed some city names have embedded hyphens/underscores
        city = upper(regexp_replace(city, '_|-', ' ', 'g')),
        -- Should only be Florida
        region = 'FL';

Let's create a geospatial point column representing the coordinates::

    ALTER TABLE sampled_addy ADD COLUMN geom GEOMETRY('POINT', 4326);

    UPDATE sampled_addy
    SET geom = ST_SetSrid(ST_MakePoint(lon, lat), 4326);

    CREATE INDEX ON sampled_addy USING gist(geom);


Geocoding: PostGIS Tiger Geocoder
---------------------------------

::

    CREATE TABLE tiger_geocoded (
        addy_id integer,
        lat float,
        lon float,
        geom geometry('POINT', 4326),
        precision float,
        method text);

    INSERT INTO tiger_geocoded
    SELECT
        addy_id,
        ST_Y((g.geo).geomout)::numeric,
        ST_X((g.geo).geomout)::numeric,
        ST_Transform((g.geo).geomout, 4326),
        (g.geo).rating,
        'postgis'
    FROM (
        SELECT
            addy_id,
            geocode((house_number || ' ' ||
                     street || ' ' ||
                     city || ' ' ||
                     region || ' ' || postcode),
                    1) as geo
        FROM new_samp
        ) g;
