-- Add B-tree indexes for competition foreign keys only when no existing index
-- already covers the same leading key columns.
do $$
declare r record; v_index_name text;
begin
 for r in
  select c.conrelid::regclass as table_name,
   string_agg(quote_ident(a.attname),', ' order by k.ordinality) as column_list,
   string_agg(a.attname,'_' order by k.ordinality) as column_slug,
   array_agg(a.attnum order by k.ordinality)::smallint[] as column_attnums
  from pg_constraint c
  join pg_namespace n on n.oid=(select relnamespace from pg_class where oid=c.conrelid)
  cross join lateral unnest(c.conkey) with ordinality as k(attnum,ordinality)
  join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum
  where c.contype='f' and n.nspname='public'
   and (c.conrelid::regclass::text like 'competition_%' or c.conrelid::regclass::text='company_templates')
  group by c.conrelid,c.conkey
 loop
  v_index_name:=left('idx_'||replace(r.table_name::text,'.','_')||'_'||r.column_slug,63);
  if not exists(
   select 1 from pg_index i
   where i.indrelid=r.table_name::regclass and i.indisvalid
    and i.indnkeyatts>=cardinality(r.column_attnums)
    and (
     select array_agg(k.attnum order by k.ordinality)
     from unnest(i.indkey::smallint[]) with ordinality as k(attnum,ordinality)
     where k.ordinality<=cardinality(r.column_attnums)
    )=r.column_attnums
  ) then
   execute format('create index if not exists %I on %s (%s)',v_index_name,r.table_name,r.column_list);
  end if;
 end loop;
end $$;