/*
PROJECT: Microsoft Scope 3 "Digital Twin" & Net Zero Simulation
DATABASE: SQLite
DESCRIPTION:
This project simulates Microsoft-style Scope 3 emissions from 2020 to 2030.
It models business growth, decarbonization adoption, green premium cost,
and the remaining carbon removal gap required to reach a 2030 net-zero target.
*/

-- =========================================================
-- 1. CLEAN OLD TABLES
-- =========================================================

DROP TABLE IF EXISTS simulation_results;
DROP TABLE IF EXISTS decarbonization_levers;
DROP TABLE IF EXISTS scope3_categories;
DROP TABLE IF EXISTS model_assumptions;
DROP VIEW IF EXISTS executive_scope3_dashboard;

-- =========================================================
-- 2. MODEL ASSUMPTIONS TABLE
-- =========================================================

CREATE TABLE model_assumptions (
    assumption_id INTEGER PRIMARY KEY AUTOINCREMENT,
    assumption_name TEXT,
    assumption_value REAL,
    unit TEXT,
    description TEXT
);

INSERT INTO model_assumptions
(assumption_name, assumption_value, unit, description)
VALUES
('Start Year', 2020, 'Year', 'Base year for the simulation'),
('End Year', 2030, 'Year', 'Final target year'),
('Scope 3 Reduction Target', 0.50, 'Percentage', 'Target is to reduce Scope 3 emissions by 50 percent by 2030'),
('Carbon Removal Cost', 0.0005, 'Billion USD per MT CO2e', 'Estimated cost of removing one MT CO2e using high-quality carbon removal');

-- =========================================================
-- 3. SCOPE 3 CATEGORY TABLE
-- =========================================================

CREATE TABLE scope3_categories (
    category_id INTEGER PRIMARY KEY AUTOINCREMENT,
    category_name TEXT,
    category_group TEXT,
    baseline_year INTEGER,
    baseline_emissions_mt REAL,
    annual_growth_rate REAL,
    baseline_budget_bn REAL,
    risk_level TEXT
);

INSERT INTO scope3_categories
(category_name, category_group, baseline_year, baseline_emissions_mt, annual_growth_rate, baseline_budget_bn, risk_level)
VALUES
('Data Centers', 'Capital Goods and Infrastructure', 2020, 4.75, 0.1200, 12.00, 'Critical'),
('Cloud Infrastructure Materials', 'Capital Goods and Infrastructure', 2020, 2.10, 0.1200, 5.50, 'High'),
('Hardware Devices', 'Purchased Goods and Services', 2020, 3.20, 0.0800, 8.00, 'High'),
('Capital Goods', 'Capital Goods and Infrastructure', 2020, 2.60, 0.1000, 6.00, 'High'),
('Logistics', 'Transportation and Distribution', 2020, 0.78, 0.0500, 3.00, 'Medium'),
('Business Travel', 'Travel and Operations', 2020, 0.42, 0.0300, 1.20, 'Low');

-- =========================================================
-- 4. DECARBONIZATION LEVERS TABLE
-- =========================================================

CREATE TABLE decarbonization_levers (
    lever_id INTEGER PRIMARY KEY AUTOINCREMENT,
    category_id INTEGER REFERENCES scope3_categories(category_id),
    lever_name TEXT,
    adoption_curve TEXT,
    first_adoption_year INTEGER,
    full_adoption_year INTEGER,
    max_adoption_rate REAL,
    abatement_efficiency REAL,
    green_premium_rate REAL
);

INSERT INTO decarbonization_levers
(category_id, lever_name, adoption_curve, first_adoption_year, full_adoption_year, max_adoption_rate, abatement_efficiency, green_premium_rate)
SELECT category_id, 'Green Steel and Low Carbon Concrete', 'LAGGED_S_CURVE', 2024, 2030, 1.00, 0.60, 0.35
FROM scope3_categories WHERE category_name = 'Data Centers';

INSERT INTO decarbonization_levers
(category_id, lever_name, adoption_curve, first_adoption_year, full_adoption_year, max_adoption_rate, abatement_efficiency, green_premium_rate)
SELECT category_id, 'Low Carbon Cloud Infrastructure Materials', 'LAGGED_S_CURVE', 2024, 2030, 1.00, 0.58, 0.35
FROM scope3_categories WHERE category_name = 'Cloud Infrastructure Materials';

INSERT INTO decarbonization_levers
(category_id, lever_name, adoption_curve, first_adoption_year, full_adoption_year, max_adoption_rate, abatement_efficiency, green_premium_rate)
SELECT category_id, 'Device Efficiency and Circular Hardware', 'LINEAR_RAMP', 2021, 2030, 0.90, 0.55, 0.25
FROM scope3_categories WHERE category_name = 'Hardware Devices';

