using TOML, Dates, DataFrames

struct FleetChange
    name::String
    hub::String
    technology::String
    capacity_mw::Float64
    energy_mwh::Float64
    effective::Date
    kind::String       # "addition" | "retirement"
    source_note::String
end

struct Fleet
    projects::Vector{FleetChange}
end

const FLEET_TECHNOLOGIES = ("wind", "solar", "geothermal", "battery", "thermal", "hydro")

function load_fleet(path::AbstractString)
    cfg = TOML.parsefile(path)
    changes = FleetChange[]
    for p in get(cfg, "projects", [])
        push!(changes, FleetChange(p["name"], p["hub"], p["technology"],
                                   Float64(p["capacity_mw"]),
                                   Float64(get(p, "energy_mwh", 0.0)),
                                   Date(p["commissioning"]), "addition",
                                   p["source_note"]))
    end
    for r in get(cfg, "retirements", [])
        push!(changes, FleetChange(r["name"], r["hub"], r["technology"],
                                   Float64(r["capacity_mw"]), 0.0,
                                   Date(r["date"]), "retirement", r["source_note"]))
    end
    for c in changes
        c.hub in HUB_CODES || error("fleet: $(c.name) has unknown hub $(c.hub)")
        c.technology in FLEET_TECHNOLOGIES ||
            error("fleet: $(c.name) has unknown technology $(c.technology)")
        c.capacity_mw > 0 || error("fleet: $(c.name) has non-positive capacity")
    end
    return Fleet(changes)
end

"Fleet changes effective on or before `date`, as a DataFrame."
function fleet_changes(fleet::Fleet, date::Date)
    rows = [(name = c.name, hub = c.hub, technology = c.technology,
             capacity_mw = c.capacity_mw, energy_mwh = c.energy_mwh,
             effective = c.effective, kind = c.kind)
            for c in fleet.projects if c.effective <= date]
    return isempty(rows) ?
        DataFrame(name = String[], hub = String[], technology = String[],
                  capacity_mw = Float64[], energy_mwh = Float64[],
                  effective = Date[], kind = String[]) :
        DataFrame(rows)
end
