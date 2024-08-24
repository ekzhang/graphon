//! Tokenizer for GQL statements. This is heavily borrowed and modified from the
//! Zig language tokenizer, which exported from the standard library as the
//! `std.zig.Tokenizer` struct.
//!
//! The Zig standard library is available under the MIT license.
//! https://github.com/ziglang/zig/blob/0.12.x/LICENSE

// Copyright (c) Zig contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");
const code_point = @import("zg/code_point");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    /// "… certain syntax elements are used to specify GQL statements and parts
    /// of GQL expressions. Those syntax elements are called keywords."
    ///
    /// All keywords are case-insensitive (but canonically uppercase).
    ///
    /// Reference: ISO/IEC 39075:2024, Section 4.3.5.1 and Section 21.3.
    pub const keywords = std.StaticStringMapWithEql(Tag, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
        // Reserved word
        .{ "ABS", .keyword_abs },
        .{ "ACOS", .keyword_acos },
        .{ "ALL", .keyword_all },
        .{ "ALL_DIFFERENT", .keyword_all_different },
        .{ "AND", .keyword_and },
        .{ "ANY", .keyword_any },
        .{ "ARRAY", .keyword_array },
        .{ "AS", .keyword_as },
        .{ "ASC", .keyword_asc },
        .{ "ASCENDING", .keyword_ascending },
        .{ "ASIN", .keyword_asin },
        .{ "AT", .keyword_at },
        .{ "ATAN", .keyword_atan },
        .{ "AVG", .keyword_avg },
        .{ "BIG", .keyword_big },
        .{ "BIGINT", .keyword_bigint },
        .{ "BINARY", .keyword_binary },
        .{ "BOOL", .keyword_bool },
        .{ "BOOLEAN", .keyword_boolean },
        .{ "BOTH", .keyword_both },
        .{ "BTRIM", .keyword_btrim },
        .{ "BY", .keyword_by },
        .{ "BYTE_LENGTH", .keyword_byte_length },
        .{ "BYTES", .keyword_bytes },
        .{ "CALL", .keyword_call },
        .{ "CARDINALITY", .keyword_cardinality },
        .{ "CASE", .keyword_case },
        .{ "CAST", .keyword_cast },
        .{ "CEIL", .keyword_ceil },
        .{ "CEILING", .keyword_ceiling },
        .{ "CHAR", .keyword_char },
        .{ "CHAR_LENGTH", .keyword_char_length },
        .{ "CHARACTER_LENGTH", .keyword_character_length },
        .{ "CHARACTERISTICS", .keyword_characteristics },
        .{ "CLOSE", .keyword_close },
        .{ "COALESCE", .keyword_coalesce },
        .{ "COLLECT_LIST", .keyword_collect_list },
        .{ "COMMIT", .keyword_commit },
        .{ "COPY", .keyword_copy },
        .{ "COS", .keyword_cos },
        .{ "COSH", .keyword_cosh },
        .{ "COT", .keyword_cot },
        .{ "COUNT", .keyword_count },
        .{ "CREATE", .keyword_create },
        .{ "CURRENT_DATE", .keyword_current_date },
        .{ "CURRENT_GRAPH", .keyword_current_graph },
        .{ "CURRENT_PROPERTY_GRAPH", .keyword_current_property_graph },
        .{ "CURRENT_SCHEMA", .keyword_current_schema },
        .{ "CURRENT_TIME", .keyword_current_time },
        .{ "CURRENT_TIMESTAMP", .keyword_current_timestamp },
        .{ "DATE", .keyword_date },
        .{ "DATETIME", .keyword_datetime },
        .{ "DAY", .keyword_day },
        .{ "DEC", .keyword_dec },
        .{ "DECIMAL", .keyword_decimal },
        .{ "DEGREES", .keyword_degrees },
        .{ "DELETE", .keyword_delete },
        .{ "DESC", .keyword_desc },
        .{ "DESCENDING", .keyword_descending },
        .{ "DETACH", .keyword_detach },
        .{ "DISTINCT", .keyword_distinct },
        .{ "DOUBLE", .keyword_double },
        .{ "DROP", .keyword_drop },
        .{ "DURATION", .keyword_duration },
        .{ "DURATION_BETWEEN", .keyword_duration_between },
        .{ "ELEMENT_ID", .keyword_element_id },
        .{ "ELSE", .keyword_else },
        .{ "END", .keyword_end },
        .{ "EXCEPT", .keyword_except },
        .{ "EXISTS", .keyword_exists },
        .{ "EXP", .keyword_exp },
        .{ "FALSE", .keyword_false },
        .{ "FILTER", .keyword_filter },
        .{ "FINISH", .keyword_finish },
        .{ "FLOAT", .keyword_float },
        .{ "FLOAT16", .keyword_float16 },
        .{ "FLOAT32", .keyword_float32 },
        .{ "FLOAT64", .keyword_float64 },
        .{ "FLOAT128", .keyword_float128 },
        .{ "FLOAT256", .keyword_float256 },
        .{ "FLOOR", .keyword_floor },
        .{ "FOR", .keyword_for },
        .{ "FROM", .keyword_from },
        .{ "GROUP", .keyword_group },
        .{ "HAVING", .keyword_having },
        .{ "HOME_GRAPH", .keyword_home_graph },
        .{ "HOME_PROPERTY_GRAPH", .keyword_home_property_graph },
        .{ "HOME_SCHEMA", .keyword_home_schema },
        .{ "HOUR", .keyword_hour },
        .{ "IF", .keyword_if },
        .{ "IMPLIES", .keyword_implies },
        .{ "IN", .keyword_in },
        .{ "INSERT", .keyword_insert },
        .{ "INT", .keyword_int },
        .{ "INTEGER", .keyword_integer },
        .{ "INT8", .keyword_int8 },
        .{ "INTEGER8", .keyword_integer8 },
        .{ "INT16", .keyword_int16 },
        .{ "INTEGER16", .keyword_integer16 },
        .{ "INT32", .keyword_int32 },
        .{ "INTEGER32", .keyword_integer32 },
        .{ "INT64", .keyword_int64 },
        .{ "INTEGER64", .keyword_integer64 },
        .{ "INT128", .keyword_int128 },
        .{ "INTEGER128", .keyword_integer128 },
        .{ "INT256", .keyword_int256 },
        .{ "INTEGER256", .keyword_integer256 },
        .{ "INTERSECT", .keyword_intersect },
        .{ "INTERVAL", .keyword_interval },
        .{ "IS", .keyword_is },
        .{ "LEADING", .keyword_leading },
        .{ "LEFT", .keyword_left },
        .{ "LET", .keyword_let },
        .{ "LIKE", .keyword_like },
        .{ "LIMIT", .keyword_limit },
        .{ "LIST", .keyword_list },
        .{ "LN", .keyword_ln },
        .{ "LOCAL", .keyword_local },
        .{ "LOCAL_DATETIME", .keyword_local_datetime },
        .{ "LOCAL_TIME", .keyword_local_time },
        .{ "LOCAL_TIMESTAMP", .keyword_local_timestamp },
        .{ "LOG", .keyword_log },
        .{ "LOG10", .keyword_log10 },
        .{ "LOWER", .keyword_lower },
        .{ "LTRIM", .keyword_ltrim },
        .{ "MATCH", .keyword_match },
        .{ "MAX", .keyword_max },
        .{ "MIN", .keyword_min },
        .{ "MINUTE", .keyword_minute },
        .{ "MOD", .keyword_mod },
        .{ "MONTH", .keyword_month },
        .{ "NEXT", .keyword_next },
        .{ "NODETACH", .keyword_nodetach },
        .{ "NORMALIZE", .keyword_normalize },
        .{ "NOT", .keyword_not },
        .{ "NOTHING", .keyword_nothing },
        .{ "NULL", .keyword_null },
        .{ "NULLS", .keyword_nulls },
        .{ "NULLIF", .keyword_nullif },
        .{ "OCTET_LENGTH", .keyword_octet_length },
        .{ "OF", .keyword_of },
        .{ "OFFSET", .keyword_offset },
        .{ "OPTIONAL", .keyword_optional },
        .{ "OR", .keyword_or },
        .{ "ORDER", .keyword_order },
        .{ "OTHERWISE", .keyword_otherwise },
        .{ "PARAMETER", .keyword_parameter },
        .{ "PARAMETERS", .keyword_parameters },
        .{ "PATH", .keyword_path },
        .{ "PATH_LENGTH", .keyword_path_length },
        .{ "PATHS", .keyword_paths },
        .{ "PERCENTILE_CONT", .keyword_percentile_cont },
        .{ "PERCENTILE_DISC", .keyword_percentile_disc },
        .{ "POWER", .keyword_power },
        .{ "PRECISION", .keyword_precision },
        .{ "PROPERTY_EXISTS", .keyword_property_exists },
        .{ "RADIANS", .keyword_radians },
        .{ "REAL", .keyword_real },
        .{ "RECORD", .keyword_record },
        .{ "REMOVE", .keyword_remove },
        .{ "REPLACE", .keyword_replace },
        .{ "RESET", .keyword_reset },
        .{ "RETURN", .keyword_return },
        .{ "RIGHT", .keyword_right },
        .{ "ROLLBACK", .keyword_rollback },
        .{ "RTRIM", .keyword_rtrim },
        .{ "SAME", .keyword_same },
        .{ "SCHEMA", .keyword_schema },
        .{ "SECOND", .keyword_second },
        .{ "SELECT", .keyword_select },
        .{ "SESSION", .keyword_session },
        .{ "SESSION_USER", .keyword_session_user },
        .{ "SET", .keyword_set },
        .{ "SIGNED", .keyword_signed },
        .{ "SIN", .keyword_sin },
        .{ "SINH", .keyword_sinh },
        .{ "SIZE", .keyword_size },
        .{ "SKIP", .keyword_skip },
        .{ "SMALL", .keyword_small },
        .{ "SMALLINT", .keyword_smallint },
        .{ "SQRT", .keyword_sqrt },
        .{ "START", .keyword_start },
        .{ "STDDEV_POP", .keyword_stddev_pop },
        .{ "STDDEV_SAMP", .keyword_stddev_samp },
        .{ "STRING", .keyword_string },
        .{ "SUM", .keyword_sum },
        .{ "TAN", .keyword_tan },
        .{ "TANH", .keyword_tanh },
        .{ "THEN", .keyword_then },
        .{ "TIME", .keyword_time },
        .{ "TIMESTAMP", .keyword_timestamp },
        .{ "TRAILING", .keyword_trailing },
        .{ "TRIM", .keyword_trim },
        .{ "TRUE", .keyword_true },
        .{ "TYPED", .keyword_typed },
        .{ "UBIGINT", .keyword_ubigint },
        .{ "UINT", .keyword_uint },
        .{ "UINT8", .keyword_uint8 },
        .{ "UINT16", .keyword_uint16 },
        .{ "UINT32", .keyword_uint32 },
        .{ "UINT64", .keyword_uint64 },
        .{ "UINT128", .keyword_uint128 },
        .{ "UINT256", .keyword_uint256 },
        .{ "UNION", .keyword_union },
        .{ "UNKNOWN", .keyword_unknown },
        .{ "UNSIGNED", .keyword_unsigned },
        .{ "UPPER", .keyword_upper },
        .{ "USE", .keyword_use },
        .{ "USMALLINT", .keyword_usmallint },
        .{ "VALUE", .keyword_value },
        .{ "VARBINARY", .keyword_varbinary },
        .{ "VARCHAR", .keyword_varchar },
        .{ "VARIABLE", .keyword_variable },
        .{ "WHEN", .keyword_when },
        .{ "WHERE", .keyword_where },
        .{ "WITH", .keyword_with },
        .{ "XOR", .keyword_xor },
        .{ "YEAR", .keyword_year },
        .{ "YIELD", .keyword_yield },
        .{ "ZONED", .keyword_zoned },
        .{ "ZONED_DATETIME", .keyword_zoned_datetime },
        .{ "ZONED_TIME", .keyword_zoned_time },

        // Pre-reserved word
        .{ "ABSTRACT", .keyword_abstract },
        .{ "AGGREGATE", .keyword_aggregate },
        .{ "AGGREGATES", .keyword_aggregates },
        .{ "ALTER", .keyword_alter },
        .{ "CATALOG", .keyword_catalog },
        .{ "CLEAR", .keyword_clear },
        .{ "CLONE", .keyword_clone },
        .{ "CONSTRAINT", .keyword_constraint },
        .{ "CURRENT_ROLE", .keyword_current_role },
        .{ "CURRENT_USER", .keyword_current_user },
        .{ "DATA", .keyword_data },
        .{ "DIRECTORY", .keyword_directory },
        .{ "DRYRUN", .keyword_dryrun },
        .{ "EXACT", .keyword_exact },
        .{ "EXISTING", .keyword_existing },
        .{ "FUNCTION", .keyword_function },
        .{ "GQLSTATUS", .keyword_gqlstatus },
        .{ "GRANT", .keyword_grant },
        .{ "INSTANT", .keyword_instant },
        .{ "INFINITY", .keyword_infinity },
        .{ "NUMBER", .keyword_number },
        .{ "NUMERIC", .keyword_numeric },
        .{ "ON", .keyword_on },
        .{ "OPEN", .keyword_open },
        .{ "PARTITION", .keyword_partition },
        .{ "PROCEDURE", .keyword_procedure },
        .{ "PRODUCT", .keyword_product },
        .{ "PROJECT", .keyword_project },
        .{ "QUERY", .keyword_query },
        .{ "RECORDS", .keyword_records },
        .{ "REFERENCE", .keyword_reference },
        .{ "RENAME", .keyword_rename },
        .{ "REVOKE", .keyword_revoke },
        .{ "SUBSTRING", .keyword_substring },
        .{ "SYSTEM_USER", .keyword_system_user },
        .{ "TEMPORAL", .keyword_temporal },
        .{ "UNIQUE", .keyword_unique },
        .{ "UNIT", .keyword_unit },
        .{ "VALUES", .keyword_values },
        .{ "WHITESPACE", .keyword_whitespace },

        // Non-reserved word
        .{ "ACYCLIC", .keyword_acyclic },
        .{ "BINDING", .keyword_binding },
        .{ "BINDINGS", .keyword_bindings },
        .{ "CONNECTING", .keyword_connecting },
        .{ "DESTINATION", .keyword_destination },
        .{ "DIFFERENT", .keyword_different },
        .{ "DIRECTED", .keyword_directed },
        .{ "EDGE", .keyword_edge },
        .{ "EDGES", .keyword_edges },
        .{ "ELEMENT", .keyword_element },
        .{ "ELEMENTS", .keyword_elements },
        .{ "FIRST", .keyword_first },
        .{ "GRAPH", .keyword_graph },
        .{ "GROUPS", .keyword_groups },
        .{ "KEEP", .keyword_keep },
        .{ "LABEL", .keyword_label },
        .{ "LABELED", .keyword_labeled },
        .{ "LABELS", .keyword_labels },
        .{ "LAST", .keyword_last },
        .{ "NFC", .keyword_nfc },
        .{ "NFD", .keyword_nfd },
        .{ "NFKC", .keyword_nfkc },
        .{ "NFKD", .keyword_nfkd },
        .{ "NO", .keyword_no },
        .{ "NODE", .keyword_node },
        .{ "NORMALIZED", .keyword_normalized },
        .{ "ONLY", .keyword_only },
        .{ "ORDINALITY", .keyword_ordinality },
        .{ "PROPERTY", .keyword_property },
        .{ "READ", .keyword_read },
        .{ "RELATIONSHIP", .keyword_relationship },
        .{ "RELATIONSHIPS", .keyword_relationships },
        .{ "REPEATABLE", .keyword_repeatable },
        .{ "SHORTEST", .keyword_shortest },
        .{ "SIMPLE", .keyword_simple },
        .{ "SOURCE", .keyword_source },
        .{ "TABLE", .keyword_table },
        .{ "TEMP", .keyword_temp },
        .{ "TO", .keyword_to },
        .{ "TRAIL", .keyword_trail },
        .{ "TRANSACTION", .keyword_transaction },
        .{ "TYPE", .keyword_type },
        .{ "UNDIRECTED", .keyword_undirected },
        .{ "VERTEX", .keyword_vertex },
        .{ "WALK", .keyword_walk },
        .{ "WITHOUT", .keyword_without },
        .{ "WRITE", .keyword_write },
        .{ "ZONE", .keyword_zone },
    });

    /// Lookup a keyword for the given string. Unlike Zig, this is case-insensitive.
    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {
        invalid,
        identifier,
        string_literal, // includes both character and byte string literals
        char_literal, // not part of the GQL spec
        number_literal,
        eof,

        // Standalone punctuation, see "<GQL special character>"
        ampersand, // &
        asterisk, // *
        colon, // :
        colon_colon, // ::
        equal, // =, used as the equals operator, not assignment
        not_equal, // <>
        comma, // ,
        bang, // !, used for label negation
        l_paren, // (
        r_paren, // )
        l_brace, // {
        r_brace, // }
        l_bracket, // [
        r_bracket, // ]
        minus, // -
        period, // .
        ellipsis2, // ..
        ellipsis3, // ...
        plus, // +
        question_mark, // ?
        slash, // /
        pipe, // |
        pipe_pipe, // ||, concatenation operator
        percent, // %
        tilde, // ~
        angle_bracket_left, // <
        angle_bracket_left_equal, // <=
        angle_bracket_right, // >
        angle_bracket_right_equal, // >=
        implies, // =>

        // Arrows, see "<delimiter token>"
        bracket_right_arrow, // ]->
        bracket_tilde_right_arrow, // ]~>
        left_arrow, // <-
        left_arrow_bracket, // <-[
        left_arrow_tilde, // <~
        left_arrow_tilde_bracket, // <~[
        left_minus_right, // <->
        left_minus_slash, // <-/
        left_tilde_slash, // <~/
        minus_left_bracket, // -[
        minus_slash, // -/
        right_arrow, // ->
        right_bracket_minus, // ]-
        right_bracket_tilde, // ]~
        slash_minus, // /-
        slash_minus_right, // /->
        slash_tilde, // /~
        slash_tilde_right, // /~>
        tilde_left_bracket, // ~[
        tilde_right_arrow, // ~>
        tilde_slash, // ~/

        // Miscellaneous characters
        semicolon, // ;, allowed at the end of queries, not part of the spec

        keyword_abs,
        keyword_acos,
        keyword_all,
        keyword_all_different,
        keyword_and,
        keyword_any,
        keyword_array,
        keyword_as,
        keyword_asc,
        keyword_ascending,
        keyword_asin,
        keyword_at,
        keyword_atan,
        keyword_avg,
        keyword_big,
        keyword_bigint,
        keyword_binary,
        keyword_bool,
        keyword_boolean,
        keyword_both,
        keyword_btrim,
        keyword_by,
        keyword_byte_length,
        keyword_bytes,
        keyword_call,
        keyword_cardinality,
        keyword_case,
        keyword_cast,
        keyword_ceil,
        keyword_ceiling,
        keyword_char,
        keyword_char_length,
        keyword_character_length,
        keyword_characteristics,
        keyword_close,
        keyword_coalesce,
        keyword_collect_list,
        keyword_commit,
        keyword_copy,
        keyword_cos,
        keyword_cosh,
        keyword_cot,
        keyword_count,
        keyword_create,
        keyword_current_date,
        keyword_current_graph,
        keyword_current_property_graph,
        keyword_current_schema,
        keyword_current_time,
        keyword_current_timestamp,
        keyword_date,
        keyword_datetime,
        keyword_day,
        keyword_dec,
        keyword_decimal,
        keyword_degrees,
        keyword_delete,
        keyword_desc,
        keyword_descending,
        keyword_detach,
        keyword_distinct,
        keyword_double,
        keyword_drop,
        keyword_duration,
        keyword_duration_between,
        keyword_element_id,
        keyword_else,
        keyword_end,
        keyword_except,
        keyword_exists,
        keyword_exp,
        keyword_false,
        keyword_filter,
        keyword_finish,
        keyword_float,
        keyword_float16,
        keyword_float32,
        keyword_float64,
        keyword_float128,
        keyword_float256,
        keyword_floor,
        keyword_for,
        keyword_from,
        keyword_group,
        keyword_having,
        keyword_home_graph,
        keyword_home_property_graph,
        keyword_home_schema,
        keyword_hour,
        keyword_if,
        keyword_implies,
        keyword_in,
        keyword_insert,
        keyword_int,
        keyword_integer,
        keyword_int8,
        keyword_integer8,
        keyword_int16,
        keyword_integer16,
        keyword_int32,
        keyword_integer32,
        keyword_int64,
        keyword_integer64,
        keyword_int128,
        keyword_integer128,
        keyword_int256,
        keyword_integer256,
        keyword_intersect,
        keyword_interval,
        keyword_is,
        keyword_leading,
        keyword_left,
        keyword_let,
        keyword_like,
        keyword_limit,
        keyword_list,
        keyword_ln,
        keyword_local,
        keyword_local_datetime,
        keyword_local_time,
        keyword_local_timestamp,
        keyword_log,
        keyword_log10,
        keyword_lower,
        keyword_ltrim,
        keyword_match,
        keyword_max,
        keyword_min,
        keyword_minute,
        keyword_mod,
        keyword_month,
        keyword_next,
        keyword_nodetach,
        keyword_normalize,
        keyword_not,
        keyword_nothing,
        keyword_null,
        keyword_nulls,
        keyword_nullif,
        keyword_octet_length,
        keyword_of,
        keyword_offset,
        keyword_optional,
        keyword_or,
        keyword_order,
        keyword_otherwise,
        keyword_parameter,
        keyword_parameters,
        keyword_path,
        keyword_path_length,
        keyword_paths,
        keyword_percentile_cont,
        keyword_percentile_disc,
        keyword_power,
        keyword_precision,
        keyword_property_exists,
        keyword_radians,
        keyword_real,
        keyword_record,
        keyword_remove,
        keyword_replace,
        keyword_reset,
        keyword_return,
        keyword_right,
        keyword_rollback,
        keyword_rtrim,
        keyword_same,
        keyword_schema,
        keyword_second,
        keyword_select,
        keyword_session,
        keyword_session_user,
        keyword_set,
        keyword_signed,
        keyword_sin,
        keyword_sinh,
        keyword_size,
        keyword_skip,
        keyword_small,
        keyword_smallint,
        keyword_sqrt,
        keyword_start,
        keyword_stddev_pop,
        keyword_stddev_samp,
        keyword_string,
        keyword_sum,
        keyword_tan,
        keyword_tanh,
        keyword_then,
        keyword_time,
        keyword_timestamp,
        keyword_trailing,
        keyword_trim,
        keyword_true,
        keyword_typed,
        keyword_ubigint,
        keyword_uint,
        keyword_uint8,
        keyword_uint16,
        keyword_uint32,
        keyword_uint64,
        keyword_uint128,
        keyword_uint256,
        keyword_union,
        keyword_unknown,
        keyword_unsigned,
        keyword_upper,
        keyword_use,
        keyword_usmallint,
        keyword_value,
        keyword_varbinary,
        keyword_varchar,
        keyword_variable,
        keyword_when,
        keyword_where,
        keyword_with,
        keyword_xor,
        keyword_year,
        keyword_yield,
        keyword_zoned,
        keyword_zoned_datetime,
        keyword_zoned_time,

        keyword_abstract,
        keyword_aggregate,
        keyword_aggregates,
        keyword_alter,
        keyword_catalog,
        keyword_clear,
        keyword_clone,
        keyword_constraint,
        keyword_current_role,
        keyword_current_user,
        keyword_data,
        keyword_directory,
        keyword_dryrun,
        keyword_exact,
        keyword_existing,
        keyword_function,
        keyword_gqlstatus,
        keyword_grant,
        keyword_instant,
        keyword_infinity,
        keyword_number,
        keyword_numeric,
        keyword_on,
        keyword_open,
        keyword_partition,
        keyword_procedure,
        keyword_product,
        keyword_project,
        keyword_query,
        keyword_records,
        keyword_reference,
        keyword_rename,
        keyword_revoke,
        keyword_substring,
        keyword_system_user,
        keyword_temporal,
        keyword_unique,
        keyword_unit,
        keyword_values,
        keyword_whitespace,

        keyword_acyclic,
        keyword_binding,
        keyword_bindings,
        keyword_connecting,
        keyword_destination,
        keyword_different,
        keyword_directed,
        keyword_edge,
        keyword_edges,
        keyword_element,
        keyword_elements,
        keyword_first,
        keyword_graph,
        keyword_groups,
        keyword_keep,
        keyword_label,
        keyword_labeled,
        keyword_labels,
        keyword_last,
        keyword_nfc,
        keyword_nfd,
        keyword_nfkc,
        keyword_nfkd,
        keyword_no,
        keyword_node,
        keyword_normalized,
        keyword_only,
        keyword_ordinality,
        keyword_property,
        keyword_read,
        keyword_relationship,
        keyword_relationships,
        keyword_repeatable,
        keyword_shortest,
        keyword_simple,
        keyword_source,
        keyword_table,
        keyword_temp,
        keyword_to,
        keyword_trail,
        keyword_transaction,
        keyword_type,
        keyword_undirected,
        keyword_vertex,
        keyword_walk,
        keyword_without,
        keyword_write,
        keyword_zone,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .identifier,
                .string_literal,
                .char_literal,
                .number_literal,
                .eof,
                => null,

                .ampersand => "&",
                .asterisk => "*",
                .colon => ":",
                .equal => "=",
                .not_equal => "<>",
                .comma => ",",
                .bang => "!",
                .l_paren => "(",
                .r_paren => ")",
                .l_brace => "{",
                .r_brace => "}",
                .l_bracket => "[",
                .r_bracket => "]",
                .minus => "-",
                .period => ".",
                .plus => "+",
                .question_mark => "?",
                .slash => "/",
                .pipe => "|",
                .pipe_pipe => "||",
                .percent => "%",
                .tilde => "~",
                .angle_bracket_left => "<",
                .angle_bracket_left_equal => "<=",
                .angle_bracket_right => ">",
                .angle_bracket_right_equal => ">=",
                .implies => "=>",

                .bracket_right_arrow => "]->",
                .bracket_tilde_right_arrow => "]~>",
                .left_arrow => "<-",
                .left_arrow_bracket => "<-[",
                .left_arrow_tilde => "<~",
                .left_arrow_tilde_bracket => "<~[",
                .left_minus_right => "<->",
                .left_minus_slash => "</-",
                .left_tilde_slash => "<~/",
                .minus_left_bracket => "-[",
                .minus_slash => "-/",
                .right_arrow => "->",
                .right_bracket_minus => "]-",
                .right_bracket_tilde => "]~",
                .slash_minus => "/-",
                .slash_minus_right => "/->",
                .slash_tilde => "/~",
                .slash_tilde_right => "/~>",
                .tilde_left_bracket => "~[",
                .tilde_right_arrow => "~>",
                .tilde_slash => "~/",

                .semicolon => ";",

                .keyword_abs => "ABS",
                .keyword_acos => "ACOS",
                .keyword_all => "ALL",
                .keyword_all_different => "ALL_DIFFERENT",
                .keyword_and => "AND",
                .keyword_any => "ANY",
                .keyword_array => "ARRAY",
                .keyword_as => "AS",
                .keyword_asc => "ASC",
                .keyword_ascending => "ASCENDING",
                .keyword_asin => "ASIN",
                .keyword_at => "AT",
                .keyword_atan => "ATAN",
                .keyword_avg => "AVG",
                .keyword_big => "BIG",
                .keyword_bigint => "BIGINT",
                .keyword_binary => "BINARY",
                .keyword_bool => "BOOL",
                .keyword_boolean => "BOOLEAN",
                .keyword_both => "BOTH",
                .keyword_btrim => "BTRIM",
                .keyword_by => "BY",
                .keyword_byte_length => "BYTE_LENGTH",
                .keyword_bytes => "BYTES",
                .keyword_call => "CALL",
                .keyword_cardinality => "CARDINALITY",
                .keyword_case => "CASE",
                .keyword_cast => "CAST",
                .keyword_ceil => "CEIL",
                .keyword_ceiling => "CEILING",
                .keyword_char => "CHAR",
                .keyword_char_length => "CHAR_LENGTH",
                .keyword_character_length => "CHARACTER_LENGTH",
                .keyword_characteristics => "CHARACTERISTICS",
                .keyword_close => "CLOSE",
                .keyword_coalesce => "COALESCE",
                .keyword_collect_list => "COLLECT_LIST",
                .keyword_commit => "COMMIT",
                .keyword_copy => "COPY",
                .keyword_cos => "COS",
                .keyword_cosh => "COSH",
                .keyword_cot => "COT",
                .keyword_count => "COUNT",
                .keyword_create => "CREATE",
                .keyword_current_date => "CURRENT_DATE",
                .keyword_current_graph => "CURRENT_GRAPH",
                .keyword_current_property_graph => "CURRENT_PROPERTY_GRAPH",
                .keyword_current_schema => "CURRENT_SCHEMA",
                .keyword_current_time => "CURRENT_TIME",
                .keyword_current_timestamp => "CURRENT_TIMESTAMP",
                .keyword_date => "DATE",
                .keyword_datetime => "DATETIME",
                .keyword_day => "DAY",
                .keyword_dec => "DEC",
                .keyword_decimal => "DECIMAL",
                .keyword_degrees => "DEGREES",
                .keyword_delete => "DELETE",
                .keyword_desc => "DESC",
                .keyword_descending => "DESCENDING",
                .keyword_detach => "DETACH",
                .keyword_distinct => "DISTINCT",
                .keyword_double => "DOUBLE",
                .keyword_drop => "DROP",
                .keyword_duration => "DURATION",
                .keyword_duration_between => "DURATION_BETWEEN",
                .keyword_element_id => "ELEMENT_ID",
                .keyword_else => "ELSE",
                .keyword_end => "END",
                .keyword_except => "EXCEPT",
                .keyword_exists => "EXISTS",
                .keyword_exp => "EXP",
                .keyword_false => "FALSE",
                .keyword_filter => "FILTER",
                .keyword_finish => "FINISH",
                .keyword_float => "FLOAT",
                .keyword_float16 => "FLOAT16",
                .keyword_float32 => "FLOAT32",
                .keyword_float64 => "FLOAT64",
                .keyword_float128 => "FLOAT128",
                .keyword_float256 => "FLOAT256",
                .keyword_floor => "FLOOR",
                .keyword_for => "FOR",
                .keyword_from => "FROM",
                .keyword_group => "GROUP",
                .keyword_having => "HAVING",
                .keyword_home_graph => "HOME_GRAPH",
                .keyword_home_property_graph => "HOME_PROPERTY_GRAPH",
                .keyword_home_schema => "HOME_SCHEMA",
                .keyword_hour => "HOUR",
                .keyword_if => "IF",
                .keyword_implies => "IMPLIES",
                .keyword_in => "IN",
                .keyword_insert => "INSERT",
                .keyword_int => "INT",
                .keyword_integer => "INTEGER",
                .keyword_int8 => "INT8",
                .keyword_integer8 => "INTEGER8",
                .keyword_int16 => "INT16",
                .keyword_integer16 => "INTEGER16",
                .keyword_int32 => "INT32",
                .keyword_integer32 => "INTEGER32",
                .keyword_int64 => "INT64",
                .keyword_integer64 => "INTEGER64",
                .keyword_int128 => "INT128",
                .keyword_integer128 => "INTEGER128",
                .keyword_int256 => "INT256",
                .keyword_integer256 => "INTEGER256",
                .keyword_intersect => "INTERSECT",
                .keyword_interval => "INTERVAL",
                .keyword_is => "IS",
                .keyword_leading => "LEADING",
                .keyword_left => "LEFT",
                .keyword_let => "LET",
                .keyword_like => "LIKE",
                .keyword_limit => "LIMIT",
                .keyword_list => "LIST",
                .keyword_ln => "LN",
                .keyword_local => "LOCAL",
                .keyword_local_datetime => "LOCAL_DATETIME",
                .keyword_local_time => "LOCAL_TIME",
                .keyword_local_timestamp => "LOCAL_TIMESTAMP",
                .keyword_log => "LOG",
                .keyword_log10 => "LOG10",
                .keyword_lower => "LOWER",
                .keyword_ltrim => "LTRIM",
                .keyword_match => "MATCH",
                .keyword_max => "MAX",
                .keyword_min => "MIN",
                .keyword_minute => "MINUTE",
                .keyword_mod => "MOD",
                .keyword_month => "MONTH",
                .keyword_next => "NEXT",
                .keyword_nodetach => "NODETACH",
                .keyword_normalize => "NORMALIZE",
                .keyword_not => "NOT",
                .keyword_nothing => "NOTHING",
                .keyword_null => "NULL",
                .keyword_nulls => "NULLS",
                .keyword_nullif => "NULLIF",
                .keyword_octet_length => "OCTET_LENGTH",
                .keyword_of => "OF",
                .keyword_offset => "OFFSET",
                .keyword_optional => "OPTIONAL",
                .keyword_or => "OR",
                .keyword_order => "ORDER",
                .keyword_otherwise => "OTHERWISE",
                .keyword_parameter => "PARAMETER",
                .keyword_parameters => "PARAMETERS",
                .keyword_path => "PATH",
                .keyword_path_length => "PATH_LENGTH",
                .keyword_paths => "PATHS",
                .keyword_percentile_cont => "PERCENTILE_CONT",
                .keyword_percentile_disc => "PERCENTILE_DISC",
                .keyword_power => "POWER",
                .keyword_precision => "PRECISION",
                .keyword_property_exists => "PROPERTY_EXISTS",
                .keyword_radians => "RADIANS",
                .keyword_real => "REAL",
                .keyword_record => "RECORD",
                .keyword_remove => "REMOVE",
                .keyword_replace => "REPLACE",
                .keyword_reset => "RESET",
                .keyword_return => "RETURN",
                .keyword_right => "RIGHT",
                .keyword_rollback => "ROLLBACK",
                .keyword_rtrim => "RTRIM",
                .keyword_same => "SAME",
                .keyword_schema => "SCHEMA",
                .keyword_second => "SECOND",
                .keyword_select => "SELECT",
                .keyword_session => "SESSION",
                .keyword_session_user => "SESSION_USER",
                .keyword_set => "SET",
                .keyword_signed => "SIGNED",
                .keyword_sin => "SIN",
                .keyword_sinh => "SINH",
                .keyword_size => "SIZE",
                .keyword_skip => "SKIP",
                .keyword_small => "SMALL",
                .keyword_smallint => "SMALLINT",
                .keyword_sqrt => "SQRT",
                .keyword_start => "START",
                .keyword_stddev_pop => "STDDEV_POP",
                .keyword_stddev_samp => "STDDEV_SAMP",
                .keyword_string => "STRING",
                .keyword_sum => "SUM",
                .keyword_tan => "TAN",
                .keyword_tanh => "TANH",
                .keyword_then => "THEN",
                .keyword_time => "TIME",
                .keyword_timestamp => "TIMESTAMP",
                .keyword_trailing => "TRAILING",
                .keyword_trim => "TRIM",
                .keyword_true => "TRUE",
                .keyword_typed => "TYPED",
                .keyword_ubigint => "UBIGINT",
                .keyword_uint => "UINT",
                .keyword_uint8 => "UINT8",
                .keyword_uint16 => "UINT16",
                .keyword_uint32 => "UINT32",
                .keyword_uint64 => "UINT64",
                .keyword_uint128 => "UINT128",
                .keyword_uint256 => "UINT256",
                .keyword_union => "UNION",
                .keyword_unknown => "UNKNOWN",
                .keyword_unsigned => "UNSIGNED",
                .keyword_upper => "UPPER",
                .keyword_use => "USE",
                .keyword_usmallint => "USMALLINT",
                .keyword_value => "VALUE",
                .keyword_varbinary => "VARBINARY",
                .keyword_varchar => "VARCHAR",
                .keyword_variable => "VARIABLE",
                .keyword_when => "WHEN",
                .keyword_where => "WHERE",
                .keyword_with => "WITH",
                .keyword_xor => "XOR",
                .keyword_year => "YEAR",
                .keyword_yield => "YIELD",
                .keyword_zoned => "ZONED",
                .keyword_zoned_datetime => "ZONED_DATETIME",
                .keyword_zoned_time => "ZONED_TIME",

                .keyword_abstract => "ABSTRACT",
                .keyword_aggregate => "AGGREGATE",
                .keyword_aggregates => "AGGREGATES",
                .keyword_alter => "ALTER",
                .keyword_catalog => "CATALOG",
                .keyword_clear => "CLEAR",
                .keyword_clone => "CLONE",
                .keyword_constraint => "CONSTRAINT",
                .keyword_current_role => "CURRENT_ROLE",
                .keyword_current_user => "CURRENT_USER",
                .keyword_data => "DATA",
                .keyword_directory => "DIRECTORY",
                .keyword_dryrun => "DRYRUN",
                .keyword_exact => "EXACT",
                .keyword_existing => "EXISTING",
                .keyword_function => "FUNCTION",
                .keyword_gqlstatus => "GQLSTATUS",
                .keyword_grant => "GRANT",
                .keyword_instant => "INSTANT",
                .keyword_infinity => "INFINITY",
                .keyword_number => "NUMBER",
                .keyword_numeric => "NUMERIC",
                .keyword_on => "ON",
                .keyword_open => "OPEN",
                .keyword_partition => "PARTITION",
                .keyword_procedure => "PROCEDURE",
                .keyword_product => "PRODUCT",
                .keyword_project => "PROJECT",
                .keyword_query => "QUERY",
                .keyword_records => "RECORDS",
                .keyword_reference => "REFERENCE",
                .keyword_rename => "RENAME",
                .keyword_revoke => "REVOKE",
                .keyword_substring => "SUBSTRING",
                .keyword_system_user => "SYSTEM_USER",
                .keyword_temporal => "TEMPORAL",
                .keyword_unique => "UNIQUE",
                .keyword_unit => "UNIT",
                .keyword_values => "VALUES",
                .keyword_whitespace => "WHITESPACE",

                .keyword_acyclic => "ACYCLIC",
                .keyword_binding => "BINDING",
                .keyword_bindings => "BINDINGS",
                .keyword_connecting => "CONNECTING",
                .keyword_destination => "DESTINATION",
                .keyword_different => "DIFFERENT",
                .keyword_directed => "DIRECTED",
                .keyword_edge => "EDGE",
                .keyword_edges => "EDGES",
                .keyword_element => "ELEMENT",
                .keyword_elements => "ELEMENTS",
                .keyword_first => "FIRST",
                .keyword_graph => "GRAPH",
                .keyword_groups => "GROUPS",
                .keyword_keep => "KEEP",
                .keyword_label => "LABEL",
                .keyword_labeled => "LABELED",
                .keyword_labels => "LABELS",
                .keyword_last => "LAST",
                .keyword_nfc => "NFC",
                .keyword_nfd => "NFD",
                .keyword_nfkc => "NFKC",
                .keyword_nfkd => "NFKD",
                .keyword_no => "NO",
                .keyword_node => "NODE",
                .keyword_normalized => "NORMALIZED",
                .keyword_only => "ONLY",
                .keyword_ordinality => "ORDINALITY",
                .keyword_property => "PROPERTY",
                .keyword_read => "READ",
                .keyword_relationship => "RELATIONSHIP",
                .keyword_relationships => "RELATIONSHIPS",
                .keyword_repeatable => "REPEATABLE",
                .keyword_shortest => "SHORTEST",
                .keyword_simple => "SIMPLE",
                .keyword_source => "SOURCE",
                .keyword_table => "TABLE",
                .keyword_temp => "TEMP",
                .keyword_to => "TO",
                .keyword_trail => "TRAIL",
                .keyword_transaction => "TRANSACTION",
                .keyword_type => "TYPE",
                .keyword_undirected => "UNDIRECTED",
                .keyword_vertex => "VERTEX",
                .keyword_walk => "WALK",
                .keyword_without => "WITHOUT",
                .keyword_write => "WRITE",
                .keyword_zone => "ZONE",
            };
        }

        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .invalid => "invalid bytes",
                .identifier => "an identifier",
                .string_literal => "a string literal",
                .char_literal => "a character literal",
                .eof => "EOF",
                .number_literal => "a number literal",
                else => unreachable,
            };
        }
    };
};

