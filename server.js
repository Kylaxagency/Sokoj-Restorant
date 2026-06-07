const express    = require('express');
const Database   = require('better-sqlite3');
const cors       = require('cors');
const path       = require('path');
const crypto     = require('crypto');

const app  = express();
const PORT = process.env.PORT || 3001;
const ADMIN_PASS = process.env.ADMIN_PASS || 'sokoj-admin-2024';

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname)));

/* ── DATABASE ── */
const db = new Database(path.join(__dirname, 'reservations.db'));

db.exec(`
  CREATE TABLE IF NOT EXISTS reservations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    first_name  TEXT    NOT NULL,
    last_name   TEXT    NOT NULL,
    email       TEXT    NOT NULL,
    phone       TEXT    NOT NULL,
    date        TEXT    NOT NULL,
    time        TEXT    NOT NULL,
    guests      INTEGER NOT NULL,
    table_id    TEXT    NOT NULL,
    table_area  TEXT    NOT NULL,
    notes       TEXT,
    status      TEXT    DEFAULT 'pending',
    created_at  TEXT    DEFAULT (datetime('now'))
  );
`);

/* ── HELPERS ── */
function adminAuth(req, res, next) {
  const token = req.headers['x-admin-token'];
  if (token !== ADMIN_PASS) return res.status(401).json({ error: 'Unauthorized' });
  next();
}

/* ══════════════════════════════════════════
   PUBLIC API
══════════════════════════════════════════ */

/* GET /api/available-tables?date=YYYY-MM-DD&time=HH:MM */
app.get('/api/available-tables', (req, res) => {
  const { date, time } = req.query;
  if (!date || !time) return res.status(400).json({ error: 'date and time required' });

  const booked = db.prepare(
    `SELECT table_id FROM reservations
     WHERE date = ? AND time = ? AND status != 'cancelled'`
  ).all(date, time).map(r => r.table_id);

  res.json({ booked });
});

/* POST /api/reservations */
app.post('/api/reservations', (req, res) => {
  const { first_name, last_name, email, phone, date, time, guests, table_id, table_area, notes } = req.body;

  if (!first_name || !last_name || !email || !phone || !date || !time || !guests || !table_id) {
    return res.status(400).json({ error: 'Missing required fields' });
  }

  // Check table not already booked
  const conflict = db.prepare(
    `SELECT id FROM reservations WHERE date=? AND time=? AND table_id=? AND status!='cancelled'`
  ).get(date, time, table_id);

  if (conflict) return res.status(409).json({ error: 'Table already booked for this slot' });

  const stmt = db.prepare(
    `INSERT INTO reservations (first_name, last_name, email, phone, date, time, guests, table_id, table_area, notes)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
  );
  const info = stmt.run(first_name, last_name, email, phone, date, time, guests, table_id, table_area || '', notes || '');

  res.json({ id: info.lastInsertRowid, message: 'Reservation created' });
});

/* ══════════════════════════════════════════
   ADMIN API  (requires x-admin-token header)
══════════════════════════════════════════ */

/* POST /api/admin/login */
app.post('/api/admin/login', (req, res) => {
  const { password } = req.body;
  if (password === ADMIN_PASS) {
    res.json({ token: ADMIN_PASS });
  } else {
    res.status(401).json({ error: 'Wrong password' });
  }
});

/* GET /api/admin/reservations */
app.get('/api/admin/reservations', adminAuth, (req, res) => {
  const { date, status } = req.query;
  let sql = 'SELECT * FROM reservations WHERE 1=1';
  const params = [];
  if (date)   { sql += ' AND date = ?';   params.push(date); }
  if (status) { sql += ' AND status = ?'; params.push(status); }
  sql += ' ORDER BY date DESC, time ASC';
  res.json(db.prepare(sql).all(...params));
});

/* PATCH /api/admin/reservations/:id/status */
app.patch('/api/admin/reservations/:id/status', adminAuth, (req, res) => {
  const { status } = req.body;
  const allowed = ['pending', 'confirmed', 'cancelled', 'completed'];
  if (!allowed.includes(status)) return res.status(400).json({ error: 'Invalid status' });

  db.prepare('UPDATE reservations SET status=? WHERE id=?').run(status, req.params.id);
  res.json({ message: 'Updated' });
});

/* DELETE /api/admin/reservations/:id */
app.delete('/api/admin/reservations/:id', adminAuth, (req, res) => {
  db.prepare('DELETE FROM reservations WHERE id=?').run(req.params.id);
  res.json({ message: 'Deleted' });
});

/* GET /api/admin/stats */
app.get('/api/admin/stats', adminAuth, (req, res) => {
  const today = new Date().toISOString().split('T')[0];
  res.json({
    total:     db.prepare('SELECT COUNT(*) as n FROM reservations').get().n,
    pending:   db.prepare("SELECT COUNT(*) as n FROM reservations WHERE status='pending'").get().n,
    confirmed: db.prepare("SELECT COUNT(*) as n FROM reservations WHERE status='confirmed'").get().n,
    today:     db.prepare('SELECT COUNT(*) as n FROM reservations WHERE date=?').get(today).n,
  });
});

app.listen(PORT, () => console.log(`Sokoj server running on http://localhost:${PORT}`));
