-- ============================================================================
-- Pipeline Health: nightly transform
-- Populates fact_account_pipeline_health from the two staging tables.
--
-- Pre-aggregate BOTH sides before joining. stg_crm_deals and
-- stg_campaign_touches are both many-rows-per-account; joining them directly
-- multiplies rows (this is exactly the bug Question 2 is about), so each
-- side is rolled up to account grain first and only then joined 1:1.
--
-- Uses MERGE so re-running the same night's load twice doesn't duplicate
-- rows -- delete-then-insert would also work, MERGE just makes the
-- upsert-by-key intent explicit.
-- ============================================================================

DECLARE @load_date DATE = CAST(GETDATE() AS DATE);

WITH deal_rollup AS (
    SELECT
        account_id,
        SUM(CASE WHEN stage NOT IN ('Closed Won', 'Closed Lost')
                 THEN 1 ELSE 0 END)                                    AS open_deal_count,
        SUM(CASE WHEN stage NOT IN ('Closed Won', 'Closed Lost')
                 THEN ISNULL(deal_value, 0) ELSE 0 END)                AS open_pipeline_value,
        SUM(CASE WHEN stage = 'Closed Won'  THEN ISNULL(deal_value, 0) ELSE 0 END) AS won_value_ytd,
        SUM(CASE WHEN stage = 'Closed Lost' THEN ISNULL(deal_value, 0) ELSE 0 END) AS lost_value_ytd
    FROM stg_crm_deals
    WHERE account_id IS NOT NULL          -- orphan rows are quarantined upstream, not here
    GROUP BY account_id
),
touch_rollup AS (
    SELECT
        account_id,
        COUNT(*)         AS touch_count_90d,
        MAX(touch_date)  AS last_touch_date
    FROM stg_campaign_touches
    WHERE touch_date >= DATEADD(DAY, -90, CAST(GETDATE() AS DATE))   -- sargable range, not a function on the column
    GROUP BY account_id
),
combined AS (
    SELECT
        d.account_id,
        d.open_deal_count,
        d.open_pipeline_value,
        d.won_value_ytd,
        d.lost_value_ytd,
        ISNULL(t.touch_count_90d, 0)   AS touch_count_90d,
        t.last_touch_date,
        -- DERIVED METRIC: this account's share of total open pipeline
        -- across the whole portfolio. NULLIF guards the all-zero edge case
        -- (no open pipeline anywhere) so we return 0 instead of dividing by 0.
        CASE
            WHEN SUM(d.open_pipeline_value) OVER () = 0 THEN 0
            ELSE ROUND(
                d.open_pipeline_value * 100.0
                / NULLIF(SUM(d.open_pipeline_value) OVER (), 0), 4)
        END AS pct_of_portfolio_open_pipeline
    FROM deal_rollup d
    LEFT JOIN touch_rollup t ON t.account_id = d.account_id
)
MERGE fact_account_pipeline_health AS target
USING (SELECT *, @load_date AS load_date FROM combined) AS source
    ON target.account_id = source.account_id AND target.load_date = source.load_date
WHEN MATCHED THEN
    UPDATE SET
        open_deal_count = source.open_deal_count,
        open_pipeline_value = source.open_pipeline_value,
        won_value_ytd = source.won_value_ytd,
        lost_value_ytd = source.lost_value_ytd,
        touch_count_90d = source.touch_count_90d,
        last_touch_date = source.last_touch_date,
        pct_of_portfolio_open_pipeline = source.pct_of_portfolio_open_pipeline
WHEN NOT MATCHED THEN
    INSERT (account_id, open_deal_count, open_pipeline_value, won_value_ytd,
            lost_value_ytd, touch_count_90d, last_touch_date,
            pct_of_portfolio_open_pipeline, load_date)
    VALUES (source.account_id, source.open_deal_count, source.open_pipeline_value,
            source.won_value_ytd, source.lost_value_ytd, source.touch_count_90d,
            source.last_touch_date, source.pct_of_portfolio_open_pipeline, source.load_date);