pub const Tokenizer = struct {
    buffer: [:0]const u8,
    index: usize,

    /// For debugging purposes
    pub fn dump(self: *Tokenizer, token: *const Token) void {
        std.debug.print("{s} \"{s}\"\n", .{ @tagName(token.tag), self.buffer[token.loc.start..token.loc.end] });
    }

    pub fn init(buffer: [:0]const u8) Tokenizer {
        // Skip the UTF-8 BOM if present
        const src_start: usize = if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) 3 else 0;
        return Tokenizer{
            .buffer = buffer,
            .index = src_start,
        };
    }

    const State = enum {
        start,
        identifier,
        builtin,
        string_literal,
        string_literal_backslash,
        char_literal,
        char_literal_backslash,
        char_literal_hex_escape,
        char_literal_unicode_escape_saw_u,
        char_literal_unicode_escape,
        char_literal_end,
        equal,
        pipe,
        colon,
        minus,
        slash,
        line_comment_start,
        line_comment,
        int,
        int_exponent,
        int_period,
        float,
        float_exponent,
        angle_bracket_left,
        angle_bracket_right,
        period,
        period_2,
        saw_at_sign,
    };

    pub fn next(self: *Tokenizer) Token {
        var state: State = .start;
        var result = Token{
            .tag = .eof,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };
        var seen_escape_digits: usize = undefined;
        while (true) : (self.index += 1) {
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += 1;
                            return result;
                        }
                        break;
                    },
                    ' ', '\n', '\t', '\r' => {
                        result.loc.start = self.index + 1;
                    },
                    '"' => {
                        state = .string_literal;
                        result.tag = .string_literal;
                    },
                    '\'' => {
                        state = .char_literal;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .identifier;
                        result.tag = .identifier;
                    },
                    '@' => {
                        state = .saw_at_sign;
                    },
                    '=' => {
                        state = .equal;
                    },
                    '|' => {
                        state = .pipe;
                    },
                    '(' => {
                        result.tag = .l_paren;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        result.tag = .r_paren;
                        self.index += 1;
                        break;
                    },
                    '[' => {
                        result.tag = .l_bracket;
                        self.index += 1;
                        break;
                    },
                    ']' => {
                        result.tag = .r_bracket;
                        self.index += 1;
                        break;
                    },
                    ';' => {
                        result.tag = .semicolon;
                        self.index += 1;
                        break;
                    },
                    ',' => {
                        result.tag = .comma;
                        self.index += 1;
                        break;
                    },
                    '!' => {
                        result.tag = .bang;
                        self.index += 1;
                        break;
                    },
                    '?' => {
                        result.tag = .question_mark;
                        self.index += 1;
                        break;
                    },
                    ':' => {
                        state = .colon;
                    },
                    '%' => {
                        result.tag = .percent;
                        self.index += 1;
                        break;
                    },
                    '*' => {
                        result.tag = .asterisk;
                        self.index += 1;
                        break;
                    },
                    '+' => {
                        result.tag = .plus;
                        self.index += 1;
                        break;
                    },
                    '<' => {
                        state = .angle_bracket_left;
                    },
                    '>' => {
                        state = .angle_bracket_right;
                    },
                    '{' => {
                        result.tag = .l_brace;
                        self.index += 1;
                        break;
                    },
                    '}' => {
                        result.tag = .r_brace;
                        self.index += 1;
                        break;
                    },
                    '~' => {
                        result.tag = .tilde;
                        self.index += 1;
                        break;
                    },
                    '.' => {
                        state = .period;
                    },
                    '-' => {
                        state = .minus;
                    },
                    '/' => {
                        state = .slash;
                    },
                    '&' => {
                        result.tag = .ampersand;
                        self.index += 1;
                        break;
                    },
                    '0'...'9' => {
                        state = .int;
                        result.tag = .number_literal;
                    },
                    else => {
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        self.index += std.unicode.utf8ByteSequenceLength(c) catch 1;
                        return result;
                    },
                },

                .saw_at_sign => switch (c) {
                    '"' => {
                        result.tag = .identifier;
                        state = .string_literal;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .builtin;
                        // result.tag = .builtin; TODO
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .identifier => switch (c) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => {
                        if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                            result.tag = tag;
                        }
                        break;
                    },
                },
                .builtin => switch (c) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => break,
                },
                .string_literal => switch (c) {
                    0, '\n' => {
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        if (self.index != self.buffer.len) {
                            self.index += 1;
                        }
                        return result;
                    },
                    '\\' => {
                        state = .string_literal_backslash;
                    },
                    '"' => {
                        self.index += 1;
                        break;
                    },
                    else => {
                        if (self.invalidCharacterLength()) |len| {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += len;
                            return result;
                        }

                        self.index += (std.unicode.utf8ByteSequenceLength(c) catch unreachable) - 1;
                    },
                },

                .string_literal_backslash => switch (c) {
                    0, '\n' => {
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        if (self.index != self.buffer.len) {
                            self.index += 1;
                        }
                        return result;
                    },
                    else => {
                        state = .string_literal;

                        if (self.invalidCharacterLength()) |len| {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += len;
                            return result;
                        }

                        self.index += (std.unicode.utf8ByteSequenceLength(c) catch unreachable) - 1;
                    },
                },

                .char_literal => switch (c) {
                    0, '\n', '\'' => {
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        if (self.index != self.buffer.len) {
                            self.index += 1;
                        }
                        return result;
                    },
                    '\\' => {
                        state = .char_literal_backslash;
                    },
                    else => {
                        state = .char_literal_end;

                        if (self.invalidCharacterLength()) |len| {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += len;
                            return result;
                        }

                        self.index += (std.unicode.utf8ByteSequenceLength(c) catch unreachable) - 1;
                    },
                },

                .char_literal_backslash => switch (c) {
                    0, '\n' => {
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        if (self.index != self.buffer.len) {
                            self.index += 1;
                        }
                        return result;
                    },
                    'x' => {
                        state = .char_literal_hex_escape;
                        seen_escape_digits = 0;
                    },
                    'u' => {
                        state = .char_literal_unicode_escape_saw_u;
                    },
                    else => {
                        state = .char_literal_end;

                        if (self.invalidCharacterLength()) |len| {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += len;
                            return result;
                        }

                        self.index += (std.unicode.utf8ByteSequenceLength(c) catch unreachable) - 1;
                    },
                },

                .char_literal_hex_escape => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        seen_escape_digits += 1;
                        if (seen_escape_digits == 2) {
                            state = .char_literal_end;
                        }
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .char_literal_unicode_escape_saw_u => switch (c) {
                    '{' => {
                        state = .char_literal_unicode_escape;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .char_literal_unicode_escape => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {},
                    '}' => {
                        state = .char_literal_end; // too many/few digits handled later
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .char_literal_end => switch (c) {
                    '\'' => {
                        result.tag = .char_literal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .pipe => switch (c) {
                    '|' => {
                        result.tag = .pipe_pipe;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .pipe;
                        break;
                    },
                },

                .equal => switch (c) {
                    '>' => {
                        result.tag = .implies;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .equal;
                        break;
                    },
                },

                .colon => switch (c) {
                    ':' => {
                        result.tag = .colon_colon;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .colon;
                        break;
                    },
                },

                .minus => switch (c) {
                    '-' => {
                        state = .line_comment_start;
                    },
                    '/' => {
                        result.tag = .minus_slash;
                        self.index += 1;
                        break;
                    },
                    '[' => {
                        result.tag = .minus_left_bracket;
                        self.index += 1;
                        break;
                    },
                    '>' => {
                        result.tag = .right_arrow;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .minus;
                        break;
                    },
                },

                .angle_bracket_left => switch (c) {
                    '=' => {
                        result.tag = .angle_bracket_left_equal;
                        self.index += 1;
                        break;
                    },
                    '>' => {
                        result.tag = .not_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_left;
                        break;
                    },
                },

                .angle_bracket_right => switch (c) {
                    '=' => {
                        result.tag = .angle_bracket_right_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_right;
                        break;
                    },
                },

                .period => switch (c) {
                    '.' => {
                        state = .period_2;
                    },
                    else => {
                        result.tag = .period;
                        break;
                    },
                },

                .period_2 => switch (c) {
                    '.' => {
                        result.tag = .ellipsis3;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .ellipsis2;
                        break;
                    },
                },

                .slash => switch (c) {
                    '/' => {
                        state = .line_comment_start;
                    },
                    '=' => {
                        // result.tag = .slash_equal; TODO
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .slash;
                        break;
                    },
                },
                .line_comment_start => switch (c) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += 1;
                            return result;
                        }
                        break;
                    },
                    '\n' => {
                        state = .start;
                        result.loc.start = self.index + 1;
                    },
                    '\t' => {
                        state = .line_comment;
                    },
                    else => {
                        state = .line_comment;

                        if (self.invalidCharacterLength()) |len| {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += len;
                            return result;
                        }

                        self.index += (std.unicode.utf8ByteSequenceLength(c) catch unreachable) - 1;
                    },
                },
                .line_comment => switch (c) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += 1;
                            return result;
                        }
                        break;
                    },
                    '\n' => {
                        state = .start;
                        result.loc.start = self.index + 1;
                    },
                    '\t' => {},
                    else => {
                        if (self.invalidCharacterLength()) |len| {
                            result.tag = .invalid;
                            result.loc.end = self.index;
                            self.index += len;
                            return result;
                        }

                        self.index += (std.unicode.utf8ByteSequenceLength(c) catch unreachable) - 1;
                    },
                },
                .int => switch (c) {
                    '.' => state = .int_period,
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {},
                    'e', 'E', 'p', 'P' => state = .int_exponent,
                    else => break,
                },
                .int_exponent => switch (c) {
                    '-', '+' => {
                        state = .float;
                    },
                    else => {
                        self.index -= 1;
                        state = .int;
                    },
                },
                .int_period => switch (c) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                        state = .float;
                    },
                    'e', 'E', 'p', 'P' => state = .float_exponent,
                    else => {
                        self.index -= 1;
                        break;
                    },
                },
                .float => switch (c) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {},
                    'e', 'E', 'p', 'P' => state = .float_exponent,
                    else => break,
                },
                .float_exponent => switch (c) {
                    '-', '+' => state = .float,
                    else => {
                        self.index -= 1;
                        state = .float;
                    },
                },
            }
        }

        if (result.tag == .eof) {
            result.loc.start = self.index;
        }

        result.loc.end = self.index;
        return result;
    }

    fn invalidCharacterLength(self: *Tokenizer) ?u3 {
        const c0 = self.buffer[self.index];
        if (std.ascii.isASCII(c0)) {
            if (c0 == '\r') {
                if (self.index + 1 < self.buffer.len and self.buffer[self.index + 1] == '\n') {
                    // Carriage returns are *only* allowed just before a linefeed as part of a CRLF pair, otherwise
                    // they constitute an illegal byte!
                    return null;
                } else {
                    return 1;
                }
            } else if (std.ascii.isControl(c0)) {
                // ascii control codes are never allowed
                // (note that \n was checked before we got here)
                return 1;
            }
            // looks fine to me.
            return null;
        } else {
            // check utf8-encoded character.
            const length = std.unicode.utf8ByteSequenceLength(c0) catch return 1;
            if (self.index + length > self.buffer.len) {
                return @as(u3, @intCast(self.buffer.len - self.index));
            }
            const bytes = self.buffer[self.index .. self.index + length];
            switch (length) {
                2 => {
                    const value = std.unicode.utf8Decode2(bytes) catch return length;
                    if (value == 0x85) return length; // U+0085 (NEL)
                },
                3 => {
                    const value = std.unicode.utf8Decode3(bytes) catch return length;
                    if (value == 0x2028) return length; // U+2028 (LS)
                    if (value == 0x2029) return length; // U+2029 (PS)
                },
                4 => {
                    _ = std.unicode.utf8Decode4(bytes) catch return length;
                },
                else => unreachable,
            }
            return null;
        }
    }
};

