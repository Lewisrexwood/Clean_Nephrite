using DataFrames, DuckDB, DBInterface, Dates, Downloads

# EMI Forward-markets (KOP4VM) CSV export. A range query (DateFrom/DateTo), so it
# does NOT fit the per-date datasets.toml template — its URL is built here.
# The space in "/Forward markets/" is percent-encoded (%20): Downloads.download
# does not encode it for us and EMI 404s on a raw space.
const FORWARD_CSV_BASE = "https://www.emi.ea.govt.nz/Forward%20markets/Download/DataReport/CSV/KOP4VM"

# KOP4VM CSV "Location" values -> our hub codes.
const FORWARD_LOCATION_TO_HUB = Dict("Otahuhu" => "OTA", "Benmore" => "BEN")

"Build the KOP4VM CSV-export URL for one location/commodity/duration over a date range."
function forward_url(; location::AbstractString, commodity::AbstractString,
                     duration::AbstractString, from::Date, to::Date,
                     instrument::AbstractString = "FUTURE")
    "$FORWARD_CSV_BASE?CommodityType=$commodity&Location=$location" *
    "&Duration=$duration&Instrument=$instrument" *
    "&DateFrom=$(Dates.format(from, "yyyymmdd"))&DateTo=$(Dates.format(to, "yyyymmdd"))"
end

"""
Download the KOP4VM forward+spot CSVs for each location x commodity into
`data/static/forward_prices/`. DELIBERATE manual action (no per-date template);
tests inject `fetch`.
"""
# Default duration is QTR: NZ electricity futures trade quarterly/calendar, so
# Duration=MTH returns only the spot series (no FUTURE quotes). QTR is the traded
# granularity; the harness maps the model's monthly curve onto these maturities.
function fetch_forward_prices!(; root::AbstractString, from::Date, to::Date,
                               locations = ["OTA", "BEN"], commodities = ["BASE", "PEAK"],
                               duration::AbstractString = "QTR",
                               fetch = Downloads.download)
    dir = joinpath(root, "static", "forward_prices")
    mkpath(dir)
    for loc in locations, com in commodities
        url  = forward_url(location = loc, commodity = com, duration = duration,
                           from = from, to = to)
        dest = joinpath(dir, "KOP4VM_$(loc)_$(com)_$(duration).csv")
        fetch(url, dest)
    end
    return dir
end

"""
    load_forward_prices(path) -> DataFrame

Parse a KOP4VM CSV into a tidy frame: settlement_date (Date, from DD/MM/YYYY),
location, hub (OTA/BEN), duration, commodity, series, price. Rows whose Location
is not a known hub are dropped.
"""
function load_forward_prices(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    raw = try
        DataFrame(DBInterface.execute(con,
            "SELECT \"Settlement Date\" AS sdate, \"Location\" AS location, " *
            "\"Duration\" AS duration, \"Commodity type\" AS commodity, " *
            "\"Series\" AS series, \"Price (\$/MWh)\" AS price " *
            "FROM read_csv_auto('$(sql_path(path))', all_varchar=true)"))
    finally
        DBInterface.close!(con); GC.gc()
    end
    out = DataFrame(settlement_date = Date[], location = String[], hub = String[],
                    duration = String[], commodity = String[], series = String[],
                    price = Float64[])
    for r in eachrow(raw)
        hub = get(FORWARD_LOCATION_TO_HUB, string(r.location), "")
        isempty(hub) && continue
        push!(out, (Date(string(r.sdate), dateformat"dd/mm/yyyy"),
                    string(r.location), hub, string(r.duration),
                    string(r.commodity), string(r.series), parse(Float64, string(r.price))))
    end
    return out
end
