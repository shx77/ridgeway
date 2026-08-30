-- ============================================================================
-- Q2.1: Original query, annotated in place with what's wrong
-- ============================================================================
/*
SELECT d.account_id, d.deal_value, COUNT(t.touch_id) AS touch_count
FROM stg_crm_deals d
LEFT JOIN stg_campaign_touches t
    ON d.account_id = t.account_id
WHERE YEAR(d.updated_date) = 2026
GROUP BY d.account_id, d.deal_value
*/

-- Three separate problems, not one:
--
-- 1) FAN-OUT: stg_crm_deals and stg_campaign_touches are both many-rows-
--    per-account. Joining them directly multiplies rows -- an account with
--    3 deals and 10 touches produces 30 joined rows, so COUNT(t.touch_id)
--    counts the same touches multiple times, once per deal. This is why the
--    dashboard's touch counts don't match the campaign platform: they're
--    inflated by however many deals that account happens to have.
--
-- 2) WRONG GRAIN: GROUP BY d.account_id, d.deal_value groups by VALUE, not
--    by deal_id. Two different deals on the same account that happen to
--    have the same deal_value silently collapse into one group -- losing a
--    deal and compounding the touch-count inflation from (1) further. This
--    is a second, independent bug from the fan-out and would still corrupt
--    results even if the join were fixed.
--
-- 3) NON-SARGABLE FILTER: YEAR(d.updated_date) = 2026 wraps the column in a
--    function, so SQL Server can't seek an index on updated_date -- it has
--    to evaluate YEAR() on every row first, forcing a full scan. This is
--    the main driver of the 2-hour runtime.

-- ============================================================================
-- Q2.1 fixed: same shape, minimal diff, correct output
-- ============================================================================
SELECT
    d.account_id,
    SUM(ISNULL(d.deal_value, 0))       AS total_deal_value,   -- CHANGED: SUM not raw column -- see grain note below
    ISNULL(t.touch_count, 0)           AS touch_count
FROM stg_crm_deals d
LEFT JOIN (
    -- CHANGED: touches are pre-aggregated to account grain BEFORE the join,
    -- so the join is now 1-to-1 and can't multiply rows.
    SELECT account_id, COUNT(*) AS touch_count
    FROM stg_campaign_touches
    GROUP BY account_id
) t ON t.account_id = d.account_id
WHERE d.updated_date >= '2026-01-01'
  AND d.updated_date <  '2027-01-01'   -- CHANGED: range predicate instead of YEAR() -- sargable, index-usable
GROUP BY d.account_id, ISNULL(t.touch_count, 0)  -- CHANGED: group by account_id only in intent;
                                                   -- keeping deal_value out of GROUP BY fixes bug (2)
;

-- ============================================================================
-- Q2.2: rewrite that scales to a much larger touch history
-- ============================================================================
-- Pre-aggregating in a subquery (above) works, but at real scale -- millions
-- of touch rows per account over years -- COUNT(*) still scans the whole
-- touch table every night even though most of that history never changes.
-- The better shape is an incremental rollup table that's appended to daily,
-- so the nightly job only touches yesterday's new rows instead of the full
-- history.

-- One-time backfill (run once):
-- SELECT account_id, touch_date, COUNT(*) AS daily_touch_count
-- INTO stg_touch_daily_rollup
-- FROM stg_campaign_touches
-- GROUP BY account_id, touch_date;

-- Nightly incremental step (run every night, only processes new rows):
-- INSERT INTO stg_touch_daily_rollup (account_id, touch_date, daily_touch_count)
-- SELECT account_id, touch_date, COUNT(*)
-- FROM stg_campaign_touches
-- WHERE touch_date = CAST(GETDATE() AS DATE) - 1   -- yesterday's landed touches only
-- GROUP BY account_id, touch_date;

SELECT
    d.account_id,
    SUM(ISNULL(d.deal_value, 0))          AS total_deal_value,
    ISNULL(SUM(r.daily_touch_count), 0)   AS touch_count
FROM stg_crm_deals d
LEFT JOIN stg_touch_daily_rollup r ON r.account_id = d.account_id
WHERE d.updated_date >= '2026-01-01'
  AND d.updated_date <  '2027-01-01'
GROUP BY d.account_id;

-- TRADE-OFF: this moves cost from query-time to load-time and adds a table
-- to maintain (schema drift, backfill logic, one more thing that can break
-- silently if the nightly step is skipped). It's worth it once touch volume
-- is large enough that re-scanning full history nightly is the bottleneck --
-- not worth the added moving part at the data volumes implied by the brief.
