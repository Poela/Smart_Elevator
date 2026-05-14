"""
ML Forecast Service – LightGBM + Quantile-Regression
=====================================================
Modell-Wahl: LightGBM mit Quantile-Regression (statt Prophet)

Warum LightGBM besser für ~2 Monate Daten ist:
  Prophet:     Fourier-Saisonalität braucht mehrere Jahreszyk­len → breite CI
  LightGBM QR: Lernt direkt Wochentags­muster über lag_7 (gleicher Tag
               letzte Woche) → enge CI bereits ab 8 Datenpunkten / Wochentag

Feature-Set:
  ┌─ Kalender ──────── day_of_week, is_weekend, month, week_of_year
  ├─ Lag-Features ──── lag_7 (Fahrten vor 7 Tagen), lag_14
  ├─ Rolling-Stats ─── rolling_7_mean, rolling_7_std
  └─ Wetter (DWD) ──── temperature_avg, precipitation (optional)

Quantile-Regression:
  Drei separate LightGBM-Modelle – q10, q50, q90:
    q50 → yhat         (Punktprognose)
    q10 → yhat_lower   (untere 80 %-Konfidenzgrenze)
    q90 → yhat_upper   (obere 80 %-Konfidenzgrenze)
  Die CIs werden direkt auf die Perzentile optimiert, nicht
  aus Posterior-Varianz geschätzt → engere, kalibrierte Bänder.

Evaluation:
  Holdout = letzte FORECAST_HOLDOUT_DAYS Tage
  Metriken: MAE, RMSE, MAPE, Coverage (wie oft liegt Ist-Wert im 80 %-Band)

Nutzung:
  python forecast_service.py               # einmaliger Lauf
  python forecast_service.py --loop        # täglich neu trainieren (02:00 Uhr)
  python forecast_service.py --evaluate    # nur Metriken ausgeben
  python forecast_service.py --elevator "Aufzug links L-Bau"

Umgebungsvariablen:
  DB_HOST/PORT/NAME/USER/PASSWORD
  FORECAST_HORIZON_DAYS   (Standard: 14)
  FORECAST_HISTORY_DAYS   (Standard: 365)
  FORECAST_HOLDOUT_DAYS   (Standard: 7)
  FORECAST_LOOP_HOUR      (Standard: 2)
"""

import argparse
import logging
import os
import time
from datetime import datetime, timezone, timedelta, date

import lightgbm as lgb
import numpy as np
import pandas as pd
import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import execute_values
from sklearn.metrics import mean_absolute_error, root_mean_squared_error

load_dotenv()

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(name)s – %(message)s",
)
log = logging.getLogger("elevator.forecast")

# ── Konfiguration ─────────────────────────────────────────────────────────────
DB_CONFIG = {
    "host":     os.getenv("DB_HOST",     "localhost"),
    "port":     int(os.getenv("DB_PORT", 5432)),
    "dbname":   os.getenv("DB_NAME",     "elevator_db"),
    "user":     os.getenv("DB_USER",     "postgres"),
    "password": os.getenv("DB_PASSWORD", ""),
}

HORIZON_DAYS   = int(os.getenv("FORECAST_HORIZON_DAYS",  "14"))
HISTORY_DAYS   = int(os.getenv("FORECAST_HISTORY_DAYS",  "365"))
HOLDOUT_DAYS   = int(os.getenv("FORECAST_HOLDOUT_DAYS",  "7"))
LOOP_HOUR      = int(os.getenv("FORECAST_LOOP_HOUR",     "2"))
MIN_TRAIN_DAYS = 21   # Mindestens 3 volle Wochen für verlässliche lag_7-Features

# Feature-Spalten (kein target, kein Datum)
FEATURE_COLS = [
    "day_of_week", "is_weekend", "month", "week_of_year", "day_of_year",
    "lag_7", "lag_14", "rolling_7_mean", "rolling_7_std",
]
WEATHER_FEATURES = ["temperature_avg", "precipitation"]

MODEL_NAME = "lgbm_quantile"