INSERT INTO decarbonization_levers
(category_id, lever_name, adoption_curve, first_adoption_year, full_adoption_year, max_adoption_rate, abatement_efficiency, green_premium_rate)
SELECT category_id, 'Supplier Renewable Manufacturing', 'LAGGED_S_CURVE', 2023, 2030, 1.00, 0.57, 0.35
FROM scope3_categories WHERE category_name = 'Capital Goods';

INSERT INTO decarbonization_levers
(category_id, lever_name, adoption_curve, first_adoption_year, full_adoption_year, max_adoption_rate, abatement_efficiency, green_premium_rate)
SELECT category_id, 'Sustainable Aviation Fuel and EV Freight', 'LINEAR_RAMP', 2021, 2030, 0.95, 0.75, 0.20
FROM scope3_categories WHERE category_name = 'Logistics';

INSERT INTO decarbonization_levers
(category_id, lever_name, adoption_curve, first_adoption_year, full_adoption_year, max_adoption_rate, abatement_efficiency, green_premium_rate)
SELECT category_id, 'Virtual Collaboration and Low Carbon Travel', 'LINEAR_RAMP', 2021, 2030, 0.80, 0.70, 0.10
FROM scope3_categories WHERE category_name = 'Business Travel';

-- =========================================================
-- 5. CREATE SIMULATION RESULTS TABLE USING RECURSIVE CTE
-- =========================================================

CREATE TABLE simulation_results AS
WITH RECURSIVE digital_twin AS (

    SELECT
        c.category_id,
        c.category_name,
        c.category_group,
        c.baseline_year AS simulation_year,
        c.baseline_emissions_mt,
        c.baseline_emissions_mt AS bau_emissions_mt,
        c.baseline_emissions_mt AS revised_emissions_mt,
        0.0 AS adoption_rate,
        0.0 AS avoided_emissions_mt,
        0.0 AS green_premium_spend_bn,
        c.annual_growth_rate,
        c.baseline_budget_bn,
        c.risk_level,
        l.lever_name,
        l.adoption_curve,
        l.first_adoption_year,
        l.full_adoption_year,
        l.max_adoption_rate,
        l.abatement_efficiency,
        l.green_premium_rate
    FROM scope3_categories c
    JOIN decarbonization_levers l
        ON c.category_id = l.category_id

    UNION ALL

    SELECT
        category_id,
        category_name,
        category_group,
        simulation_year + 1,
        baseline_emissions_mt,

        ROUND(bau_emissions_mt * (1 + annual_growth_rate), 4) AS bau_emissions_mt,

        ROUND(
            (bau_emissions_mt * (1 + annual_growth_rate))
            *
            (
                1 -
                (
                    CASE
                        WHEN simulation_year + 1 < first_adoption_year THEN 0

                        WHEN adoption_curve = 'LINEAR_RAMP' THEN
                            MIN(
                                max_adoption_rate,
                                (CAST(simulation_year + 1 - first_adoption_year + 1 AS REAL) /
                                (full_adoption_year - first_adoption_year + 1)) * max_adoption_rate
                            )

                        WHEN adoption_curve = 'LAGGED_S_CURVE' THEN
                            MIN(
                                max_adoption_rate,
                                max_adoption_rate /
                                (
                                    1 + EXP(
                                        -1.20 * (
                                            (simulation_year + 1)
                                            - ((first_adoption_year + full_adoption_year) / 2.0)
                                        )
                                    )
                                )
                            )

                        ELSE 0
                    END
                ) * abatement_efficiency
            ),
        4) AS revised_emissions_mt,

        ROUND(
            CASE
                WHEN simulation_year + 1 < first_adoption_year THEN 0

                WHEN adoption_curve = 'LINEAR_RAMP' THEN
                    MIN(
                        max_adoption_rate,
                        (CAST(simulation_year + 1 - first_adoption_year + 1 AS REAL) /
                        (full_adoption_year - first_adoption_year + 1)) * max_adoption_rate
                    )

                WHEN adoption_curve = 'LAGGED_S_CURVE' THEN
                    MIN(
                        max_adoption_rate,
                        max_adoption_rate /
                        (
                            1 + EXP(
                                -1.20 * (
                                    (simulation_year + 1)
                                    - ((first_adoption_year + full_adoption_year) / 2.0)
                                )
                            )
                        )
                    )

                ELSE 0
            END,
        4) AS adoption_rate,

        ROUND(
            (bau_emissions_mt * (1 + annual_growth_rate))
            -
            (
                (bau_emissions_mt * (1 + annual_growth_rate))
                *
                (
                    1 -
                    (
                        CASE
                            WHEN simulation_year + 1 < first_adoption_year THEN 0

                            WHEN adoption_curve = 'LINEAR_RAMP' THEN
                                MIN(
                                    max_adoption_rate,
                                    (CAST(simulation_year + 1 - first_adoption_year + 1 AS REAL) /
                                    (full_adoption_year - first_adoption_year + 1)) * max_adoption_rate
                                )

                            WHEN adoption_curve = 'LAGGED_S_CURVE' THEN
                                MIN(
                                    max_adoption_rate,
                                    max_adoption_rate /
                                    (
                                        1 + EXP(
                                            -1.20 * (
                                                (simulation_year + 1)
                                                - ((first_adoption_year + full_adoption_year) / 2.0)
                                            )
                                        )
                                    )
                                )

                            ELSE 0
                        END
                    ) * abatement_efficiency
                )
            ),
        4) AS avoided_emissions_mt,

        ROUND(
            baseline_budget_bn
            * POWER((1 + annual_growth_rate), (simulation_year + 1 - 2020))
            * green_premium_rate
            *
            CASE
                WHEN simulation_year + 1 < first_adoption_year THEN 0

                WHEN adoption_curve = 'LINEAR_RAMP' THEN
                    MIN(
                        max_adoption_rate,
                        (CAST(simulation_year + 1 - first_adoption_year + 1 AS REAL) /
                        (full_adoption_year - first_adoption_year + 1)) * max_adoption_rate
                    )

                WHEN adoption_curve = 'LAGGED_S_CURVE' THEN
                    MIN(
                        max_adoption_rate,
                        max_adoption_rate /
                        (
                            1 + EXP(
                                -1.20 * (
                                    (simulation_year + 1)
                                    - ((first_adoption_year + full_adoption_year) / 2.0)
                                )
                            )
                        )
                    )

                ELSE 0
            END,
        4) AS green_premium_spend_bn,

        annual_growth_rate,
        baseline_budget_bn,
        risk_level,
        lever_name,
        adoption_curve,
        first_adoption_year,
        full_adoption_year,
        max_adoption_rate,
        abatement_efficiency,
        green_premium_rate
    FROM digital_twin
    WHERE simulation_year < 2030
)

