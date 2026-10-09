-- =====================================================================
-- Netflix Customer Intelligence & AI Analytics Copilot
-- MySQL 8.0 schema for the CLEANED tables in data/processed/
--
-- Re-runnable: tables are dropped first (children before parents).
-- Column lists match the cleaned CSVs exactly, including the flag
-- columns added by the cleaning step (age_imputed, amount_clean, ...).
-- =====================================================================

DROP TABLE IF EXISTS churn_labels;
DROP TABLE IF EXISTS customer_feedback;
DROP TABLE IF EXISTS support_tickets;
DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS viewing_activity;
DROP TABLE IF EXISTS content;
DROP TABLE IF EXISTS subscriptions;
DROP TABLE IF EXISTS subscription_plans;
DROP TABLE IF EXISTS customers;

-- 1. customers (hub table) ---------------------------------------------
CREATE TABLE customers (
    customer_id          VARCHAR(12)  NOT NULL,
    first_name           VARCHAR(50),
    last_name            VARCHAR(50),
    age                  SMALLINT     NOT NULL,
    gender               VARCHAR(25),
    country              VARCHAR(60)  NOT NULL,
    city                 VARCHAR(60)  NOT NULL,
    registration_date    DATE,
    acquisition_channel  VARCHAR(50),
    customer_segment     VARCHAR(30),
    preferred_language   VARCHAR(30)  NOT NULL,
    country_imputed      BOOLEAN      NOT NULL DEFAULT FALSE,
    age_imputed          BOOLEAN      NOT NULL DEFAULT FALSE,
    PRIMARY KEY (customer_id),
    KEY idx_customers_country (country),
    KEY idx_customers_segment (customer_segment)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 2. subscription_plans ------------------------------------------------
CREATE TABLE subscription_plans (
    plan_id         VARCHAR(10)   NOT NULL,
    plan_name       VARCHAR(30)   NOT NULL,
    monthly_price   DECIMAL(6,2)  NOT NULL,
    video_quality   VARCHAR(30),
    max_devices     SMALLINT,
    advertisements  VARCHAR(5),
    PRIMARY KEY (plan_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 3. subscriptions -----------------------------------------------------
CREATE TABLE subscriptions (
    subscription_id          VARCHAR(12)   NOT NULL,
    customer_id              VARCHAR(12)   NOT NULL,
    plan_id                  VARCHAR(10)   NOT NULL,
    subscription_start_date  DATE          NOT NULL,
    subscription_end_date    DATE,
    subscription_status      VARCHAR(20),
    auto_renew               BOOLEAN,
    cancellation_date        DATE,
    cancellation_reason      VARCHAR(80),
    monthly_price            DECIMAL(6,2),
    effective_end_date       DATE,
    is_current               BOOLEAN       NOT NULL DEFAULT FALSE,
    cancel_before_start      BOOLEAN       NOT NULL DEFAULT FALSE,
    PRIMARY KEY (subscription_id),
    KEY idx_subscriptions_customer (customer_id),
    KEY idx_subscriptions_plan (plan_id),
    KEY idx_subscriptions_status (subscription_status),
    CONSTRAINT fk_subscriptions_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id),
    CONSTRAINT fk_subscriptions_plan FOREIGN KEY (plan_id)
        REFERENCES subscription_plans (plan_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 4. content -----------------------------------------------------------
CREATE TABLE content (
    content_id          VARCHAR(10)   NOT NULL,
    title               VARCHAR(150)  NOT NULL,
    content_type        VARCHAR(30),
    genre               VARCHAR(30),
    release_year        SMALLINT,
    duration_minutes    SMALLINT,
    content_language    VARCHAR(30),
    production_country  VARCHAR(60),
    maturity_rating     VARCHAR(10),
    PRIMARY KEY (content_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 5. viewing_activity (largest engagement table) -----------------------
CREATE TABLE viewing_activity (
    viewing_id                VARCHAR(14)   NOT NULL,
    customer_id               VARCHAR(12)   NOT NULL,
    content_id                VARCHAR(10)   NOT NULL,
    viewing_date              DATE          NOT NULL,
    watch_duration_minutes    SMALLINT,
    completion_percentage     DECIMAL(5,2),
    device_type               VARCHAR(30),
    login_location            VARCHAR(60),
    session_duration_minutes  SMALLINT,
    completion_imputed        BOOLEAN       NOT NULL DEFAULT FALSE,
    watch_duration_raw        SMALLINT,
    watch_outlier             BOOLEAN       NOT NULL DEFAULT FALSE,
    session_adjusted          BOOLEAN       NOT NULL DEFAULT FALSE,
    PRIMARY KEY (viewing_id),
    KEY idx_viewing_customer (customer_id),
    KEY idx_viewing_content (content_id),
    KEY idx_viewing_date (viewing_date),
    CONSTRAINT fk_viewing_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id),
    CONSTRAINT fk_viewing_content FOREIGN KEY (content_id)
        REFERENCES content (content_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 6. payments (subscription_id is now resolved, so it is a real FK) ----
CREATE TABLE payments (
    payment_id              VARCHAR(14)   NOT NULL,
    customer_id             VARCHAR(12)   NOT NULL,
    subscription_id         VARCHAR(12)   NOT NULL,
    payment_date            DATE          NOT NULL,
    amount                  DECIMAL(7,2),
    amount_clean            DECIMAL(7,2),
    amount_anomaly          BOOLEAN       NOT NULL DEFAULT FALSE,
    in_subscription_window  BOOLEAN       NOT NULL DEFAULT TRUE,
    payment_method          VARCHAR(30),
    payment_status          VARCHAR(15),
    failed_payment_reason   VARCHAR(60),
    PRIMARY KEY (payment_id),
    KEY idx_payments_customer (customer_id),
    KEY idx_payments_date (payment_date),
    KEY idx_payments_status (payment_status),
    KEY idx_payments_subscription (subscription_id),
    CONSTRAINT fk_payments_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id),
    CONSTRAINT fk_payments_subscription FOREIGN KEY (subscription_id)
        REFERENCES subscriptions (subscription_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 7. support_tickets ---------------------------------------------------
CREATE TABLE support_tickets (
    ticket_id                    VARCHAR(12)   NOT NULL,
    customer_id                  VARCHAR(12)   NOT NULL,
    ticket_date                  DATE,
    issue_category               VARCHAR(40),
    issue_subcategory            VARCHAR(60),
    priority                     VARCHAR(15),
    ticket_status                VARCHAR(15),
    resolution_time_hours        DECIMAL(6,1),
    customer_satisfaction_score  SMALLINT,
    ticket_description           TEXT,
    support_agent_id             VARCHAR(10),
    ticket_date_invalid          BOOLEAN       NOT NULL DEFAULT FALSE,
    PRIMARY KEY (ticket_id),
    KEY idx_tickets_customer (customer_id),
    KEY idx_tickets_category (issue_category),
    KEY idx_tickets_date (ticket_date),
    CONSTRAINT fk_tickets_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 8. customer_feedback -------------------------------------------------
CREATE TABLE customer_feedback (
    feedback_id          VARCHAR(12)   NOT NULL,
    customer_id          VARCHAR(12)   NOT NULL,
    feedback_date        DATE,
    rating               SMALLINT,
    feedback_text        TEXT,
    sentiment_label      VARCHAR(15),
    sentiment_corrected  VARCHAR(15),
    sentiment_mismatch   BOOLEAN       NOT NULL DEFAULT FALSE,
    PRIMARY KEY (feedback_id),
    KEY idx_feedback_customer (customer_id),
    KEY idx_feedback_sentiment (sentiment_label),
    CONSTRAINT fk_feedback_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 9. churn_labels (1:1 outcome table) ----------------------------------
CREATE TABLE churn_labels (
    customer_id   VARCHAR(12)  NOT NULL,
    churned       BOOLEAN      NOT NULL,
    churn_date    DATE,
    churn_reason  VARCHAR(80),
    PRIMARY KEY (customer_id),
    CONSTRAINT fk_churn_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;