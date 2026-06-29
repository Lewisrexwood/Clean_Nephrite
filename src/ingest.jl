using TOML, Dates, Downloads
using DuckDB, DBInterface

struct DatasetSpec
    name::String
    url_template::String
    required::Bool
    bymonth_url_template::String
end

function load_registry(path::AbstractString)
    raw = TOML.parsefile(path)
    return [DatasetSpec(d["name"], d["url_template"], get(d, "required", true),
                        get(d, "bymonth_url_template", ""))
            for d in raw["datasets"]]
end

function url_for(spec::DatasetSpec, date::Date)
    url = replace(spec.url_template, "{yyyy}" => Dates.format(date, "yyyy"))
    return replace(url, "{yyyymmdd}" => Dates.format(date, "yyyymmdd"))
end

"Render a dataset's ByMonth (monthly-file) URL for `date` (substitutes {yyyymm})."
url_bymonth(spec::DatasetSpec, date::Date) =
    replace(spec.bymonth_url_template, "{yyyymm}" => Dates.format(date, "yyyymm"))

function download_to_raw!(spec::DatasetSpec, date::Date, root::AbstractString;
                          fetch = Downloads.download)
    dir = raw_dir(root, date)
    mkpath(dir)
    url = url_for(spec, date)
    dest = joinpath(dir, "$(spec.name).csv")
    fetch(url, dest)
    ts = string(Dates.now(Dates.UTC))
    return dest, url, ts
end

"DuckDB-friendly path: forward slashes, single quotes escaped."
sql_path(p::AbstractString) = replace(replace(p, "\\" => "/"), "'" => "''")

