-- ICT371 Advanced Database - Question 2: University Fee Payments
-- Bwalya Marvelous (202406501), Mulungushi University
-- PostgreSQL. Run the whole file in order: psql -d yourdb -f answer.sql
-- Scheduled jobs need the pg_cron extension.

-- ======================================================================
-- (a) Database and seed data [6 marks] - tables and seed data
-- ======================================================================
CREATE TABLE students (
  student_id SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL,
  fee_due NUMERIC(10,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount NUMERIC(10,2) NOT NULL CHECK (amount > 0),
  paid_on DATE NOT NULL DEFAULT CURRENT_DATE
);
CREATE TABLE payment_audit (
  audit_id SERIAL PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount NUMERIC(10,2) NOT NULL,
  logged_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count INT NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
('202406501', 'Student One',   5000.00),
('202406502', 'Student Two',   4200.00),
('202406503', 'Student Three', 3000.00);  -- no payments yet

-- ======================================================================
-- (b) Function [6 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_fee NUMERIC; v_paid NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid
  FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;
END $$;

-- ======================================================================
-- (c) Procedure [8 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid amount: %', p_amount;
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- ======================================================================
-- (d) Trigger [8 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION trg_fn_payment_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- ======================================================================
-- (a) continued - seed data that needs the code above
-- ======================================================================
-- run after parts (b), (c), (d) exist
CALL pr_receive_payment(1, 1000, DATE '2026-11-22');
CALL pr_receive_payment(1, 1500, DATE '2026-11-23');
CALL pr_receive_payment(1,  500, DATE '2026-11-23');
CALL pr_receive_payment(2, 1200, DATE '2026-11-22');
CALL pr_receive_payment(2,  800, DATE '2026-11-23');
CALL pr_receive_payment(2, 1000, DATE '2026-11-23');

-- ======================================================================
-- (e) View [5 marks]
-- ======================================================================
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;

-- ======================================================================
-- (f) Index [5 marks]
-- ======================================================================
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN
SELECT * FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- ======================================================================
-- (g) Scheduled job [6 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
  SET payment_count = EXCLUDED.payment_count,
      total_amount  = EXCLUDED.total_amount;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_collections', '0 1 * * *',
  $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);

CALL pr_refresh_collections(DATE '2026-11-23');  -- test
CALL pr_refresh_collections(DATE '2026-11-23');  -- rerun: still one row
SELECT * FROM daily_collections;
