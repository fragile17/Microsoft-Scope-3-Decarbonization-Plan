"""
Runner script: Executes the SQLite-compatible decarbonization simulation
and prints query results with formatted tables.
"""
import sqlite3
import os
import sys
import re

DB_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "decarbonization.db")
SQL_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "decarbonization_sqlite.sql")


def print_table(rows, headers, title=None):
    """Pretty-print a result set as a formatted table."""
    if not rows:
        if title:
            print(f"\n{'='*60}\n{title}\n{'='*60}")
        print("(no rows returned)\n")
        return

    col_widths = [len(h) for h in headers]
    str_rows = []
    for row in rows:
        str_row = [str(v) if v is not None else "NULL" for v in row]
        str_rows.append(str_row)
        for i, val in enumerate(str_row):
            col_widths[i] = max(col_widths[i], len(val))

    sep = "+-" + "-+-".join("-" * w for w in col_widths) + "-+"
    header_line = "| " + " | ".join(h.ljust(w) for h, w in zip(headers, col_widths)) + " |"

    if title:
        print(f"\n{'='*60}")
        print(title)
        print(f"{'='*60}")
    print(sep)
    print(header_line)
    print(sep)
    for sr in str_rows:
        print("| " + " | ".join(v.ljust(w) for v, w in zip(sr, col_widths)) + " |")
    print(sep)
    print(f"({len(rows)} rows)\n")


def run_query(conn, sql, title):
    """Execute a SELECT query and print results."""
    try:
        cursor = conn.execute(sql)
        headers = [desc[0] for desc in cursor.description]
        rows = cursor.fetchall()
        print_table(rows, headers, title)
    except Exception as e:
        print(f"\n*** ERROR in '{title}' ***")
        print(f"Error: {e}\n")


def main():
    # Remove old DB so we start fresh
    if os.path.exists(DB_PATH):
        os.remove(DB_PATH)

    conn = sqlite3.connect(DB_PATH)

    # Check SQLite version for math function support
    ver = conn.execute("SELECT sqlite_version()").fetchone()[0]
    print(f"SQLite version: {ver}")

    with open(SQL_PATH, "r", encoding="utf-8") as f:
        sql_script = f.read()

    # Split the script at the section comments to separate DDL/DML from SELECT queries
    # First, run everything up through the simulation_results creation and the view creation
    # Then run the SELECT queries individually

    # Extract the DDL/DML portion (sections 1-5: DROP, CREATE, INSERT, CREATE TABLE AS)
    # and the view creation (section 12's CREATE VIEW)
    # Then run each reporting SELECT separately

    # Strategy: use executescript for the non-SELECT parts, then run SELECTs individually
    
    # Split on section markers
    sections = re.split(r'-- =+\n-- (\d+)\. (.+?)\n-- =+\n', sql_script)
    
    # sections[0] = header comment
    # then groups of 3: section_num, section_title, section_body

    setup_sql = ""   # DDL/DML to run via executescript
    select_queries = []  # (title, sql) pairs

    i = 1
    while i < len(sections):
        sec_num = sections[i]
        sec_title = sections[i+1]
        sec_body = sections[i+2]
        i += 3

        body_stripped = sec_body.strip()

        # Sections 1-5: setup (DDL/DML including CREATE TABLE AS)
        if int(sec_num) <= 5:
            setup_sql += body_stripped + "\n\n"
        # Section 12: has both CREATE VIEW and a SELECT
        elif int(sec_num) == 12:
            # Split: CREATE VIEW ... ; then SELECT ...;
            parts = body_stripped.split(";")
            view_parts = []
            select_parts = []
            found_select_star = False
            current = []
            for part in parts:
                p = part.strip()
                if not p:
                    continue
                if p.upper().startswith("SELECT") and "executive_scope3_dashboard" in p:
                    select_parts.append(p)
                elif p.upper().startswith("CREATE"):
                    view_parts.append(p)
                else:
                    # Part of the CREATE VIEW (multi-statement with subqueries)
                    view_parts.append(part)

            # Reconstruct the CREATE VIEW as one statement
            # Actually, let's just find the CREATE VIEW ... ; boundary properly
            # The CREATE VIEW ends at the first top-level semicolon after its ORDER BY
            create_view_match = re.search(
                r'(CREATE\s+VIEW\s+IF\s+NOT\s+EXISTS\s+executive_scope3_dashboard\s+AS\s+.+?ORDER\s+BY\s+y\.simulation_year)\s*;',
                body_stripped,
                re.DOTALL | re.IGNORECASE
            )
            if create_view_match:
                setup_sql += create_view_match.group(1) + ";\n\n"
            
            final_select = re.search(
                r'(SELECT\s+\*\s+FROM\s+executive_scope3_dashboard)\s*;',
                body_stripped,
                re.DOTALL | re.IGNORECASE
            )
            if final_select:
                select_queries.append((f"{sec_num}. {sec_title}", final_select.group(1)))
        else:
            # Sections 6-11: SELECT queries
            select_queries.append((f"{sec_num}. {sec_title}", body_stripped.rstrip(";")))

    # Execute all setup DDL/DML
    print("Running setup (tables, data, simulation, view)...\n")
    try:
        conn.executescript(setup_sql)
    except Exception as e:
        print(f"*** ERROR during setup ***")
        print(f"Error: {e}")
        # Print the problematic area
        print(f"\nFull setup SQL (last 500 chars):\n...{setup_sql[-500:]}")
        sys.exit(1)

    print("Setup complete. Running queries...\n")

    # Execute each SELECT query
    for title, sql in select_queries:
        run_query(conn, sql, title)

    conn.close()
    print(f"Database saved to: {DB_PATH}")
    print("Simulation completed successfully!")


if __name__ == "__main__":
    main()