function normalise_to_parquet(csv_path::AbstractString, parquet_path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        DBInterface.execute(con,
            "COPY (SELECT * FROM read_csv_auto('$(sql_path(csv_path))')) " *
            "TO '$(sql_path(parquet_path))' (FORMAT PARQUET)")
    finally
        DBInterface.close!(con)
        GC.gc()  # Windows: force release of DuckDB's CSV file handle before the caller may overwrite the raw file
    end
    return parquet_path
end

"Dates from `from` to `to` inclusive, every `stride` days. Stride > 1 still samples all weekdays over time (use stride coprime with 7, e.g. 3)."
function backfill_dates(from::Date, to::Date, stride::Int)
    from <= to || error("backfill: from $from is after to $to")
    stride >= 1 || error("backfill: stride must be >= 1")
    return collect(from:Day(stride):to)
end

"""
Download historical grid_demand daily files into data/history/demand/ (a plain
download cache, NOT snapshots — these files are revision-free history used
only for demand-shape estimation). Skips files already present.
On fetch error the loop aborts; already-downloaded files are retained and a subsequent call resumes from the next missing date (skip-existing is idempotent).
"""
function backfill_demand!(from::Date, to::Date; root::AbstractString,
                          registry_path::AbstractString, stride::Int = 3,
                          fetch = Downloads.download)
    spec = only(s for s in load_registry(registry_path) if s.name == "grid_demand")
    dir = joinpath(root, "history", "demand")
    mkpath(dir)
    done, skipped = 0, 0
    for d in backfill_dates(from, to, stride)
        dest = joinpath(dir, "$(Dates.format(d, "yyyymmdd"))_grid_demand.csv")
        if isfile(dest)
            skipped += 1
            continue
        end
        fetch(url_for(spec, d), dest)
        done += 1
    end
    return (downloaded = done, skipped = skipped, dir = dir)
end

"""
Resumably ingest historical snapshots across a (strided) date range. Calls
`ingest!` for each date whose snapshot is not already complete and skips dates
already finalized — so a re-run resumes from the first missing date.

The EMI offer files are 150-250 MB each; this is a deliberate, staged action,
NEVER invoked from tests or loops against the live site (tests inject `fetch`).
On a fetch error the loop aborts; completed snapshots are retained.
"""
function backfill_snapshots!(from::Date, to::Date; root::AbstractString,
                             registry_path::AbstractString, stride::Int = 7,
                             fetch = Downloads.download, historical::Bool = false)
    done, skipped = 0, 0
    for d in backfill_dates(from, to, stride)
        if is_complete(snapshot_dir(root, d))
            skipped += 1
            continue
        end
        ingest!(d; root = root, registry_path = registry_path, fetch = fetch,
                historical = historical)
        done += 1
    end
    return (downloaded = done, skipped = skipped, root = root)
end

"""
Historical `final_energy_prices`: fetch the ByMonth monthly CSV and slice to the
snapshot day (DuckDB `WHERE TradingDate = DATE 'date'`) straight into the snapshot
Parquet. Returns the source URL and a UTC timestamp.
"""
function _ingest_final_energy_bymonth!(spec::DatasetSpec, date::Date,
                                       dir::AbstractString, root::AbstractString; fetch)
    isempty(spec.bymonth_url_template) &&
        error("historical ingest: no bymonth_url_template for $(spec.name)")
    url = url_bymonth(spec, date)
    rd  = raw_dir(root, date); mkpath(rd)
    csv = joinpath(rd, "final_energy_prices_bymonth.csv")
    fetch(url, csv)
    parquet = joinpath(dir, "final_energy_prices.parquet")
    con = DBInterface.connect(DuckDB.DB)
    try
        DBInterface.execute(con,
            "COPY (SELECT * FROM read_csv_auto('$(sql_path(csv))') " *
            "WHERE TradingDate = DATE '$(date)') " *
            "TO '$(sql_path(parquet))' (FORMAT PARQUET)")
    finally
        DBInterface.close!(con); GC.gc()
    end
    return url, string(Dates.now(Dates.UTC))
end

"Historical `network_supply_points`: normalise the pinned static table into the snapshot."
function _ingest_static_nsp!(dir::AbstractString, root::AbstractString)
    src = joinpath(root, "static", "network_supply_points.csv")
    isfile(src) ||
        error("historical ingest: static network_supply_points not found at $src")
    normalise_to_parquet(src, joinpath(dir, "network_supply_points.parquet"))
    return src
end

"""
All-or-nothing ingest for one snapshot date. With `historical=true`, builds a
backtest-window snapshot: `final_energy_prices` from the ByMonth monthly file
sliced to the day, `network_supply_points` from the pinned static table, and
`final_reserve_prices` skipped (unused by the energy-only model). offers and
grid_demand use their normal (year-subfolder) URLs. On any failure the partial
snapshot directory is removed.
"""
function ingest!(date::Date; root::AbstractString, registry_path::AbstractString,
                 fetch = Downloads.download, historical::Bool = false)
    registry = load_registry(registry_path)
    dir = create_snapshot!(root, date)
    sources = Dict{String,String}()
    downloaded = Dict{String,String}()
    # Raw CSVs under data/raw/<date>/ are a transient download cache: they are
    # overwritten on re-runs and survive failed ingests (useful for retries).
    # The audit trail is the snapshot layer — hashed parquet + snapshot.json.
    try
        for spec in registry
            spec.required || continue
            key = "$(spec.name).parquet"
            if historical && spec.name == "final_reserve_prices"
                continue
            elseif historical && spec.name == "final_energy_prices"
                url, ts = _ingest_final_energy_bymonth!(spec, date, dir, root; fetch)
                sources[key] = url; downloaded[key] = ts
            elseif historical && spec.name == "network_supply_points"
                # Source is the local static path (no per-date URL exists historically);
                # an accurate, if machine-local, provenance record for the static table.
                sources[key] = _ingest_static_nsp!(dir, root)
                downloaded[key] = string(Dates.now(Dates.UTC))
            else
                csv_path, url, ts = download_to_raw!(spec, date, root; fetch)
                normalise_to_parquet(csv_path, joinpath(dir, key))
                sources[key] = url; downloaded[key] = ts
            end
        end
        isempty(sources) && error("registry $registry_path has no required datasets")
        return finalize_snapshot!(dir; sources, downloaded)
    catch
        rm(dir; recursive = true, force = true)
        rethrow()
    end
end
