/*--------------------------------------------------------------------------
 *
 * detoast_reuse.c
 *		Test code for detoasting a column once per row.
 *
 * Copyright (c) 2026, PostgreSQL Global Development Group
 *
 * IDENTIFICATION
 *		src/test/modules/detoast_reuse/detoast_reuse.c
 *
 * -------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/detoast.h"
#include "access/htup_details.h"
#include "catalog/pg_collation.h"
#include "catalog/pg_type.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "nodes/makefuncs.h"
#include "nodes/supportnodes.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "utils/tuplestore.h"

PG_MODULE_MAGIC;

/*
 * A plan node scanning tuples of scandesc, with attribute attnum marked for
 * detoasting once per row as set_plan_references() would mark it.
 */
static PlanState *
make_marked_planstate(EState *estate, TupleDesc scandesc, int attnum)
{
	Plan	   *plan = (Plan *) makeNode(Result);
	PlanState  *ps = (PlanState *) makeNode(ResultState);

	plan->detoast_reuse_scan = bms_make_singleton(attnum);
	ps->plan = plan;
	ps->state = estate;
	ps->scandesc = scandesc;
	return ps;
}

/* attribute attno of the scan tuple, cast to text through I/O */
static Expr *
make_text_of_var(Form_pg_attribute attr, AttrNumber attno)
{
	CoerceViaIO *coerce = makeNode(CoerceViaIO);

	coerce->arg = (Expr *) makeVar(1, attno, attr->atttypid, attr->atttypmod,
								   attr->attcollation, 0);
	coerce->resulttype = TEXTOID;
	coerce->resultcollid = DEFAULT_COLLATION_OID;
	coerce->coerceformat = COERCE_EXPLICIT_CAST;
	coerce->location = -1;
	return (Expr *) coerce;
}

/*
 * Run query, then evaluate the text form of its column attnum for each row
 * the way an extension's scan node may: the rows go through one virtual
 * slot, the first stored with ExecStoreVirtualTuple() and every later one
 * written over tts_values in place, without ExecClearTuple().  mode is one
 * of
 *
 * distinct		each row's datums at an address of their own
 * same_address	each row's datums built in a context reset before each row,
 *				so that they usually land where the previous row's were
 * project		as distinct, with each row projected into a second slot and
 *				the expression evaluated there; the expression on the first
 *				slot runs for the first row only, as a qual that
 *				short-circuits on later rows would, so that the projection
 *				finds a copy made for an earlier row
 * project_same_address  both of the above
 * result_refilled  the first row projected into the second slot as above,
 *				the first slot then cleared, which frees the copy the second
 *				slot borrowed, and every later row written over the second
 *				slot's tts_values in place
 * expanded		as same_address, with the column, which must be an array,
 *				handed over as an expanded object
 * indirect		as same_address, with the column handed over as an indirect
 *				toast pointer to its detoasted value
 *
 * In the last two the stored datum is only the address of the value, and
 * each row's is the same as the previous row's.
 */