# ── DB-Verbindung ─────────────────────────────────────────────────────────────
def get_connection():
    return psycopg2.connect(**DB_CONFIG)


# ── Daten laden ───────────────────────────────────────────────────────────────
def load_trips(conn, elevator_name: str) -> pd.DataFrame:
    since = datetime.now(timezone.utc) - timedelta(days=HISTORY_DAYS)
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT date_trunc('day', time)::date AS ds, COUNT(*) AS y
            FROM elevator_events ev
            JOIN elevators e ON e.id = ev.elevator_id
            WHERE e.name = %s AND time >= %s
            GROUP BY 1
            ORDER BY 1
            """,
            (elevator_name, since),
        )
        rows = cur.fetchall()
    df = pd.DataFrame(rows, columns=["ds", "y"])
    df["ds"] = pd.to_datetime(df["ds"])
    df["y"]  = df["y"].astype(float)
    return df.sort_values("ds").reset_index(drop=True)


def load_weather(conn, start: date, end: date) -> pd.DataFrame:
    """Historische + Vorhersage-Wetterdaten (weather_observations + weather_hourly)."""
    with conn.cursor() as cur:
        # Historische Tagesdaten
        cur.execute(
            """
            SELECT date_trunc('day', time)::date AS ds,
                   AVG(temperature_avg) AS temperature_avg,
                   SUM(precipitation)   AS precipitation
            FROM weather_observations
            WHERE time::date BETWEEN %s AND %s
            GROUP BY 1
            UNION ALL
            -- DWD stündliche Vorhersage aggregiert auf Tage
            SELECT date_trunc('day', time)::date AS ds,
                   AVG(temperature)   AS temperature_avg,
                   SUM(precipitation) AS precipitation
            FROM weather_hourly
            WHERE time::date BETWEEN %s AND %s
            GROUP BY 1
            ORDER BY 1
            """,
            (start, end, start, end),
        )
        rows = cur.fetchall()
    if not rows:
        return pd.DataFrame(columns=["ds", "temperature_avg", "precipitation"])
    df = pd.DataFrame(rows, columns=["ds", "temperature_avg", "precipitation"])
    df["ds"] = pd.to_datetime(df["ds"])
    # Bei Duplikaten (overlap observations + hourly): neuesten Wert behalten
    df = df.sort_values("ds").drop_duplicates("ds", keep="last")
    return df


def load_weather_climatology(conn) -> pd.Series:
    """DOY-Klimadurchschnitt (Fallback für Zukunfts-Tage ohne Vorhersage)."""
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT EXTRACT(DOY FROM time)::int AS doy,
                   AVG(temperature_avg) AS t, AVG(precipitation) AS p
            FROM weather_observations
            GROUP BY doy
            """
        )
        rows = cur.fetchall()
    if not rows:
        return None
    return pd.DataFrame(rows, columns=["doy", "temperature_avg", "precipitation"]).set_index("doy")


# ── Feature Engineering ───────────────────────────────────────────────────────
def add_calendar_features(df: pd.DataFrame) -> pd.DataFrame:
    """Fügt Kalender-Features hinzu (ds muss datetime64 sein)."""
    df = df.copy()
    df["day_of_week"]  = df["ds"].dt.dayofweek          # 0=Montag
    df["is_weekend"]   = (df["day_of_week"] >= 5).astype(int)
    df["month"]        = df["ds"].dt.month
    df["week_of_year"] = df["ds"].dt.isocalendar().week.astype(int)
    df["day_of_year"]  = df["ds"].dt.dayofyear
    return df


def add_lag_features(df: pd.DataFrame) -> pd.DataFrame:
    """
    Fügt Lag-Features auf Basis der 'y'-Spalte hinzu.
    lag_7 ist das wichtigste Feature: gleicher Wochentag letzte Woche.
    """
    df = df.copy().sort_values("ds").reset_index(drop=True)
    df["lag_7"]           = df["y"].shift(7)
    df["lag_14"]          = df["y"].shift(14)
    df["rolling_7_mean"]  = df["y"].shift(1).rolling(7, min_periods=3).mean()
    df["rolling_7_std"]   = df["y"].shift(1).rolling(7, min_periods=3).std().fillna(1.0)
    return df


