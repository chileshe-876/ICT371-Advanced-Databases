-- ICT371 Advanced Database - Question 5: Hostel Room Allocation
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
CREATE TABLE rooms (
  room_id SERIAL PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  room_id INT NOT NULL REFERENCES rooms(room_id),
  allocated_on DATE NOT NULL,
  released_on DATE,
  status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT chk_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED' AND released_on IS NOT NULL
                      AND released_on >= allocated_on))
);
-- safety net for concurrent sessions: one ACTIVE allocation per student
CREATE UNIQUE INDEX uq_one_active_per_student
  ON allocations (student_id) WHERE status = 'ACTIVE';
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL,
  free_beds INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
('202406501', 'Student One'), ('202406502', 'Student Two'),
('202406503', 'Student Three'), ('202406504', 'Student Four'),
('202406505', 'Student Five');
INSERT INTO rooms (room_number, capacity) VALUES
('R101', 2), ('R102', 3), ('R103', 2);

-- ENDED history (does not occupy a bed)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, DATE '2026-03-01', DATE '2026-06-30', 'ENDED');

-- ======================================================================
-- (b) Function [6 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_capacity INT; v_occupied INT;
BEGIN
  SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;
  SELECT COUNT(*) INTO v_occupied
  FROM allocations
  WHERE room_id = p_room_id AND status = 'ACTIVE';
  RETURN v_capacity - v_occupied;
END $$;

-- ======================================================================
-- (c) Procedure [8 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_allocate_room(
  p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  -- lock the room so two allocations cannot take the last bed together
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'allocated_on must not be NULL';
  END IF;
  IF EXISTS (SELECT 1 FROM allocations
             WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;
  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- ======================================================================
-- (d) Trigger [8 marks]
-- ======================================================================
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_capacity INT; v_occupied INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_capacity FROM rooms
    WHERE room_id = NEW.room_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown room: %', NEW.room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id AND status = 'ACTIVE'
                 AND allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_occupied FROM allocations
    WHERE room_id = NEW.room_id AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM NEW.allocation_id;
    IF v_occupied >= v_capacity THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_fn_allocation_rules();

-- ======================================================================
-- (a) continued - seed data that needs the code above
-- ======================================================================
-- run after pr_allocate_room (c) exists
CALL pr_allocate_room(1, 1, DATE '2026-09-01');
CALL pr_allocate_room(2, 1, DATE '2026-09-01');   -- R101 now full (2 of 2)
CALL pr_allocate_room(3, 2, DATE '2026-09-02');   -- R102 partly occupied (1 of 3)
-- R103 has only ended history, so it is empty

-- ======================================================================
-- (e) View [5 marks]
-- ======================================================================
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

-- ======================================================================
-- (f) Index [5 marks]
-- ======================================================================
CREATE INDEX idx_alloc_active_room
  ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN
SELECT * FROM allocations
WHERE room_id = 1 AND status = 'ACTIVE';

-- ======================================================================
-- (g) Scheduled job [6 marks]
-- ======================================================================
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
  FROM v_room_occupancy
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
  SET occupied_beds = EXCLUDED.occupied_beds,
      free_beds = EXCLUDED.free_beds;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_occupancy', '55 23 * * *',
  $$CALL pr_refresh_occupancy()$$);

CALL pr_refresh_occupancy();  -- test
CALL pr_refresh_occupancy();  -- rerun: still one row per room
SELECT * FROM occupancy_snapshot ORDER BY room_id;