PG_FUNCTION_INFO_V1(detoast_reuse_refill_in_place);
Datum
detoast_reuse_refill_in_place(PG_FUNCTION_ARGS)
{
	char	   *query = text_to_cstring(PG_GETARG_TEXT_PP(0));
	int			attnum = PG_GETARG_INT32(1);
	char	   *mode = text_to_cstring(PG_GETARG_TEXT_PP(2));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	bool		same_address;
	bool		project;
	bool		result_refilled;
	bool		expanded;
	bool		indirect;
	MemoryContext callercxt;
	MemoryContext rowcxt;
	TupleDesc	tupdesc;
	Form_pg_attribute attr;
	int			natts;
	uint64		nrows;
	Datum	  **values;
	bool	  **isnull;
	EState	   *estate;
	ExprContext *econtext;
	TupleTableSlot *slot;
	TupleTableSlot *resultslot = NULL;
	ExprState  *expr;
	ExprState  *resultexpr = NULL;
	ProjectionInfo *proj = NULL;

	expanded = strcmp(mode, "expanded") == 0;
	indirect = strcmp(mode, "indirect") == 0;
	same_address = strcmp(mode, "same_address") == 0 ||
		strcmp(mode, "project_same_address") == 0 || expanded || indirect;
	project = strncmp(mode, "project", 7) == 0;
	result_refilled = strcmp(mode, "result_refilled") == 0;
	if (!same_address && !project && !result_refilled &&
		strcmp(mode, "distinct") != 0)
		elog(ERROR, "unrecognized mode \"%s\"", mode);

	InitMaterializedSRF(fcinfo, MAT_SRF_USE_EXPECTED_DESC);

	callercxt = CurrentMemoryContext;
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed");
	if (SPI_execute(query, true, 0) != SPI_OK_SELECT)
		elog(ERROR, "query must be a SELECT");

	MemoryContextSwitchTo(callercxt);
	tupdesc = CreateTupleDescCopy(SPI_tuptable->tupdesc);
	natts = tupdesc->natts;
	if (attnum < 1 || attnum > natts)
		elog(ERROR, "attribute number %d out of range", attnum);
	attr = TupleDescAttr(tupdesc, attnum - 1);
	if (expanded && !type_is_array(attr->atttypid))
		elog(ERROR, "attribute %d is not an array", attnum);
	if (indirect && attr->attlen != -1)
		elog(ERROR, "attribute %d is not a varlena", attnum);
	nrows = SPI_processed;
	values = palloc_array(Datum *, nrows);
	isnull = palloc_array(bool *, nrows);
	for (uint64 i = 0; i < nrows; i++)
	{
		values[i] = palloc_array(Datum, natts);
		isnull[i] = palloc_array(bool, natts);
		heap_deform_tuple(SPI_tuptable->vals[i], tupdesc, values[i], isnull[i]);

		/* a toast pointer is copied as such, each row's to its own address */
		for (int j = 0; j < natts; j++)
			if (!isnull[i][j])
				values[i][j] = datumCopy(values[i][j],
										 TupleDescAttr(tupdesc, j)->attbyval,
										 TupleDescAttr(tupdesc, j)->attlen);
	}
	SPI_finish();

	rowcxt = AllocSetContextCreate(CurrentMemoryContext, "refilled row",
								   ALLOCSET_SMALL_SIZES);
	estate = CreateExecutorState();
	econtext = GetPerTupleExprContext(estate);
	slot = MakeSingleTupleTableSlot(tupdesc, &TTSOpsVirtual);
	expr = ExecInitExpr(make_text_of_var(attr, attnum),
						make_marked_planstate(estate, tupdesc, attnum));
	if (project || result_refilled)
	{
		TupleDesc	resultdesc = CreateTemplateTupleDesc(1);
		Var		   *var = makeVar(1, attnum, attr->atttypid, attr->atttypmod,
								  attr->attcollation, 0);

		TupleDescInitEntry(resultdesc, 1, "v", attr->atttypid,
						   attr->atttypmod, 0);
		TupleDescInitEntryCollation(resultdesc, 1, attr->attcollation);
		TupleDescFinalize(resultdesc);
		resultslot = MakeSingleTupleTableSlot(resultdesc, &TTSOpsVirtual);
		proj = ExecBuildProjectionInfo(list_make1(makeTargetEntry((Expr *) var,
																  1, "v",
																  false)),
									   econtext, resultslot,
									   make_marked_planstate(estate, tupdesc, attnum),
									   tupdesc);
		resultexpr = ExecInitExpr(make_text_of_var(TupleDescAttr(resultdesc, 0),
												   1),
								  make_marked_planstate(estate, resultdesc, 1));
	}

	for (uint64 i = 0; i < nrows; i++)
	{
		Datum	   *rowvalues = values[i];
		Datum		result;
		bool		resnull;

		if (same_address)
		{
			MemoryContext oldcxt;

			MemoryContextReset(rowcxt);
			oldcxt = MemoryContextSwitchTo(rowcxt);
			rowvalues = palloc_array(Datum, natts);
			if (expanded && !isnull[i][attnum - 1])
				rowvalues[attnum - 1] = expand_array(values[i][attnum - 1],
													 rowcxt, NULL);
			else if (indirect && !isnull[i][attnum - 1])
			{
				varlena    *ptr = palloc(INDIRECT_POINTER_SIZE);
				varatt_indirect redirect;

				/* allocated before the value, whose size differs by row */
				redirect.pointer = detoast_attr((varlena *)
												DatumGetPointer(values[i][attnum - 1]));
				SET_VARTAG_EXTERNAL(ptr, VARTAG_INDIRECT);
				memcpy(VARDATA_EXTERNAL(ptr), &redirect, sizeof(redirect));
				rowvalues[attnum - 1] = PointerGetDatum(ptr);
			}
			for (int j = 0; j < natts; j++)
			{
				if ((expanded || indirect) && j == attnum - 1)
					continue;
				rowvalues[j] = isnull[i][j] ? (Datum) 0 :
					datumCopy(values[i][j],
							  TupleDescAttr(tupdesc, j)->attbyval,
							  TupleDescAttr(tupdesc, j)->attlen);
			}
			MemoryContextSwitchTo(oldcxt);
		}

		if (result_refilled && i > 0)
		{
			resultslot->tts_values[0] = rowvalues[attnum - 1];
			resultslot->tts_isnull[0] = isnull[i][attnum - 1];
			econtext->ecxt_scantuple = resultslot;
			result = ExecEvalExprSwitchContext(resultexpr, econtext, &resnull);
		}
		else
		{
			if (i == 0)
				ExecClearTuple(slot);
			memcpy(slot->tts_values, rowvalues, natts * sizeof(Datum));
			memcpy(slot->tts_isnull, isnull[i], natts * sizeof(bool));
			if (i == 0)
				ExecStoreVirtualTuple(slot);

			econtext->ecxt_scantuple = slot;
			if (project || result_refilled)
			{
				if (i == 0)
					(void) ExecEvalExprSwitchContext(expr, econtext, &resnull);
				ExecProject(proj);
				econtext->ecxt_scantuple = resultslot;
				result = ExecEvalExprSwitchContext(resultexpr, econtext,
												   &resnull);
				if (result_refilled)
					ExecClearTuple(slot);
			}
			else
				result = ExecEvalExprSwitchContext(expr, econtext, &resnull);
		}

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							 &result, &resnull);
		ResetExprContext(econtext);
	}

	ExecDropSingleTupleTableSlot(slot);
	if (resultslot)
		ExecDropSingleTupleTableSlot(resultslot);
	FreeExecutorState(estate);
	MemoryContextDelete(rowcxt);

	return (Datum) 0;
}

/*
 * The size of the argument as it was passed, which is the stored size only
 * if the executor passed the stored datum.
 */
PG_FUNCTION_INFO_V1(detoast_reuse_stored_size);
Datum
detoast_reuse_stored_size(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32((int32) toast_datum_size(PG_GETARG_DATUM(0)));
}

PG_FUNCTION_INFO_V1(detoast_reuse_stored_support);
Datum
detoast_reuse_stored_support(PG_FUNCTION_ARGS)
{
	Node	   *rawreq = (Node *) PG_GETARG_POINTER(0);
	Node	   *ret = NULL;

	if (IsA(rawreq, SupportRequestArgRead))
	{
		SupportRequestArgRead *req = (SupportRequestArgRead *) rawreq;

		req->read = FUNC_ARG_READS_STORED;
		ret = (Node *) req;
	}

	PG_RETURN_POINTER(ret);
}