test "keywords" {
    try testTokenize("match PARTITION oRdEr BY partition", &.{
        .keyword_match,
        .keyword_partition,
        .keyword_order,
        .keyword_by,
        .keyword_partition,
    });
}

test "line comment followed by statement" {
    try testTokenize(
        \\// line comment
        \\MATCH ();
        \\
    , &.{
        .keyword_match,
        .l_paren,
        .r_paren,
        .semicolon,
    });
}

test "unknown length pointer and then c pointer" {
    try testTokenize(
        \\[*]u8
        \\[*c]u8
    , &.{
        .l_bracket,
        .asterisk,
        .r_bracket,
        .identifier,
        .l_bracket,
        .asterisk,
        .identifier,
        .r_bracket,
        .identifier,
    });
}

test "code point literal with hex escape" {
    try testTokenize(
        \\'\x1b'
    , &.{.char_literal});
    try testTokenize(
        \\'\x1'
    , &.{ .invalid, .invalid });
}

test "newline in char literal" {
    try testTokenize(
        \\'
        \\'
    , &.{ .invalid, .invalid });
}

test "newline in string literal" {
    try testTokenize(
        \\"
        \\"
    , &.{ .invalid, .invalid });
}

test "code point literal with unicode escapes" {
    // Valid unicode escapes
    try testTokenize(
        \\'\u{3}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{01}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{2a}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{3f9}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{6E09aBc1523}'
    , &.{.char_literal});
    try testTokenize(
        \\"\u{440}"
    , &.{.string_literal});

    // Invalid unicode escapes
    try testTokenize(
        \\'\u'
    , &.{ .invalid, .invalid });
    try testTokenize(
        \\'\u{{'
    , &.{ .invalid, .l_brace, .invalid });
    try testTokenize(
        \\'\u{}'
    , &.{.char_literal});
    try testTokenize(
        \\'\u{s}'
    , &.{
        .invalid,
        .identifier,
        .r_brace,
        .invalid,
    });
    try testTokenize(
        \\'\u{2z}'
    , &.{
        .invalid,
        .identifier,
        .r_brace,
        .invalid,
    });
    try testTokenize(
        \\'\u{4a'
    , &.{ .invalid, .invalid }); // 4a is valid

    // Test old-style unicode literals
    try testTokenize(
        \\'\u0333'
    , &.{ .invalid, .number_literal, .invalid });
    try testTokenize(
        \\'\U0333'
    , &.{ .invalid, .number_literal, .invalid });
}

