.. title: Geocoder Showdown Part 1: Setup and Installation
.. slug: geocoder-showdown-part-1
.. date: 2016-09-19
.. tags: 
.. category: 
.. link: 
.. description: 
.. hyphenate: yes
.. type: text

.. contents ::

Back in 2011, I `asked a question`_ on gis.stackexchange.com regarding the
accuracy of range-based geocoders that can be installed and run locally. Since
then, I've leveraged several solutions for the bulk geocoding of millions of
addresses, including the `PostGIS geocoder`_ and the ruby-based `Geocommons
Geocoder::US`_. I haven't come across a thorough comparison of the setup, usage,
and performance of these geocoders in the meantime, so I figured I'd evaluate
them here.

.. _asked a question: http://gis.stackexchange.com/questions/7271/geocode-quality-nominatim-vs-postgis-geocoder-vs-geocoderus-2-0)
.. _PostGIS geocoder: http://postgis.net/docs/Geocode.html
.. _Geocommons Geocoder::US: https://github.com/geocommons/geocoder/

In Part 1 I'll cover the installation and configuration of the PostGIS Tiger
geocoder, the Nominatim geocoder, and the Geocommons Geocoder. While there are
web services that expose each through APIs, I wanted to document the setup and
installation of each for offline processing.

In `Part 2`_ I'll download, prepare, and geocode a reference dataset to use as
a benchmark: the Florida extract of the OpenAddresses_ database.

.. _OpenAddresses: http://openaddresses.io
.. _Part 2: link:/posts/geocoder-showdown-part-2

In `Part 3`_ I'll evaluate the accuracy of each geocoder against our reference
data set.

.. _Part 3: link:/posts/geocoder-showdown-part-3

Installing the Geocoders
========================

I'll install and evaluate the geocoders on an ``m4.xlarge`` AWS EC2 instance
with 16GB of memory and a 50GB SSD, running the Ubuntu 16.04 LTS AMI
(``ami-746aba14``).

Installing PostgreSQL 9.5 and PostGIS 2.2
-----------------------------------------

First we'll set the following PostgreSQL environment variables for convenience.

.. code-block:: bash

    export PGDATABASE=geocoder
    export PGUSER=postgres


Install PostgreSQL 9.5 and PostGIS 2.2:

.. code-block:: bash

    sudo apt-get install -y postgresql-9.5 postgresql-9.5-postgis-2.2 \
        postgresql-server-dev-9.5
    export PATH='/usr/lib/postgresql/9.5/bin/':$PATH

The PostgreSQL APT repository doesn't package ``shp2pgsql`` anymore, so install
it from the Ubuntu postgis repository:

.. code-block:: bash

    sudo apt-get install postgis

You'll want to edit the PostgreSQL config file for optimum performance while
bulk-loading data (``/etc/postgresql/9.5/main/postgresql.conf`` on Ubuntu) .
Here's how I tuned my PostgreSQL cluster running on an instance with 16GB of
RAM:

.. code-block:: ini

    shared_buffers = 4GB
    work_mem = 50MB
    maintenance_work_mem = 4GB
    synchronous_commit = off
    checkpoint_timeout = 10min
    checkpoint_completion_target = 0.9
    effective_cache_size = 12GB

I've also set:

.. code-block:: ini

    fsync = off
    full_page_writes = off

Be sure to turn these on after the data has been loaded, or you'll risk not
only data *loss* in the event of a crash, but data *corruption*.

Also, before connecting to our database, you'll need to edit the ``pg_hba.conf``
file to ``trust`` local connections. The default location on Ubuntu is
``/etc/postgresql/9.5/main/pg_hba.conf``

.. code-block:: 

    # "local" is for Unix domain socket connections only
    local   all             all                                     trust
    # IPv4 local connections:
    host    all             all             127.0.0.1/32            trust

Restart Postgres with ``sudo service postgresql restart`` and you should be
able to connect with `psql`:

.. code-block:: bash

    $ psql
    psql (9.5.4)
    Type "help" for help.
    
    geocoder=# 

Configuring the PostGIS Tiger Geocoder
--------------------------------------
Create our PostGIS-enabled database and install the geocoder.

