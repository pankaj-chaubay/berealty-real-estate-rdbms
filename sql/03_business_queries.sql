-- =============================================================================
-- Berealty Real Estate RDBMS
-- 03_business_queries.sql : reporting and operational queries
--
-- Each query starts with the business question it answers and who uses it.
-- Target: MySQL 8.0 (CTEs, recursive CTEs, window functions, ROLLUP/GROUPING).
--
-- Reporting date: the sample data is a snapshot taken on 2025-10-31, so the
-- queries use @as_of instead of CURDATE() to give stable results.
-- In production, set @as_of = CURDATE().
-- =============================================================================

USE berealty;
SET @as_of       = DATE('2025-10-31');
SET @report_year = YEAR(@as_of);

-- -----------------------------------------------------------------------------
-- Q1. Agent league table
-- Question : Who closed the most business this year, how close to the asking
--            price do they sell, and what is still in their pipeline?
-- Used by  : Sales director, monthly performance review, bonus calculation.
-- Shows    : CTEs, LEFT JOIN, RANK(), share of total with SUM() OVER ().
-- -----------------------------------------------------------------------------
WITH closed AS (
    SELECT t.agent_id,
           COUNT(*)                                     AS deals_closed,
           SUM(t.sale_amount)                           AS revenue,
           SUM(t.sale_amount * t.commission_rate)       AS commission,
           AVG(t.sale_amount / p.list_price)            AS sale_to_list
    FROM sale_transaction t
    JOIN property p ON p.property_id = t.property_id
    WHERE t.stage = 'CLOSED'
      AND YEAR(t.transaction_date) = @report_year
    GROUP BY t.agent_id
),
pipeline AS (
    SELECT agent_id, COUNT(*) AS open_offers, SUM(sale_amount) AS open_offer_value
    FROM sale_transaction
    WHERE stage = 'OFFER'
    GROUP BY agent_id
)
SELECT RANK() OVER (ORDER BY COALESCE(c.revenue, 0) DESC)                    AS revenue_rank,
       CONCAT(a.first_name, ' ', a.last_name)                                AS agent,
       COALESCE(c.deals_closed, 0)                                           AS deals_closed,
       COALESCE(c.revenue, 0)                                                AS revenue_eur,
       ROUND(100 * COALESCE(c.revenue, 0) / SUM(COALESCE(c.revenue, 0)) OVER (), 1) AS revenue_share_pct,
       ROUND(100 * c.sale_to_list, 1)                                        AS sale_to_list_pct,
       ROUND(COALESCE(c.commission, 0), 0)                                   AS commission_eur,
       COALESCE(pl.open_offers, 0)                                           AS open_offers,
       COALESCE(pl.open_offer_value, 0)                                      AS pipeline_eur
FROM agent a
LEFT JOIN closed   c  ON c.agent_id  = a.agent_id
LEFT JOIN pipeline pl ON pl.agent_id = a.agent_id
WHERE a.is_active
ORDER BY revenue_rank, agent;

-- -----------------------------------------------------------------------------
-- Q2. Monthly revenue trend with running total and month-on-month change
-- Question : How is revenue developing month by month, including months with
--            no sales, and are we ahead of last month?
-- Used by  : Management board pack, cash-flow planning.
-- Shows    : Recursive CTE (calendar), LEFT JOIN, SUM() OVER (running total),
--            LAG() for month-on-month change.
-- -----------------------------------------------------------------------------
WITH RECURSIVE calendar AS (
    SELECT DATE('2024-01-01') AS month_start
    UNION ALL
    SELECT month_start + INTERVAL 1 MONTH FROM calendar
    WHERE month_start + INTERVAL 1 MONTH <= @as_of
),
monthly AS (
    SELECT c.month_start,
           COUNT(t.transaction_id)        AS deals_closed,
           COALESCE(SUM(t.sale_amount), 0) AS revenue
    FROM calendar c
    LEFT JOIN sale_transaction t
           ON t.stage = 'CLOSED'
          AND t.transaction_date >= c.month_start
          AND t.transaction_date <  c.month_start + INTERVAL 1 MONTH
    GROUP BY c.month_start
)
SELECT DATE_FORMAT(month_start, '%Y-%m')                                       AS month,
       deals_closed,
       revenue                                                                 AS revenue_eur,
       SUM(revenue) OVER (PARTITION BY YEAR(month_start) ORDER BY month_start) AS ytd_revenue_eur,
       revenue - LAG(revenue) OVER (ORDER BY month_start)                      AS change_vs_prior_month_eur