SELECT
    ROW_NUMBER() OVER (ORDER BY category_name, simulation_year) AS result_id,
    category_id,
    category_name,
    category_group,
    simulation_year,
    baseline_emissions_mt,
    bau_emissions_mt,
    revised_emissions_mt,
    adoption_rate,
    avoided_emissions_mt,
    green_premium_spend_bn,
    annual_growth_rate,
    risk_level,
    lever_name,
    adoption_curve,
    CASE
        WHEN simulation_year < 2030 THEN 'In Progress'
        WHEN revised_emissions_mt <= baseline_emissions_mt * 0.50 THEN 'On Track'
        WHEN revised_emissions_mt <= baseline_emissions_mt THEN 'Partially Decarbonized'
        ELSE 'Critical Gap'
    END AS status
FROM digital_twin;

-- =========================================================
-- 6. FULL SIMULATION OUTPUT
-- =========================================================

SELECT
    simulation_year,
    category_name,
    ROUND(bau_emissions_mt, 2) AS bau_emissions_mt,
    ROUND(adoption_rate * 100, 2) AS adoption_percentage,
    ROUND(revised_emissions_mt, 2) AS revised_emissions_mt,
    ROUND(avoided_emissions_mt, 2) AS avoided_emissions_mt,
    ROUND(green_premium_spend_bn, 2) AS green_premium_spend_bn,
    status
FROM simulation_results
ORDER BY category_name, simulation_year;

-- =========================================================
-- 7. 2030 CATEGORY-WISE RESULT
-- =========================================================

SELECT
    category_name,
    category_group,
    ROUND(baseline_emissions_mt, 2) AS emissions_2020_mt,
    ROUND(bau_emissions_mt, 2) AS bau_2030_emissions_mt,
    ROUND(revised_emissions_mt, 2) AS simulated_2030_emissions_mt,
    ROUND(avoided_emissions_mt, 2) AS avoided_emissions_mt,
    ROUND(green_premium_spend_bn, 2) AS green_premium_spend_bn,
    ROUND(((revised_emissions_mt - baseline_emissions_mt) / baseline_emissions_mt) * 100, 2) AS change_vs_2020_percentage,
    status
FROM simulation_results
WHERE simulation_year = 2030
ORDER BY revised_emissions_mt DESC;

-- =========================================================
-- 8. YEARLY TOTAL TRAJECTORY
-- =========================================================

SELECT
    simulation_year,
    ROUND(SUM(bau_emissions_mt), 2) AS total_bau_emissions_mt,
    ROUND(SUM(revised_emissions_mt), 2) AS total_revised_emissions_mt,
    ROUND(SUM(avoided_emissions_mt), 2) AS total_avoided_emissions_mt,
    ROUND(SUM(green_premium_spend_bn), 2) AS total_green_premium_spend_bn
