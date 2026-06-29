using Dates, SHA, JSON3

const PROJECT_ROOT = dirname(@__DIR__)

git_commit() = try
    strip(read(setenv(`git rev-parse HEAD`; dir = PROJECT_ROOT), String))
catch
    "unknown"
end

git_dirty() = try
    !isempty(strip(read(setenv(`git status --porcelain`; dir = PROJECT_ROOT), String)))
catch
    true
end

"""
Everything needed to reproduce a run: code commit, dirty flag, Julia and
package versions (via Manifest.toml hash), data snapshot hashes, config
hashes, seed. A run is reproducible from its manifest alone.
"""
function build_manifest(; snapshot_dir::AbstractString,
                        config_paths::Vector{String}, seed::Int)
    snap = JSON3.read(read(joinpath(snapshot_dir, SNAPSHOT_MANIFEST), String))
    pkg_manifest = joinpath(PROJECT_ROOT, "Manifest.toml")
    return Dict(
        "created_utc"         => string(Dates.now(Dates.UTC)),
        "git_commit"          => git_commit(),
        "git_dirty"           => git_dirty(),
        "julia_version"       => string(VERSION),
        "pkg_manifest_sha256" => file_sha256(pkg_manifest),
        "snapshot_dir"        => abspath(snapshot_dir),
        "snapshot_files"      => [Dict(String(k) => v for (k, v) in pairs(e)) for e in snap["files"]],
        "config_hashes"       => Dict(p => file_sha256(p) for p in config_paths),
        "seed"                => seed,
    )
end

write_manifest(path::AbstractString, manifest::Dict) =
    open(io -> JSON3.write(io, manifest), path, "w")
