using Dates, SHA, JSON3

const SNAPSHOT_MANIFEST = "snapshot.json"

snapshot_dir(root::AbstractString, date::Date) =
    joinpath(root, "snapshots", Dates.format(date, "yyyy-mm-dd"))

raw_dir(root::AbstractString, date::Date) =
    joinpath(root, "raw", Dates.format(date, "yyyy-mm-dd"))

is_complete(dir::AbstractString) = isfile(joinpath(dir, SNAPSHOT_MANIFEST))

file_sha256(path::AbstractString) = bytes2hex(open(sha256, path))

"""
Create a writable snapshot directory for `date`. Finalized snapshots are
immutable: if one exists for this date, a suffixed sibling (`_2`, `_3`, ...)
is created instead. Never overwrites.
"""
function create_snapshot!(root::AbstractString, date::Date)
    base = snapshot_dir(root, date)
    dir = base
    # base (no suffix) is slot 1; siblings start at _2.
    n = 1
    while is_complete(dir)
        n += 1
        dir = base * "_$n"
    end
    mkpath(dir)
    return dir
end

"""
Resolve the newest finalized snapshot for `date` (base dir or highest
contiguous finalized sibling; `create_snapshot!` produces a contiguous
sequence). Errors if no finalized snapshot exists.
"""
function latest_snapshot_dir(root::AbstractString, date::Date)
    base = snapshot_dir(root, date)
    latest = is_complete(base) ? base : nothing
    n = 2
    while is_complete(base * "_$n")  # suffix is part of the dir name, not a path segment
        latest = base * "_$n"
        n += 1
    end
    latest === nothing &&
        error("no finalized snapshot for $date under $root — run ingest! first " *
              "(no silent fallback to stale data)")
    return latest
end

"""
Finalize a snapshot: hash every file, record sources, write snapshot.json.
After this the folder is immutable by convention (enforced by create_snapshot!).
"""
function finalize_snapshot!(dir::AbstractString; sources::Dict{String,String},
                            downloaded::Dict{String,String} = Dict{String,String}())
    files = sort([f for f in readdir(dir)
                  if f != SNAPSHOT_MANIFEST && isfile(joinpath(dir, f))])
    isempty(files) && error("refusing to finalize empty snapshot: $dir")
    entries = [Dict("name" => f,
                    "sha256" => file_sha256(joinpath(dir, f)),
                    "source" => get(sources, f, "unknown"),
                    "downloaded_utc" => get(downloaded, f, "unknown"))
               for f in files]
    manifest = Dict("created_utc" => string(Dates.now(Dates.UTC)),
                    "files" => entries)
    tmp = joinpath(dir, SNAPSHOT_MANIFEST * ".tmp")
    open(tmp, "w") do io
        JSON3.write(io, manifest)
    end
    mv(tmp, joinpath(dir, SNAPSHOT_MANIFEST))
    return manifest
end