FROM simulation_results
GROUP BY simulation_year
ORDER BY simulation_year;

-- =========================================================
-- 9. 2030 CARBON REMOVAL GAP
-- =========================================================

WITH baseline AS (
    SELECT SUM(baseline_emissions_mt) AS total_2020_emissions
    FROM scope3_categories
),
target AS (
    SELECT total_2020_emissions * 0.50 AS allowed_2030_emissions
    FROM baseline
),
actual AS (
    SELECT SUM(revised_emissions_mt) AS simulated_2030_emissions
    FROM simulation_results
    WHERE simulation_year = 2030
),
cost AS (
    SELECT assumption_value AS carbon_removal_cost_per_mt
    FROM model_assumptions
    WHERE assumption_name = 'Carbon Removal Cost'
)
SELECT
    ROUND(b.total_2020_emissions, 2) AS total_2020_emissions_mt,
    ROUND(t.allowed_2030_emissions, 2) AS required_2030_target_mt,
    ROUND(a.simulated_2030_emissions, 2) AS simulated_2030_emissions_mt,
    ROUND(MAX(a.simulated_2030_emissions - t.allowed_2030_emissions, 0), 2) AS carbon_removal_required_mt,
    ROUND(MAX(a.simulated_2030_emissions - t.allowed_2030_emissions, 0) * c.carbon_removal_cost_per_mt, 2) AS estimated_carbon_removal_cost_bn,
    CASE
        WHEN a.simulated_2030_emissions <= t.allowed_2030_emissions
            THEN 'Target Achieved'
        ELSE 'Carbon Removal Required'
    END AS strategic_conclusion
FROM baseline b, target t, actual a, cost c;

-- =========================================================
-- 10. FINANCIAL CLIFF ANALYSIS
-- =========================================================

SELECT
    simulation_year,
    ROUND(SUM(green_premium_spend_bn), 2) AS annual_green_premium_spend_bn
FROM simulation_results
WHERE simulation_year BETWEEN 2028 AND 2030
GROUP BY simulation_year
ORDER BY simulation_year;

-- =========================================================
-- 11. HIGHEST RISK CATEGORIES
-- =========================================================

SELECT
    category_name,
    risk_level,
    ROUND(baseline_emissions_mt, 2) AS emissions_2020_mt,
    ROUND(revised_emissions_mt, 2) AS simulated_2030_emissions_mt,
    ROUND(revised_emissions_mt - baseline_emissions_mt, 2) AS absolute_gap_vs_2020_mt,
    ROUND(((revised_emissions_mt - baseline_emissions_mt) / baseline_emissions_mt) * 100, 2) AS percentage_gap_vs_2020,
    status
FROM simulation_results
WHERE simulation_year = 2030
ORDER BY absolute_gap_vs_2020_mt DESC;

-- =========================================================
-- 12. EXECUTIVE DASHBOARD VIEW
-- =========================================================

CREATE VIEW IF NOT EXISTS executive_scope3_dashboard AS
WITH yearly AS (
    SELECT
        simulation_year,
        SUM(bau_emissions_mt) AS total_bau_emissions_mt,
        SUM(revised_emissions_mt) AS total_revised_emissions_mt,
        SUM(avoided_emissions_mt) AS total_avoided_emissions_mt,
        SUM(green_premium_spend_bn) AS total_green_premium_spend_bn
    FROM simulation_results
    GROUP BY simulation_year
),
baseline AS (
    SELECT SUM(baseline_emissions_mt) AS total_2020_emissions
    FROM scope3_categories
)
SELECT
    y.simulation_year,
    ROUND(y.total_bau_emissions_mt, 2) AS total_bau_emissions_mt,
    ROUND(y.total_revised_emissions_mt, 2) AS total_revised_emissions_mt,
    ROUND(y.total_avoided_emissions_mt, 2) AS total_avoided_emissions_mt,
    ROUND(y.total_green_premium_spend_bn, 2) AS total_green_premium_spend_bn,
    ROUND(b.total_2020_emissions * 0.50, 2) AS required_2030_target_mt,
    ROUND(y.total_revised_emissions_mt - (b.total_2020_emissions * 0.50), 2) AS gap_to_target_mt,
    CASE
        WHEN y.simulation_year < 2030 THEN 'Tracking'
        WHEN y.total_revised_emissions_mt <= b.total_2020_emissions * 0.50 THEN '2030 Target Achieved'
        ELSE '2030 Target Missed Without Carbon Removal'
    END AS target_status
FROM yearly y
CROSS JOIN baseline b
ORDER BY y.simulation_year;

SELECT *
FROM executive_scope3_dashboard;