test "code point literal with unicode code point" {
    try testTokenize(
        \\'💩'
    , &.{.char_literal});
}

test "float literal e exponent" {
    try testTokenize("a = 4.94065645841246544177e-324;\n", &.{
        .identifier,
        .equal,
        .number_literal,
        .semicolon,
    });
}

test "float literal p exponent" {
    try testTokenize("a = 0x1.a827999fcef32p+1022;\n", &.{
        .identifier,
        .equal,
        .number_literal,
        .semicolon,
    });
}

test "chars" {
    try testTokenize("'c'", &.{.char_literal});
}

test "invalid token characters" {
    try testTokenize("#", &.{.invalid});
    try testTokenize("`", &.{.invalid});
    try testTokenize("'c", &.{.invalid});
    try testTokenize("'", &.{.invalid});
    try testTokenize("''", &.{.invalid});
    try testTokenize("'\n'", &.{ .invalid, .invalid });
}

test "invalid literal/comment characters" {
    try testTokenize("\"\x00\"", &.{
        .invalid,
        .invalid, // Incomplete string literal starting after invalid
    });
    try testTokenize("//\x00", &.{
        .invalid,
    });
    try testTokenize("//\x1f", &.{
        .invalid,
    });
    try testTokenize("//\x7f", &.{
        .invalid,
    });
}

