package teslrt

// Canonical framing is checked independently inside the protected retirement
// function. Empty finality arrays alone never authorize table retirement.
func pgRowTableContractFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	return []pgMigrationControlFunction{
		{"tesl_row_canonical_children", "doc bytea", "bytea[]", "immutable", `
declare pos integer:=0; size integer:=pg_catalog.octet_length(doc); start_pos integer; begin_child integer;
 count_value integer; digit integer; token integer; root_count integer; pending bigint; i integer; nodes integer:=0;
 result bytea[]:=array[]::bytea[];
begin
 if doc is null or size<3 or size>67108864 or pg_catalog.get_byte(doc,0)<>108 then raise exception 'tesl: canonical list required'; end if;
 pos:=1;start_pos:=pos;count_value:=0;
 while pos<size and pg_catalog.get_byte(doc,pos)<>58 loop
  digit:=pg_catalog.get_byte(doc,pos)-48;
  if digit<0 or digit>9 or pos-start_pos>=7 or (pos>start_pos and pg_catalog.get_byte(doc,start_pos)=48) then raise exception 'tesl: noncanonical list length'; end if;
  count_value:=count_value*10+digit;pos:=pos+1;
 end loop;
 if pos=start_pos or pos>=size or count_value>1000000 then raise exception 'tesl: invalid canonical list length'; end if;
 root_count:=count_value;pos:=pos+1;
 if root_count>0 then for i in 1..root_count loop
  begin_child:=pos;pending:=1;
  while pending>0 loop
   nodes:=nodes+1;
   if nodes>1000000 or pos>=size then raise exception 'tesl: truncated canonical child'; end if;
   token:=pg_catalog.get_byte(doc,pos);
   if token not in (108,115) then raise exception 'tesl: invalid canonical token'; end if;
   pos:=pos+1;start_pos:=pos;count_value:=0;
   while pos<size and pg_catalog.get_byte(doc,pos)<>58 loop
    digit:=pg_catalog.get_byte(doc,pos)-48;
    if digit<0 or digit>9 or pos-start_pos>=8 or (pos>start_pos and pg_catalog.get_byte(doc,start_pos)=48) then raise exception 'tesl: noncanonical child length'; end if;
    count_value:=count_value*10+digit;pos:=pos+1;
   end loop;
   if pos=start_pos or pos>=size then raise exception 'tesl: truncated canonical length'; end if;
   pos:=pos+1;pending:=pending-1;
   if token=115 then
    if count_value>size-pos then raise exception 'tesl: truncated canonical atom'; end if;
    pos:=pos+count_value;
   else
    if count_value>1000000 then raise exception 'tesl: oversized canonical list'; end if;
    pending:=pending+count_value;
   end if;
  end loop;
  result:=pg_catalog.array_append(result,pg_catalog.substring(doc,begin_child+1,pos-begin_child));
 end loop; end if;
 if pos<>size then raise exception 'tesl: trailing canonical bytes'; end if;
 return result;
end`},
		{"tesl_row_table_contract_valid", "doc bytea, physical bytea, settled bytea, predecessor bytea, v integer", "boolean", "immutable", `
declare d bytea[]; p bytea[]; s bytea[]; prior bytea[]; envelope bytea[];
 retirements bytea[]; retirement bytea[]; entities bytea[]; survivors bytea[]; old_entities bytea[];
 parts bytea[]; raw bytea; normalized bytea; dropped bytea;
 normalized_prior bytea[]:=array[]::bytea[]; normalized_survivors bytea[]:=array[]::bytea[]; expected_survivors bytea[]:=array[]::bytea[]; identities bytea[]:=array[]::bytea[];
 expected_behavior bytea; expected_ops bytea; empty_list bytea:=pg_catalog.convert_to('l0:','UTF8');
begin
 envelope:=` + ns + `tesl_row_canonical_children(doc);
 if pg_catalog.cardinality(envelope)<>4 or envelope[1]<>pg_catalog.convert_to('s24:tesl-migration-canonical','UTF8') or envelope[2]<>pg_catalog.convert_to('s1:1','UTF8') or envelope[3]<>pg_catalog.convert_to('s8:contract','UTF8') then return false; end if;
 d:=` + ns + `tesl_row_canonical_children(envelope[4]);
 if pg_catalog.cardinality(d)<>10 or d[1]<>pg_catalog.convert_to('s22:tesl-table-contract-v1','UTF8') then return false; end if;
 envelope:=` + ns + `tesl_row_canonical_children(physical);
 if pg_catalog.cardinality(envelope)<>4 or envelope[1]<>pg_catalog.convert_to('s24:tesl-migration-canonical','UTF8') or envelope[2]<>pg_catalog.convert_to('s1:1','UTF8') or envelope[3]<>pg_catalog.convert_to('s9:migration','UTF8') then return false; end if;
 p:=` + ns + `tesl_row_canonical_children(envelope[4]);
 envelope:=` + ns + `tesl_row_canonical_children(settled);
 if pg_catalog.cardinality(envelope)<>4 or envelope[1]<>pg_catalog.convert_to('s24:tesl-migration-canonical','UTF8') or envelope[2]<>pg_catalog.convert_to('s1:1','UTF8') or envelope[3]<>pg_catalog.convert_to('s9:migration','UTF8') then return false; end if;
 s:=` + ns + `tesl_row_canonical_children(envelope[4]);
 envelope:=` + ns + `tesl_row_canonical_children(predecessor);
 if pg_catalog.cardinality(envelope)<>4 or envelope[1]<>pg_catalog.convert_to('s24:tesl-migration-canonical','UTF8') or envelope[2]<>pg_catalog.convert_to('s1:1','UTF8') or envelope[3]<>pg_catalog.convert_to('s9:migration','UTF8') then return false; end if;
 prior:=` + ns + `tesl_row_canonical_children(envelope[4]);
 if pg_catalog.cardinality(d)<>10 or d[1]<>pg_catalog.convert_to('s22:tesl-table-contract-v1','UTF8') or
 pg_catalog.cardinality(p)<>10 or p[1]<>pg_catalog.convert_to('s33:tesl-retained-physical-version-v5','UTF8') or
 pg_catalog.cardinality(s)<>8 or s[1]<>pg_catalog.convert_to('s32:tesl-settled-physical-version-v1','UTF8') or
 pg_catalog.cardinality(prior) not in (8,9,10) or
 d[2]<>p[2] or d[3]<>p[3] or d[4]<>p[4] or d[5]<>p[5] or
 s[2]<>p[2] or s[3]<>p[3] or s[4]<>p[4] or s[5]<>p[5] or s[6]<>p[6] or
 prior[2]<>p[2] or prior[3]<>p[3] or
 p[4]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(v::text,'UTF8')) or
 prior[4]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to((v-1)::text,'UTF8')) or
 p[8]<>empty_list or s[8]<>empty_list or d[9]<>empty_list or
 d[7]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(pg_catalog.encode(pg_catalog.sha256(physical),'hex'),'UTF8')) or
 d[8]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(pg_catalog.encode(pg_catalog.sha256(settled),'hex'),'UTF8')) then return false; end if;
 retirements:=` + ns + `tesl_row_canonical_children(p[10]);
 if pg_catalog.cardinality(retirements)<>1 then return false; end if;
 retirement:=` + ns + `tesl_row_canonical_children(retirements[1]);
 if pg_catalog.cardinality(retirement)<>3 or retirement[2]<>prior[5] or retirement[3]<>p[5] then return false; end if;
 expected_behavior:=pg_catalog.convert_to('l4:s24:tesl-migration-canonicals1:1s8:contractl5:s24:tesl-table-retirement-v1','UTF8')||p[2]||p[3]||p[4]||p[10];
 if d[6]<>` + ns + `tesl_queue_bytes(pg_catalog.convert_to(pg_catalog.encode(pg_catalog.sha256(expected_behavior),'hex'),'UTF8')) then return false; end if;
 entities:=` + ns + `tesl_row_canonical_children(p[7]);survivors:=` + ns + `tesl_row_canonical_children(s[7]);
 old_entities:=` + ns + `tesl_row_canonical_children(prior[7]);
 if pg_catalog.cardinality(survivors)=0 or pg_catalog.cardinality(entities)<>pg_catalog.cardinality(survivors)+1 then return false; end if;
 foreach raw in array entities loop
  parts:=` + ns + `tesl_row_canonical_children(raw);
  if pg_catalog.cardinality(parts)<>10 or parts[9]<>empty_list or parts[10]<>empty_list or parts[1]=any(identities) then return false; end if;
  identities:=pg_catalog.array_append(identities,parts[1]);
  if parts[1]=retirement[1] then
   if dropped is not null then return false; end if;
   dropped:=raw;
  else expected_survivors:=pg_catalog.array_append(expected_survivors,raw);
  end if;
 end loop;
 foreach raw in array old_entities loop
  parts:=` + ns + `tesl_row_canonical_children(raw);
  if pg_catalog.cardinality(parts) not in (9,10) then return false; end if;
  if pg_catalog.cardinality(parts)=9 then normalized:=pg_catalog.convert_to('l10:','UTF8')||pg_catalog.substring(raw,4)||empty_list; else normalized:=raw; end if;
  normalized_prior:=pg_catalog.array_append(normalized_prior,normalized);
 end loop;
 foreach raw in array survivors loop
  parts:=` + ns + `tesl_row_canonical_children(raw);
  if pg_catalog.cardinality(parts)<>9 then return false; end if;
  normalized_survivors:=pg_catalog.array_append(normalized_survivors,pg_catalog.convert_to('l10:','UTF8')||pg_catalog.substring(raw,4)||empty_list);
 end loop;
 if dropped is null or entities<>normalized_prior or expected_survivors<>normalized_survivors then return false; end if;
 expected_ops:=pg_catalog.convert_to('l1:l3:s10:drop-table','UTF8')||retirement[1]||dropped;
 return d[10]=expected_ops;
end`},
	}
}
