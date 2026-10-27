# Review of the original coursework

**Assignment:** *Enterprise Data Warehouses and Database Management Systems*: design and implement a real estate database for the fictional Berlin agency Berealty, write SQL queries and triggers, and discuss the CAP theorem (BSBI Berlin, M.Sc. Data Analytics, submitted October 2024).

**Original form:** a written report with SQL*Plus screenshots, the session log (`Queries.txt`) and five CSV files of sample data. The brief asked for MySQL; the work was done in Oracle (data types `NUMBER`/`VARCHAR2`, `&` substitution variables, `ORA-` errors in the log).

## Summary

| Area | Rating | Main issue |
|---|---|---|
| Data model | Medium | The five entities and relationships were right; status was later duplicated onto the transaction table, breaking 3NF. |
| Integrity | Low | `ON DELETE CASCADE` from status to property to transaction; no UNIQUE or CHECK constraints; dates and money stored as text. |
| Data quality | Low | Property and deal statuses disagreed; agent emails did not match agent names; duplicate names; an amount typed with an extra digit. |
| Automation | Low | One trigger, which failed to compile several times in the log; the working version reacted to a status column on the deal. |
| Queries | Medium-low | Four correct but basic queries; no period reports, aggregation or window functions, although the brief asked for monthly, quarterly and yearly reports. |
| CAP discussion | Medium | Components explained well; the conclusion (deprioritise consistency) contradicts the report's own double-selling example. |

## Findings

1. **Destructive cascades.** `Property.Status_ID` referenced `PropertyStatus` with `ON DELETE CASCADE`, and the transaction foreign keys cascaded too. Deleting the status "Available" would have deleted every available property and their deals.
2. **Status in two places.** `ALTER TABLE transaction ADD Status_ID` put a property fact on the deal. In the loaded data, property 101 was "Available" while its deal 401 said "Sold". This is the inconsistency the trigger was meant to prevent.
3. **Wrong types.** `TransactionDate VARCHAR2(20)` and `Amount VARCHAR2(6)` (seen in `DESC transaction`), so date filters compared strings like `'22-08-2024'` and amounts could not be summed safely. `Type NUMBER(2)` was declared but held 'Condo'. `Amount NUMBER(4)` in the first version could not hold any of the amounts.
4. **Missing keys and constraints.** `Client` and `Agent` were created without primary keys; no column had `UNIQUE` or `CHECK`, and only `StatusDescription` was `NOT NULL`.
5. **Implausible sample data.** Sale amounts were unrelated to list prices (property 110 listed at 777,840, sold for 105,142); a deal on 19-12-2024 was dated after the submission; agent 301 "George Black" had the email `david.white@mail.com`; two agents shared the name "Emily Brown", which made the agent query in the report ambiguous.
6. **Typo reached the table.** The session log shows `8128953` entered for an 812,895 deal. Nothing rejected it.
7. **Trigger.** The log shows the trigger script failing with `ORA-00942` (wrong table name) and `ORA-00904` (unknown column) before the final version, which updated property status when the deal's status column was updated by hand: the manual step the trigger was supposed to remove.
8. **Queries.** Filtering an agent by name (`WHERE a.Name = 'Emily Brown'`) is fragile with duplicate names; there were no monthly, quarterly or yearly reports, no aggregation and no RIGHT or CROSS JOIN examples, all of which the brief listed.
9. **CAP conclusion.** The report argued that consistency "can be put on back burner" for real estate, after explaining that a stale status lets two agents sell the same property.

## What was good

- The entity choice and the one-to-many relationships matched the brief.
- Separating property status into its own table was the right instinct for 3NF.
- Generating sample data with Python rather than typing it all in was sensible.
- The CAP chapter explained each component clearly with real estate examples.

## How each finding is addressed

| Finding | Fix |
|---|---|
| 1 | `RESTRICT` for lookups and financial records, `SET NULL` for listing agent; tests prove the deletes are blocked. |
| 2 | Status lives only on `property`; the deal has a `stage`. Triggers derive the status (R1) and block manual SOLD (R9); query Q8 and a test check consistency. |
| 3 | `DATE`, `DECIMAL(12,2)`, property-type lookup. |
| 4 | Primary keys everywhere, unique emails, named CHECK constraints, NOT NULL where the business requires a value. |
| 5 | Seeded generator: prices from district price levels, deal amounts within a few percent of list price, all dates before the snapshot, unique emails derived from names. |
| 6 | Rule R6 rejects amounts outside 50% to 150% of list price, with a message saying what to check. |
| 7 | Ten tested rules; status changes happen automatically from the deal. |
| 8 | Queries filter by id, and eight report queries cover period reporting, rankings, lifecycle, exceptions and governance. |
| 9 | Per-workload CAP choice: consistency for deals, availability for search. |
