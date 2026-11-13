# emo-db benchmark results

Recorded 2026-11-13T01:03:29Z by `bench/run.sh` on Darwin arm64, c target.
Method: one warmup plus three timed runs, wall clock, the mean in
milliseconds per run; the database is recreated by the insert modes
and reseeded before the read modes. Only measured numbers appear.

| workload | size | ms per run | per second |
| --- | --- | ---: | ---: |
| INSERT, autocommit | 200 rows, one transaction each | 1160 | 172 inserts |
| INSERT, one transaction | 10000 rows, one COMMIT | 6680 | 1497 inserts |
| primary-key lookup | 10000 lookups over 10000 rows | 1037 | 9643 lookups |
| full table scan | 10000 rows, one SELECT | 580 | 17241 rows |
| UPDATE, autocommit | 200 rows by primary key | 1305 | 153 updates |
