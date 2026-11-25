-- ICT371 Advanced Database - Question 9: Farmer Cooperative Maize Deliveries
-- Bwalya Marvelous (202406501), Mulungushi University
-- PostgreSQL. Run the whole file in order: psql -d yourdb -f answer.sql
-- Scheduled jobs need the pg_cron extension.

-- ======================================================================
-- (a) Database and seed data [6 marks] - tables and seed data
-- ======================================================================
CREATE TABLE farmers (
  farmer_id SERIAL PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id SERIAL PRIMARY KEY,
  farmer_id INT NOT NULL REFERENCES farmers(farmer_id),
  grade VARCHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
  weight_kg NUMERIC(10,2) NOT NULL,
  unit_rate NUMERIC(10,2) NOT NULL,   -- filled in by the trigger
  total_value NUMERIC(12,2) NOT NULL, -- filled in by the trigger
  delivered_on DATE NOT NULL,
  is_paid BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight NUMERIC(14,2) NOT NULL,
  total_value NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
('F001', 'Joseph Mwale'), ('F002', 'Esther Zimba'), ('F003', 'Lazarus Phiri');

-- ======================================================================
-- (b) Function [6 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade must not be NULL';
  ELSIF p_grade = 'A' THEN
    RETURN 5;
  ELSIF p_grade = 'B' THEN
    RETURN 4;
  ELSIF p_grade = 'C' THEN
    RETURN 3;
  END IF;
  RAISE EXCEPTION 'Unsupported grade: %', p_grade;
END $$;

-- ======================================================================
-- (c) Procedure [8 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
  p_farmer_id INT, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
    RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
  END IF;
  PERFORM fn_maize_rate(p_grade);          -- rejects NULL or unsupported grade
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive: %', p_weight;
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date must not be NULL';
  END IF;
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- ======================================================================
-- (d) Trigger [8 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION trg_fn_price_delivery() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive: %', NEW.weight_kg;
  END IF;
  NEW.unit_rate := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_price_delivery
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_fn_price_delivery();

-- test through the procedure (run after (c) and this trigger exist)
CALL pr_receive_delivery(1, 'C', 40, DATE '2026-11-24');

-- ======================================================================
-- (a) continued - seed data that needs the code above
-- ======================================================================
-- run after the trigger (d) is installed; rate and value come from the trigger
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
(1, 'A', 100,    DATE '2026-11-20', FALSE),
(1, 'B',  80,    DATE '2026-11-21', TRUE),
(2, 'C', 150.50, DATE '2026-11-21', FALSE),
(2, 'A',  60,    DATE '2026-11-22', TRUE),
(3, 'B', 200,    DATE '2026-11-22', TRUE),
(3, 'C',  90,    DATE '2026-11-23', TRUE);

-- ======================================================================
-- (e) View [5 marks]
-- ======================================================================
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;

-- ======================================================================
-- (f) Index [5 marks]
-- ======================================================================
CREATE INDEX idx_deliveries_farmer_date
  ON deliveries (farmer_id, delivered_on);

EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- ======================================================================
-- (g) Scheduled job [6 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries
  WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
  SET total_weight = EXCLUDED.total_weight,
      total_value = EXCLUDED.total_value;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_purchases', '30 1 * * *',
  $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);

CALL pr_refresh_purchases(DATE '2026-11-21');  -- test
CALL pr_refresh_purchases(DATE '2026-11-21');  -- rerun: same totals
SELECT * FROM daily_purchases;