.. code-block:: bash

    createdb
    psql -c "CREATE EXTENSION postgis;"
    psql -c "CREATE EXTENSION fuzzystrmatch;"
    psql -c "CREATE EXTENSION address_standardizer;"
    psql -c "CREATE EXTENSION postgis_tiger_geocoder;"

Now we'll generate and run the scripts that download and process the FL TIGER
data, as well as the national state and county lookup tables needed by the geocoder.

.. code-block:: bash

    sudo apt-get install unzip

    cd ~
    sudo mkdir /gisdata
    sudo chown ubuntu /gisdata
    psql -t -c "SELECT Loader_Generate_Script(ARRAY['FL'], 'sh');" -o import-fl.sh --no-align
    sh import-fl.sh
    # Go for a long walk
    psql -t -c "SELECT loader_generate_nation_script('sh');" -o import-nation.sh --no-align
    sh import-nation.sh

Just for good measure:

.. code-block:: bash

    psql -c "SELECT install_missing_indexes();"
    psql -c "vacuum analyze verbose tiger.addr;"
    psql -c "vacuum analyze verbose tiger.edges;"
    psql -c "vacuum analyze verbose tiger.faces;"
    psql -c "vacuum analyze verbose tiger.featnames;"
    psql -c "vacuum analyze verbose tiger.place;"
    psql -c "vacuum analyze verbose tiger.cousub;"
    psql -c "vacuum analyze verbose tiger.county;"
    psql -c "vacuum analyze verbose tiger.state;"

Check that the geocoder and all necessary data was installed correctly.

.. code-block:: bash

    psql -c "SELECT st_x(geomout), st_y(geomout) FROM geocode('400 S Monroe St, Tallahassee, FL 32399', 1);"

           st_x        |       st_y
    -------------------+------------------
     -84.2807360244119 | 30.4381207774995

With that, our PostGIS TIGER geocoder is installed and ready to go.

The Geocommons Geocoder::US
---------------------------

Install some dependencies:

.. code-block:: bash

    apt-get install -y ruby-dev sqlite3 libsqlite3-dev flex
    gem install text sqlite3 fastercsv

Grab the latest version of the geocommons geocoder and install it:

.. code-block:: bash

    cd ~
    apt-get install git flex ruby-dev
    git clone git://github.com/geocommons/geocoder.git
    cd geocoder
    make
    make install
    gem install Geocoder-US-2.0.4.gem
    gem install text

We can use the 2015 Tiger data we downloaded previously:

