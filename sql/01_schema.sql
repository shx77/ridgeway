-- ============================================================================
-- Pipeline Health: schema
-- Target grain: one row per account_id per load date (SCD-2-lite via snapshot,
-- not a running total table -- see notes below on why).
-- ============================================================================

-- Staging tables (assumed to already exist per the brief; included here so
-- this script is runnable standalone against a fresh database).
CREATE TABLE stg_crm_deals (
    deal_id         VARCHAR(20)     NOT NULL,
    account_id      VARCHAR(20)     NULL,
    stage           VARCHAR(30)     NOT NULL,
    deal_value      DECIMAL(18,2)   NULL,
    opened_date     DATE            NULL,
    close_date      DATE            NULL,
    updated_date    DATE            NOT NULL
);

CREATE TABLE stg_campaign_touches (
    touch_id        VARCHAR(20)     NOT NULL,
    account_id      VARCHAR(20)     NOT NULL,
    channel         VARCHAR(30)     NOT NULL,
    touch_date      DATE            NOT NULL
);

-- ============================================================================
-- Target table: fact_account_pipeline_health
--
-- GRAIN: one row per account_id, refreshed nightly (full snapshot, not
-- incremental accumulation -- see ADF sketch for why full-refresh is fine
-- at this data volume, and what changes if it stops being fine).
--
-- Deliberately NOT deal-grain: leadership asked for a "Pipeline Health view
-- ... per account", and analysts want to compare accounts against the
-- portfolio, not compare individual deals. Account grain also sidesteps the
-- exact fan-out bug that Question 2 is about.
--
-- COLUMNS:
--   account_id                   -- natural key from the CRM
--   open_deal_count               -- deals not yet closed (won or lost)
--   open_pipeline_value           -- sum of deal_value where stage is open.
--                                    "Pipeline" excludes closed deals on
--                                    purpose -- a won or lost deal isn't
--                                    pipeline anymore, it's an outcome.
--   won_value_ytd                 -- sum of deal_value where Closed Won
--   lost_value_ytd                -- sum of deal_value where Closed Lost
--   touch_count_90d                -- campaign touches in the trailing 90 days
--   last_touch_date               -- most recent touch, any channel
--   pct_of_portfolio_open_pipeline -- DERIVED METRIC: this account's open
--                                    pipeline as a % of total open pipeline
--                                    across all accounts. This is what lets
--                                    the dashboard say "this account is X%
--                                    of everything we're chasing right now"
--                                    -- i.e. positions each account against
--                                    the rest of the portfolio, as asked.
--   load_date                     -- snapshot date, for trending over time
--
-- GOVERNANCE / ACCESS NOTES TO RAISE BEFORE GO-LIVE:
--   1. deal_value is commercial-sensitive. Row-level security or a separate
--      view without deal_value should gate who sees raw pipeline $ vs who
--      just sees touch/engagement metrics -- not every stakeholder consuming
--      "Pipeline Health" needs to see deal-level revenue.
--   2. account_id is the join key between two systems owned by different
--      teams (CRM vs campaign platform). Need an agreed source of truth for
--      what counts as a valid account_id and a process for when they drift
--      (e.g. a CRM account renamed/merged but the campaign platform wasn't
--      updated) -- otherwise touch_count silently under-reports for those
--      accounts with no error raised anywhere.
--   3. Quarantined rows (see validate_crm.py) need an owner and an SLA --
--      if nobody looks at the quarantine table, silently-dropped deals
--      quietly understate pipeline and nobody notices until someone asks
--      "why does this account look smaller than I expected".
--   4. This table blends CRM data (deal_value, stage) with marketing data
--      (touches). If marketing and sales report to different leaders,
--      confirm both are comfortable with a single blended view before it
--      goes in front of the client -- attribution disputes ("was it the
--      campaign or the rep") are a people problem this table will surface.
-- ============================================================================
CREATE TABLE fact_account_pipeline_health (
    account_id                      VARCHAR(20)     NOT NULL,
    open_deal_count                 INT             NOT NULL,
    open_pipeline_value             DECIMAL(18,2)   NOT NULL,
    won_value_ytd                   DECIMAL(18,2)   NOT NULL,
    lost_value_ytd                  DECIMAL(18,2)   NOT NULL,
    touch_count_90d                 INT             NOT NULL,
    last_touch_date                 DATE            NULL,
    pct_of_portfolio_open_pipeline  DECIMAL(9,4)    NOT NULL,
    load_date                       DATE            NOT NULL,
    CONSTRAINT pk_fact_account_pipeline_health PRIMARY KEY (account_id, load_date)
);
