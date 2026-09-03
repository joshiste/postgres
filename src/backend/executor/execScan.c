/*-------------------------------------------------------------------------
 *
 * execScan.c
 *	  This code provides support for generalized relation scans. ExecScan
 *	  is passed a node and a pointer to a function to "do the right thing"
 *	  and return a tuple from the relation. ExecScan then does the tedious
 *	  stuff - checking the qualification and projecting the tuple
 *	  appropriately.
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/executor/execScan.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "catalog/pg_type.h"
#include "executor/executor.h"
#include "executor/execScan.h"
#include "miscadmin.h"
#include "nodes/nodeFuncs.h"
#include "utils/fmgroids.h"

/* ----------------------------------------------------------------
 *		ExecScan
 *
 *		Scans the relation using the 'access method' indicated and
 *		returns the next qualifying tuple.
 *		The access method returns the next tuple and ExecScan() is
 *		responsible for checking the tuple returned against the qual-clause.
 *
 *		A 'recheck method' must also be provided that can check an
 *		arbitrary tuple of the relation against any qual conditions
 *		that are implemented internal to the access method.
 *
 *		Conditions:
 *		  -- the "cursor" maintained by the AMI is positioned at the tuple
 *			 returned previously.
 *
 *		Initial States:
 *		  -- the relation indicated is opened for scanning so that the
 *			 "cursor" is positioned before the first qualifying tuple.
 * ----------------------------------------------------------------
 */
TupleTableSlot *
ExecScan(ScanState *node,
		 ExecScanAccessMtd accessMtd,	/* function returning a tuple */
		 ExecScanRecheckMtd recheckMtd)
{
	EPQState   *epqstate;
	ExprState  *qual;
	ProjectionInfo *projInfo;

	epqstate = node->ps.state->es_epq_active;
	qual = node->ps.qual;
	projInfo = node->ps.ps_ProjInfo;

	return ExecScanExtended(node,
							accessMtd,
							recheckMtd,
							epqstate,
							qual,
							projInfo);
}

/*
 * ExecAssignScanProjectionInfo
 *		Set up projection info for a scan node, if necessary.
 *
 * We can avoid a projection step if the requested tlist exactly matches
 * the underlying tuple type.  If so, we just set ps_ProjInfo to NULL.
 * Note that this case occurs not only for simple "SELECT * FROM ...", but
 * also in most cases where there are joins or other processing nodes above
 * the scan node, because the planner will preferentially generate a matching
 * tlist.
 *
 * The scan slot's descriptor must have been set already.
 */
void
ExecAssignScanProjectionInfo(ScanState *node)
{
	Scan	   *scan = (Scan *) node->ps.plan;
	TupleDesc	tupdesc = node->ss_ScanTupleSlot->tts_tupleDescriptor;

	ExecConditionalAssignProjectionInfo(&node->ps, tupdesc, scan->scanrelid);
}

/*
 * ExecAssignScanProjectionInfoWithVarno
 *		As above, but caller can specify varno expected in Vars in the tlist.
 */
void
ExecAssignScanProjectionInfoWithVarno(ScanState *node, int varno)
{
	TupleDesc	tupdesc = node->ss_ScanTupleSlot->tts_tupleDescriptor;

	ExecConditionalAssignProjectionInfo(&node->ps, tupdesc, varno);
}

/*
 * ExecScanReScan
 *
 * This must be called within the ReScan function of any plan node type
 * that uses ExecScan().
 */
void
ExecScanReScan(ScanState *node)
{
	EState	   *estate = node->ps.state;

	/*
	 * We must clear the scan tuple so that observers (e.g., execCurrent.c)
	 * can tell that this plan node is not positioned on a tuple.
	 */
	ExecClearTuple(node->ss_ScanTupleSlot);

	/*
	 * Rescan EvalPlanQual tuple(s) if we're inside an EvalPlanQual recheck.
	 * But don't lose the "blocked" status of blocked target relations.
	 */
	if (estate->es_epq_active != NULL)
	{
		EPQState   *epqstate = estate->es_epq_active;
		Index		scanrelid = ((Scan *) node->ps.plan)->scanrelid;

		if (scanrelid > 0)
			epqstate->relsubs_done[scanrelid - 1] =
				epqstate->relsubs_blocked[scanrelid - 1];
		else
		{
			Bitmapset  *relids;
			int			rtindex = -1;

			/*
			 * If an FDW or custom scan provider has replaced the join with a
			 * scan, there are multiple RTIs; reset the relsubs_done flag for
			 * all of them.
			 */
			if (IsA(node->ps.plan, ForeignScan))
				relids = ((ForeignScan *) node->ps.plan)->fs_base_relids;
			else if (IsA(node->ps.plan, CustomScan))
				relids = ((CustomScan *) node->ps.plan)->custom_relids;
			else
				elog(ERROR, "unexpected scan node: %d",
					 (int) nodeTag(node->ps.plan));

			while ((rtindex = bms_next_member(relids, rtindex)) >= 0)
			{
				Assert(rtindex > 0);
				epqstate->relsubs_done[rtindex - 1] =
					epqstate->relsubs_blocked[rtindex - 1];
			}
		}
	}
}


