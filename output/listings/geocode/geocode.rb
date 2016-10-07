require 'pg'
require 'geocoder/us'

db = Geocoder::US::Database.new('/home/ubuntu/geocoder/database/geocoder.db')

conn = PG.connect()

geocoded = Array.new

sql = %q(
SELECT
    a.addy_id, 
    house_number || ' ' || street || ', ' || city || ' ' || region || ' ' || postcode as freeform
  FROM sampled_addy a
  LEFT JOIN geocoded c ON c.method = 'geocommons' AND c.addy_id = a.addy_id
  WHERE c.addy_id IS NULL;
)

result = conn.exec(sql)
result.each do |row|
    # puts "%s" % row.values_at('freeform')[0]
    g = db.geocode(row.values_at('freeform')[0])[0]
    if g != nil
      g[:addy_id] = row.values_at('addy_id')[0]
      geocoded << g
    end
end

conn.prepare(
  'insert',
  "INSERT INTO geocoded (addy_id, lat, lon, precision, method) "\
  "VALUES ($1, $2, $3, $4, 'geocommons') ")

geocoded.each do |coded|
  conn.exec_prepared('insert', [coded[:addy_id], coded[:lat], coded[:lon], coded[:score]])
end
conn.close()