.. code-block:: bash

    mkdir data
    mkdir database
    cd data
    cp /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/ADDR/*.zip ./
    cp /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/FEATNAMES/*.zip ./
    cp /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/EDGES/*.zip ./

Create the geocoder database. Note that this must be executed from within the
``build`` directory since it has a relative path reference to
``../src/shp2sqlite/shp2sqlite``:

.. code-block:: bash

    cd ../build
    ./tiger_import ../database/geocoder.db ../data
    sh build_indexes ../database/geocoder.db
    cd ..
    bin/rebuild_metaphones database/geocoder.db
    sudo sh build/rebuild_cluster database/geocoder.db

To test the geocommons geocoder, fire up an irb session and geocode a test
address:

.. code-block:: ruby

    irb(main):001:0> require 'geocoder/us'
    => true

    irb(main):002:0> db = Geocoder::US::Database.new('database/geocoder.db')
    => #<Geocoder::US::Database:0x00000001cc1248 @db=#<SQLite3::Database:0x00000001cc1158>, @st={}, @dbtype=1, @debug=false, @threadsafe=false>

    irb(main):003:0> p db.geocode("400 S Monroe St, Tallahassee, FL 32399")
    [{:street=>"S Monroe St",
      :zip=>"32301",
      :score=>0.805, 
      :prenum=>"", 
      :number=>"400", 
      :precision=>:range, 
      :lon=>-84.280632, 
      :lat=>30.438122}]

Installing Nominatim
--------------------
Install the Nominatim dependencies (some of these were installed in previous
steps but are included here for completeness):

.. code-block:: bash

    sudo apt-get install -y build-essential cmake g++ libboost-dev \
        libboost-system-dev libboost-filesystem-dev libexpat1-dev zlib1g-dev \
        libxml2-dev libbz2-dev libpq-dev libgeos-dev libgeos++-dev \
        libproj-dev postgresql-server-dev-9.5 postgresql-9.5-postgis-2.2 \
        postgresql-contrib-9.5 apache2 php php-pgsql libapache2-mod-php \
        php-pear php-db git

We'll use a separate linux user account for nominatim:

.. code-block:: bash

    sudo useradd -d /srv/nominatim -s /bin/bash -m nominatim

    export USERNAME=nominatim
    export USERHOME=/srv/nominatim
    sudo chmod a+wx $USERHOME

    createuser -s $USERNAME
    createuser -s www-data

Install Nominatim:

.. code-block:: bash

    cd $USERHOME
    git clone --recursive git://github.com/twain47/Nominatim.git
    cd Nominatim

Building must happen within the ``build`` directory:

.. code-block:: bash

    mkdir build
    cd build
    cmake $USERHOME/Nominatim
    make

Setup the apache webserver:

.. code-block:: bash

    sudo tee /etc/apache2/conf-available/nominatim.conf << EOFAPACHECONF
    <Directory "$USERHOME/Nominatim/build/website">
      Options FollowSymLinks MultiViews
      AddType text/html   .php
      Require all granted
    </Directory>

    Alias /nominatim $USERHOME/Nominatim/build/website
    EOFAPACHECONF


Enable the configuration and restart apache:

.. code-block:: bash

    sudo a2enconf nominatim
    sudo systemctl restart apache2

Update the nominatim php settings (``settings/settings.php``) to reflect our
version of PostgreSQL, PostGIS, and our local website URL:

.. code-block:: php

    // Software versions
    @define('CONST_Database_DSN', 'pgsql://postgres@localhost/nominatim');

    // Website settings
    @define('CONST_Website_BaseURL', '/nominatim/');

Now that Nominatim is installed and configured, we need to download and process
the Florida extract of the OpenStreetMap data.

.. code-block:: bash

    wget -P /gisdata/ http://download.geofabrik.de/north-america/us/florida-latest.osm.pbf
    ./utils/setup.php --osm-file /gisdata/florida-latest.osm.pbf --all

At this point, you should be able to point your browser to
``http://localhost/nominatim/status.php`` and get a page with the text "OK".

Nominatim can use TIGER address data to supplement the OSM house number data.
Luckily, we already have the TIGER EDGE data downloaded. We'll need to convert
the data to SQL to use it:

.. code-block:: bash

    sudo apt-get install python-gdal
    sudo apt-get install gdal-bin

    ./utils/imports.php --parse-tiger /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/EDGES/

Then we'll load it:

.. code-block:: bash

    ./utils/setup.php --import-tiger-data

Enable the use of Tiger data in the settings/local.php file...

.. code-block:: php

    @define('CONST_Use_US_Tiger_Data', true);

...and then run the setup script:

.. code-block:: bash

    ./utils/setup.php --create-functions --enable-diff-updates --create-partition-functions

Again, let's geocode a test address to confirm everything is configured correctly.

.. code-block:: bash

    curl "http://127.0.0.1/nominatim/search.php?q=400%20S%20Monroe%20St%2C%20Tallahassee%2C%20FL%2032399&format=json"

    [{"place_id":"1828601",
      "licence":"Data © OpenStreetMap contributors, ODbL 1.0. http:\/\/www.openstreetmap.org\/copyright",
      "osm_type":"tiger",
      "osm_id":"1828601",
      "boundingbox":["30.437948","30.438048","-84.280774","-84.280674"],
      "lat":"30.437998",
      "lon":"-84.280724",
      "display_name":"400, South Monroe Street, Tallahassee, Leon County, Florida, 32301, United States of America",
      "class":"place",
      "type":"house",
      "importance":0.511}]

At this point, all three geocoders are functional and loaded with 2015 range
data. In `Part 2`_ we'll load and geocode some benchmark data.

.. Part 2: link:/posts/geocoder-showdown-part-2
