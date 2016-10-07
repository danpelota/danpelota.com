import requests
import psycopg2 as pg
from pprint import pprint

con = pg.connect(dbname='geocoder')
cur = con.cursor()

url = 'http://localhost/nominatim/search.php'
sql = '''
SELECT
    a.addy_id, 
    house_number || ' ' || street || ', ' || city || ' ' || region || ' ' || postcode as freeform
  FROM sampled_addy a
  LEFT JOIN geocoded c ON c.method = 'nominatim' AND c.addy_id = a.addy_id
  WHERE c.addy_id IS NULL;
'''

geocoded = []

cur.execute(sql)
for result in cur:
    g = requests.get(url, params={'q': result[1], 'format': 'json'}).json()
    if len(g) > 0:
        coded = g[0]
        coded['addy_id'] = result[0]
        geocoded.append(coded)
    else:
        pass

cur.executemany("INSERT INTO geocoded(addy_id, lat, lon, method) VALUES(%(addy_id)s, %(lat)s, %(lon)s, 'nominatim')", geocoded)
con.commit()
con.close()
