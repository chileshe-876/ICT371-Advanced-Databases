
-- (a) Database and seed data 
CREATE TABLE customers (
  customer_id SERIAL PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
  reading_id SERIAL PRIMARY KEY,
  customer_id INT NOT NULL REFERENCES customers(customer_id),
  reading_month DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
  bill_id SERIAL PRIMARY KEY,
  reading_id INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on DATE NOT NULL,
  CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES
('Mary Tembo'), ('Peter Kunda'), ('Ruth Musonda');


-- (b) Function 
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Invalid consumption: %', p_units;
  END IF;
  IF p_units <= 10 THEN
    RETURN ROUND(p_units * 5, 2);
  END IF;
  RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END $$;

SELECT fn_water_charge(0), fn_water_charge(10), fn_water_charge(12);
-- 0.00, 50.00, 66.00

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC; v_charge NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN
    RAISE EXCEPTION 'due date must not be NULL';
  END IF;
  SELECT previous_reading, current_reading INTO v_prev, v_curr
  FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown reading: %', p_reading_id;
  END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;
  v_charge := fn_water_charge(v_curr - v_prev);
  INSERT INTO bills (reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, v_charge, 0, p_due_on);
END $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_check_reading() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
      NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_check_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_fn_check_reading();


-- (a) continued - seed data that needs the code above

INSERT INTO readings
  (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, DATE '2026-09-01', 100, 100),   --  0 units
(1, DATE '2026-10-01', 100, 110),   -- exactly 10 units
(2, DATE '2026-09-01',  50,  62),   -- 12 units
(2, DATE '2026-10-01',  62,  75),   -- 13 units
(3, DATE '2026-09-01', 200, 205),   --  5 units
(3, DATE '2026-10-01', 205, 230);   -- 25 units

-- run after pr_generate_bill (c) exists: one bill per reading
CALL pr_generate_bill(1, DATE '2026-10-10');
CALL pr_generate_bill(2, DATE '2026-11-10');
CALL pr_generate_bill(3, DATE '2026-10-10');
CALL pr_generate_bill(4, DATE '2026-12-10');
CALL pr_generate_bill(5, DATE '2026-10-10');
CALL pr_generate_bill(6, DATE '2026-12-10');

-- (e) View [5 marks]

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT b.bill_id, c.full_name AS customer_name, b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- record some payments, then query the view
UPDATE bills SET amount_paid = 30 WHERE reading_id = 3;       -- part paid
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;   -- fully paid
SELECT * FROM v_overdue_bills;

-- (f) Index 
CREATE INDEX idx_bills_unpaid_due
  ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN
SELECT * FROM bills
WHERE amount_paid < charge AND due_on < CURRENT_DATE;

-- (g) Scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot (snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
  FROM bills
  WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE
  SET total_due = EXCLUDED.total_due;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_receivables', '30 0 * * *',
  $$CALL pr_refresh_receivables()$$);

CALL pr_refresh_receivables();  -- test
CALL pr_refresh_receivables();  -- rerun: still one row
SELECT * FROM receivable_snapshot;