def prepare_dataset(
    trips_df: pd.DataFrame,
    weather_df: pd.DataFrame | None = None,
) -> pd.DataFrame:
    """Kombiniert Fahrten + Wetter + Features zu einem ML-DataFrame."""
    df = add_calendar_features(trips_df)
    df = add_lag_features(df)

    use_weather = weather_df is not None and not weather_df.empty
    if use_weather:
        df = df.merge(weather_df[["ds", "temperature_avg", "precipitation"]],
                      on="ds", how="left")
        df["temperature_avg"] = df["temperature_avg"].fillna(
            df["temperature_avg"].expanding().mean()  # Vorwärts-Mittel als Fallback
        ).fillna(10.0)
        df["precipitation"] = df["precipitation"].fillna(0.0)

    return df, use_weather


# ── Modell-Training ───────────────────────────────────────────────────────────
LGBM_PARAMS = {
    "n_estimators":      300,
    "learning_rate":     0.05,
    "num_leaves":        15,      # Niedrig = weniger Overfitting bei kleinen Datasets
    "min_child_samples": 3,       # Mindest-Samples pro Blatt
    "reg_alpha":         0.1,     # L1-Regularisierung
    "reg_lambda":        0.5,     # L2-Regularisierung
    "subsample":         0.8,
    "colsample_bytree":  0.8,
    "random_state":      42,
    "verbose":          -1,
}


def train_quantile_models(
    df_train: pd.DataFrame,
    feature_cols: list[str],
) -> dict:
    """
    Trainiert drei LightGBM-Modelle für q=0.1, 0.5, 0.9.
    Gibt dict mit Keys 'q10', 'q50', 'q90' zurück.
    """
    # Zeilen mit NaN in Features entfernen (erste ~14 Tage haben keine Lag-Werte)
    mask = df_train[feature_cols].notna().all(axis=1)
    X = df_train.loc[mask, feature_cols].values
    y = df_train.loc[mask, "y"].values

    models = {}
    for alpha, key in [(0.10, "q10"), (0.50, "q50"), (0.90, "q90")]:
        m = lgb.LGBMRegressor(objective="quantile", alpha=alpha, **LGBM_PARAMS)
        m.fit(X, y)
        models[key] = m
        log.debug("  %s trainiert auf %d Samples, %d Features", key, len(X), len(feature_cols))

    return models


# ── Rekursiver Forecast ───────────────────────────────────────────────────────
def _build_future_row(
    future_date: pd.Timestamp,
    history: pd.DataFrame,
    weather_row: dict | None,
    feature_cols: list[str],
) -> pd.DataFrame:
    """
    Baut einen Feature-Vektor für einen Zukunftstag als DataFrame
    (mit Spaltennamen, damit LightGBM keine Feature-Names-Warnung wirft).
    """
    row = {
        "day_of_week":  future_date.dayofweek,
        "is_weekend":   int(future_date.dayofweek >= 5),
        "month":        future_date.month,
        "week_of_year": int(future_date.isocalendar().week),
        "day_of_year":  future_date.day_of_year,
    }

    hist_y = history.set_index("ds")["y"]
    lag7_date  = future_date - pd.Timedelta(days=7)
    lag14_date = future_date - pd.Timedelta(days=14)
    row["lag_7"]  = float(hist_y.get(lag7_date,  np.nan))
    row["lag_14"] = float(hist_y.get(lag14_date, np.nan))

    recent = history.sort_values("ds").tail(7)["y"]
    row["rolling_7_mean"] = float(recent.mean()) if len(recent) >= 3 else 0.0
    row["rolling_7_std"]  = float(recent.std())  if len(recent) >= 3 else 1.0

    if weather_row:
        row["temperature_avg"] = float(weather_row.get("temperature_avg", 10.0))
        row["precipitation"]   = float(weather_row.get("precipitation",    0.0))

    # NaN durch 0 ersetzen und als DataFrame zurückgeben → keine LightGBM-Warnung
    return pd.DataFrame([{f: row.get(f, 0.0) for f in feature_cols}])


