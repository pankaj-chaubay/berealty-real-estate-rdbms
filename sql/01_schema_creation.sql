-- =============================================================================
-- Berealty Real Estate RDBMS
-- 01_schema_creation.sql : database, tables, keys, constraints and indexes
--
-- Target  : MySQL 8.0.16 or later (CHECK constraints are enforced from 8.0.16)
-- Model   : Third normal form. Every non-key column depends on the key, the
--           whole key and nothing but the key.
-- Re-run  : Safe. The script drops and recreates the database.
-- =============================================================================

DROP DATABASE IF EXISTS berealty;
CREATE DATABASE berealty
    DEFAULT CHARACTER SET utf8mb4
    DEFAULT COLLATE utf8mb4_0900_ai_ci;
USE berealty;

-- -----------------------------------------------------------------------------
-- Lookup tables
-- Small, stable code lists. Kept separate so a label can change in one place
-- and every property or transaction keeps pointing at the same id.
-- -----------------------------------------------------------------------------

CREATE TABLE property_status (
    status_id      TINYINT UNSIGNED NOT NULL,
    status_code    VARCHAR(20)      NOT NULL,
    description    VARCHAR(100)     NOT NULL,
    CONSTRAINT pk_property_status PRIMARY KEY (status_id),
    CONSTRAINT uq_property_status_code UNIQUE (status_code),
    CONSTRAINT ck_property_status_code CHECK (status_code = UPPER(status_code))
) ENGINE = InnoDB COMMENT = 'Lifecycle states of a listing: AVAILABLE, UNDER_OFFER, SOLD, WITHDRAWN';

CREATE TABLE property_type (
    property_type_id TINYINT UNSIGNED NOT NULL,
    type_name        VARCHAR(30)      NOT NULL,
    segment          VARCHAR(20)      NOT NULL,
    CONSTRAINT pk_property_type PRIMARY KEY (property_type_id),
    CONSTRAINT uq_property_type_name UNIQUE (type_name),
    CONSTRAINT ck_property_type_segment CHECK (segment IN ('RESIDENTIAL', 'COMMERCIAL'))
) ENGINE = InnoDB COMMENT = 'Apartment, house, office and so on, grouped into residential or commercial';

CREATE TABLE district (
    district_id   SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
    district_name VARCHAR(60)       NOT NULL,
    city          VARCHAR(60)       NOT NULL DEFAULT 'Berlin',
    CONSTRAINT pk_district PRIMARY KEY (district_id),
    CONSTRAINT uq_district UNIQUE (city, district_name)
) ENGINE = InnoDB COMMENT = 'City districts (Bezirke). Holding them once avoids spelling variants in addresses';

-- -----------------------------------------------------------------------------
-- People
-- -----------------------------------------------------------------------------

CREATE TABLE agent (
    agent_id    INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    first_name  VARCHAR(50)   NOT NULL,
    last_name   VARCHAR(50)   NOT NULL,
    email       VARCHAR(120)  NOT NULL,
    phone       VARCHAR(30)       NULL,
    hire_date   DATE          NOT NULL,
    is_active   BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_agent PRIMARY KEY (agent_id),
    CONSTRAINT uq_agent_email UNIQUE (email),
    CONSTRAINT ck_agent_email CHECK (email LIKE '%_@_%._%')
) ENGINE = InnoDB COMMENT = 'Sales agents employed by Berealty';

CREATE TABLE client (
    client_id    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    client_type  VARCHAR(12)  NOT NULL DEFAULT 'INDIVIDUAL',
    first_name   VARCHAR(50)      NULL,
    last_name    VARCHAR(50)      NULL,
    company_name VARCHAR(120)     NULL,
    email        VARCHAR(120) NOT NULL,
    phone        VARCHAR(30)      NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT pk_client PRIMARY KEY (client_id),
    CONSTRAINT uq_client_email UNIQUE (email),
    CONSTRAINT ck_client_email CHECK (email LIKE '%_@_%._%'),
    CONSTRAINT ck_client_type CHECK (client_type IN ('INDIVIDUAL', 'COMMERCIAL')),
    -- A person needs a name; a company needs a company name.
    CONSTRAINT ck_client_identity CHECK (
        (client_type = 'INDIVIDUAL' AND first_name IS NOT NULL AND last_name IS NOT NULL)
        OR (client_type = 'COMMERCIAL' AND company_name IS NOT NULL)
    )
) ENGINE = InnoDB COMMENT = 'Buyers: households and companies';

-- -----------------------------------------------------------------------------
-- Property listings
-- -----------------------------------------------------------------------------

