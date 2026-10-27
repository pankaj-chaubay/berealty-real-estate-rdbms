#!/usr/bin/env bash
# =============================================================================
# Berealty RDBMS test suite.
#
# Rebuilds the database from the scripts in sql/, then checks every business
# rule: each one must accept valid writes and reject invalid ones with the
# expected message. Exit code 0 means every check passed.
#
# Usage:  tests/run_tests.sh            (uses: mysql -uroot)
#         MYSQL="mysql -h 127.0.0.1 -uroot -psecret" tests/run_tests.sh
# =============================================================================
set -u
cd "$(dirname "$0")/.."

MYSQL=${MYSQL:-"mysql -uroot"}
DB=berealty
PASS=0
FAIL=0

run()   { $MYSQL --batch --skip-column-names "$DB" -e "$1" 2>&1; }
ok()    { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n        %s\n' "$1" "$2"; }

expect_ok() {        # name, sql
    local out
    if out=$(run "$2"); then ok "$1"; else bad "$1" "$out"; fi
}
expect_error() {     # name, sql, message fragment
    local out
    if out=$(run "$2"); then bad "$1" "statement succeeded but should have failed"
    elif grep -qi -- "$3" <<<"$out"; then ok "$1"
    else bad "$1" "wrong error: $out"; fi
}
expect_value() {     # name, sql, expected value
    local out
    out=$(run "$2")
    if [[ "$out" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$out'"; fi
}

echo "Building database from sql/ ..."
for f in sql/01_schema_creation.sql sql/02_sample_data.sql sql/04_triggers_and_automation.sql; do
    $MYSQL < "$f" || { echo "Failed to run $f"; exit 1; }
done

echo
echo "Data quality"
expect_value "every property status agrees with its deals" \
  "SELECT COUNT(*) FROM property p
     JOIN property_status s ON s.status_id = p.status_id
    WHERE s.status_code <> CASE
            WHEN EXISTS (SELECT 1 FROM sale_transaction t WHERE t.property_id = p.property_id AND t.stage = 'CLOSED') THEN 'SOLD'
            WHEN EXISTS (SELECT 1 FROM sale_transaction t WHERE t.property_id = p.property_id AND t.stage = 'OFFER')  THEN 'UNDER_OFFER'
            WHEN s.status_code = 'WITHDRAWN' THEN 'WITHDRAWN'
            ELSE 'AVAILABLE' END;" "0"
expect_value "no property has two closed sales" \
  "SELECT COUNT(*) FROM (SELECT property_id FROM sale_transaction WHERE stage = 'CLOSED'
                          GROUP BY property_id HAVING COUNT(*) > 1) x;" "0"

echo
echo "Constraints"
expect_error "negative list price is rejected" \
  "INSERT INTO property (street_address, postal_code, district_id, property_type_id, area_sqm, list_price, listed_date)
   VALUES ('Teststrasse 1', '10115', 1, 1, 50, -1, '2025-01-01');" "ck_property_price"
expect_error "postal code must be five digits" \
  "INSERT INTO property (street_address, postal_code, district_id, property_type_id, area_sqm, list_price, listed_date)
   VALUES ('Teststrasse 1', '1011', 1, 1, 50, 300000, '2025-01-01');" "ck_property_postal_code"
expect_error "duplicate client email is rejected" \
  "INSERT INTO client (first_name, last_name, email) SELECT 'X', 'Y', email FROM client LIMIT 1;" "Duplicate entry"
expect_error "commercial client needs a company name" \
  "INSERT INTO client (client_type, email) VALUES ('COMMERCIAL', 'nobody@example.com');" "ck_client_identity"
expect_error "agent with deals cannot be deleted" \
  "DELETE FROM agent WHERE agent_id = (SELECT agent_id FROM sale_transaction LIMIT 1);" "foreign key constraint fails"
expect_error "status in use cannot be deleted" \
  "DELETE FROM property_status WHERE status_code = 'AVAILABLE';" "foreign key constraint fails"

echo
echo "Automation (setup: a new listing)"
expect_ok "insert a new listing" \
  "INSERT INTO property (property_id, street_address, postal_code, district_id, property_type_id, area_sqm, rooms,
                         list_price, listing_agent_id, listed_date)
   VALUES (900, 'Teststrasse 9', '10115', 1, 1, 72.5, 2.5, 520000, 301, '2025-06-01');"
expect_value "R10 listing writes the first history row" \
  "SELECT CONCAT(IFNULL(old_status_id, 'NULL'), '->', new_status_id) FROM property_status_history WHERE property_id = 900;" "NULL->1"
expect_ok "record an offer" \
  "INSERT INTO sale_transaction (transaction_id, property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (9001, 900, 201, 301, '2025-07-01', 515000);"
expect_value "R1 offer moves the property to UNDER_OFFER" \
  "SELECT s.status_code FROM property p JOIN property_status s USING (status_id) WHERE property_id = 900;" "UNDER_OFFER"
expect_error "R3 a second open offer is rejected" \
  "INSERT INTO sale_transaction (property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (900, 202, 302, '2025-07-02', 530000);" "already has open offer 9001"
expect_error "R9 property cannot be set to SOLD by hand" \
  "UPDATE property SET status_id = 2 WHERE property_id = 900;" "come from deals"
expect_ok "close the deal without a date" \
  "UPDATE sale_transaction SET stage = 'CLOSED' WHERE transaction_id = 9001;"
expect_value "closing fills today's date" \
  "SELECT transaction_date = CURDATE() FROM sale_transaction WHERE transaction_id = 9001;" "1"
expect_value "R1 closing moves the property to SOLD" \
  "SELECT s.status_code FROM property p JOIN property_status s USING (status_id) WHERE property_id = 900;" "SOLD"
expect_value "R10 history shows AVAILABLE -> UNDER_OFFER -> SOLD" \
  "SELECT GROUP_CONCAT(new_status_id ORDER BY history_id) FROM property_status_history WHERE property_id = 900;" "1,3,2"
expect_value "history records the database user" \
  "SELECT COUNT(*) > 0 FROM property_status_history WHERE property_id = 900 AND changed_by LIKE '%@%';" "1"
expect_error "R2 a sold property cannot take a new offer" \
  "INSERT INTO sale_transaction (property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (900, 203, 301, '2025-08-01', 520000);" "already sold"
expect_error "R7 a closed deal cannot be reopened" \
  "UPDATE sale_transaction SET stage = 'OFFER', transaction_date = NULL WHERE transaction_id = 9001;" "cannot change stage"
expect_error "R7 a deal cannot move to another property" \
  "UPDATE sale_transaction SET property_id = 101 WHERE transaction_id = 9001;" "cannot be moved"
expect_error "R8 deals are never deleted" \
  "DELETE FROM sale_transaction WHERE transaction_id = 9001;" "never deleted"

echo
echo "Automation (cancellation and withdrawal)"
expect_ok "second listing with an offer" \
  "INSERT INTO property (property_id, street_address, postal_code, district_id, property_type_id, area_sqm,
                         list_price, listing_agent_id, listed_date)
   VALUES (901, 'Teststrasse 10', '10243', 2, 3, 88, 610000, 302, '2025-05-01');
   INSERT INTO sale_transaction (transaction_id, property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (9002, 901, 204, 302, '2025-06-10', 600000);"
expect_ok "cancel the offer" \
  "UPDATE sale_transaction SET stage = 'CANCELLED' WHERE transaction_id = 9002;"
expect_value "R1 cancellation puts the property back to AVAILABLE" \
  "SELECT s.status_code FROM property p JOIN property_status s USING (status_id) WHERE property_id = 901;" "AVAILABLE"
expect_error "R7 a cancelled deal cannot be revived" \
  "UPDATE sale_transaction SET stage = 'OFFER' WHERE transaction_id = 9002;" "cannot change stage"
expect_ok "R9 owner withdraws an available listing by hand" \
  "UPDATE property SET status_id = 4 WHERE property_id = 901;"
expect_error "R2 a withdrawn property cannot take an offer" \
  "INSERT INTO sale_transaction (property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (901, 205, 302, '2025-09-01', 600000);" "is withdrawn"
expect_ok "R9 listing put back on the market by hand" \
  "UPDATE property SET status_id = 1 WHERE property_id = 901;"

echo
echo "Validation"
expect_error "R4 an inactive agent cannot take a deal" \
  "INSERT INTO sale_transaction (property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (901, 205, 308, '2025-09-01', 600000);" "inactive"
expect_error "R5 offer before the listing date is rejected" \
  "INSERT INTO sale_transaction (property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (901, 205, 302, '2025-01-01', 600000);" "before the listing date"
expect_error "R6 a mistyped amount (extra digit) is rejected" \
  "INSERT INTO sale_transaction (property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (901, 205, 302, '2025-09-01', 6000000);" "outside 50%-150%"
expect_error "a closed deal needs a contract date after the offer" \
  "INSERT INTO sale_transaction (property_id, client_id, agent_id, stage, offer_date, transaction_date, sale_amount)
   VALUES (901, 205, 302, 'CLOSED', '2025-09-01', '2025-08-01', 600000);" "ck_sale_dates"
expect_error "R9 automation flag does not leak within a session" \
  "INSERT INTO sale_transaction (transaction_id, property_id, client_id, agent_id, offer_date, sale_amount)
   VALUES (9003, 901, 206, 302, '2025-09-15', 605000);
   UPDATE sale_transaction SET stage = 'CANCELLED' WHERE transaction_id = 9003;
   UPDATE property SET status_id = 2 WHERE property_id = 901;" "come from deals"
expect_value "  and the two automated changes before it were applied" \
  "SELECT GROUP_CONCAT(new_status_id ORDER BY history_id) FROM property_status_history WHERE property_id = 901;" "1,3,1,4,1,3,1"

echo
echo "Reports"
expect_ok "every query in 03_business_queries.sql runs" \
  "$(cat sql/03_business_queries.sql)"

echo
echo "Passed: $PASS   Failed: $FAIL"
[[ $FAIL -eq 0 ]]