test "utf8" {
    try testTokenize("//\xc2\x80", &.{});
    try testTokenize("//\xf4\x8f\xbf\xbf", &.{});
}

test "invalid utf8" {
    try testTokenize("//\x80", &.{
        .invalid,
    });
    try testTokenize("//\xbf", &.{
        .invalid,
    });
    try testTokenize("//\xf8", &.{
        .invalid,
    });
    try testTokenize("//\xff", &.{
        .invalid,
    });
    try testTokenize("//\xc2\xc0", &.{
        .invalid,
    });
    try testTokenize("//\xe0", &.{
        .invalid,
    });
    try testTokenize("//\xf0", &.{
        .invalid,
    });
    try testTokenize("//\xf0\x90\x80\xc0", &.{
        .invalid,
    });
}

test "illegal unicode codepoints" {
    // unicode newline characters.U+0085, U+2028, U+2029
    try testTokenize("//\xc2\x84", &.{});
    try testTokenize("//\xc2\x85", &.{
        .invalid,
    });
    try testTokenize("//\xc2\x86", &.{});
    try testTokenize("//\xe2\x80\xa7", &.{});
    try testTokenize("//\xe2\x80\xa8", &.{
        .invalid,
    });
    try testTokenize("//\xe2\x80\xa9", &.{
        .invalid,
    });
    try testTokenize("//\xe2\x80\xaa", &.{});
}