def forecast_recursive(
    models: dict,
    df_history: pd.DataFrame,
    future_dates: list[pd.Timestamp],
    weather_future: pd.DataFrame | None,
    feature_cols: list[str],
) -> pd.DataFrame:
    """
    Rekursiver Forecast: Prognose-Wert von Tag t wird als lag_7 für Tag t+7 genutzt.
    So bleiben die CI auch für Tag 8–14 eng (statt auf einen konstanten Wert zu kollabieren).
    """
    history = df_history[["ds", "y"]].copy()

    weather_idx = {}
    if weather_future is not None and not weather_future.empty:
        weather_idx = weather_future.set_index("ds").to_dict("index")

    results = []
    for fd in future_dates:
        weather_row = weather_idx.get(fd)
        x = _build_future_row(fd, history, weather_row, feature_cols)

        # Nan-Werte mit Spalten-Median aus Training ersetzen (Robustheit)
        x = np.where(np.isnan(x), 0, x)

        yhat     = max(0.0, float(models["q50"].predict(x)[0]))
        yhat_low = max(0.0, float(models["q10"].predict(x)[0]))
        yhat_up  = max(0.0, float(models["q90"].predict(x)[0]))

        # Prognose zur History hinzufügen (für kommende lag_7-Berechnungen)
        history = pd.concat(
            [history, pd.DataFrame({"ds": [fd], "y": [yhat]})],
            ignore_index=True,
        )

        results.append({"ds": fd, "yhat": yhat, "yhat_lower": yhat_low, "yhat_upper": yhat_up})

    return pd.DataFrame(results)


# ── Evaluation ────────────────────────────────────────────────────────────────
def evaluate_holdout(
    df_full: pd.DataFrame,
    feature_cols: list[str],
    holdout: int,
) -> dict:
    """Train/Test-Split auf den letzten `holdout` Tagen."""
    if len(df_full) <= MIN_TRAIN_DAYS + holdout:
        return {}

    df_train = df_full.iloc[:-holdout].copy()
    df_test  = df_full.iloc[-holdout:].copy()

    models = train_quantile_models(df_train, feature_cols)

    # Rekursiv auf Holdout forecasen
    future_dates = df_test["ds"].tolist()
    fc = forecast_recursive(models, df_train, future_dates, None, feature_cols)

    y_true = df_test["y"].values
    y_pred = fc["yhat"].values
    ci_lo  = fc["yhat_lower"].values
    ci_hi  = fc["yhat_upper"].values

    coverage = float(np.mean((y_true >= ci_lo) & (y_true <= ci_hi)) * 100)
    mae  = mean_absolute_error(y_true, y_pred)
    rmse = float(root_mean_squared_error(y_true, y_pred))
    mape = float(np.mean(np.abs((y_true - y_pred) / np.maximum(y_true, 1))) * 100)

    return {
        "mae":       round(mae,      2),
        "rmse":      round(rmse,     2),
        "mape":      round(mape,     1),
        "coverage":  round(coverage, 1),  # Anteil Ist-Werte im 80 %-CI
        "holdout_days": holdout,
    }


# ── Feature Importance (Logging) ─────────────────────────────────────────────
def log_feature_importance(models: dict, feature_cols: list[str], elevator: str) -> None:
    imp = pd.Series(
        models["q50"].feature_importances_,
        index=feature_cols,
    ).sort_values(ascending=False)
    top3 = ", ".join(f"{k}={v}" for k, v in imp.head(3).items())
    log.info("[%s] Top-3 Features (q50): %s", elevator, top3)


