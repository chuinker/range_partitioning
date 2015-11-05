create table master (
    master_class oid not null primary key,
    partition_attribute text not null,
    range_type oid not null,
    insert_trigger_function text not null
);

comment on table master
is E'every table that is range partitioned will have an entry here.';

comment on column master.master_class
is E'points to the pg_class entry for the table that is partitioned';

comment on column master.partition_attribute
is E'the name of the column on which the table is partitioned';

comment on column master.range_type
is E'points to the range pg_type';

comment on column master.insert_trigger_function
is E'name of the trigger function created for this table';


create table partition (
    partition_class oid not null primary key,
    master_class oid not null references master(master_class),
    partition_number integer not null,
    range text not null,
    unique(master_class,partition_number)
);

comment on table partition
is E'every partition must have an entry in this table';

comment on column partition.master_class
is E'points to the pg_class entry for the table that is partitioned';

comment on column partition.partition_class
is E'points to the pg_class entry for the partition';

comment on column partition.partition_number
is E'the number of this partition, used only to ensure unique partition names';

comment on column partition.range
is E'text representation of the range enforced by the check constraint';

create or replace function create_trigger_function(p_master_class oid) returns void
language plpgsql as $$
begin
    execute format(E'create or replace function %s() returns trigger language plpgsql as $BODY$\n'
                    'begin\n%sreturn null;\nend;$BODY$',
                    ( select insert_trigger_function from master where master_class = p_master_class ),
                    trigger_iter(p_master_class));
end;
$$;

comment on function create_trigger_function(oid)
is E'(re)create a trigger function for the given table. This is run as a part of adding/removing partitions.';


create function partition_reflect() returns trigger
language plpgsql as $$
declare
    l_update_constraint boolean := false;
    l_constraint_name text;
begin
    select  format('%s_%s',c.relname,new.partition_number)
    into    strict l_constraint_name
    from    pg_class c
    where   c.oid = new.partition_class;

    if TG_OP = 'UPDATE' then
        if new.master_class <> old.master_class then
            raise exception '%', 'Cannot modify master_class';
        elsif new.partition_number <> old.partition_number then
            raise exception '%', 'Cannot modify partition_number';
        elsif new.partition_class <> old.partition_class then
            raise exception '%', 'Cannot modify partition_class';
        elsif new.range is distinct from old.range then
            -- the old constraint has to go
            execute format('alter table %s drop constraint %I',
                            new.partition_class::regclass::text,
                            l_constraint_name);
            l_update_constraint := true;
        end if;
    end if;

    if TG_OP = 'INSERT' then
        l_update_constraint := true;
        -- complete the inheritance
        execute format('alter table %s inherit %s',
                        new.partition_class::regclass::text,
                        new.master_class::regclass::text);
    end if;

    if l_update_constraint then
        execute format('alter table %s add constraint %I check (%s)',
                        new.partition_class::regclass::text,
                        l_constraint_name,
                        (   select  where_clause(m.partition_attribute,new.range,m.range_type::regtype::text)
                            from    master m
                            where   m.master_class = new.master_class ));
                        /*
                        ( select partition_attribute from master where master_class = new.master_class ),
                        new.range,
                        ( select range_type::regtype::text from master where master_class = new.master_class ));
                        */
    end if;

    return new;
end
$$;

comment on function partition_reflect() 
is E'Reflect whatever changes were made to the partition table in the actual metadata(constraints, inheritance) of the table.';

create trigger partition_reflect after insert or update on partition for each row execute procedure partition_reflect();

comment on trigger partition_reflect on partition
is E'Any changes made to the partition table should be reflected in the actual partition metadata';

create function range_type_info(p_range text, p_range_type text, empty out boolean,
                                lower out text, lower_inc out boolean, lower_inf out boolean,
                                upper out text, upper_inc out boolean, upper_inf out boolean)