test "comments with literal tab" {
    try testTokenize(
        \\//foo	bar
        \\//!foo	bar
        \\///foo	bar
        \\//	foo
        \\///	foo
        \\///	/foo
    , &.{});
}

test "pipe and then invalid" {
    try testTokenize("||=", &.{
        .pipe_pipe,
        .equal,
    });
}

test "line comments in two forms" {
    try testTokenize("//", &.{});
    try testTokenize("// a / b", &.{});
    try testTokenize("// /", &.{});
    try testTokenize("/// a", &.{});
    try testTokenize("///", &.{});
    try testTokenize("////", &.{});
    try testTokenize("--", &.{});
    try testTokenize("-- hello world!", &.{});
    try testTokenize("---", &.{});
    try testTokenize("-- ---", &.{});
}

test "line comment followed by identifier" {
    try testTokenize(
        \\    Unexpected,
        \\    // another
        \\    Another,
    , &.{
        .identifier,
        .comma,
        .identifier,
        .comma,
    });
}

test "UTF-8 BOM is recognized and skipped" {
    try testTokenize("\xEF\xBB\xBFa;\n", &.{
        .identifier,
        .semicolon,
    });
}

test "correctly parse an accessor" {
    try testTokenize("b.c=3;\n", &.{
        .identifier,
        .period,
        .identifier,
        .equal,
        .number_literal,
        .semicolon,
    });
}

