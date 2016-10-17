.. title: Geocoder Showdown Part 2: Geocoding Benchmark Data
.. slug: geocoder-showdown-part-2
.. date: 2016-09-23 19:53:44 UTC-04:00
.. tags:
.. category: 
.. link: 
.. description: 
.. type: text

.. contents ::

In `Part 1`_ I covered the installation and configuration of the PostGIS, Open
Addresses, and Nominatim geocoders. In this article we'll download and geocode
some reference data for evaluation. In `Part 3`_ I'll compare the results.

.. _Part 1: link:/posts/geocoder-showdown-part-1
.. _Part 3: link:/posts/geocoder-showdown-part-3

First, we'll download, load, and postprocess the OpenAddresses data we're using
as a reference. Then, we'll pull out a sample of 50,000 records and geocode
them with each of our geocoders.

OpenAddresses Data
------------------

OpenAddresses is an effort to aggregate and standardize a global collection
of address data. We'll be using the Florida extract of the OpenAddresses
data as our benchmark. Download it to get started.

.. code-block:: bash

    wget http://s3.amazonaws.com/data.openaddresses.io/openaddr-collected-us_south.zip
    unzip openaddr-collected-us_south.zip
    cd us/fl

Create our table to hold the data:

.. code-block:: bash

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

Now load all the CSV files. There is some overlapping coverage in these files
but we'll deal with that later.

.. code-block:: bash

    for FILE in *.csv
    do
        echo "Loading $FILE"
        psql -c "\copy addresses FROM $FILE CSV HEADER"
    done

Pop open ``psql`` and let's take a look!

.. code-block:: sql

    SELECT count(*) FROM addresses;
      count
    ----------
     20558789

20 million addresses, ripe for geocoding! Unfortunately, the OpenAddresses data
is based on aggregated data from public sources which is sometimes incomplete. Let's
check the coverage of the address fields.

.. code-block:: sql

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

It looks like only half (10 million) of all addresses have a zip code, 17.4
million have a city, and 7.6 million have all address components. Instead of
dropping those without all address components, we'll classify each address
based on the completeness of the components to see how the geocoders stand up
to missing data.

.. code-block:: sql

    ALTER TABLE addresses ADD COLUMN components TEXT;

    -- Consider "unincorporated" to be a missing city component
    UPDATE addresses SET city = NULL WHERE city = 'Unincorporated';

    UPDATE addresses
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
    * 7,500 (15%) with street + postcode only
    * 7,500 (15%) with street + city only

.. code-block:: sql

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
hygiene:

.. code-block:: sql

    UPDATE sampled_addy
    SET
        street = upper(street),
        unit = COALESCE(upper(unit), ''),
        -- I noticed some city names have embedded hyphens/underscores
        city = COALESCE(upper(regexp_replace(city, '_|-', ' ', 'g')), ''),
        -- Should only be Florida
        region = 'FL',
        postcode = COALESCE(substr(postcode, 1, 5), '');

Let's create a geospatial point column representing the coordinates.

.. code-block:: sql

    ALTER TABLE sampled_addy ADD COLUMN geom GEOMETRY('POINT', 4326);

    UPDATE sampled_addy
    SET geom = ST_SetSrid(ST_MakePoint(lon, lat), 4326);

    CREATE INDEX ON sampled_addy USING gist(geom);


Geocoding: PostGIS Tiger Geocoder
---------------------------------

We'll create a table to hold the results from each geocoder. First, the Tiger geocoder.

.. code-block:: sql

    CREATE TABLE geocoded (
        addy_id integer,
        lat float,
        lon float,
        geom geometry('POINT', 4326),
        precision float,
        method text,
        UNIQUE(addy_id, method));


We have a few options on the granularity of the address components we submit.
One option is to concatenate all address components into a single freeform
string and let the geocoder's address parser handle it. However, since we
already have some address components broken out, we can also try specifying the
city, state, and zip code components individually. The street number and name
components still need to be parsed since the unit numbers are often embedded in
the ``street`` field and predirections are not broken out. We'll try both.

First we'll use the freeform addresses. The ``geocode`` function will accept a
freeform address string, parse the address into the geocoder's ``norm_addy``
type, and return the normalized address, the geocoded geometry, and a rating
representing the estimated quality of the geocode.

.. listing:: geocode/geocode-freeform.sql sql

Let's try one more time, manually setting the city, state, and zipcode where
available. We'll still need the geocoder to parse the address so we can extract
the street number, predirection, street name, postdirection, and unit number.

.. listing:: geocode/geocode-parsed.sql sql

Geocoding: The Geocommons Geocoder::US
--------------------------------------

Here's a quick ruby script to geocode our benchmark data with the Geocommons
geocoder (note that I've made no effort to make this efficient):

.. listing:: geocode/geocode-geocommons.rb ruby

Geocoding: Nominatim
--------------------

And finally, a python script to pull the freeform addresses from the database,
throw them at our Nominatim endpoint, and insert the results into our
``geocoded`` table:

.. listing:: geocode/geocode-nominatim.py python

In `Part 3`_ we'll analyze the results.

