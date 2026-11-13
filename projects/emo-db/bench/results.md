# emo-db benchmark results

Recorded 2026-11-13T02:26:45Z by `bench/run.sh` on Darwin arm64, c target.
Method: one warmup plus three timed runs, wall clock, the mean in
milliseconds per run; the database is recreated by the insert modes
and reseeded before the read modes. Only measured numbers appear.

| workload | size | ms per run | per second |
| --- | --- | ---: | ---: |
| INSERT, autocommit | 200 rows, one transaction each | 1283 | 156 inserts |
| INSERT, one transaction | 10000 rows, one COMMIT | 7168 | 1395 inserts |
| primary-key lookup | 10000 lookups over 10000 rows | 1129 | 8857 lookups |
| full table scan | 10000 rows, one SELECT | 675 | 14815 rows |
| UPDATE, autocommit | 200 rows by primary key | 1196 | 167 updates |
| column-store scan | 10000 rows, one SELECT | 304 | 32895 rows |
| column-store aggregate | count(*), sum(id), avg(score) over 10000 rows | 142 | 70423 rows |
