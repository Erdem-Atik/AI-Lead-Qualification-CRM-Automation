-- AI Lead Qualification & CRM Automation: PostgreSQL schema (tested on Supabase)

CREATE TABLE companies (
    id           SERIAL PRIMARY KEY,
    name         VARCHAR(255) NOT NULL,
    domain       VARCHAR(255) UNIQUE,          -- company matching key
    industry     VARCHAR(120),
    company_size VARCHAR(50),                  -- small | medium | enterprise | unknown
    hubspot_id   VARCHAR(50),                  -- HubSpot company id (reused on repeat leads)
    created_at   TIMESTAMPTZ DEFAULT now(),
    updated_at   TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE contacts (
    id         SERIAL PRIMARY KEY,
    company_id INTEGER REFERENCES companies(id),
    full_name  VARCHAR(255),
    email      VARCHAR(255) UNIQUE NOT NULL,   -- contact matching key
    phone      VARCHAR(50),
    hubspot_id VARCHAR(50),
    created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE leads (
    id              SERIAL PRIMARY KEY,
    company_id      INTEGER REFERENCES companies(id),
    contact_id      INTEGER REFERENCES contacts(id),
    project_type    VARCHAR(255),
    budget_range    VARCHAR(100),
    timeline        VARCHAR(100),
    requirements    TEXT,
    raw_message     TEXT,
    ai_confidence   NUMERIC(4,3),              -- share of extracted fields that are filled (0-1)
    status          VARCHAR(30) DEFAULT 'pending', -- pending | converted | rejected
    hubspot_deal_id VARCHAR(50),
    source_channel  VARCHAR(50),               -- web_form | api | ...
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE lead_scores (
    id              SERIAL PRIMARY KEY,
    lead_id         INTEGER REFERENCES leads(id),
    budget_score    INTEGER,
    urgency_score   INTEGER,
    company_score   INTEGER,
    fit_score       INTEGER,
    total_score     INTEGER,                   -- 0-100
    scoring_version VARCHAR(20),
    created_at      TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE interactions (
    id               SERIAL PRIMARY KEY,
    lead_id          INTEGER REFERENCES leads(id),
    interaction_type VARCHAR(50),              -- ai_extraction | human_approval | notification_sent
    detail           TEXT,
    created_at       TIMESTAMPTZ DEFAULT now()
);

-- Reserved for a later phase (scheduled follow-ups); not used by the current workflow.
CREATE TABLE followups (
    id            SERIAL PRIMARY KEY,
    lead_id       INTEGER REFERENCES leads(id),
    followup_type VARCHAR(50),
    scheduled_at  TIMESTAMPTZ,
    sent_at       TIMESTAMPTZ,
    status        VARCHAR(30) DEFAULT 'scheduled',
    created_at    TIMESTAMPTZ DEFAULT now()
);

-- Scoring rubric lives in the database; the workflow falls back to built-in defaults if a row is missing.
CREATE TABLE scoring_rules (
    id            SERIAL PRIMARY KEY,
    rule_name     VARCHAR(50),                 -- budget | urgency | company_size | product_fit
    max_points    INTEGER,
    weight_config JSONB,
    version       VARCHAR(20) DEFAULT 'v1',
    is_active     BOOLEAN DEFAULT true
);

INSERT INTO scoring_rules (rule_name, max_points, weight_config, version) VALUES
('budget',       30, '{"high": 30, "medium": 15, "low": 5}', 'v1'),
('urgency',      20, '{"immediate": 20, "this_quarter": 10, "exploring": 3}', 'v1'),
('company_size', 20, '{"enterprise": 20, "medium": 12, "small": 5}', 'v1'),
('product_fit',  30, '{"exact_match": 30, "partial_match": 15, "poor_match": 0}', 'v1');