FROM monthly
ORDER BY month_start;

-- -----------------------------------------------------------------------------
-- Q3. Quarterly and yearly report with subtotals
-- Question : Revenue and volume by year and quarter, split residential vs
--            commercial, with year subtotals and a grand total in one result.
-- Used by  : Year-end reporting, auditors.
-- Shows    : GROUP BY ... WITH ROLLUP, GROUPING() to label subtotal rows.
-- -----------------------------------------------------------------------------
SELECT CASE WHEN GROUPING(sale_year) = 1 THEN 'All years'
            ELSE CAST(sale_year AS CHAR) END                                AS year,
       CASE WHEN GROUPING(sale_year) = 1 THEN ''
            WHEN GROUPING(sale_quarter) = 1 THEN 'Year total'
            ELSE CONCAT('Q', sale_quarter) END                              AS quarter,
       COUNT(*)                                                             AS deals_closed,
       SUM(CASE WHEN segment = 'RESIDENTIAL' THEN sale_amount ELSE 0 END)   AS residential_eur,
       SUM(CASE WHEN segment = 'COMMERCIAL'  THEN sale_amount ELSE 0 END)   AS commercial_eur,
       SUM(sale_amount)                                                     AS total_eur,
       ROUND(AVG(sale_amount), 0)                                           AS avg_deal_eur
FROM (
    SELECT YEAR(t.transaction_date)    AS sale_year,
           QUARTER(t.transaction_date) AS sale_quarter,
           pt.segment,
           t.sale_amount
    FROM sale_transaction t
    JOIN property      p  ON p.property_id       = t.property_id
    JOIN property_type pt ON pt.property_type_id = p.property_type_id
    WHERE t.stage = 'CLOSED'
) closed_sales
GROUP BY sale_year, sale_quarter WITH ROLLUP;

-- -----------------------------------------------------------------------------
-- Q4. Listing lifecycle: how long does each stage take?
-- Question : From listing to signed contract, how many days does a property
--            spend available and how many under offer, by property type?
--            Long "under offer" times point to slow financing or notary steps.
-- Used by  : Operations manager, process improvement.
-- Shows    : LEAD() over the status history to turn change events into
--            durations, conditional aggregation, multi-table JOIN.
-- -----------------------------------------------------------------------------
WITH status_spells AS (
    SELECT h.property_id,
           s.status_code,
           h.changed_at                                                        AS spell_start,
           LEAD(h.changed_at) OVER (PARTITION BY h.property_id ORDER BY h.changed_at, h.history_id) AS spell_end
    FROM property_status_history h
    JOIN property_status s ON s.status_id = h.new_status_id
),
per_property AS (
    SELECT sp.property_id,
           SUM(CASE WHEN sp.status_code = 'AVAILABLE'
                    THEN DATEDIFF(sp.spell_end, sp.spell_start) END)           AS days_available,
           SUM(CASE WHEN sp.status_code = 'UNDER_OFFER'
                    THEN DATEDIFF(sp.spell_end, sp.spell_start) END)           AS days_under_offer
    FROM status_spells sp
    WHERE sp.spell_end IS NOT NULL
    GROUP BY sp.property_id
)
SELECT pt.type_name                                       AS property_type,
       COUNT(*)                                           AS properties_sold,
       ROUND(AVG(pp.days_available), 0)                   AS avg_days_available,
       ROUND(AVG(pp.days_under_offer), 0)                 AS avg_days_under_offer,
       ROUND(AVG(DATEDIFF(t.transaction_date, p.listed_date)), 0) AS avg_days_listing_to_contract,
       MAX(DATEDIFF(t.transaction_date, p.listed_date))   AS slowest_days
