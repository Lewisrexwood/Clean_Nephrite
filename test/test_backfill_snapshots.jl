using Dates

@testset "backfill_snapshots!" begin
    @testset "ingests a strided range and is idempotent" begin
        mktempdir() do root
            registry_path = write_test_registry(mktempdir())
            calls = Ref(0)
            counting_fetch(url, dest) = (calls[] += 1; fake_fetch(url, dest))

            r1 = Nephrite.backfill_snapshots!(Date(2024,1,1), Date(2024,1,8);
                root = root, registry_path = registry_path, stride = 7,
                fetch = counting_fetch)
            @test r1.downloaded == 2                       # Jan 1 and Jan 8
            @test Nephrite.is_complete(Nephrite.snapshot_dir(root, Date(2024,1,1)))
            @test Nephrite.is_complete(Nephrite.snapshot_dir(root, Date(2024,1,8)))
            first_calls = calls[]

            r2 = Nephrite.backfill_snapshots!(Date(2024,1,1), Date(2024,1,8);
                root = root, registry_path = registry_path, stride = 7,
                fetch = counting_fetch)
            @test r2.downloaded == 0
            @test r2.skipped == 2
            @test calls[] == first_calls                   # re-run fetches nothing
        end
    end
end
