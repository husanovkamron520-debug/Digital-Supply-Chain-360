-- Add B-tree indexes for competition foreign keys to support joins and parent-row updates/deletes.
do $$
declare r record; v_index_name text;
begin
 for r in
  select c.conrelid::regclass as table_name,
   string_agg(quote_ident(a.attname),', ' order by k.ordinality) as column_list,
   string_agg(a.attname,'_' order by k.ordinality) as column_slug
  from pg_constraint c
  join pg_namespace n on n.oid=(select relnamespace from pg_class where oid=c.conrelid)
  cross join lateral unnest(c.conkey) with ordinality as k(attnum,ordinality)
  join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k.attnum
  where c.contype='f' and n.nspname='public'
   and (c.conrelid::regclass::text like 'competition_%' or c.conrelid::regclass::text='company_templates')
  group by c.conrelid,c.conkey
 loop
  v_index_name:=left('idx_'||replace(r.table_name::text,'.','_')||'_'||r.column_slug,63);
  execute format('create index if not exists %I on %s (%s)',v_index_name,r.table_name,r.column_list);
 end loop;
end $$;
