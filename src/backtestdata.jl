using DataFrames, Dates

"Weekly (or strided) backtest dates from `from` to `to` inclusive."
backtest_dates(from::Date, to::Date; stride_days::Int = 7) =
    backfill_dates(from, to, stride_days)

"True if `storage` can return a reading on or before `date`."
function _has_storage(storage::HMDStorageProvider, date::Date)
    try
        historical_storage(storage, date)
        return true
    catch
        return false
    end
end

"""
    backtest_coverage(dates; root, storage, forward) -> DataFrame

Per-date data presence so a harness can iterate and skip gaps loudly:
- `has_snapshot` — a finalized snapshot exists for the date.
- `has_storage`  — the storage provider has a reading on or before the date.
- `has_forward`  — the forward frame has ANY quote settled on or before the date.
  This is a coarse, hub-agnostic probe (it does not distinguish OTA vs BEN or
  BASE vs PEAK); a harness needing per-hub/per-commodity presence must check the
  forward frame itself, not this flag.
"""
function backtest_coverage(dates::Vector{Date}; root::AbstractString,
                           storage::HMDStorageProvider, forward::DataFrame)
    out = DataFrame(date = Date[], has_snapshot = Bool[], has_storage = Bool[],
                    has_forward = Bool[])
    for d in dates
        has_snap = is_complete(snapshot_dir(root, d))
        has_stor = _has_storage(storage, d)
        has_fwd  = any(forward.settlement_date .<= d)
        push!(out, (d, has_snap, has_stor, has_fwd))
    end
    return out
end
