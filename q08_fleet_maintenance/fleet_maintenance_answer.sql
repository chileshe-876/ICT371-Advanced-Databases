-- (a) Database and seed data 
CREATE TABLE vehicles (
  vehicle_id SERIAL PRIMARY KEY,
  registration VARCHAR(20) NOT NULL UNIQUE,
  current_odometer INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_service_not_ahead
    CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id SERIAL PRIMARY KEY,
  vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer INT NOT NULL CHECK (end_odometer >= 0),
  CONSTRAINT chk_trip_distance CHECK (end_odometer > start_odometer)
);
CREATE TABLE service_alerts (
  vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on DATE NOT NULL
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('ZM 1001 A', 20000, 18000),   -- 2,000 km since service
('ZM 2002 B', 30000, 26000),   -- 4,000 km since service
('ZM 3003 C', 45000, 39000);   -- 6,000 km since service


-- (b) Function 

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_km INT;
BEGIN
  SELECT current_odometer - last_service_odometer INTO v_km
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  RETURN v_km >= 5000;
END $$;


-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_trip(
  p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date and odometer values must not be NULL';
  END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)',
      p_end, p_start;
  END IF;
  -- the odometer is updated by the trigger, not here
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (d) Trigger 

CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE v_current INT;
BEGIN
  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
  END IF;
  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Trip must start at the current odometer % (got %)',
      v_current, NEW.start_odometer;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end % is not above start %',
      NEW.end_odometer, NEW.start_odometer;
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer
  WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_fn_trip_odometer();

-- (a) continued - seed data that needs the code above
CALL pr_record_trip(1, DATE '2026-11-18', 20000, 20300);
CALL pr_record_trip(1, DATE '2026-11-22', 20300, 20650);
CALL pr_record_trip(2, DATE '2026-11-19', 30000, 30600);
CALL pr_record_trip(2, DATE '2026-11-23', 30600, 31200);
CALL pr_record_trip(3, DATE '2026-11-20', 45000, 45400);
CALL pr_record_trip(3, DATE '2026-11-24', 45400, 45900);


-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;


-- (f) Index
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  -- one alert per due vehicle: insert it, or update the distance
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE fn_service_due(vehicle_id)
  ON CONFLICT (vehicle_id) DO UPDATE
  SET km_since_service = EXCLUDED.km_since_service;

  -- remove alerts for vehicles that are no longer due
  DELETE FROM service_alerts
  WHERE NOT fn_service_due(vehicle_id);
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1',
  $$CALL pr_refresh_service_alerts()$$);

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;

-- servicing vehicle 2 removes its alert on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;
