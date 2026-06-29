using Dates, DataFrames
using DuckDB, DBInterface

struct DataStore
    con::DuckDB.DB
    dir::String
end

"""
Open DuckDB views over a complete snapshot. One view per parquet file,
named after the dataset (offers, final_energy_prices, ...). The model run
for date D may only read snapshot D — this is the single entry point.
"""
function open_datastore(root::AbstractString, date::Date)
    dir = latest_snapshot_dir(root, date)
    con = DBInterface.connect(DuckDB.DB)
    try
        for f in sort(readdir(dir))
            endswith(f, ".parquet") || continue
            view = replace(f, ".parquet" => "")
            occursin(r"^[a-z][a-z0-9_]*$", view) ||
                error("invalid dataset/view name: $view (must be lower snake_case)")
            DBInterface.execute(con,
                "CREATE VIEW $view AS SELECT * FROM read_parquet('$(sql_path(joinpath(dir, f)))')")
        end
    catch
        DBInterface.close!(con)
        rethrow()
    end
    return DataStore(con, dir)
end

query(ds::DataStore, sql::AbstractString) =
    DataFrame(DBInterface.execute(ds.con, sql))

Base.close(ds::DataStore) = DBInterface.close!(ds.con)