# ── DB-Write ──────────────────────────────────────────────────────────────────
def store_forecast(conn, elevator_name: str, fc_df: pd.DataFrame) -> int:
    today = datetime.now(timezone.utc).date()
    records = [
        (
            pd.Timestamp(row["ds"]).tz_localize("UTC"),
            elevator_name,
            MODEL_NAME,
            today,
            float(row["yhat"]),
            float(row["yhat_lower"]),
            float(row["yhat_upper"]),
        )
        for _, row in fc_df.iterrows()
    ]

    with conn.cursor() as cur:
        execute_values(
            cur,
            """
            INSERT INTO elevator_forecast
                (time, elevator_name, model, forecast_date, yhat, yhat_lower, yhat_upper)
            VALUES %s
            ON CONFLICT (time, elevator_name, model, forecast_date) DO UPDATE SET
                yhat       = EXCLUDED.yhat,
                yhat_lower = EXCLUDED.yhat_lower,
                yhat_upper = EXCLUDED.yhat_upper
            """,
            records,
        )
    conn.commit()
    return len(records)


# ── Haupt-Pipeline pro Aufzug ─────────────────────────────────────────────────
def run_for_elevator(
    conn,
    elevator_name: str,
    evaluate_only: bool = False,
) -> dict:
    log.info("── %s ──────────────────────────────────", elevator_name)

    # 1. Daten laden
    df_trips  = load_trips(conn, elevator_name)
    if len(df_trips) < MIN_TRAIN_DAYS:
        log.warning("[%s] Nur %d Tage – mind. %d benötigt. Übersprungen.",
                    elevator_name, len(df_trips), MIN_TRAIN_DAYS)
        return {}

    today     = pd.Timestamp(datetime.now(timezone.utc).date())
    hist_end  = df_trips["ds"].max().date()
    future_start = today
    future_end   = today + timedelta(days=HORIZON_DAYS - 1)

    weather_all = load_weather(conn,
                               df_trips["ds"].min().date(),
                               future_end)
    clim        = load_weather_climatology(conn)

    # Klimadurchschnitt für Zukunfts-Tage ohne echte Vorhersage
    if clim is not None and not weather_all.empty:
        future_missing = pd.date_range(future_start, future_end, freq="D")
        existing_ds = set(weather_all["ds"])
        for d in future_missing:
            if pd.Timestamp(d) not in existing_ds:
                doy = d.dayofyear
                row_clim = clim.loc[doy] if doy in clim.index else clim.iloc[0]
                weather_all = pd.concat([
                    weather_all,
                    pd.DataFrame({
                        "ds": [pd.Timestamp(d)],
                        "temperature_avg": [row_clim["temperature_avg"]],
                        "precipitation":   [row_clim["precipitation"]],
                    })
                ], ignore_index=True)
        weather_all = weather_all.sort_values("ds").drop_duplicates("ds")

    # 2. Features bauen
    df_full, use_weather = prepare_dataset(df_trips, weather_all if not weather_all.empty else None)
    feature_cols = FEATURE_COLS + (WEATHER_FEATURES if use_weather else [])

    log.info("[%s] %d Trainings-Tage | Wetter: %s | Features: %d",
             elevator_name, len(df_trips), "ja" if use_weather else "nein", len(feature_cols))

    # 3. Evaluation (Holdout)
    metrics = evaluate_holdout(df_full, feature_cols, HOLDOUT_DAYS)
    if metrics:
        log.info(
            "[%s] Holdout-Eval (%d Tage): MAE=%.1f  RMSE=%.1f  "
            "MAPE=%.1f%%  CI-Coverage=%.0f%%",
            elevator_name, HOLDOUT_DAYS,
            metrics["mae"], metrics["rmse"], metrics["mape"], metrics["coverage"],
        )
    else:
        log.info("[%s] Zu wenig Daten für Holdout-Eval.", elevator_name)

    if evaluate_only:
        return metrics

    # 4. Finale Modelle auf allen Daten trainieren
    models = train_quantile_models(df_full, feature_cols)
    log_feature_importance(models, feature_cols, elevator_name)

    # 5. Rekursiver Forecast
    weather_future = (
        weather_all[weather_all["ds"] >= today] if not weather_all.empty else None
    )

    # Forecast startet ab dem Tag NACH dem letzten bekannten Datenpunkt,
    # nicht ab heute – das verhindert den schwarzen Leerbereich im Dashboard
    # wenn CSV-Daten einige Tage vor heute enden.
    last_data_date = df_trips["ds"].max()
    fc_start = last_data_date + pd.Timedelta(days=1)
    future_dates = [fc_start + pd.Timedelta(days=i) for i in range(HORIZON_DAYS)]

    fc = forecast_recursive(models, df_full[["ds", "y"]], future_dates,
                            weather_future, feature_cols)

    log.info("[%s] Prognose: %.1f … %.1f Fahrten/Tag (Ø q50), "
             "Bandbreite Ø ±%.1f | Start: %s",
             elevator_name, fc["yhat"].min(), fc["yhat"].max(),
             ((fc["yhat_upper"] - fc["yhat_lower"]) / 2).mean(),
             fc_start.date())

    # 6. DB-Write
    n = store_forecast(conn, elevator_name, fc)
    log.info("[%s] %d Forecast-Records gespeichert.", elevator_name, n)
    return {**metrics, "forecast_days": n}


