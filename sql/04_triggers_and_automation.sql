-- =============================================================================
-- Berealty Real Estate RDBMS
-- 04_triggers_and_automation.sql : business rules enforced inside the database
--
-- What this replaces: in the spreadsheet process an agent closed a deal in one
-- file and someone had to remember to mark the property "Sold" in another.
-- Here the property status is derived from the deals and kept in step by the
-- database itself, and the rules that used to live in people's heads are
-- checked on every write.
--
-- Rules
--   R1  A property's status follows its deals:
--         a CLOSED deal          -> SOLD
--         an open OFFER          -> UNDER_OFFER
--         no open/closed deal    -> AVAILABLE (or stays WITHDRAWN)
--   R2  A sold or withdrawn property cannot take a new deal.
--   R3  Only one open offer per property at a time.
--   R4  Only active agents can take new deals.
--   R5  An offer cannot be dated before the property was listed.
--   R6  The deal amount must be within +/-50% of the list price (typo guard).
--   R7  CLOSED and CANCELLED are final; the property of a deal cannot change.
--   R8  Deals are never deleted. Cancel them instead, so the history stays.
--   R9  Nobody can set a property to SOLD or UNDER_OFFER by hand; only the
--       deal triggers can. Manual changes are limited to AVAILABLE <-> WITHDRAWN.
--   R10 Every status change is written to property_status_history with
--       the time and the database user.
--
-- Target: MySQL 8.0. Run after 01 and 02. Re-runnable (drops objects first).
-- Errors are raised with SQLSTATE '45000' and a message that says what to do.
-- =============================================================================

USE berealty;

DROP TRIGGER IF EXISTS trg_sale_transaction_bi;
DROP TRIGGER IF EXISTS trg_sale_transaction_ai;
DROP TRIGGER IF EXISTS trg_sale_transaction_bu;
DROP TRIGGER IF EXISTS trg_sale_transaction_au;
DROP TRIGGER IF EXISTS trg_sale_transaction_bd;
DROP TRIGGER IF EXISTS trg_property_ai;
DROP TRIGGER IF EXISTS trg_property_bu;
DROP TRIGGER IF EXISTS trg_property_au;
DROP PROCEDURE IF EXISTS sp_sync_property_status;
DROP PROCEDURE IF EXISTS sp_assert_deal_allowed;
DROP FUNCTION IF EXISTS fn_status_id;

DELIMITER $$

-- -----------------------------------------------------------------------------
-- fn_status_id: status code -> id, so the logic below reads 'SOLD', not 2.
-- -----------------------------------------------------------------------------
CREATE FUNCTION fn_status_id(p_code VARCHAR(20))
RETURNS TINYINT UNSIGNED
READS SQL DATA
NOT DETERMINISTIC
BEGIN
    DECLARE v_id TINYINT UNSIGNED;
    SELECT status_id INTO v_id FROM property_status WHERE status_code = p_code;
    IF v_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown property status code';
    END IF;
    RETURN v_id;
END$$

-- -----------------------------------------------------------------------------
-- sp_sync_property_status (R1): recompute one property's status from its deals.
-- The session flag @berealty_status_sync tells trg_property_bu that this change
-- comes from the automation, not from a person (R9).
-- -----------------------------------------------------------------------------
CREATE PROCEDURE sp_sync_property_status(IN p_property_id INT UNSIGNED)
MODIFIES SQL DATA
BEGIN
    DECLARE v_current TINYINT UNSIGNED;
    DECLARE v_target  TINYINT UNSIGNED;

    SELECT status_id INTO v_current FROM property WHERE property_id = p_property_id FOR UPDATE;

    IF EXISTS (SELECT 1 FROM sale_transaction
               WHERE property_id = p_property_id AND stage = 'CLOSED') THEN
        SET v_target = fn_status_id('SOLD');
    ELSEIF EXISTS (SELECT 1 FROM sale_transaction
                   WHERE property_id = p_property_id AND stage = 'OFFER') THEN
        SET v_target = fn_status_id('UNDER_OFFER');
    ELSEIF v_current = fn_status_id('WITHDRAWN') THEN
        SET v_target = v_current;
    ELSE
        SET v_target = fn_status_id('AVAILABLE');
    END IF;

    IF v_target <> v_current THEN
        SET @berealty_status_sync = 1;  -- consumed by trg_property_bu
        UPDATE property SET status_id = v_target WHERE property_id = p_property_id;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- sp_assert_deal_allowed: checks shared by INSERT and UPDATE (R2-R6).
