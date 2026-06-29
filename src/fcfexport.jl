using DataFrames
using DuckDB, DBInterface

# fcfexport.jl — write/read the per-reservoir water-value table.
# Long format: reservoir, storage_gwh, water_value (+ optional week).
# A per-reservoir extension of the storage-vs-water-value breakpoint idea used by
# terminal_water_value.csv (a single aggregate stored_energy/value curve);
# reuses _write_csv.

"Long DataFrame of all curves, sorted by reservoir then storage. Optional `week` column."
function fcf_dataframe(curves::Dict{String,Curve}; week::Union{Int,Nothing} = nothing)
    res = String[]; sg = Float64[]; wv = Float64[]
    for r in sort(collect(keys(curves)))
        c = curves[r]
        append!(res, fill(r, length(c.storage_gwh)))
        append!(sg, c.storage_gwh)
        append!(wv, c.water_value)
    end
    df = DataFrame(reservoir = res, storage_gwh = sg, water_value = wv)
    week === nothing || insertcols!(df, :week => fill(week, nrow(df)))
    return df
end

"Write the curve table to CSV via the shared DuckDB writer."
function write_fcf(curves::Dict{String,Curve}, path::AbstractString; week::Union{Int,Nothing} = nothing)
    _write_csv(fcf_dataframe(curves; week = week), path)
    return path
end

"Read a curve table CSV back into a Dict of Curves."
function read_fcf(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    try
        df = DataFrame(DBInterface.execute(con,
            "SELECT reservoir, storage_gwh, water_value FROM read_csv_auto('$(sql_path(path))') " *
            "ORDER BY reservoir, storage_gwh"))
        curves = Dict{String,Curve}()
        for g in groupby(df, :reservoir)
            r = String(g.reservoir[1])
            curves[r] = Curve(r, Float64.(g.storage_gwh), Float64.(g.water_value))
        end
        return curves
    finally
        DBInterface.close!(con)
        GC.gc()
    end
end
