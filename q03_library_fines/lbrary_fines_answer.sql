-- ICT371 Advanced Database - Question 3: Library Returns and Overdue Fines
-- Bwalya Marvelous (202406501), Mulungushi University
-- PostgreSQL. Run the whole file in order: psql -d yourdb -f answer.sql
-- Scheduled jobs need the pg_cron extension.

-- ======================================================================
-- (a) Database and seed data [6 marks] - tables and seed data
-- ======================================================================
CREATE TABLE books (
  book_id SERIAL PRIMARY KEY,
  title VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id SERIAL PRIMARY KEY,
  book_id INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on DATE NOT NULL,
  due_on DATE NOT NULL,
  returned_on DATE,
  fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id SERIAL PRIMARY KEY,
  loan_id INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on DATE,
  new_returned_on DATE,
  changed_at TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
('Database Systems'), ('Operating Systems'), ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
(1, 'Mwansa C.',  DATE '2026-10-01', DATE '2026-10-15'),  -- open, overdue
(1, 'Chanda M.',  DATE '2026-11-15', DATE '2026-12-06'),  -- open, not yet due
(2, 'Bupe K.',    DATE '2026-10-20', DATE '2026-11-03'),  -- will be returned on time
(2, 'Temwani L.', DATE '2026-10-10', DATE '2026-10-24'),  -- will be returned late
(3, 'Natasha P.', DATE '2026-11-01', DATE '2026-11-15'),  -- open, overdue
(3, 'Joseph S.',  DATE '2026-11-20', DATE '2026-11-27');  -- open, not yet due

-- ======================================================================
-- (b) Function [6 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_due DATE; v_returned DATE; v_end DATE;
BEGIN
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'p_as_of must not be NULL';
  END IF;
  SELECT due_on, returned_on INTO v_due, v_returned
  FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  -- earlier of p_as_of and returned_on (when the loan has been returned)
  IF v_returned IS NOT NULL AND v_returned < p_as_of THEN
    v_end := v_returned;
  ELSE
    v_end := p_as_of;
  END IF;
  RETURN 2 * GREATEST(v_end - v_due, 0);
END $$;

-- ======================================================================
-- (c) Procedure [8 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_returned DATE; v_fine NUMERIC;
BEGIN
  SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  IF v_returned IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
  END IF;
  IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Invalid return date % (borrowed on %)', p_returned_on, v_borrowed;
  END IF;
  v_fine := fn_loan_fine(p_loan_id, p_returned_on);
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = v_fine
  WHERE loan_id = p_loan_id;
END $$;

-- ======================================================================
-- (d) Trigger [8 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
  RETURN NEW;
END $$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- ======================================================================
-- (a) continued - seed data that needs the code above
-- ======================================================================
-- run after pr_return_loan (c) and the trigger (d) exist
CALL pr_return_loan(3, DATE '2026-11-03');  -- on the due date: fine 0
CALL pr_return_loan(4, DATE '2026-10-30');  -- 6 days late: fine K12

-- ======================================================================
-- (e) View [5 marks]
-- ======================================================================
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- ======================================================================
-- (f) Index [5 marks]
-- ======================================================================
CREATE INDEX idx_loans_book_unreturned
  ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN
SELECT * FROM loans
WHERE book_id = 1 AND returned_on IS NULL;

-- ======================================================================
-- (g) Scheduled job [6 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
  ON CONFLICT (snapshot_date) DO UPDATE
  SET overdue_count = EXCLUDED.overdue_count,
      total_fine = EXCLUDED.total_fine;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_overdue', '10 0 * * *',
  $$CALL pr_refresh_overdue(CURRENT_DATE)$$);

CALL pr_refresh_overdue(CURRENT_DATE);  -- test
CALL pr_refresh_overdue(CURRENT_DATE);  -- rerun: still one row
SELECT * FROM overdue_summary;
