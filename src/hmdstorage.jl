using DataFrames, DuckDB, DBInterface, Dates

# HMD storage file (lake) -> JADE reservoir name(s). Manapouri + Te Anau both
# map into the single JADE reservoir Lakes_Manapouri_Te_Anau (their Mm3 sum).
# Lake_Ohau and Lake_Waikaremoana have no HMD file -> a documented small
# under-count of the aggregate (acceptable: the aggregate is re-disaggregated
# to all reservoirs by the model's share model).
const HMD_TO_RESERVOIR = Dict{String,Vector{String}}(
    "NI_TPO_Storage_LakeTaupo.csv"     => ["Lake_Taupo"],
    "SI_HWE_Storage_LakeHawea.csv"     => ["Lake_Hawea"],
    "SI_PKI_Storage_LakePukaki.csv"    => ["Lake_Pukaki"],
    "SI_TKA_Storage_LakeTekapo.csv"    => ["Lake_Tekapo"],
    "SI_MAN_Storage_LakeManapouri.csv" => ["Lakes_Manapouri_Te_Anau"],
    "SI_TAU_Storage_LakeTeAnau.csv"    => ["Lakes_Manapouri_Te_Anau"],
)

"""
Provider of historical aggregate storage (GWh) reconstructed from HMD per-lake
active storage (Mm3). `lake_series` maps each present HMD filename to a sorted
(date, mm3) frame; `lake_map` maps filenames to JADE reservoir name(s).
"""
struct HMDStorageProvider
    lake_series::Dict{String,DataFrame}
    lake_map::Dict{String,Vector{String}}
    net::HydroNetwork
end

# Read one HMD CSV -> sorted DataFrame(date::Date, mm3::Float64), dropping null storage.
function _read_hmd_series(path::AbstractString)
    con = DBInterface.connect(DuckDB.DB)
    df = try
        DataFrame(DBInterface.execute(con,
            "SELECT \"Date\" AS date, \"Active storage (Mm³)\" AS mm3 " *
            "FROM read_csv_auto('$(sql_path(path))') " *
            "WHERE \"Active storage (Mm³)\" IS NOT NULL"))
    finally
        DBInterface.close!(con); GC.gc()
    end
    df.date = Date.(string.(df.date))      # ISO yyyy-mm-dd (robust to Date or String)
    df.mm3  = Float64.(df.mm3)
    sort!(df, :date)
    return df
end

function build_hmd_provider(hmd_dir::AbstractString, net::HydroNetwork;
                            lake_map::Dict{String,Vector{String}} = HMD_TO_RESERVOIR)
    series = Dict{String,DataFrame}()
    for fname in keys(lake_map)
        path = joinpath(hmd_dir, fname)
        isfile(path) || continue           # tolerate absent lakes
        series[fname] = _read_hmd_series(path)
    end
    isempty(series) && error("build_hmd_provider: no HMD files found in $hmd_dir")
    return HMDStorageProvider(series, lake_map, net)
end

function _value_on_or_before(df::DataFrame, date::Date)
    idx = searchsortedlast(df.date, date)
    idx == 0 && error("hmdstorage: no reading on or before $date " *
                      "(series starts $(first(df.date)))")
    return df.mm3[idx]
end

"""
    historical_storage(p, date) -> (nz_gwh, si_gwh)

Aggregate stored energy (GWh) on `date`: per-reservoir Mm3 (nearest HMD reading
on or before `date`) converted to energy via `downstream_energy_coeff`. `nz_gwh`
is all reservoirs; `si_gwh` is the SI subset (NI = nz - si, as the model expects).
"""
function historical_storage(p::HMDStorageProvider, date::Date)
    vols = Dict{String,Float64}()
    for (fname, df) in p.lake_series
        v = _value_on_or_before(df, date)
        for rname in p.lake_map[fname]
            vols[rname] = get(vols, rname, 0.0) + v
        end
    end
    coeff = downstream_energy_coeff(p.net)
    nz = 0.0; si = 0.0
    for r in p.net.reservoirs
        e = get(vols, r.name, 0.0) * get(coeff, r.name, 0.0) * MWH_PER_MM3_PER_SP / 1000
        nz += e
        r.island == "SI" && (si += e)
    end
    return (nz_gwh = nz, si_gwh = si)
end