# ── Alle Aufzüge ──────────────────────────────────────────────────────────────
def run_all(conn, evaluate_only: bool = False, only_elevator: str = None) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT name FROM elevators ORDER BY name")
        elevators = [r[0] for r in cur.fetchall()]

    if only_elevator:
        elevators = [e for e in elevators if e == only_elevator]
        if not elevators:
            log.error("Aufzug '%s' nicht in der Datenbank.", only_elevator)
            return

    results = {}
    for name in elevators:
        try:
            results[name] = run_for_elevator(conn, name, evaluate_only=evaluate_only)
        except Exception as exc:
            log.exception("[%s] Fehler: %s", name, exc)

    log.info("═══ Zusammenfassung ══════════════════════════════════════════")
    for name, r in results.items():
        if r:
            log.info(
                "  %-35s MAE=%-5s RMSE=%-5s MAPE=%-6s Coverage=%-6s Tage=%s",
                name,
                r.get("mae",      "—"),
                r.get("rmse",     "—"),
                f"{r.get('mape','—')}%",
                f"{r.get('coverage','—')}%",
                r.get("forecast_days", "—"),
            )
        else:
            log.info("  %-35s  (übersprungen – zu wenig Daten)", name)


# ── Einstiegspunkt ────────────────────────────────────────────────────────────
def main() -> None:
    parser = argparse.ArgumentParser(
        description="LightGBM Quantile-Regression Forecast für Aufzugsfahrten"
    )
    parser.add_argument("--loop",     action="store_true",
                        help=f"Täglich um {LOOP_HOUR}:00 Uhr neu trainieren")
    parser.add_argument("--evaluate", action="store_true",
                        help="Nur Holdout-Metriken ausgeben, kein DB-Write")
    parser.add_argument("--elevator", type=str, default=None,
                        help="Nur diesen Aufzug forecasen (Name exakt)")
    args = parser.parse_args()

    log.info("=== Elevator Forecast Service (LightGBM Quantile-Regression) ===")
    log.info("Horizont: %d Tage | History: %d Tage | Holdout: %d Tage",
             HORIZON_DAYS, HISTORY_DAYS, HOLDOUT_DAYS)

    conn = get_connection()
    run_all(conn, evaluate_only=args.evaluate, only_elevator=args.elevator)

    if args.loop:
        log.info("Loop-Modus: täglich um %02d:00 Uhr.", LOOP_HOUR)
        while True:
            now      = datetime.now()
            next_run = now.replace(hour=LOOP_HOUR, minute=0, second=0, microsecond=0)
            if next_run <= now:
                next_run += timedelta(days=1)
            wait_s = (next_run - now).total_seconds()
            log.info("Nächster Lauf: %s (in %.0f min)",
                     next_run.strftime("%Y-%m-%d %H:%M"), wait_s / 60)
            time.sleep(wait_s)
            try:
                if conn.closed:
                    conn = get_connection()
                run_all(conn, only_elevator=args.elevator)
            except Exception as exc:
                log.exception("Fehler im Loop: %s", exc)

    conn.close()


if __name__ == "__main__":
    main()
