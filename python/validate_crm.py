"""
CRM export validator for the Pipeline Health pipeline.

Design decision: this reads with csv.reader (not DictReader) and checks the
field COUNT before mapping fields to column names. DictReader silently maps
by position, so a row with an extra unescaped comma (see D-1045 in the sample
export -- "9,800" with no quoting) doesn't raise an error, it just shifts
every field after it one column to the right and drops the last one. A row
like that isn't a "dirty data" problem, it's a structural one: we can't trust
positional parsing on it at all, so it goes straight to quarantine instead of
being "cleaned".

Everything else here follows a quarantine pattern: valid rows go to
`valid_rows`, everything else goes to `quarantined_rows` with a machine
-readable reason string, so a human (or a downstream alert) can see exactly
why each row was rejected instead of it just vanishing.
"""

import csv
import io
from datetime import datetime

REQUIRED_COLUMNS = [
    "deal_id", "account_id", "stage", "deal_value",
    "opened_date", "close_date", "updated_date",
]

# Order matters: try ISO first since that's what most of the export uses.
DATE_FORMATS = ("%Y-%m-%d", "%d/%m/%Y")


def _parse_date(raw: str):
    """Return (iso_string_or_None, error_or_None)."""
    raw = raw.strip()
    if not raw:
        return None, None  # blank is fine -- e.g. close_date on an open deal
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(raw, fmt).strftime("%Y-%m-%d"), None
        except ValueError:
            continue
    return None, f"unparseable date '{raw}'"


def _parse_deal_value(raw: str, stage: str):
    """Return (float_or_None, error_or_None)."""
    raw = raw.strip()
    if not raw:
        if stage == "Closed Won":
            # A won deal with no value isn't "zero revenue", it's missing
            # data on a deal that by definition should have a value. Flag
            # it for a human rather than silently reporting $0 revenue.
            return None, "missing deal_value on a Closed Won deal"
        return None, None  # blank is plausible pre-negotiation
    try:
        return float(raw.replace(",", "")), None
    except ValueError:
        return None, f"non-numeric deal_value '{raw}'"


def clean_and_validate_crm_csv(raw_csv_text: str):
    valid_rows, quarantined_rows = [], []
    reader = csv.reader(io.StringIO(raw_csv_text.strip()))
    header = next(reader)

    for line_num, fields in enumerate(reader, start=2):  # line 1 is the header
        # --- structural check FIRST, before any field is trusted ---
        if len(fields) != len(header):
            quarantined_rows.append({
                "line": line_num,
                "raw_fields": fields,
                "_rejection_reason": (
                    f"FIELD_COUNT_MISMATCH: expected {len(header)} columns, "
                    f"got {len(fields)} -- likely an unescaped comma in a "
                    f"numeric field upstream. Not safely reconstructable; "
                    f"send back to source rather than guess."
                ),
            })
            continue

        row = dict(zip(header, fields))
        problems = []

        if not row["deal_id"].strip() or not row["account_id"].strip():
            problems.append("missing deal_id or account_id")

        deal_value, val_err = _parse_deal_value(row["deal_value"], row["stage"])
        if val_err:
            problems.append(val_err)
        row["deal_value"] = deal_value

        for col in ("opened_date", "close_date", "updated_date"):
            parsed, date_err = _parse_date(row[col])
            if date_err:
                problems.append(f"{col}: {date_err}")
            row[col] = parsed

        if problems:
            quarantined_rows.append({**row, "_rejection_reason": "; ".join(problems)})
        else:
            valid_rows.append(row)

    return valid_rows, quarantined_rows


if __name__ == "__main__":
    with open("data/crm_export_sample.csv") as f:
        raw = f.read()

    valid, quarantined = clean_and_validate_crm_csv(raw)

    print(f"VALID ROWS ({len(valid)}):")
    for r in valid:
        print(" ", r)

    print(f"\nQUARANTINED ROWS ({len(quarantined)}):")
    for r in quarantined:
        print(" ", r)
