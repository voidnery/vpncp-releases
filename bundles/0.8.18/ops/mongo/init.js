// Mongo init: create application user on the target DB.
// Runs only on first container start (when /data/db is empty).
const dbName = process.env.MONGO_INITDB_DATABASE;
const user = process.env.MONGO_INITDB_ROOT_USERNAME;
const pass = process.env.MONGO_INITDB_ROOT_PASSWORD;

if (!dbName || !user || !pass) {
  print('[init] FATAL: required env vars missing');
  quit(1);
}

db = db.getSiblingDB(dbName);
db.createUser({
  user: user,
  pwd: pass,
  roles: [{ role: 'readWrite', db: dbName }]
});
print('[init] Created application user "' + user + '" on db "' + dbName + '"');
