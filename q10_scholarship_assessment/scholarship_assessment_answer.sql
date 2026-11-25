-- ICT371 Advanced Database - Question 10: Scholarship Application Assessment
-- Bwalya Marvelous (202406501), Mulungushi University
-- PostgreSQL. Run the whole file in order: psql -d yourdb -f answer.sql
-- Scheduled jobs need the pg_cron extension.

-- ======================================================================
-- (a) Database and seed data [6 marks] - tables and seed data
-- ======================================================================
CREATE TABLE students (
  student_id SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on DATE NOT NULL,
  status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id SERIAL PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status VARCHAR(10) NOT NULL,
  new_status VARCHAR(10) NOT NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
('202406501', 'Student One'), ('202406502', 'Student Two'),
('202406503', 'Student Three');

INSERT INTO applications
  (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
(1, 20, 2500.00, 75.00, DATE '2026-10-01'),  -- qualifies
(1, 18, 3000.00, 70.00, DATE '2026-10-03'),  -- boundary: lowest age, top income, lowest mark
(2, 25, 2999.99, 85.00, DATE '2026-10-05'),  -- boundary: highest age
(2, 26, 2000.00, 80.00, DATE '2026-10-07'),  -- fails: age 26
(3, 22, 3000.01, 90.00, DATE '2026-10-09'),  -- fails: income just over K3,000
(3, 21, 1500.00, 69.99, DATE '2026-10-11');  -- fails: mark just under 70

-- ======================================================================
-- (b) Function [6 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
  p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark must not be NULL';
  END IF;
  IF p_age <= 0 THEN
    RAISE EXCEPTION 'Age must be positive: %', p_age;
  END IF;
  IF p_income < 0 THEN
    RAISE EXCEPTION 'Income must not be negative: %', p_income;
  END IF;
  IF p_mark < 0 OR p_mark > 100 THEN
    RAISE EXCEPTION 'Mark must be between 0 and 100: %', p_mark;
  END IF;
  RETURN p_age BETWEEN 18 AND 25
     AND p_income <= 3000
     AND p_mark >= 70;
END $$;

-- ======================================================================
-- (c) Procedure [8 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_age INT; v_income NUMERIC; v_mark NUMERIC; v_status VARCHAR(10);
BEGIN
  SELECT age_at_application, monthly_income, average_mark, status
  INTO v_age, v_income, v_mark, v_status
  FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application: %', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % was already assessed (status %)',
      p_application_id, v_status;
  END IF;
  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END $$;

-- ======================================================================
-- (d) Trigger [8 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION trg_fn_decision_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- ======================================================================
-- (e) View [5 marks]
-- ======================================================================
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;

-- ======================================================================
-- (f) Index [5 marks]
-- ======================================================================
CREATE INDEX idx_applications_status_submitted
  ON applications (status, submitted_on);

EXPLAIN
SELECT * FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN DATE '2026-10-01' AND DATE '2026-10-31';

-- ======================================================================
-- (g) Scheduled job [6 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications
           WHERE status = 'PENDING' ORDER BY application_id
  LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess_pending', '0 8 * * 1',
  $$CALL pr_assess_pending()$$);

CALL pr_assess_pending();   -- test: assesses all six
CALL pr_assess_pending();   -- rerun: nothing is PENDING, nothing changes
SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit ORDER BY audit_id;
