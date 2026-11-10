/* src/test/modules/detoast_reuse/detoast_reuse--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION detoast_reuse" to load this file. \quit

CREATE FUNCTION detoast_reuse_refill_in_place(query text, attnum int,
                                              mode text DEFAULT 'distinct')
RETURNS SETOF text
STRICT
AS 'MODULE_PATHNAME' LANGUAGE C;
