-- =====================================================================
-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Name: ________________ | Student number: ____________ | PostgreSQL 16 (PL/pgSQL)
-- gross_pay = basic_salary + allowance
-- net_pay = gross_pay - deduction
-- Existing payroll rows are left unchanged when a month is reprocessed.
-- =====================================================================

DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6;

-- ---------------------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL
        CHECK (pay_month = date_trunc('month', pay_month)::date),   -- first day of month
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Mwila Banda',    12000.00, 2000.00, 1500.00, TRUE),
    ('Natasha Phiri',   9500.00, 1500.00, 1000.00, TRUE),
    ('Chanda Mulenga',  8000.00, 1000.00,  900.00, TRUE),   -- becomes inactive after October
    ('Bwalya Tembo',    7000.00,  500.00,  700.00, FALSE);  -- inactive from the start
-- Payroll for October and November 2026 is generated after (c).

-- ---------------------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net       NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allowance) - v_deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure [8 marks]
-- Query FOR loop over active employees. ON CONFLICT DO NOTHING keeps an
-- existing employee/month row unchanged. There is no exception handler,
-- so one invalid calculation aborts the whole CALL (nothing is inserted).
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger [8 marks]
-- Fires only when basic_salary actually changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- ---------------------------------------------------------------------
-- (a) continued: two payroll months
-- ---------------------------------------------------------------------
CALL pr_process_payroll(DATE '2026-10-01');                 -- 3 active employees
UPDATE employees SET active = FALSE WHERE employee_id = 3;  -- Chanda leaves after October
UPDATE employees SET basic_salary = 12500.00 WHERE employee_id = 1;  -- raise -> audited
CALL pr_process_payroll(DATE '2026-11-01');                 -- 2 active employees
CALL pr_process_payroll(DATE '2026-11-01');                 -- rerun: existing rows unchanged

-- Tests for (b)
SELECT fn_net_pay(1) AS emp1, fn_net_pay(2) AS emp2;        -- 13000.00 | 10000.00
-- SELECT fn_net_pay(99); -- ERROR: Unknown employee_id

-- Tests for (c)
-- CALL pr_process_payroll(DATE '2026-11-15'); -- ERROR: not a month start
-- Whole-call failure: make one active employee's net pay negative
-- UPDATE employees SET deduction = 50000 WHERE employee_id = 2;
-- CALL pr_process_payroll(DATE '2026-12-01'); -- ERROR: Negative net pay; no December rows
-- UPDATE employees SET deduction = 1000 WHERE employee_id = 2;
SELECT employee_id, pay_month, gross_pay, net_pay FROM payroll ORDER BY pay_month, employee_id;

-- Tests for (d)
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;  -- unchanged: no audit
SELECT * FROM salary_audit ORDER BY audit_id;               -- 1 row: 12000.00 -> 12500.00

-- ---------------------------------------------------------------------
-- (e) View [5 marks]
-- Inner join on payroll with no filter on active, so history for
-- employees who later became inactive is still shown.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT p.payroll_id,
       e.employee_id,
       e.full_name,
       e.active,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;
-- Chanda Mulenga (now inactive) still appears for 2026-10-01

-- ---------------------------------------------------------------------
-- (f) Index [5 marks]
-- The UNIQUE (employee_id, pay_month) index leads with employee_id, so it
-- cannot efficiently serve "all employees for one pay_month". A separate
-- single-column index on pay_month serves the monthly report without
-- duplicating the existing unique index.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;   -- demo only: tiny table would otherwise use Seq Scan
EXPLAIN ANALYZE
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-11-01';
RESET enable_seqscan;
-- Plan: Index Scan using idx_payroll_pay_month on payroll
-- Index Cond: (pay_month = '2026-11-01'::date)

-- ---------------------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- 02:00 on day 1 of every month, passing the first date of the previous
-- month. Rerunning is safe because existing rows are skipped.
-- ---------------------------------------------------------------------
ALTER PROCEDURE q6.pr_process_payroll(DATE) SET search_path = q6;
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q6_monthly_payroll',
    '0 2 1 * *',
    $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_monthly_payroll';

-- Inspect its run history (most recent first)
SELECT d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'q6_monthly_payroll'
ORDER BY d.start_time DESC;
