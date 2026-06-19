-- objects
INSERT INTO objects (file, name, kind, ancestor, source_text)
VALUES ($file,$name,$kind,$ancestor,$source_text);

-- procedures
INSERT INTO procedures
    (file, object, proc_type, name, modifiers, params, return_type,
     start_line, end_line, body_json, source_rendered, cyclomatic)
VALUES
    ($file,$object,$proc_type,$name,$modifiers,$params,$return_type,
     $start_line,$end_line,$body_json,$source_rendered,$cyclomatic);

-- calls
INSERT INTO calls (file, object, from_proc, to_name, call_type)
VALUES ($file,$object,$from_proc,$to_name,$call_type);

-- dw_controls
INSERT INTO dw_controls
    (file, dw_name, control_name, control_type, band,
     x, y, width, height, expression, tab_seq, source_line)
VALUES
    ($file,$dw_name,$control_name,$control_type,$band,
     $x,$y,$width,$height,$expression,$tab_seq,$source_line);

-- dw_retrieve_tables
INSERT INTO dw_retrieve_tables (file, dw_name, table_name)
VALUES ($file,$dw_name,$table_name);

-- dw_retrieve_columns
INSERT INTO dw_retrieve_columns (file, dw_name, column_fqn, table_name, column_name)
VALUES ($file,$dw_name,$column_fqn,$table_name,$column_name);

-- dw_retrieve_where
INSERT INTO dw_retrieve_where (file, dw_name, idx, exp1, op, exp2, logic)
VALUES ($file,$dw_name,$idx,$exp1,$op,$exp2,$logic);

-- dw_arguments
INSERT INTO dw_arguments (file, dw_name, arg_name, arg_type)
VALUES ($file,$dw_name,$arg_name,$arg_type);

-- inherits
INSERT INTO inherits (from_object, to_object)
VALUES ($from_object,$to_object);

-- sql_statements
INSERT INTO sql_statements
    (file, object, proc_name, line, operation, raw_sql, parsed_json,
     tables, columns, has_into, has_cursor, parse_ok)
VALUES
    ($file,$object,$proc_name,$line,$operation,$raw_sql,$parsed_json,
     $tables,$columns,$has_into,$has_cursor,$parse_ok);

-- parse_errors
INSERT INTO parse_errors (file, error_kind, message, object, proc_name, line, snippet)
VALUES ($file,$error_kind,$message,$object,$proc_name,$line,$snippet);

-- local_variables
INSERT INTO local_variables (file, object, proc_name, var_name, var_type, start_line)
VALUES ($file,$object,$proc_name,$var_name,$var_type,$start_line);

-- user_types
INSERT INTO user_types (file, type_name, ancestor, within_type)
VALUES ($file,$type_name,$ancestor,$within_type);

-- global_vars
INSERT INTO global_vars (file, object, var_name, var_type, modifiers, scope)
VALUES ($file,$object,$var_name,$var_type,$modifiers,$scope);

-- resolved_types
INSERT INTO resolved_types
    (file, object, proc_name, var_name, raw_type, resolved_kind,
     resolved_target, is_parameter, scope_line)
VALUES
    ($file,$object,$proc_name,$var_name,$raw_type,$resolved_kind,
     $resolved_target,$is_parameter,$scope_line);

-- resolved_calls
INSERT INTO resolved_calls
    (file, object, from_proc, to_name, call_type, call_line,
     target_object, target_proc, resolution_kind, confidence)
VALUES
    ($file,$object,$from_proc,$to_name,$call_type,$call_line,
     $target_object,$target_proc,$resolution_kind,$confidence);