-- p_transaction_id is NULL for a new deal.
-- -----------------------------------------------------------------------------
CREATE PROCEDURE sp_assert_deal_allowed(
    IN p_transaction_id INT UNSIGNED,
    IN p_property_id    INT UNSIGNED,
    IN p_agent_id       INT UNSIGNED,
    IN p_stage          VARCHAR(10),
    IN p_offer_date     DATE,
    IN p_amount         DECIMAL(12,2),
    IN p_check_agent    BOOLEAN
)
READS SQL DATA
BEGIN
    DECLARE v_status      TINYINT UNSIGNED;
    DECLARE v_list_price  DECIMAL(12,2);
    DECLARE v_listed_date DATE;
    DECLARE v_open_offer  INT UNSIGNED;
    DECLARE v_msg         VARCHAR(255);

    SELECT status_id, list_price, listed_date
      INTO v_status, v_list_price, v_listed_date
      FROM property WHERE property_id = p_property_id;

    IF v_status IS NULL THEN
        SET v_msg = CONCAT('Property ', p_property_id, ' does not exist.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- R2: a sold property cannot be sold again; a withdrawn one is off the market.
    IF p_stage IN ('OFFER', 'CLOSED') AND v_status = fn_status_id('SOLD')
       AND NOT EXISTS (SELECT 1 FROM sale_transaction
                       WHERE transaction_id = p_transaction_id AND stage = 'CLOSED') THEN
        SET v_msg = CONCAT('Property ', p_property_id, ' is already sold. No new offer or sale can be recorded.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
    IF p_stage IN ('OFFER', 'CLOSED') AND v_status = fn_status_id('WITHDRAWN') THEN
        SET v_msg = CONCAT('Property ', p_property_id, ' is withdrawn. Set it back to AVAILABLE first.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- R3: only one open offer at a time.
    IF p_stage IN ('OFFER', 'CLOSED') THEN
        SELECT MIN(transaction_id) INTO v_open_offer
          FROM sale_transaction
         WHERE property_id = p_property_id
           AND stage = 'OFFER'
           AND (p_transaction_id IS NULL OR transaction_id <> p_transaction_id);
        IF v_open_offer IS NOT NULL THEN
            SET v_msg = CONCAT('Property ', p_property_id, ' already has open offer ', v_open_offer,
                               '. Close or cancel it first.');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    END IF;

    -- R4: inactive agents cannot take new deals.
    IF p_check_agent AND NOT EXISTS (SELECT 1 FROM agent WHERE agent_id = p_agent_id AND is_active) THEN
        SET v_msg = CONCAT('Agent ', p_agent_id, ' is inactive or unknown and cannot take new deals.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- R5: no offer before the listing date.
    IF p_offer_date < v_listed_date THEN
        SET v_msg = CONCAT('Offer date ', p_offer_date, ' is before the listing date ', v_listed_date, '.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    -- R6: typo guard. 812895 typed as 8128953 is caught here.
    IF p_amount NOT BETWEEN v_list_price * 0.5 AND v_list_price * 1.5 THEN
        SET v_msg = CONCAT('Amount ', p_amount, ' is outside 50%-150% of the list price ', v_list_price,
                           '. Check the figure or update the list price first.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$

-- -----------------------------------------------------------------------------
-- sale_transaction triggers
-- -----------------------------------------------------------------------------

CREATE TRIGGER trg_sale_transaction_bi
BEFORE INSERT ON sale_transaction
FOR EACH ROW
BEGIN
    -- Convenience: closing without a date means "closed today".
    IF NEW.stage = 'CLOSED' AND NEW.transaction_date IS NULL THEN
        SET NEW.transaction_date = CURDATE();
    END IF;
    CALL sp_assert_deal_allowed(NULL, NEW.property_id, NEW.agent_id, NEW.stage,
                                NEW.offer_date, NEW.sale_amount, TRUE);
END$$

CREATE TRIGGER trg_sale_transaction_ai
AFTER INSERT ON sale_transaction
FOR EACH ROW
BEGIN
    CALL sp_sync_property_status(NEW.property_id);
END$$

CREATE TRIGGER trg_sale_transaction_bu
BEFORE UPDATE ON sale_transaction
FOR EACH ROW
BEGIN
    DECLARE v_msg VARCHAR(255);

    -- R7: a deal cannot move to another property.
    IF NEW.property_id <> OLD.property_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A deal cannot be moved to another property. Cancel it and record a new one.';
    END IF;

    -- R7: CLOSED and CANCELLED are final.
    IF OLD.stage IN ('CLOSED', 'CANCELLED') AND NEW.stage <> OLD.stage THEN
        SET v_msg = CONCAT('Deal ', OLD.transaction_id, ' is ', OLD.stage, ' and cannot change stage.');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    IF NEW.stage = 'CLOSED' AND NEW.transaction_date IS NULL THEN
        SET NEW.transaction_date = CURDATE();
    END IF;

    -- Re-check the business rules when an open deal is edited or closed.
    -- The agent check applies only if the agent is being changed.
    IF OLD.stage = 'OFFER' AND NEW.stage IN ('OFFER', 'CLOSED') THEN
        CALL sp_assert_deal_allowed(NEW.transaction_id, NEW.property_id, NEW.agent_id, NEW.stage,
                                    NEW.offer_date, NEW.sale_amount, NEW.agent_id <> OLD.agent_id);
    END IF;
END$$

CREATE TRIGGER trg_sale_transaction_au
AFTER UPDATE ON sale_transaction
FOR EACH ROW
BEGIN
    IF NEW.stage <> OLD.stage THEN
        CALL sp_sync_property_status(NEW.property_id);
    END IF;
END$$

CREATE TRIGGER trg_sale_transaction_bd
BEFORE DELETE ON sale_transaction
FOR EACH ROW
BEGIN
    -- R8
    SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Deals are never deleted. Set stage = ''CANCELLED'' instead.';
END$$

-- -----------------------------------------------------------------------------
-- property triggers
-- -----------------------------------------------------------------------------

CREATE TRIGGER trg_property_ai
AFTER INSERT ON property
FOR EACH ROW
BEGIN
    -- R10: the first history row records the listing itself.
    INSERT INTO property_status_history (property_id, old_status_id, new_status_id, changed_by)
    VALUES (NEW.property_id, NULL, NEW.status_id, CURRENT_USER());
END$$

CREATE TRIGGER trg_property_bu
BEFORE UPDATE ON property
FOR EACH ROW
BEGIN
    -- R9: manual status changes are limited to AVAILABLE <-> WITHDRAWN.
    -- The sync flag is a one-shot token: it is consumed here, so it can never
    -- linger in the session and let a later manual update through.
    IF @berealty_status_sync IS NOT NULL THEN
        SET @berealty_status_sync = NULL;
    ELSEIF NEW.status_id <> OLD.status_id THEN
        IF NOT (OLD.status_id IN (fn_status_id('AVAILABLE'), fn_status_id('WITHDRAWN'))
                AND NEW.status_id IN (fn_status_id('AVAILABLE'), fn_status_id('WITHDRAWN'))) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Status SOLD and UNDER_OFFER come from deals. Record or update the deal instead.';
        END IF;
    END IF;
END$$

CREATE TRIGGER trg_property_au
AFTER UPDATE ON property
FOR EACH ROW
BEGIN
    -- R10
    IF NEW.status_id <> OLD.status_id THEN
        INSERT INTO property_status_history (property_id, old_status_id, new_status_id, changed_by)
        VALUES (NEW.property_id, OLD.status_id, NEW.status_id, CURRENT_USER());
    END IF;
END$$

DELIMITER ;
