select relname as table, n_live_tup as rows, pg_size_pretty(pg_total_relation_size(relid)) as size
from pg_stat_user_tables where n_live_tup > 0 order by n_live_tup desc;
