"""Einmaliger Fix: Korrekte Aufzugsnamen in Cloud SQL eintragen."""
import os
import psycopg2

conn = psycopg2.connect(
    host=os.getenv("DB_HOST", "34.123.254.160"),
    user=os.getenv("DB_USER", "postgres"),
    password=os.getenv("DB_PASSWORD", "ElevatorHN2024!"),
    dbname=os.getenv("DB_NAME", "elevator_db"),
    sslmode=os.getenv("DB_SSLMODE", "disable"),
)
cur = conn.cursor()

# Vorher: Zeige was aktuell in der DB ist
cur.execute("SELECT id, name FROM elevators ORDER BY id")
print("Aktuelle Eintraege in elevators-Tabelle:")
for row in cur.fetchall():
    print(f"  [{row[0]}] {repr(row[1])}")

# Losche alle Eintraege mit falschen Zeichen (? statt Umlaut)
cur.execute("DELETE FROM elevators WHERE name LIKE '%?%'")
deleted = cur.rowcount
print(f"\n{deleted} korrumpierte Eintraege geloescht.")

# Alle korrekten Aufzuege eintragen
elevators = [
    ("Aufzug links L-Bau",               "L-Bau",     10),
    ("Aufzug rechts L-Bau",              "L-Bau",     10),
    ("Campus Brücken HN West",           "Campus HN",  1),
    ("Feuerwehraufzug L-Bau",            "L-Bau",     10),
    ("Campus Brücken HN Ost",            "Campus HN",  1),
    ("Teststand lipah Aufzüge Heilbronn","Campus HN", 10),
]

inserted = 0
for name, location, max_floor in elevators:
    cur.execute(
        "INSERT INTO elevators (name, location, max_floor) VALUES (%s, %s, %s) ON CONFLICT (name) DO NOTHING",
        (name, location, max_floor),
    )
    if cur.rowcount > 0:
        inserted += 1
        print(f"  + Eingefuegt: {name}")
    else:
        print(f"  = Bereits vorhanden: {name}")

conn.commit()
cur.close()
conn.close()
print(f"\nFertig: {inserted} neue Aufzuege eingefuegt.")