FROM sale_transaction t
JOIN property      p  ON p.property_id       = t.property_id
JOIN property_type pt ON pt.property_type_id = p.property_type_id
JOIN per_property  pp ON pp.property_id      = t.property_id
WHERE t.stage = 'CLOSED'
GROUP BY pt.type_name
ORDER BY avg_days_listing_to_contract DESC;

-- -----------------------------------------------------------------------------
-- Q5. Exception queue: listings that need action today
-- Question : Which available listings have no agent, or have had no offer for
--            more than 90 days? Each row says what to do.
-- Used by  : Team leads, daily stand-up. Replaces a weekly manual sweep of the
--            listings spreadsheet.
-- Shows    : LEFT JOIN with aggregate subquery, CASE for rule-based actions,
--            NOT EXISTS.
-- -----------------------------------------------------------------------------
SELECT p.property_id,
       p.street_address,
       d.district_name,
       pt.type_name,
       p.list_price,
       DATEDIFF(@as_of, p.listed_date)                            AS days_on_market,
       COALESCE(CONCAT(a.first_name, ' ', a.last_name), '-')      AS listing_agent,
       COALESCE(last_offer.last_offer_date, '-')                  AS last_offer,
       CASE
           WHEN p.listing_agent_id IS NULL      THEN '1 - Assign an agent'
           WHEN a.is_active = FALSE             THEN '1 - Reassign: agent has left'
           WHEN DATEDIFF(@as_of, COALESCE(last_offer.last_offer_date, p.listed_date)) > 180
                                                THEN '2 - Price review: no interest for 6+ months'
           ELSE                                      '3 - Follow up: no offer for 90+ days'
       END                                                        AS action
FROM property p
JOIN property_status s  ON s.status_id         = p.status_id
JOIN district        d  ON d.district_id       = p.district_id
JOIN property_type   pt ON pt.property_type_id = p.property_type_id
LEFT JOIN agent      a  ON a.agent_id          = p.listing_agent_id
LEFT JOIN (
    SELECT property_id, MAX(offer_date) AS last_offer_date
    FROM sale_transaction
    GROUP BY property_id
) last_offer ON last_offer.property_id = p.property_id
WHERE s.status_code = 'AVAILABLE'
  AND (   p.listing_agent_id IS NULL
       OR a.is_active = FALSE
       OR DATEDIFF(@as_of, COALESCE(last_offer.last_offer_date, p.listed_date)) > 90)
ORDER BY action, days_on_market DESC;

-- -----------------------------------------------------------------------------
-- Q6. Client value and repeat business
-- Question : Who are our most valuable buyers, which of them buy repeatedly,
--            and what did each buy most recently?
-- Used by  : Key-account management, marketing (repeat buyers get first look
--            at new listings).
-- Shows    : ROW_NUMBER() to pick the latest purchase per client, DENSE_RANK(),
--            aggregates in a CTE.
-- -----------------------------------------------------------------------------
WITH purchases AS (
    SELECT t.client_id,
           t.transaction_date,
           t.sale_amount,
           p.street_address,
           pt.type_name,
           ROW_NUMBER() OVER (PARTITION BY t.client_id ORDER BY t.transaction_date DESC, t.transaction_id DESC) AS rn
    FROM sale_transaction t
    JOIN property      p  ON p.property_id       = t.property_id
    JOIN property_type pt ON pt.property_type_id = p.property_type_id
    WHERE t.stage = 'CLOSED'
),
totals AS (
    SELECT client_id, COUNT(*) AS purchases, SUM(sale_amount) AS total_spend
    FROM purchases
    GROUP BY client_id
)
SELECT DENSE_RANK() OVER (ORDER BY tot.total_spend DESC)                     AS spend_rank,
       COALESCE(c.company_name, CONCAT(c.first_name, ' ', c.last_name))      AS client,
       c.client_type,
       tot.purchases,
       CASE WHEN tot.purchases > 1 THEN 'Repeat buyer' ELSE 'One-off' END    AS segment,
       tot.total_spend                                                       AS total_spend_eur,
       latest.transaction_date                                               AS latest_purchase,
       CONCAT(latest.type_name, ', ', latest.street_address)                 AS latest_property