language plpgsql set search_path from current as $$
begin
    execute format('select  lower(x.x)::text, upper(x.x)::text, isempty(x.x),
                            lower_inc(x.x), upper_inc(x.x), lower_inf(x.x), upper_inf(x.x) 
                    from    ( select $1::%1$I as x) x',p_range_type)
    using   p_range
    into strict lower, upper, empty, lower_inc, upper_inc, lower_inf, upper_inf;
end;
$$;

comment on function range_type_info(text, text, out text, out boolean, out boolean, out text, out boolean, out boolean)
is E'given a text representation of a range and the name of the range type, create that range\n'
    'and then run the lower(), upper(), lower_inc(), upper_inc(), lower_inf(), and upper_inf() functions';

create function where_clause(p_col text, p_range text, p_range_type text) returns text
language sql set search_path from current as $$
select  case
            when i.lower = i.upper then format('%I = %L',p_col,i.lower)
            when i.lower_inf and i.upper_inf then 'true'
            when i.empty then 'false'
            else    case
                        when i.lower_inf then ''
                        when i.lower_inc then format('%I >= %L',p_col,i.lower)
                        else format('%I > %L',p_col,i.lower)
                    end ||
                    case
                        when not i.lower_inf and not i.upper_inf then ' and ' 
                        else ''
                    end ||
                    case
                        when i.upper_inf then ''
                        when i.upper_inc then format('%I <= %L',p_col,i.upper)
                        else format('%I < %L',p_col,i.upper)
                    end
        end
from    range_type_info(p_range,p_range_type) i;
$$;


comment on function where_clause(text,text,text)
is E'construct a WHERE clause that would exactly fit the given column, range, and range_type';

create function where_clause(p_partition_class oid) returns text
language sql set search_path from current as $$
select  where_clause(m.partition_attribute,p.range,m.range_type::regtype::text)
from    partition p
join    master m
on      m.master_class = p.master_class
cross join
lateral range_type_info(p.range::text,m.range_type::regtype::text) i
where   p.partition_class = p_partition_class;
$$;

comment on function where_clause(oid)
is E'given a partiton oid, derive the WHERE clause that would exactly fit the range of the partition.';

create function trigger_iter(   p_master_class oid,
                                p_range in text default '(,)',
                                p_indent integer default 1)
returns text
language plpgsql set search_path from current as $$
declare
    r record;
    l_lower_range text := 'empty';
    l_upper_range text := 'empty';
    l_range_type text;
begin
    select  range_type::regtype::text
    into strict l_range_type
    from    master
    where   master_class = p_master_class;
    
    for r in execute format('select p.partition_class::regclass::text as partition_name,
                                    p.range,
                                    ( count(*) over () = 1 ) as is_only_partition,
                                    ( row_number() over(order by p.range::%1$s) < ((count(*) over () / 2) + 1) ) as is_lower_half
                            from partition p
                            where p.master_class = $1
                            and p.range::%1$s <@ $2::%1$s
                            order by range::%1$s',
                            l_range_type)
                            using p_master_class, p_range
    loop
        if r.is_only_partition then
            -- there is only one partition, so just insert into it
            return format(E'insert into %s values(new.*);\n', r.partition_name);
        elsif r.is_lower_half then
        --elsif r.partition_num < r.median_partition then
            -- add this partition to the lower range
            execute format('select $1::%1$s + $2::%1$s',l_range_type::regtype::text)
            using l_lower_range, r.range
            into l_lower_range;
        else
            -- add this partition to the upper range, good thing they're already in order
            execute format('select $1::%1$s + $2::%1$s',l_range_type::regtype::text)
            using l_upper_range, r.range
            into l_upper_range;
        end if;
    end loop;

    return  format(E'%1$sif new.%2$s <@ %3$L::%4$s then\n%5$s%1$selse\n%6$s%1$send if;',
                    repeat('  ',p_indent),
                    (select partition_attribute from master where master_class = p_master_class),
                    l_lower_range,
                    l_range_type,
                    trigger_iter(p_master_class, l_lower_range, p_indent + 1),
                    trigger_iter(p_master_class, l_upper_range, p_indent + 1));

end
$$;

comment on function trigger_iter(oid, text, integer)
is E'recursive function to do a binary traversal of the partitions in a table,\n'
    'generating IF/THEN tests to find the right partition.';

create function create_parent(  p_qual_table_name text,
                                p_range_column_name text,
                                p_dest_schema text default null) returns void
language plpgsql set search_path from current as $$
declare
    r record;
begin
    -- find the range type for the partitioning column, must find exactly one, fail otherwise
    select  c.oid as master_oid,
            rt.rngtypid as range_type_oid,
            format('%I.%I',n.nspname,c.relname) as source_table,
            format('%I.%I',coalesce(p_dest_schema,n.nspname),c.relname || '_p0') as partition_table,
            format('%I.%I',coalesce(p_dest_schema,n.nspname),c.relname || '_ins_trigger') as insert_trigger_function,
            format('%I',c.relname || '_ins_trig') as insert_trigger_name,
            rt.rngtypid::regtype::text
    into    strict r
    from    pg_class c
    join    pg_namespace n
    on      n.oid = c.relnamespace
    join    pg_attribute a
    on      a.attrelid = c.oid
    join    pg_range rt
    on      rt.rngsubtype = a.atttypid
    and     rt.rngcollation = a.attcollation
    join    pg_type t
    on      t.oid = rt.rngtypid
    where   c.oid = p_qual_table_name::regclass
    and     a.attname = p_range_column_name;

    -- create the table that will inherit from the master table
    execute format('create table %s(like %s including indexes)',
                    r.partition_table,
                    r.source_table);

    -- create the record and set the name of the trigger function so that it can be created
    insert into master 
    values (r.master_oid, p_range_column_name, r.range_type_oid, r.insert_trigger_function);

    -- inserting a row here will automatically add the constraint on the partition and complete the inheritance
    insert into partition(partition_class,master_class,partition_number,range)
    values (r.partition_table::regclass, r.master_oid, 0, '(,)');

    -- migrate rows to main partition
    execute format('with d as (delete from %s returning *) insert into %s select * from d',
                    r.source_table,
                    r.partition_table);

    perform create_trigger_function(r.master_oid);

    execute format('create trigger %s before insert on %s for each row execute procedure %s()',
                    r.insert_trigger_name,
                    p_qual_table_name,
                    r.insert_trigger_function);
end;
$$;

comment on function create_parent(text,text,text)
is E'Convert a normal table into the master table of a partition set.';

create function create_partition (  p_qual_table_name text,
                                    p_new_partition_range text) returns void 
language plpgsql set search_path from current as $$
declare
    mr master%rowtype;
    pr partition%rowtype;
    l_new_partition text;
    l_new_partition_number integer;
    l_range_difference text;
begin
    -- verify that we actually have a partitioned table
    select  *
    into strict mr
    from    master
    where   master_class = p_qual_table_name::regclass;

    -- figure out the number of the new partition that we are about to create
    select  max(partition_number) + 1
    into    l_new_partition_number
    from    partition
    where   master_class = mr.master_class;

    begin
        -- verify new range is entirely within an existing range, and matches one edge of that range
        execute format('select partition_class, (range::%1$s - $2::%1$s)::text
                        from partition
                        where master_class = $1
                        and range::%1$s @> $2::%1$s',
                        mr.range_type::regtype::text)
        using   mr.master_class, p_new_partition_range
        into strict pr.partition_class, l_range_difference;
    exception
        when no_data_found or data_exception then
            raise exception 'New range {%} must match have one boundary in common with an existing partition',
                            p_new_partition_range;
    end;

    if l_range_difference = 'empty' then
        raise notice 'New partition {%} exactly matches an existing partition {%}, skipping',
                        p_new_partition_range, pr.partition_class::regclass::text;
        return;
    end if;

    l_new_partition := format('%I.%I',
                                (   select n.nspname
                                    from pg_class c
                                    join pg_namespace n on n.oid = c.relnamespace
                                    where c.oid = pr.partition_class),
                                (   select c.relname || '_p' || l_new_partition_number
                                    from pg_class c
                                    where c.oid = mr.master_class ));

    -- create the table that will inherit from the master table
    execute format('create table %s(like %s including indexes)',
                    l_new_partition,
                    mr.master_class::regclass::text);

    -- inserting into partition will automatically add the check constraint on the table and complete the inherance
    insert into partition(partition_class,master_class,partition_number,range)
    values (l_new_partition::regclass, mr.master_class, l_new_partition_number, p_new_partition_range);

    -- migrate rows to main partition
    execute format('with d as (delete from %s where %I <@ %L::%s returning *) insert into %s select * from d',
                    pr.partition_class::regclass::text,
                    mr.partition_attribute,
                    p_new_partition_range,
                    mr.range_type::regtype::text,
                    l_new_partition);

    -- updating this table will drop the old constraint and create a new one
    update  partition
    set     range = l_range_difference
    where   partition_class = pr.partition_class;

    perform create_trigger_function(mr.master_class);
end;
$$;

comment on function create_partition(text,text)
is E'create a new partition by splitting it off from an existing partition.\n'
    'the range given must match the left side or right side of an existing partition or the operation will fail.';


create function drop_partition (p_drop_partition_name text,
                                p_adjacent_partition_name text) returns void 
language plpgsql set search_path from current as $$
declare
    l_range_union text;
    r record;
begin
    -- verify that both partitions exist
    select  m.partition_attribute as range_column,
            m.range_type,
            a.range as drop_range,
            b.range as keep_range,
            m.master_class::regclass::text as qual_master_table_name
    into strict r
    from    partition a
    join    partition b
    on      b.master_class = a.master_class
    join    master m
    on      m.master_class = a.master_class
    where   a.partition_class = p_drop_partition_name::regclass
    and     b.partition_class = p_adjacent_partition_name::regclass;

    -- verify that both partitions are adjacent, get the combined range
    begin
        execute format('select r.x + r.y from( select $1::%1$s as x, $2::%1$s as y ) as r where r.x -|- r.y',
                        r.range_type::regtype::text)
        using r.drop_range, r.keep_range
        into strict l_range_union;
    exception
        when no_data_found then
        raise exception '% cannot be merged into %s because it is not adjacent',
                        p_drop_partition_name,
                        p_adjacent_partition_name;
    end;

    -- reflect the change in the partition table, this will update the constraint as well
    update  partition
    set     range = l_range_union
    where   partition_class = p_adjacent_partition_name::regclass;

    -- move rows from doomed partition to survivor
    execute format('insert into %s select * from %s',
                    p_adjacent_partition_name::regclass::text,
                    p_drop_partition_name::regclass::text);

    -- delete the entry
    delete from partition where partition_class = p_drop_partition_name::regclass;

    -- drop doomed partition
    execute format('drop table %s',
                    p_drop_partition_name::regclass::text);
end;
$$;

comment on function drop_partition (text, text)
is E'merge two adjacent partitions into one single partition';

do $$
begin
    if not exists( select null from pg_roles where rolname = 'range_partitioning') then
        create role range_partitioning;
    end if;
end
$$;

grant select,insert,update, delete on master, partition to range_partitioning;
grant execute on function
    range_type_info(text, text, out text, out boolean, out boolean, out text, out boolean, out boolean),
    where_clause(text,text,text),
    where_clause(oid),
    trigger_iter(oid, text, integer),
    create_trigger_function(oid), 
    create_parent(text, text, text),
    create_partition (text, text),
    drop_partition (text, text) 
    to range_partitioning;