test "range literals" {
    try testTokenize("0...9", &.{ .number_literal, .ellipsis3, .number_literal });
    try testTokenize("'0'...'9'", &.{ .char_literal, .ellipsis3, .char_literal });
    try testTokenize("0x00...0x09", &.{ .number_literal, .ellipsis3, .number_literal });
    try testTokenize("0b00...0b11", &.{ .number_literal, .ellipsis3, .number_literal });
    try testTokenize("0o00...0o11", &.{ .number_literal, .ellipsis3, .number_literal });
}

test "number literals decimal" {
    try testTokenize("0", &.{.number_literal});
    try testTokenize("1", &.{.number_literal});
    try testTokenize("2", &.{.number_literal});
    try testTokenize("3", &.{.number_literal});
    try testTokenize("4", &.{.number_literal});
    try testTokenize("5", &.{.number_literal});
    try testTokenize("6", &.{.number_literal});
    try testTokenize("7", &.{.number_literal});
    try testTokenize("8", &.{.number_literal});
    try testTokenize("9", &.{.number_literal});
    try testTokenize("1..", &.{ .number_literal, .ellipsis2 });
    try testTokenize("0a", &.{.number_literal});
    try testTokenize("9b", &.{.number_literal});
    try testTokenize("1z", &.{.number_literal});
    try testTokenize("1z_1", &.{.number_literal});
    try testTokenize("9z3", &.{.number_literal});

    try testTokenize("0_0", &.{.number_literal});
    try testTokenize("0001", &.{.number_literal});
    try testTokenize("01234567890", &.{.number_literal});
    try testTokenize("012_345_6789_0", &.{.number_literal});
    try testTokenize("0_1_2_3_4_5_6_7_8_9_0", &.{.number_literal});

    try testTokenize("00_", &.{.number_literal});
    try testTokenize("0_0_", &.{.number_literal});
    try testTokenize("0__0", &.{.number_literal});
    try testTokenize("0_0f", &.{.number_literal});
    try testTokenize("0_0_f", &.{.number_literal});
    try testTokenize("0_0_f_00", &.{.number_literal});
    try testTokenize("1_,", &.{ .number_literal, .comma });

    try testTokenize("0.0", &.{.number_literal});
    try testTokenize("1.0", &.{.number_literal});
    try testTokenize("10.0", &.{.number_literal});
    try testTokenize("0e0", &.{.number_literal});
    try testTokenize("1e0", &.{.number_literal});
    try testTokenize("1e100", &.{.number_literal});
    try testTokenize("1.0e100", &.{.number_literal});
    try testTokenize("1.0e+100", &.{.number_literal});
    try testTokenize("1.0e-100", &.{.number_literal});
    try testTokenize("1_0_0_0.0_0_0_0_0_1e1_0_0_0", &.{.number_literal});

    try testTokenize("1.", &.{ .number_literal, .period });
    try testTokenize("1e", &.{.number_literal});
    try testTokenize("1.e100", &.{.number_literal});
    try testTokenize("1.0e1f0", &.{.number_literal});
    try testTokenize("1.0p100", &.{.number_literal});
    try testTokenize("1.0p-100", &.{.number_literal});
    try testTokenize("1.0p1f0", &.{.number_literal});
    try testTokenize("1.0_,", &.{ .number_literal, .comma });
    try testTokenize("1_.0", &.{.number_literal});
    try testTokenize("1._", &.{.number_literal});
    try testTokenize("1.a", &.{.number_literal});
    try testTokenize("1.z", &.{.number_literal});
    try testTokenize("1._0", &.{.number_literal});
    try testTokenize("1.+", &.{ .number_literal, .period, .plus });
    try testTokenize("1._+", &.{ .number_literal, .plus });
    try testTokenize("1._e", &.{.number_literal});
    try testTokenize("1.0e", &.{.number_literal});
    try testTokenize("1.0e,", &.{ .number_literal, .comma });
    try testTokenize("1.0e_", &.{.number_literal});
    try testTokenize("1.0e+_", &.{.number_literal});
    try testTokenize("1.0e-_", &.{.number_literal});
    try testTokenize("1.0e0_+", &.{ .number_literal, .plus });
}

test "number literals binary" {
    try testTokenize("0b0", &.{.number_literal});
    try testTokenize("0b1", &.{.number_literal});
    try testTokenize("0b2", &.{.number_literal});
    try testTokenize("0b3", &.{.number_literal});
    try testTokenize("0b4", &.{.number_literal});
    try testTokenize("0b5", &.{.number_literal});
    try testTokenize("0b6", &.{.number_literal});
    try testTokenize("0b7", &.{.number_literal});
    try testTokenize("0b8", &.{.number_literal});
    try testTokenize("0b9", &.{.number_literal});
    try testTokenize("0ba", &.{.number_literal});
    try testTokenize("0bb", &.{.number_literal});
    try testTokenize("0bc", &.{.number_literal});
    try testTokenize("0bd", &.{.number_literal});
    try testTokenize("0be", &.{.number_literal});
    try testTokenize("0bf", &.{.number_literal});
    try testTokenize("0bz", &.{.number_literal});

    try testTokenize("0b0000_0000", &.{.number_literal});
    try testTokenize("0b1111_1111", &.{.number_literal});
    try testTokenize("0b10_10_10_10", &.{.number_literal});
    try testTokenize("0b0_1_0_1_0_1_0_1", &.{.number_literal});
    try testTokenize("0b1.", &.{ .number_literal, .period });
    try testTokenize("0b1.0", &.{.number_literal});

    try testTokenize("0B0", &.{.number_literal});
    try testTokenize("0b_", &.{.number_literal});
    try testTokenize("0b_0", &.{.number_literal});
    try testTokenize("0b1_", &.{.number_literal});
    try testTokenize("0b0__1", &.{.number_literal});
    try testTokenize("0b0_1_", &.{.number_literal});
    try testTokenize("0b1e", &.{.number_literal});
    try testTokenize("0b1p", &.{.number_literal});
    try testTokenize("0b1e0", &.{.number_literal});
    try testTokenize("0b1p0", &.{.number_literal});
    try testTokenize("0b1_,", &.{ .number_literal, .comma });
}

