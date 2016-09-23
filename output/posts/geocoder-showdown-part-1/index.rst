.. title: Geocoder Showdown Part 1: Setup and Installation
.. slug: geocoder-showdown-part-1
.. date: 2016-09-19 22:27:08 UTC-04:00
.. tags: 
.. category: 
.. link: 
.. description: 
.. type: text

Back in 2011, I `asked a question`_ on gis.stackexchange.com regarding the
accuracy of range-based geocoders that can be installed and run locally. Since
then, I've leveraged several solutions for bulk geocoding, including the
`PostGIS geocoder`_, the ruby-based `Geocommons Geocoder`_,  and SmartyStreets_
(which doesn't run locally, but has no trouble geocoding millions of addresses
per hour). However, I haven't come across a thorough comparison of the setup,
usage, and performance of these geocoders, so I figured I'd evaluate them here.

.. _asked a question: http://gis.stackexchange.com/questions/7271/geocode-quality-nominatim-vs-postgis-geocoder-vs-geocoderus-2-0)
.. _PostGIS geocoder: http://postgis.net/docs/Geocode.html
.. _Geocommons Geocoder: https://github.com/geocommons/geocoder/
.. _SmartyStreets: https://smartystreets.com/


In Part 1, I'll cover the installation and configuration of the PostGIS Tiger
geocoder, the Nominatim geocoder, and the Geocommons Geocoder. While there are
web services that expose each through APIs, I wanted to document the setup and
installation of each.

In Part 2, I'll evaluate each against a test dataset: the Florida extract of the
openaddresses.io_ database. I'll also evaluate SmartyStreets, which offers
CASS-certified address standardization and validation through a web API.

.. _openaddresses.io: http://openaddresses.io

I'll install and evaluate the geocoders on an ``m4.xlarge`` AWS EC2 instance
with 16GB of memory and a 50GB SSD, running the Ubuntu 16.04 LTS AMI
(``ami-746aba14``).

Installing the Geocoders
========================

PostgreSQL 9.5, PostGIS 2.2, and the TIGER geocoder
---------------------------------------------------

First, we'll set the following PostgreSQL environment variables for convenience::

    export PGDATABASE=geocoder
    export PGUSER=postgres


Next, add the PostgreSQL apt repo and key::

    sudo add-apt-repository \
        "deb http://apt.postgresql.org/pub/repos/apt/ xenial-pgdg main"
    wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
        sudo apt-key add -
    sudo apt-get update

Install PostgreSQL 9.5 and PostGIS 2.2::

    sudo apt-get install -y postgresql-9.5 postgresql-9.5-postgis-2.2 \
        postgresql-server-dev-9.5
    export PATH='/usr/lib/postgresql/9.5/bin/':$PATH

The PostgreSQL APT repository doesn't package ``shp2pgsql`` anymore, so install
it from the Ubuntu postgis repository::

    sudo apt-get install postgis

You'll want to edit the PostgreSQL config file
for optimum performance in bulk-loading data
(``/etc/postgresql/9.5/main/postgresql.conf`` on Ubuntu) . Here's how I tuned
my PostgreSQL cluster running on an instance with 16GB of RAM::

    shared_buffers = 4GB
    work_mem = 50MB
    maintenance_work_mem = 4GB
    synchronous_commit = off``
    checkpoint_timeout = 10min
    checkpoint_completion_target = 0.9
    effective_cache_size = 12GB

I've also set::

    fsync = off
    full_page_writes = off

Be sure to turn these on after the data has been loaded, or you'll risk not
only data *loss* in the event of a crash, but data *corruption*.

Also, before connecting to our database, you'll need to edit the ``pg_hba.conf``
file to ``trust`` local connections.

Create our PostGIS-enabled database and install the geocoder::

    createdb
    psql -c "CREATE EXTENSION postgis;"
    psql -c "CREATE EXTENSION fuzzystrmatch;"
    psql -c "CREATE EXTENSION address_standardizer;"
    psql -c "CREATE EXTENSION postgis_tiger_geocoder;"

Now we'll generate and run the scripts that download and process the FL TIGER
data, as well as the national state and county lookup tables needed by the geocoder.

::

    sudo apt-get install unzip

    cd ~
    sudo mkdir /gisdata
    sudo chown ubuntu /gisdata
    psql -t -c "SELECT Loader_Generate_Script(ARRAY['FL'], 'sh');" -o import-fl.sh --no-align
    sh import-fl.sh
    # Go for a long walk
    psql -t -c "SELECT loader_generate_nation_script('sh');" -o import-nation.sh --no-align
    sh import-nation.sh

