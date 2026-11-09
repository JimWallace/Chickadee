-- Foreign keys whose referencing columns have no index that starts with them.
-- Every delete/update of a referenced row scans the referencing table.
select c.conrelid::regclass as referencing_table,
       string_agg(a.attname, ',' order by x.n) as fk_columns,
       c.confrelid::regclass as referenced_table,
       c.confdeltype as on_delete,
       pg_size_pretty(pg_relation_size(c.conrelid)) as referencing_size,
       (select n_live_tup from pg_stat_user_tables t where t.relid = c.conrelid) as referencing_rows
from pg_constraint c
cross join lateral unnest(c.conkey) with ordinality as x(attnum, n)
join pg_attribute a on a.attrelid = c.conrelid and a.attnum = x.attnum
where c.contype = 'f'
  and not exists (
    select 1 from pg_index i
    where i.indrelid = c.conrelid
      and (i.indkey::int2[])[0:cardinality(c.conkey) - 1] @> c.conkey
      and (i.indkey::int2[])[0] = c.conkey[1])
group by c.conrelid, c.confrelid, c.confdeltype, c.conname
order by referencing_rows desc nulls last;
