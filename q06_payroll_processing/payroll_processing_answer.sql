-- ICT371 Advanced Database - Question 6: Monthly Payroll Processing
-- Bwalya Marvelous (202406501), Mulungushi University
-- PostgreSQL. Run the whole file in order: psql -d yourdb -f answer.sql
-- Scheduled jobs need the pg_cron extension.

-- ======================================================================
-- (a) Database and seed data [6 marks] - tables and seed data
-- ======================================================================
CREATE TABLE employees (
  employee_id SERIAL PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
  gross_pay NUMERIC(12,2) NOT NULL,
  net_pay NUMERIC(12,2) NOT NULL,
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary NUMERIC(12,2) NOT NULL,
  new_salary NUMERIC(12,2) NOT NULL,
  changed_at TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Alice Mumba',   8000.00, 1500.00, 1200.00, TRUE),
('Brian Chola',   6500.00, 1000.00,  900.00, TRUE),
('Cynthia Lungu', 5200.00,  800.00,  700.00, TRUE),
('David Simbeye', 4800.00,  600.00,  500.00, TRUE);

-- ======================================================================
-- (b) Function [6 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
  END IF;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- ======================================================================
-- (c) Procedure [8 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'p_month must be the first day of a month: %', p_month;
  END IF;
  FOR r IN SELECT employee_id, basic_salary, allowance
           FROM employees WHERE active ORDER BY employee_id
  LOOP
    v_net := fn_net_pay(r.employee_id);  -- raises on a negative net pay
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;
  END LOOP;
END $$;

-- ======================================================================
-- (d) Trigger [8 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;  -- logged
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;  -- unchanged: no entry
SELECT * FROM salary_audit;

-- ======================================================================
-- (a) continued - seed data that needs the code above
-- ======================================================================
-- run after parts (b) and (c) exist: two payroll months
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- David becomes inactive: November skips him but his history stays
UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll(DATE '2026-11-01');
CALL pr_process_payroll(DATE '2026-11-01');  -- rerun: existing rows unchanged

-- ======================================================================
-- (e) View [5 marks]
-- ======================================================================
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id, e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month, e.full_name;

SELECT * FROM v_payroll_report;

-- ======================================================================
-- (f) Index [5 marks]
-- ======================================================================
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

EXPLAIN
SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';

-- ======================================================================
-- (g) Scheduled job [6 marks]
-- ======================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('monthly_payroll', '0 2 1 * *',
  $$CALL pr_process_payroll(
      (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- inspect the job
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'monthly_payroll';

-- inspect its run history
SELECT d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'monthly_payroll'
ORDER BY d.start_time DESC;

-- to remove it later
SELECT cron.unschedule('monthly_payroll');