Just for good measure::

    psql -c "SELECT install_missing_indexes();"
    psql -c "vacuum analyze verbose tiger.addr;"
    psql -c "vacuum analyze verbose tiger.edges;"
    psql -c "vacuum analyze verbose tiger.faces;"
    psql -c "vacuum analyze verbose tiger.featnames;"
    psql -c "vacuum analyze verbose tiger.place;"
    psql -c "vacuum analyze verbose tiger.cousub;"
    psql -c "vacuum analyze verbose tiger.county;"
    psql -c "vacuum analyze verbose tiger.state;"

Check that the geocoder and all necessary data was installed correctly::

    psql -c "SELECT st_x(geomout), st_y(geomout) FROM geocode('400 S Monroe St, Tallahassee, FL 32399', 1);"

           st_x        |       st_y
    -------------------+------------------
     -84.2807360244119 | 30.4381207774995

With that, our PostGIS TIGER geocoder is installed and ready to go.

The Geocommons Geocoder
-----------------------

Install some dependencies::

    apt-get install -y ruby-dev sqlite3 libsqlite3-dev flex
    gem install text sqlite3 fastercsv

Grab the latest version of the geocommons geocoder and install it::

    cd ~
    apt-get install git flex ruby-dev
    git clone git://github.com/geocommons/geocoder.git
    cd geocoder
    make
    make install
    gem install Geocoder-US-2.0.4.gem
    gem install text

We can use the 2015 Tiger data we downloaded previously::

    mkdir data
    mkdir database
    cd data
    cp /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/ADDR/*.zip ./
    cp /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/FEATNAMES/*.zip ./
    cp /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/EDGES/*.zip ./

Create the geocoder database. Note that this must be executed from within the
``build`` directory since it has a relative path reference to
``../src/shp2sqlite/shp2sqlite``::

    cd ../build
    ./tiger_import ../database/geocoder.db ../data
    sh build_indexes ../database/geocoder.db
    cd ..
    bin/rebuild_metaphones database/geocoder.db
    sudo sh build/rebuild_cluster database/geocoder.db

To test the geocommons geocoder, fire up an irb session and geocode a test
address::

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
steps, but are included here for completeness)::

    sudo apt-get install -y build-essential cmake g++ libboost-dev \
        libboost-system-dev libboost-filesystem-dev libexpat1-dev zlib1g-dev \
        libxml2-dev libbz2-dev libpq-dev libgeos-dev libgeos++-dev \
        libproj-dev postgresql-server-dev-9.5 postgresql-9.5-postgis-2.2 \
        postgresql-contrib-9.5 apache2 php php-pgsql libapache2-mod-php \
        php-pear php-db git

Separate linux user accounts for nominatim::

    sudo useradd -d /srv/nominatim -s /bin/bash -m nominatim

    export USERNAME=nominatim
    export USERHOME=/srv/nominatim
    sudo chmod a+wx $USERHOME

    createuser -s $USERNAME
    createuser -s www-data

Install Nominatim::

    cd $USERHOME
    git clone --recursive git://github.com/twain47/Nominatim.git
    cd Nominatim

Building must happen within the ``build`` directory::

    mkdir build
    cd build
    cmake $USERHOME/Nominatim
    make

Setup the apache webserver::

    sudo tee /etc/apache2/conf-available/nominatim.conf << EOFAPACHECONF
    <Directory "$USERHOME/Nominatim/build/website">
      Options FollowSymLinks MultiViews
      AddType text/html   .php
      Require all granted
    </Directory>

    Alias /nominatim $USERHOME/Nominatim/build/website
    EOFAPACHECONF


Enable the configuration and restart apache::

    sudo a2enconf nominatim
    sudo systemctl restart apache2

Update the nominatim php settings (``settings/settings.php``) to reflect our
version of PostgreSQL, PostGIS, and our local website URL::

    // Software versions
    @define('CONST_Database_DSN', 'pgsql://postgres@localhost/nominatim');

    // Website settings
    @define('CONST_Website_BaseURL', '/nominatim/');

Download OSM data::

    wget -P /gisdata/ http://download.geofabrik.de/north-america/us/florida-latest.osm.pbf
    ./utils/setup.php --osm-file /gisdata/florida-latest.osm.pbf --all

At this point, you should be able to point your browser to
``http://localhost/nominatim/status.php`` and get a page with the text "OK".

Nominatim can use TIGER address data to supplement the OSM house number data.
Luckily, we already have the TIGER EDGE data downloaded. First, we'll need to
convert the data to SQL::

    sudo apt-get install python-gdal
    sudo apt-get install gdal-bin

    ./utils/imports.php --parse-tiger /gisdata/ftp2.census.gov/geo/tiger/TIGER2015/EDGES/

Then we'll load it::

    ./utils/setup.php --import-tiger-data

Enable the use of Tiger data in the settings/local.php file::

    @define('CONST_Use_US_Tiger_Data', true);
    ./utils/setup.php --create-functions --enable-diff-updates --create-partition-functions

At this point, all three geocoders are functional and loaded with 2015 range
data. In Part 2 we'll cover the geocoding process for each.