CREATE TABLE property (
    property_id       INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    street_address    VARCHAR(150)      NOT NULL,
    postal_code       CHAR(5)           NOT NULL,
    district_id       SMALLINT UNSIGNED NOT NULL,
    property_type_id  TINYINT UNSIGNED  NOT NULL,
    area_sqm          DECIMAL(8,2)      NOT NULL,
    rooms             DECIMAL(3,1)          NULL,
    list_price        DECIMAL(12,2)     NOT NULL,
    status_id         TINYINT UNSIGNED  NOT NULL DEFAULT 1,
    listing_agent_id  INT UNSIGNED          NULL COMMENT 'NULL = not yet assigned to an agent',
    listed_date       DATE              NOT NULL,
    created_at        TIMESTAMP         NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP         NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT pk_property PRIMARY KEY (property_id),
    CONSTRAINT uq_property_address UNIQUE (street_address, postal_code),
    CONSTRAINT ck_property_postal_code CHECK (postal_code REGEXP '^[0-9]{5}$'),
    CONSTRAINT ck_property_area CHECK (area_sqm > 0),
    CONSTRAINT ck_property_rooms CHECK (rooms IS NULL OR rooms > 0),
    CONSTRAINT ck_property_price CHECK (list_price > 0),
    -- Lookups are never deleted while in use (RESTRICT); id changes flow through (CASCADE).
    CONSTRAINT fk_property_status FOREIGN KEY (status_id)
        REFERENCES property_status (status_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_property_type FOREIGN KEY (property_type_id)
        REFERENCES property_type (property_type_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_property_district FOREIGN KEY (district_id)
        REFERENCES district (district_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    -- If an agent record is removed, the listing stays and becomes unassigned.
    CONSTRAINT fk_property_agent FOREIGN KEY (listing_agent_id)
        REFERENCES agent (agent_id) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE = InnoDB COMMENT = 'One row per listed property';

-- -----------------------------------------------------------------------------
-- Sales transactions
-- One row per deal. A deal moves through stages: OFFER -> CLOSED, or
-- OFFER -> CANCELLED. The property status is derived from these rows by
-- the triggers in 04_triggers_and_automation.sql and is never typed in by hand.
-- -----------------------------------------------------------------------------

CREATE TABLE sale_transaction (
    transaction_id    INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    property_id       INT UNSIGNED  NOT NULL,
    client_id         INT UNSIGNED  NOT NULL,
    agent_id          INT UNSIGNED  NOT NULL,
    stage             VARCHAR(10)   NOT NULL DEFAULT 'OFFER',
    offer_date        DATE          NOT NULL,
    transaction_date  DATE              NULL COMMENT 'Contract (notary) date; set when the deal closes',
    sale_amount       DECIMAL(12,2) NOT NULL,
    commission_rate   DECIMAL(5,4)  NOT NULL DEFAULT 0.0357 COMMENT 'Buyer commission, 3.57% incl. VAT',
    created_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    -- Generated helper column: holds property_id only for closed deals, NULL otherwise.
    -- A UNIQUE index on it means a property can be sold (closed) only once.
    closed_property_id INT UNSIGNED
        GENERATED ALWAYS AS (CASE WHEN stage = 'CLOSED' THEN property_id END) STORED,
    CONSTRAINT pk_sale_transaction PRIMARY KEY (transaction_id),
    CONSTRAINT uq_sale_one_close_per_property UNIQUE (closed_property_id),
    CONSTRAINT ck_sale_stage CHECK (stage IN ('OFFER', 'CLOSED', 'CANCELLED')),
    CONSTRAINT ck_sale_amount CHECK (sale_amount > 0),
    CONSTRAINT ck_sale_commission CHECK (commission_rate BETWEEN 0 AND 0.1),
    CONSTRAINT ck_sale_closed_has_date CHECK (
        (stage = 'CLOSED' AND transaction_date IS NOT NULL)
        OR (stage <> 'CLOSED' AND transaction_date IS NULL)
    ),
    CONSTRAINT ck_sale_dates CHECK (transaction_date IS NULL OR transaction_date >= offer_date),
    -- Financial records are never deleted as a side effect of deleting master data.
    -- ON UPDATE RESTRICT here: MySQL does not allow cascading changes into a column
    -- that feeds a stored generated column (closed_property_id). Ids never change anyway.
    CONSTRAINT fk_sale_property FOREIGN KEY (property_id)
        REFERENCES property (property_id) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_sale_client FOREIGN KEY (client_id)
        REFERENCES client (client_id) ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_sale_agent FOREIGN KEY (agent_id)
        REFERENCES agent (agent_id) ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB COMMENT = 'Offers and completed sales';

-- -----------------------------------------------------------------------------
-- Audit trail
-- Written only by triggers. Answers "when did this listing change status, and
-- who did it" without anyone keeping a separate log.
-- -----------------------------------------------------------------------------

CREATE TABLE property_status_history (
    history_id      BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT,
    property_id     INT UNSIGNED     NOT NULL,
    old_status_id   TINYINT UNSIGNED     NULL,
    new_status_id   TINYINT UNSIGNED NOT NULL,
    changed_at      TIMESTAMP(3)     NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    changed_by      VARCHAR(100)     NOT NULL,
    CONSTRAINT pk_property_status_history PRIMARY KEY (history_id),
    CONSTRAINT fk_history_property FOREIGN KEY (property_id)
        REFERENCES property (property_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_history_old_status FOREIGN KEY (old_status_id)
        REFERENCES property_status (status_id) ON DELETE RESTRICT,
    CONSTRAINT fk_history_new_status FOREIGN KEY (new_status_id)
        REFERENCES property_status (status_id) ON DELETE RESTRICT
) ENGINE = InnoDB COMMENT = 'Append-only log of listing status changes';

-- -----------------------------------------------------------------------------
-- Indexes for the access paths the reports and triggers use most.
-- Foreign key columns are indexed automatically by InnoDB; the composite
-- indexes below cover the common filter + sort combinations.
-- -----------------------------------------------------------------------------

-- Inventory screens: "available listings in a district, cheapest first".
CREATE INDEX ix_property_status_district_price ON property (status_id, district_id, list_price);
-- Workload views: listings per agent by status.
CREATE INDEX ix_property_agent_status ON property (listing_agent_id, status_id);
-- Revenue reports by period.
CREATE INDEX ix_sale_stage_date ON sale_transaction (stage, transaction_date);
-- Agent performance by period.
CREATE INDEX ix_sale_agent_date ON sale_transaction (agent_id, transaction_date);
-- Trigger look-ups: all deals for one property by stage.
CREATE INDEX ix_sale_property_stage ON sale_transaction (property_id, stage);
-- Status timeline per listing.
CREATE INDEX ix_history_property_time ON property_status_history (property_id, changed_at);