test "number literals octal" {
    try testTokenize("0o0", &.{.number_literal});
    try testTokenize("0o1", &.{.number_literal});
    try testTokenize("0o2", &.{.number_literal});
    try testTokenize("0o3", &.{.number_literal});
    try testTokenize("0o4", &.{.number_literal});
    try testTokenize("0o5", &.{.number_literal});
    try testTokenize("0o6", &.{.number_literal});
    try testTokenize("0o7", &.{.number_literal});
    try testTokenize("0o8", &.{.number_literal});
    try testTokenize("0o9", &.{.number_literal});
    try testTokenize("0oa", &.{.number_literal});
    try testTokenize("0ob", &.{.number_literal});
    try testTokenize("0oc", &.{.number_literal});
    try testTokenize("0od", &.{.number_literal});
    try testTokenize("0oe", &.{.number_literal});
    try testTokenize("0of", &.{.number_literal});
    try testTokenize("0oz", &.{.number_literal});

    try testTokenize("0o01234567", &.{.number_literal});
    try testTokenize("0o0123_4567", &.{.number_literal});
    try testTokenize("0o01_23_45_67", &.{.number_literal});
    try testTokenize("0o0_1_2_3_4_5_6_7", &.{.number_literal});
    try testTokenize("0o7.", &.{ .number_literal, .period });
    try testTokenize("0o7.0", &.{.number_literal});

    try testTokenize("0O0", &.{.number_literal});
    try testTokenize("0o_", &.{.number_literal});
    try testTokenize("0o_0", &.{.number_literal});
    try testTokenize("0o1_", &.{.number_literal});
    try testTokenize("0o0__1", &.{.number_literal});
    try testTokenize("0o0_1_", &.{.number_literal});
    try testTokenize("0o1e", &.{.number_literal});
    try testTokenize("0o1p", &.{.number_literal});
    try testTokenize("0o1e0", &.{.number_literal});
    try testTokenize("0o1p0", &.{.number_literal});
    try testTokenize("0o_,", &.{ .number_literal, .comma });
}

test "number literals hexadecimal" {
    try testTokenize("0x0", &.{.number_literal});
    try testTokenize("0x1", &.{.number_literal});
    try testTokenize("0x2", &.{.number_literal});
    try testTokenize("0x3", &.{.number_literal});
    try testTokenize("0x4", &.{.number_literal});
    try testTokenize("0x5", &.{.number_literal});
    try testTokenize("0x6", &.{.number_literal});
    try testTokenize("0x7", &.{.number_literal});
    try testTokenize("0x8", &.{.number_literal});
    try testTokenize("0x9", &.{.number_literal});
    try testTokenize("0xa", &.{.number_literal});
    try testTokenize("0xb", &.{.number_literal});
    try testTokenize("0xc", &.{.number_literal});
    try testTokenize("0xd", &.{.number_literal});
    try testTokenize("0xe", &.{.number_literal});
    try testTokenize("0xf", &.{.number_literal});
    try testTokenize("0xA", &.{.number_literal});
    try testTokenize("0xB", &.{.number_literal});
    try testTokenize("0xC", &.{.number_literal});
    try testTokenize("0xD", &.{.number_literal});
    try testTokenize("0xE", &.{.number_literal});
    try testTokenize("0xF", &.{.number_literal});
    try testTokenize("0x0z", &.{.number_literal});
    try testTokenize("0xz", &.{.number_literal});

    try testTokenize("0x0123456789ABCDEF", &.{.number_literal});
    try testTokenize("0x0123_4567_89AB_CDEF", &.{.number_literal});
    try testTokenize("0x01_23_45_67_89AB_CDE_F", &.{.number_literal});
    try testTokenize("0x0_1_2_3_4_5_6_7_8_9_A_B_C_D_E_F", &.{.number_literal});

    try testTokenize("0X0", &.{.number_literal});
    try testTokenize("0x_", &.{.number_literal});
    try testTokenize("0x_1", &.{.number_literal});
    try testTokenize("0x1_", &.{.number_literal});
    try testTokenize("0x0__1", &.{.number_literal});
    try testTokenize("0x0_1_", &.{.number_literal});
    try testTokenize("0x_,", &.{ .number_literal, .comma });

    try testTokenize("0x1.0", &.{.number_literal});
    try testTokenize("0xF.0", &.{.number_literal});
    try testTokenize("0xF.F", &.{.number_literal});
    try testTokenize("0xF.Fp0", &.{.number_literal});
    try testTokenize("0xF.FP0", &.{.number_literal});
    try testTokenize("0x1p0", &.{.number_literal});
    try testTokenize("0xfp0", &.{.number_literal});
    try testTokenize("0x1.0+0xF.0", &.{ .number_literal, .plus, .number_literal });

    try testTokenize("0x1.", &.{ .number_literal, .period });
    try testTokenize("0xF.", &.{ .number_literal, .period });
    try testTokenize("0x1.+0xF.", &.{ .number_literal, .period, .plus, .number_literal, .period });
    try testTokenize("0xff.p10", &.{.number_literal});

    try testTokenize("0x0123456.789ABCDEF", &.{.number_literal});
    try testTokenize("0x0_123_456.789_ABC_DEF", &.{.number_literal});
    try testTokenize("0x0_1_2_3_4_5_6.7_8_9_A_B_C_D_E_F", &.{.number_literal});
    try testTokenize("0x0p0", &.{.number_literal});
    try testTokenize("0x0.0p0", &.{.number_literal});
    try testTokenize("0xff.ffp10", &.{.number_literal});
    try testTokenize("0xff.ffP10", &.{.number_literal});
    try testTokenize("0xffp10", &.{.number_literal});
    try testTokenize("0xff_ff.ff_ffp1_0_0_0", &.{.number_literal});
    try testTokenize("0xf_f_f_f.f_f_f_fp+1_000", &.{.number_literal});
    try testTokenize("0xf_f_f_f.f_f_f_fp-1_00_0", &.{.number_literal});

    try testTokenize("0x1e", &.{.number_literal});
    try testTokenize("0x1e0", &.{.number_literal});
    try testTokenize("0x1p", &.{.number_literal});
    try testTokenize("0xfp0z1", &.{.number_literal});
    try testTokenize("0xff.ffpff", &.{.number_literal});
    try testTokenize("0x0.p", &.{.number_literal});
    try testTokenize("0x0.z", &.{.number_literal});
    try testTokenize("0x0._", &.{.number_literal});
    try testTokenize("0x0_.0", &.{.number_literal});
    try testTokenize("0x0_.0.0", &.{ .number_literal, .period, .number_literal });
    try testTokenize("0x0._0", &.{.number_literal});
    try testTokenize("0x0.0_", &.{.number_literal});
    try testTokenize("0x0_p0", &.{.number_literal});
    try testTokenize("0x0_.p0", &.{.number_literal});
    try testTokenize("0x0._p0", &.{.number_literal});
    try testTokenize("0x0.0_p0", &.{.number_literal});
    try testTokenize("0x0._0p0", &.{.number_literal});
    try testTokenize("0x0.0p_0", &.{.number_literal});
    try testTokenize("0x0.0p+_0", &.{.number_literal});
    try testTokenize("0x0.0p-_0", &.{.number_literal});
    try testTokenize("0x0.0p0_", &.{.number_literal});
}

test "multi line string literal with only 1 backslash" {
    try testTokenize("x \\\n;", &.{ .identifier, .invalid, .semicolon });
}

test "invalid builtin identifiers" {
    try testTokenize("@()", &.{ .invalid, .l_paren, .r_paren });
    try testTokenize("@0()", &.{ .invalid, .number_literal, .l_paren, .r_paren });
}

test "invalid token with unfinished escape right before eof" {
    try testTokenize("\"\\", &.{.invalid});
    try testTokenize("'\\", &.{.invalid});
    try testTokenize("'\\u", &.{.invalid});
}

test "null byte before eof" {
    try testTokenize("123 \x00 456", &.{ .number_literal, .invalid, .number_literal });
    try testTokenize("//\x00", &.{.invalid});
    // try testTokenize("/*\x00", &.{.invalid});
    try testTokenize("\x00", &.{.invalid});
    try testTokenize("// NUL\x00\n", &.{.invalid});
    try testTokenize("///\x00\n", &.{.invalid});
    try testTokenize("/// NUL\x00\n", &.{.invalid});
}

fn testTokenize(source: [:0]const u8, expected_token_tags: []const Token.Tag) !void {
    var tokenizer = Tokenizer.init(source);
    for (expected_token_tags) |expected_token_tag| {
        const token = tokenizer.next();
        try std.testing.expectEqual(expected_token_tag, token.tag);
    }
    const last_token = tokenizer.next();
    try std.testing.expectEqual(Token.Tag.eof, last_token.tag);
    try std.testing.expectEqual(source.len, last_token.loc.start);
    try std.testing.expectEqual(source.len, last_token.loc.end);
}
