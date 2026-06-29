using TOML, DataFrames

const HUB_CODES = ["OTA", "WKM", "RDF", "HAY", "KIK", "ISL", "BEN", "INV"]

struct HubMap
    poc_to_hub::Dict{String,String}
end

"""
Build the POC->hub map from the snapshot's network supply points table plus
config rules (config/hubmap.toml). Resolution order:
1. Exact POC override (wins over everything, including multi-region conflicts).
2. All distinct non-null regions for the POC map to exactly one hub → assign it.
3. POC has no non-null regions and no override → added to `unmapped` (error).
4. POC's non-null regions map to more than one distinct hub and no override →
   added to `conflicts` (error). Add a poc_override to resolve deliberately.

Either `unmapped` or `conflicts` non-empty raises an error. Mapping must be
deliberate — there is no silent default.
"""
function build_hubmap(ds::DataStore, config_path::AbstractString)
    cfg = TOML.parsefile(config_path)
    poc_col = cfg["columns"]["poc"]
    region_col = cfg["columns"]["region"]
    region_to_hub = Dict{String,String}(cfg["region_to_hub"])
    overrides = Dict{String,String}(get(cfg, "poc_overrides", Dict{String,Any}()))

    for (k, v) in region_to_hub
        v in HUB_CODES || error("hubmap: region $k maps to unknown hub $v")
    end
    for (k, v) in overrides
        v in HUB_CODES || error("hubmap: override $k maps to unknown hub $v")
    end

    # Distinct non-null (poc, region) pairs.
    df_regions = query(ds,
        "SELECT DISTINCT \"$poc_col\" AS poc, \"$region_col\" AS region " *
        "FROM network_supply_points WHERE \"$region_col\" IS NOT NULL")
    # Full set of POCs (including null-region-only ones).
    df_all = query(ds,
        "SELECT DISTINCT \"$poc_col\" AS poc FROM network_supply_points")

    # Build poc -> set of hubs from non-null regions.
    poc_hubs = Dict{String,Set{String}}()
    for row in eachrow(df_regions)
        poc = String(row.poc)
        region = String(row.region)
        if haskey(region_to_hub, region)
            push!(get!(poc_hubs, poc, Set{String}()), region_to_hub[region])
        else
            # Region exists but has no hub mapping — treat as unmapped below.
            get!(poc_hubs, poc, Set{String}())
        end
    end

    poc_to_hub = Dict{String,String}()
    unmapped  = String[]
    conflicts = String[]

    for row in eachrow(df_all)
        poc = String(row.poc)
        if haskey(overrides, poc)
            poc_to_hub[poc] = overrides[poc]
            continue
        end
        hubs = get(poc_hubs, poc, Set{String}())
        if isempty(hubs)
            # No non-null regions map to a known hub (or all regions are null).
            push!(unmapped, "$poc (no mapped region)")
        elseif length(hubs) == 1
            poc_to_hub[poc] = first(hubs)
        else
            # Gather the (region → hub) pairs for the error message.
            region_detail = String[]
            for rrow in eachrow(df_regions)
                String(rrow.poc) == poc || continue
                r = String(rrow.region)
                h = get(region_to_hub, r, nothing)
                h === nothing && continue
                push!(region_detail, "$r→$h")
            end
            detail_str = join(sort(unique(region_detail)), ", ")
            push!(conflicts, "$poc (regions: $detail_str)")
        end
    end

    isempty(unmapped) ||
        error("hubmap: unmapped POCs — add regions or overrides to hubmap.toml:\n" *
              join(first(unmapped, 20), "\n"))
    isempty(conflicts) ||
        error("hubmap: POCs span multiple hubs — add a poc_override to resolve deliberately:\n" *
              join(first(conflicts, 20), "\n"))

    return HubMap(poc_to_hub)
end

hub_for(hm::HubMap, poc::AbstractString) =
    get(hm.poc_to_hub, poc) do
        error("hubmap: unknown POC $poc — not in network supply points table")
    end
