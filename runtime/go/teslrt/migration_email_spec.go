package teslrt

// Exact Owner-owned definitions. Request cannot choose claim tokens or retry
// state; schema Worker cannot dispatch. SMTP delivery remains at-least-once.
func pgEmailFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	table := ns + pgEmailTable
	admit := `
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then raise exception 'tesl: email requires read committed'; end if;
 if v is null or v<1 or v>2147483646 then raise exception 'tesl: invalid email version'; end if;
 select meta.fence_ns into fence from ` + ns + `tesl_schema_meta meta where meta.id=1 and meta.format_version=5;
 if not found then raise exception 'tesl: email requires format5'; end if;
 perform pg_catalog.pg_advisory_xact_lock_shared(fence,v);
 perform ` + ns + `tesl_row_admit_version(v);
 if not exists(select 1 from ` + ns + pgEmailState + ` state where state.id=1 and state.envelope='tesl-email-envelope-v1') then raise exception 'tesl: incompatible email runtime envelope'; end if;
`
	result := "TABLE(id bigint, recipient text, subject text, body_kind text, body_text text, body_html text, status text, attempts integer, next_attempt_at timestamp with time zone, sent_at timestamp with time zone, claim_token text)"
	projection := "m.id,m.recipient,m.subject,m.body_kind,m.body_text,m.body_html,m.status,m.attempts,m.next_attempt_at,m.sent_at,"
	return []pgMigrationControlFunction{
		{"tesl_email_enqueue", "v integer, recipient text, subject text, kind text, plain text, html text", "bigint", "volatile", `
declare fence integer; fresh bigint;
begin` + admit + `
 if recipient is null or subject is null or kind is null or kind not in ('text','html','rich') or plain is null or html is null then raise exception 'tesl: invalid email envelope'; end if;
 update ` + ns + pgEmailState + ` set next_id=next_id+1 where id=1 and next_id<4611686018427387904 returning next_id into fresh;
 if not found then raise exception 'tesl: email identity exhausted'; end if;
 insert into ` + table + ` values(fresh,recipient,subject,kind,plain,html,'pending',0,pg_catalog.clock_timestamp(),null,null,pg_catalog.clock_timestamp(),null);
 return fresh;
end`},
		{"tesl_email_claim", "v integer, batch integer", result, "volatile", `
declare fence integer;
begin` + admit + `
 if batch is null or batch<1 or batch>1073741824 then raise exception 'tesl: invalid email batch'; end if;
 return query update ` + table + ` m set locked_at=pg_catalog.clock_timestamp(),claim_token=pg_catalog.gen_random_uuid()::text
 where m.id in (select candidate.id from ` + table + ` candidate where candidate.status='pending' and candidate.next_attempt_at<=pg_catalog.clock_timestamp()
 and (candidate.locked_at is null or candidate.locked_at<pg_catalog.clock_timestamp()-interval '10 minutes')
 order by candidate.id for update skip locked limit batch)
 returning ` + projection + `m.claim_token;
end`},
		{"tesl_email_outcome", "v integer, message_id bigint, token text, succeeded boolean", "boolean", "volatile", `
declare fence integer; locked timestamp with time zone; failures integer;
begin` + admit + `
 if succeeded is null then raise exception 'tesl: missing email outcome'; end if;
 select m.locked_at,m.attempts into locked,failures from ` + table + ` m where m.id=message_id and m.status='pending' and m.claim_token=token for update;
 if not found or locked is null or locked<=pg_catalog.clock_timestamp()-interval '10 minutes' then return false; end if;
 if succeeded then
 update ` + table + ` set status='sent',sent_at=pg_catalog.clock_timestamp(),locked_at=null,claim_token=null where id=message_id;
 else
 failures:=failures+1;
 update ` + table + ` set attempts=failures,status=case when failures>=5 then 'dead' else 'pending' end,
 next_attempt_at=case when failures>=5 then next_attempt_at else pg_catalog.clock_timestamp()+(interval '5 minutes' * pg_catalog.power(2,failures)) end,
 locked_at=null,claim_token=null where id=message_id;
 end if;
 return true;
end`},
		{"tesl_email_messages", "v integer", result, "volatile", `
declare fence integer;
begin` + admit + `
 return query select ` + projection + `null::text from ` + table + ` m order by m.id;
end`},
		{"tesl_email_prune", "v integer, keep_ms bigint", "bigint", "volatile", `
declare fence integer; removed bigint;
begin` + admit + `
 if keep_ms is null or keep_ms<0 then raise exception 'tesl: invalid email retention'; end if;
 delete from ` + table + ` where status='sent' and sent_at<pg_catalog.clock_timestamp()-(keep_ms * interval '1 millisecond');
 get diagnostics removed = row_count;
 return removed;
end`},
	}
}