FROM totals tot
JOIN client    c      ON c.client_id      = tot.client_id
JOIN purchases latest ON latest.client_id = tot.client_id AND latest.rn = 1
ORDER BY spend_rank, client;

-- -----------------------------------------------------------------------------
-- Q7. Inventory and pricing by district
-- Question : What stock do we hold in each district, what is it worth, and do
--            buyers pay above or below our asking price per square metre?
-- Used by  : Acquisition team (where to win new listings), pricing reviews.
-- Shows    : Conditional aggregation (pivot), CROSS JOIN with a one-row
--            aggregate, LEFT JOIN to a derived table.
-- -----------------------------------------------------------------------------
SELECT d.district_name,
       SUM(s.status_code = 'AVAILABLE')                                       AS available,
       SUM(s.status_code = 'UNDER_OFFER')                                     AS under_offer,
       SUM(s.status_code = 'SOLD')                                            AS sold,
       SUM(s.status_code = 'WITHDRAWN')                                       AS withdrawn,
       SUM(CASE WHEN s.status_code = 'AVAILABLE' THEN p.list_price ELSE 0 END) AS available_stock_eur,
       ROUND(AVG(p.list_price / p.area_sqm), 0)                               AS avg_list_eur_per_sqm,
       ROUND(AVG(sold.sale_amount / p.area_sqm), 0)                           AS avg_achieved_eur_per_sqm,
       ROUND(100 * SUM(s.status_code = 'SOLD') / tot.all_sold, 1)             AS share_of_all_sales_pct
FROM property p
JOIN property_status s ON s.status_id   = p.status_id
JOIN district        d ON d.district_id = p.district_id
LEFT JOIN (SELECT property_id, sale_amount FROM sale_transaction WHERE stage = 'CLOSED') sold
       ON sold.property_id = p.property_id
CROSS JOIN (SELECT COUNT(*) AS all_sold FROM sale_transaction WHERE stage = 'CLOSED') tot
GROUP BY d.district_name, tot.all_sold
ORDER BY available_stock_eur DESC;

-- -----------------------------------------------------------------------------
-- Q8. Data-governance control: should always return zero rows
-- Question : Does any property status disagree with its deals, or does any
--            deal amount look like a typo? This is the check that used to be
--            done by eye across two spreadsheets.
-- Used by  : Data owner; scheduled daily, alert if any row comes back.
-- Shows    : UNION ALL of rule checks, EXISTS / NOT EXISTS, correlated
--            subqueries.
-- -----------------------------------------------------------------------------
SELECT 'Status disagrees with deals' AS issue,
       p.property_id,
       s.status_code                  AS detail
FROM property p
JOIN property_status s ON s.status_id = p.status_id
WHERE (s.status_code = 'SOLD'
          AND NOT EXISTS (SELECT 1 FROM sale_transaction t WHERE t.property_id = p.property_id AND t.stage = 'CLOSED'))
   OR (s.status_code = 'UNDER_OFFER'
          AND NOT EXISTS (SELECT 1 FROM sale_transaction t WHERE t.property_id = p.property_id AND t.stage = 'OFFER'))
   OR (s.status_code IN ('AVAILABLE', 'WITHDRAWN')
          AND EXISTS (SELECT 1 FROM sale_transaction t WHERE t.property_id = p.property_id AND t.stage IN ('OFFER', 'CLOSED')))
UNION ALL
SELECT 'Deal amount far from list price',
       t.property_id,
       CONCAT('deal ', t.transaction_id, ': ', t.sale_amount, ' vs list ', p.list_price)
FROM sale_transaction t
JOIN property p ON p.property_id = t.property_id
WHERE t.sale_amount NOT BETWEEN p.list_price * 0.5 AND p.list_price * 1.5
UNION ALL
SELECT 'Deal handled by an agent who has left', t.property_id, CONCAT('deal ', t.transaction_id)
FROM sale_transaction t
JOIN agent a ON a.agent_id = t.agent_id
WHERE t.stage = 'OFFER' AND a.is_active = FALSE;