/* Detoast a toasted column once per row when several expressions reference it */
bool		shared_detoast = true;

/*
 * Attributes of this scan node's slot that several of its expressions would
 * detoast.  This is the decision point that the executor-side and planner-side
 * variants replace; the base returns none, so nothing changes yet.
 */
static Bitmapset *
ExecScanPredetoastCandidates(ScanState *node, TupleDesc tupdesc)
{
	return NULL;
}

/*
 * Functions whose result depends on the stored representation of their
 * argument rather than on its value.  A Var passed directly to one of these
 * must keep its toast pointer, so the attribute is never detoasted in place.
 */
static bool
predetoast_veto_walker(Node *node, Bitmapset **vetoed)
{
	if (node == NULL)
		return false;
	if (IsA(node, FuncExpr))
	{
		FuncExpr   *f = (FuncExpr *) node;

		if (f->funcid == F_PG_COLUMN_SIZE ||
			f->funcid == F_PG_COLUMN_COMPRESSION ||
			f->funcid == F_PG_COLUMN_TOAST_CHUNK_ID)
		{
			ListCell   *lc;

			foreach(lc, f->args)
			{
				Var		   *arg = (Var *) lfirst(lc);

				if (IsA(arg, Var) && arg->varattno > 0)
					*vetoed = bms_add_member(*vetoed, arg->varattno);
			}
		}
	}
	return expression_tree_walker(node, predetoast_veto_walker, vetoed);
}

/*
 * ExecScanPredetoastAttrs
 *
 * Decide which scan-slot attributes this node may detoast in place.  A
 * detoasted value written back into the scan slot is visible to every
 * expression of the node, which is the point, but also to any parent that
 * reads the slot or a projection of it.  That is harmless as long as the
 * value is never copied into a stored tuple, so an attribute qualifies when
 * either the parent chain consumes rows one at a time (EXEC_FLAG_ROW_CONSUMER)
 * or the node projects and the attribute leaves it only inside expression
 * results, never as a bare Var.  A node without projection hands its scan slot
 * to the parent, so all attributes count as projected there.  Attributes
 * inspected by a representation-dependent function are excluded outright.
 */
Bitmapset *
ExecScanPredetoastAttrs(ScanState *node, TupleDesc tupdesc, int eflags)
{
	Plan	   *plan = node->ps.plan;
	Bitmapset  *candidates;
	Bitmapset  *allowed = NULL;
	Bitmapset  *vetoed = NULL;
	ListCell   *lc;
	int			varno;

	/* Agg, Sort and others embed a ScanState too; only real scans qualify */
	if (!shared_detoast || tupdesc == NULL || !IsScanPlan(plan))
		return NULL;

	candidates = ExecScanPredetoastCandidates(node, tupdesc);
	if (candidates == NULL)
		return NULL;

	for (int i = 0; i < tupdesc->natts; i++)
	{
		Form_pg_attribute att = TupleDescAttr(tupdesc, i);

		if (att->attisdropped || att->attlen != -1 ||
			att->attstorage == TYPSTORAGE_PLAIN)
			continue;
		if (bms_is_member(att->attnum, candidates))
			allowed = bms_add_member(allowed, att->attnum);
	}

	predetoast_veto_walker((Node *) plan->targetlist, &vetoed);
	predetoast_veto_walker((Node *) plan->qual, &vetoed);
	allowed = bms_del_members(allowed, vetoed);

	if (eflags & EXEC_FLAG_ROW_CONSUMER)
		return allowed;

	/*
	 * The targetlist of an index-only scan, and of a foreign or custom scan
	 * that replaces a join or upper relation (scanrelid == 0), refers to the
	 * scan tuple through INDEX_VAR; everything else uses the scan's own
	 * varno.
	 */
	if (IsA(plan, IndexOnlyScan) || ((Scan *) plan)->scanrelid == 0)
		varno = INDEX_VAR;
	else
		varno = ((Scan *) plan)->scanrelid;

	if (tlist_matches_tupdesc(&node->ps, plan->targetlist, varno, tupdesc))
		return NULL;			/* no projection: the whole slot is passed up */

	foreach(lc, plan->targetlist)
	{
		TargetEntry *tle = (TargetEntry *) lfirst(lc);

		if (IsA(tle->expr, Var) && ((Var *) tle->expr)->varattno > 0)
			allowed = bms_del_member(allowed, ((Var *) tle->expr)->varattno);
	}

	return allowed;
}
