%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1996
%
\section[DsExpr]{Matching expressions (Exprs)}

\begin{code}
#include "HsVersions.h"

module DsExpr ( dsExpr ) where

IMP_Ubiq()
IMPORT_DELOOPER(DsLoop)		-- partly to get dsBinds, partly to chk dsExpr

import HsSyn		( failureFreePat,
			  HsExpr(..), OutPat(..), HsLit(..), ArithSeqInfo(..),
			  Stmt(..), DoOrListComp(..), Match(..), HsBinds, HsType, Fixity,
			  GRHSsAndBinds
			)
import TcHsSyn		( SYN_IE(TypecheckedHsExpr), SYN_IE(TypecheckedHsBinds),
			  SYN_IE(TypecheckedRecordBinds), SYN_IE(TypecheckedPat),
			  SYN_IE(TypecheckedStmt)
			)
import CoreSyn

import DsMonad
import DsCCall		( dsCCall )
import DsHsSyn		( outPatType )
import DsListComp	( dsListComp )
import DsUtils		( mkAppDs, mkConDs, mkPrimDs, dsExprToAtom, mkTupleExpr,
			  mkErrorAppDs, showForErr, EquationInfo,
			  MatchResult, SYN_IE(DsCoreArg)
			)
import Match		( matchWrapper )

import CoreUtils	( coreExprType, substCoreExpr, argToExpr,
			  mkCoreIfThenElse, unTagBinders )
import CostCentre	( mkUserCC )
import FieldLabel	( fieldLabelType, FieldLabel )
import Id		( idType, nullIdEnv, addOneToIdEnv,
			  dataConArgTys, dataConFieldLabels,
			  recordSelectorFieldLabel, SYN_IE(Id)
			)
import Literal		( mkMachInt, Literal(..) )
import Name		( Name{--O only-} )
import PprStyle		( PprStyle(..) )
import PprType		( GenType )
import PrelVals		( rEC_CON_ERROR_ID, rEC_UPD_ERROR_ID, voidId )
import Pretty		( Doc, hcat, ptext, text )
import TyCon		( isDataTyCon, isNewTyCon )
import Type		( splitSigmaTy, splitFunTy, typePrimRep, 
			  getAppDataTyConExpandingDicts, maybeAppTyCon, getAppTyCon, applyTy,
			  maybeBoxedPrimType, splitAppTy, SYN_IE(Type)
			)
import TysPrim		( voidTy )
import TysWiredIn	( mkTupleTy, tupleCon, nilDataCon, consDataCon, listTyCon,
			  charDataCon, charTy
			)
import TyVar		( nullTyVarEnv, addOneToTyVarEnv, GenTyVar{-instance Eq-} )
import Usage		( SYN_IE(UVar) )
import Maybes		( maybeToBool )
import Util		( zipEqual, pprError, panic, assertPanic )

#if __GLASGOW_HASKELL__ >= 202
import Outputable
#endif

mk_nil_con ty = mkCon nilDataCon [] [ty] []  -- micro utility...
\end{code}

The funny business to do with variables is that we look them up in the
Id-to-Id and Id-to-Id maps that the monadery is carrying
around; if we get hits, we use the value accordingly.

%************************************************************************
%*									*
\subsection[DsExpr-vars-and-cons]{Variables and constructors}
%*									*
%************************************************************************

\begin{code}
dsExpr :: TypecheckedHsExpr -> DsM CoreExpr

dsExpr e@(HsVar var) = dsId var
\end{code}

%************************************************************************
%*									*
\subsection[DsExpr-literals]{Literals}
%*									*
%************************************************************************

We give int/float literals type Integer and Rational, respectively.
The typechecker will (presumably) have put \tr{from{Integer,Rational}s}
around them.

ToDo: put in range checks for when converting "i"
(or should that be in the typechecker?)

For numeric literals, we try to detect there use at a standard type
(Int, Float, etc.) are directly put in the right constructor.
[NB: down with the @App@ conversion.]
Otherwise, we punt, putting in a "NoRep" Core literal (where the
representation decisions are delayed)...

See also below where we look for @DictApps@ for \tr{plusInt}, etc.

\begin{code}
dsExpr (HsLitOut (HsString s) _)
  | _NULL_ s
  = returnDs (mk_nil_con charTy)

  | _LENGTH_ s == 1
  = let
	the_char = mkCon charDataCon [] [] [LitArg (MachChar (_HEAD_ s))]
	the_nil  = mk_nil_con charTy
    in
    mkConDs consDataCon [TyArg charTy, VarArg the_char, VarArg the_nil]

-- "_" => build (\ c n -> c 'c' n)	-- LATER

-- "str" ==> build (\ c n -> foldr charTy T c n "str")

{- LATER:
dsExpr (HsLitOut (HsString str) _)
  = newTyVarsDs [alphaTyVar]		`thenDs` \ [new_tyvar] ->
    let
 	new_ty = mkTyVarTy new_tyvar
    in
    newSysLocalsDs [
		charTy `mkFunTy` (new_ty `mkFunTy` new_ty),
		new_ty,
		       mkForallTy [alphaTyVar]
			       ((charTy `mkFunTy` (alphaTy `mkFunTy` alphaTy))
			       	        `mkFunTy` (alphaTy `mkFunTy` alphaTy))
		]			`thenDs` \ [c,n,g] ->
     returnDs (mkBuild charTy new_tyvar c n g (
	foldl App
	  (CoTyApp (CoTyApp (Var foldrId) charTy) new_ty) *** ensure non-prim type ***
   	  [VarArg c,VarArg n,LitArg (NoRepStr str)]))
-}

-- otherwise, leave it as a NoRepStr;
-- the Core-to-STG pass will wrap it in an application of "unpackCStringId".

dsExpr (HsLitOut (HsString str) _)
  = returnDs (Lit (NoRepStr str))

dsExpr (HsLitOut (HsLitLit s) ty)
  = returnDs ( mkCon data_con [] [] [LitArg (MachLitLit s kind)] )
  where
    (data_con, kind)
      = case (maybeBoxedPrimType ty) of
	  Just (boxing_data_con, prim_ty)
	    -> (boxing_data_con, typePrimRep prim_ty)
	  Nothing
	    -> pprError "ERROR: ``literal-literal'' not a single-constructor type: "
			(hcat [ptext s, text "; type: ", ppr PprDebug ty])

dsExpr (HsLitOut (HsInt i) ty)
  = returnDs (Lit (NoRepInteger i ty))

dsExpr (HsLitOut (HsFrac r) ty)
  = returnDs (Lit (NoRepRational r ty))

-- others where we know what to do:

dsExpr (HsLitOut (HsIntPrim i) _)
  = if (i >= toInteger minInt && i <= toInteger maxInt) then
    	returnDs (Lit (mkMachInt i))
    else
	error ("ERROR: Int constant " ++ show i ++ out_of_range_msg)

dsExpr (HsLitOut (HsFloatPrim f) _)
  = returnDs (Lit (MachFloat f))
    -- ToDo: range checking needed!

dsExpr (HsLitOut (HsDoublePrim d) _)
  = returnDs (Lit (MachDouble d))
    -- ToDo: range checking needed!

dsExpr (HsLitOut (HsChar c) _)
  = returnDs ( mkCon charDataCon [] [] [LitArg (MachChar c)] )

dsExpr (HsLitOut (HsCharPrim c) _)
  = returnDs (Lit (MachChar c))

dsExpr (HsLitOut (HsStringPrim s) _)
  = returnDs (Lit (MachStr s))

-- end of literals magic. --

dsExpr expr@(HsLam a_Match)
  = matchWrapper LambdaMatch [a_Match] "lambda"	`thenDs` \ (binders, matching_code) ->
    returnDs ( mkValLam binders matching_code )

dsExpr expr@(HsApp e1 e2)      = dsApp expr []
dsExpr expr@(OpApp e1 op _ e2) = dsApp expr []
\end{code}

Operator sections.  At first it looks as if we can convert
\begin{verbatim}
	(expr op)
\end{verbatim}
to
\begin{verbatim}
	\x -> op expr x
\end{verbatim}

But no!  expr might be a redex, and we can lose laziness badly this
way.  Consider
\begin{verbatim}
	map (expr op) xs
\end{verbatim}
for example.  So we convert instead to
\begin{verbatim}
	let y = expr in \x -> op y x
\end{verbatim}
If \tr{expr} is actually just a variable, say, then the simplifier
will sort it out.

\begin{code}
dsExpr (SectionL expr op)
  = dsExpr op			`thenDs` \ core_op ->
    dsExpr expr			`thenDs` \ core_expr ->
    dsExprToAtom (VarArg core_expr)	$ \ y_atom ->

    -- for the type of x, we need the type of op's 2nd argument
    let
	x_ty  =	case (splitSigmaTy (coreExprType core_op)) of { (_, _, tau_ty) ->
		case (splitFunTy tau_ty)		   of {
		  ((_:arg2_ty:_), _) -> arg2_ty;
		  _ -> panic "dsExpr:SectionL:arg 2 ty" }}
    in
    newSysLocalDs x_ty		`thenDs` \ x_id ->
    returnDs (mkValLam [x_id] (core_op `App` y_atom `App` VarArg x_id)) 

-- dsExpr (SectionR op expr)	-- \ x -> op x expr
dsExpr (SectionR op expr)
  = dsExpr op			`thenDs` \ core_op ->
    dsExpr expr			`thenDs` \ core_expr ->
    dsExprToAtom (VarArg core_expr)	$ \ y_atom ->

    -- for the type of x, we need the type of op's 1st argument
    let
	x_ty  =	case (splitSigmaTy (coreExprType core_op)) of { (_, _, tau_ty) ->
		case (splitFunTy tau_ty)		   of {
		  ((arg1_ty:_), _) -> arg1_ty;
		  _ -> panic "dsExpr:SectionR:arg 1 ty" }}
    in
    newSysLocalDs x_ty		`thenDs` \ x_id ->
    returnDs (mkValLam [x_id] (core_op `App` VarArg x_id `App` y_atom))

dsExpr (CCall label args may_gc is_asm result_ty)
  = mapDs dsExpr args		`thenDs` \ core_args ->
    dsCCall label core_args may_gc is_asm result_ty
	-- dsCCall does all the unboxification, etc.

dsExpr (HsSCC cc expr)
  = dsExpr expr			`thenDs` \ core_expr ->
    getModuleAndGroupDs		`thenDs` \ (mod_name, group_name) ->
    returnDs ( SCC (mkUserCC cc mod_name group_name) core_expr)

dsExpr expr@(HsCase discrim matches src_loc)
  = putSrcLocDs src_loc $
    dsExpr discrim				`thenDs` \ core_discrim ->
    matchWrapper CaseMatch matches "case"	`thenDs` \ ([discrim_var], matching_code) ->
    returnDs ( mkCoLetAny (NonRec discrim_var core_discrim) matching_code )

dsExpr (HsLet binds expr)
  = dsBinds binds	`thenDs` \ core_binds ->
    dsExpr expr		`thenDs` \ core_expr ->
    returnDs ( mkCoLetsAny core_binds core_expr )

dsExpr (HsDoOut do_or_lc stmts return_id then_id zero_id result_ty src_loc)
  | maybeToBool maybe_list_comp
  =	-- Special case for list comprehensions
    putSrcLocDs src_loc $
    dsListComp stmts elt_ty

  | otherwise
  = putSrcLocDs src_loc $
    dsDo do_or_lc stmts return_id then_id zero_id result_ty
  where
    maybe_list_comp 
	= case (do_or_lc, maybeAppTyCon result_ty) of
	    (ListComp, Just (tycon, [elt_ty]))
		  | tycon == listTyCon
		 -> Just elt_ty
	    other -> Nothing
	-- We need the ListComp form to use deListComp (rather than the "do" form)
	-- because the "return" in a do block is a call to "PrelBase.return", and
	-- not a ReturnStmt.  Only the ListComp form has ReturnStmts

    Just elt_ty = maybe_list_comp

dsExpr (HsIf guard_expr then_expr else_expr src_loc)
  = putSrcLocDs src_loc $
    dsExpr guard_expr	`thenDs` \ core_guard ->
    dsExpr then_expr	`thenDs` \ core_then ->
    dsExpr else_expr	`thenDs` \ core_else ->
    returnDs (mkCoreIfThenElse core_guard core_then core_else)
\end{code}


Type lambda and application
~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
dsExpr (TyLam tyvars expr)
  = dsExpr expr `thenDs` \ core_expr ->
    returnDs (mkTyLam tyvars core_expr)

dsExpr expr@(TyApp e tys) = dsApp expr []
\end{code}


Various data construction things
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
\begin{code}
dsExpr (ExplicitListOut ty xs)
  = case xs of
      []     -> returnDs (mk_nil_con ty)
      (y:ys) ->
	dsExpr y			    `thenDs` \ core_hd  ->
	dsExpr (ExplicitListOut ty ys)  `thenDs` \ core_tl  ->
	mkConDs consDataCon [TyArg ty, VarArg core_hd, VarArg core_tl]

dsExpr (ExplicitTuple expr_list)
  = mapDs dsExpr expr_list	  `thenDs` \ core_exprs  ->
    mkConDs (tupleCon (length expr_list))
	    (map (TyArg . coreExprType) core_exprs ++ map VarArg core_exprs)

dsExpr (ArithSeqOut expr (From from))
  = dsExpr expr		  `thenDs` \ expr2 ->
    dsExpr from		  `thenDs` \ from2 ->
    mkAppDs expr2 [VarArg from2]

dsExpr (ArithSeqOut expr (FromTo from two))
  = dsExpr expr		  `thenDs` \ expr2 ->
    dsExpr from		  `thenDs` \ from2 ->
    dsExpr two		  `thenDs` \ two2 ->
    mkAppDs expr2 [VarArg from2, VarArg two2]

dsExpr (ArithSeqOut expr (FromThen from thn))
  = dsExpr expr		  `thenDs` \ expr2 ->
    dsExpr from		  `thenDs` \ from2 ->
    dsExpr thn		  `thenDs` \ thn2 ->
    mkAppDs expr2 [VarArg from2, VarArg thn2]

dsExpr (ArithSeqOut expr (FromThenTo from thn two))
  = dsExpr expr		  `thenDs` \ expr2 ->
    dsExpr from		  `thenDs` \ from2 ->
    dsExpr thn		  `thenDs` \ thn2 ->
    dsExpr two		  `thenDs` \ two2 ->
    mkAppDs expr2 [VarArg from2, VarArg thn2, VarArg two2]
\end{code}

Record construction and update
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
For record construction we do this (assuming T has three arguments)

	T { op2 = e }
==>
	let err = /\a -> recConErr a 
	T (recConErr t1 "M.lhs/230/op1") 
	  e 
	  (recConErr t1 "M.lhs/230/op3")

recConErr then converts its arugment string into a proper message
before printing it as

	M.lhs, line 230: missing field op1 was evaluated


\begin{code}
dsExpr (RecordCon con_expr rbinds)
  = dsExpr con_expr	`thenDs` \ con_expr' ->
    let
	con_id       = get_con con_expr'
	(arg_tys, _) = splitFunTy (coreExprType con_expr')

	mk_arg (arg_ty, lbl)
	  = case [rhs | (sel_id,rhs,_) <- rbinds,
			lbl == recordSelectorFieldLabel sel_id] of
	      (rhs:rhss) -> ASSERT( null rhss )
		 	    dsExpr rhs
	      []         -> mkErrorAppDs rEC_CON_ERROR_ID arg_ty (showForErr lbl)
    in
    mapDs mk_arg (zipEqual "dsExpr:RecordCon" arg_tys (dataConFieldLabels con_id)) `thenDs` \ con_args ->
    mkAppDs con_expr' (map VarArg con_args)
  where
	-- "con_expr'" is simply an application of the constructor Id
	-- to types and (perhaps) dictionaries. This gets the constructor...
    get_con (Var con)   = con
    get_con (App fun _) = get_con fun
\end{code}

Record update is a little harder. Suppose we have the decl:

	data T = T1 {op1, op2, op3 :: Int}
	       | T2 {op4, op2 :: Int}
	       | T3

Then we translate as follows:

	r { op2 = e }
===>
	let op2 = e in
	case r of
	  T1 op1 _ op3 -> T1 op1 op2 op3
	  T2 op4 _     -> T2 op4 op2
	  other	       -> recUpdError "M.lhs/230"

It's important that we use the constructor Ids for T1, T2 etc on the
RHSs, and do not generate a Core Con directly, because the constructor
might do some argument-evaluation first; and may have to throw away some
dictionaries.

\begin{code}
dsExpr (RecordUpdOut record_expr record_out_ty dicts rbinds)
  = dsExpr record_expr	 `thenDs` \ record_expr' ->

	-- Desugar the rbinds, and generate let-bindings if
	-- necessary so that we don't lose sharing
    dsRbinds rbinds		$ \ rbinds' ->
    let
	record_in_ty		   = coreExprType record_expr'
	(tycon, in_inst_tys, cons) = getAppDataTyConExpandingDicts record_in_ty
	(_,     out_inst_tys, _)   = getAppDataTyConExpandingDicts record_out_ty
	cons_to_upd  	 	   = filter has_all_fields cons

	-- initial_args are passed to every constructor
	initial_args		= map TyArg out_inst_tys ++ map VarArg dicts
		
	mk_val_arg (field, arg_id) 
	  = case [arg | (f, arg) <- rbinds',
			field == recordSelectorFieldLabel f] of
	      (arg:args) -> ASSERT(null args)
			    arg
	      []	 -> VarArg arg_id

	mk_alt con
	  = newSysLocalsDs (dataConArgTys con in_inst_tys)	`thenDs` \ arg_ids ->
	    let 
		val_args = map mk_val_arg (zipEqual "dsExpr:RecordUpd" (dataConFieldLabels con) arg_ids)
	    in
	    returnDs (con, arg_ids, mkGenApp (mkGenApp (Var con) initial_args) val_args)

	mk_default
	  | length cons_to_upd == length cons 
	  = returnDs NoDefault
	  | otherwise			    
	  = newSysLocalDs record_in_ty				`thenDs` \ deflt_id ->
	    mkErrorAppDs rEC_UPD_ERROR_ID record_out_ty ""	`thenDs` \ err ->
	    returnDs (BindDefault deflt_id err)
    in
    mapDs mk_alt cons_to_upd	`thenDs` \ alts ->
    mk_default			`thenDs` \ deflt ->

    returnDs (Case record_expr' (AlgAlts alts deflt))

  where
    has_all_fields :: Id -> Bool
    has_all_fields con_id 
      = all ok rbinds
      where
	con_fields        = dataConFieldLabels con_id
	ok (sel_id, _, _) = recordSelectorFieldLabel sel_id `elem` con_fields
\end{code}

Dictionary lambda and application
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
@DictLam@ and @DictApp@ turn into the regular old things.
(OLD:) @DictFunApp@ also becomes a curried application, albeit slightly more
complicated; reminiscent of fully-applied constructors.
\begin{code}
dsExpr (DictLam dictvars expr)
  = dsExpr expr `thenDs` \ core_expr ->
    returnDs( mkValLam dictvars core_expr )

------------------

dsExpr expr@(DictApp e dicts)	-- becomes a curried application
  = dsApp expr []
\end{code}

@SingleDicts@ become @Locals@; @Dicts@ turn into tuples, unless
of length 0 or 1.
@ClassDictLam dictvars methods expr@ is ``the opposite'':
\begin{verbatim}
\ x -> case x of ( dictvars-and-methods-tuple ) -> expr
\end{verbatim}
\begin{code}
dsExpr (SingleDict dict)	-- just a local
  = lookupEnvDs dict	`thenDs` \ dict' ->
    returnDs (Var dict')

dsExpr (Dictionary [] [])	-- Empty dictionary represented by void,
  = returnDs (Var voidId)	-- (not, as would happen if we took the next case, by ())

dsExpr (Dictionary dicts methods)
  = mapDs lookupEnvDs (dicts ++ methods)	`thenDs` \ d_and_ms' ->
    returnDs (mkTupleExpr d_and_ms')

dsExpr (ClassDictLam dicts methods expr)
  = dsExpr expr		`thenDs` \ core_expr ->
    case num_of_d_and_ms of
	0 -> newSysLocalDs voidTy `thenDs` \ new_x ->
	     returnDs (mkValLam [new_x] core_expr)

	1 -> -- no untupling
	    returnDs (mkValLam dicts_and_methods core_expr)

	_ ->				-- untuple it
	    newSysLocalDs tuple_ty `thenDs` \ new_x ->
	    returnDs (
	      Lam (ValBinder new_x)
		(Case (Var new_x)
		    (AlgAlts
			[(tuple_con, dicts_and_methods, core_expr)]
			NoDefault)))
  where
    num_of_d_and_ms	    = length dicts + length methods
    dicts_and_methods	    = dicts ++ methods
    tuple_ty		    = mkTupleTy  num_of_d_and_ms (map idType dicts_and_methods)
    tuple_con		    = tupleCon   num_of_d_and_ms

#ifdef DEBUG
-- HsSyn constructs that just shouldn't be here:
dsExpr (HsDo _ _ _)	    = panic "dsExpr:HsDo"
dsExpr (ExplicitList _)	    = panic "dsExpr:ExplicitList"
dsExpr (ExprWithTySig _ _)  = panic "dsExpr:ExprWithTySig"
dsExpr (ArithSeqIn _)	    = panic "dsExpr:ArithSeqIn"
#endif

out_of_range_msg			   -- ditto
  = " out of range: [" ++ show minInt ++ ", " ++ show maxInt ++ "]\n"
\end{code}

%--------------------------------------------------------------------

@(dsApp e [t_1,..,t_n, e_1,..,e_n])@ returns something with the same
value as:
\begin{verbatim}
e t_1 ... t_n  e_1 .. e_n
\end{verbatim}

We're doing all this so we can saturate constructors (as painlessly as
possible).

\begin{code}
dsApp :: TypecheckedHsExpr	-- expr to desugar
      -> [DsCoreArg]		-- accumulated ty/val args: NB:
      -> DsM CoreExpr	-- final result

dsApp (HsApp e1 e2) args
  = dsExpr e2			`thenDs` \ core_e2 ->
    dsApp  e1 (VarArg core_e2 : args)

dsApp (OpApp e1 op _ e2) args
  = dsExpr e1			`thenDs` \ core_e1 ->
    dsExpr e2			`thenDs` \ core_e2 ->
    dsApp  op (VarArg core_e1 : VarArg core_e2 : args)

dsApp (DictApp expr dicts) args
  = mapDs lookupEnvDs dicts	`thenDs` \ core_dicts ->
    dsApp expr (map (VarArg . Var) core_dicts ++ args)

dsApp (TyApp expr tys) args
  = dsApp expr (map TyArg tys ++ args)

-- we might should look out for SectionLs, etc., here, but we don't

dsApp anything_else args
  = dsExpr anything_else	`thenDs` \ core_expr ->
    mkAppDs core_expr args

dsId v
  = lookupEnvDs v	`thenDs` \ v' ->
    returnDs (Var v')
\end{code}

\begin{code}
dsRbinds :: TypecheckedRecordBinds		-- The field bindings supplied
	 -> ([(Id, CoreArg)] -> DsM CoreExpr)	-- A continuation taking the field
	  					-- bindings with atomic rhss
	 -> DsM CoreExpr			-- The result of the continuation,
						-- wrapped in suitable Lets

dsRbinds [] continue_with 
  = continue_with []

dsRbinds ((sel_id, rhs, pun_flag) : rbinds) continue_with
  = dsExpr rhs		 `thenDs` \ rhs' ->
    dsExprToAtom (VarArg rhs')	$ \ rhs_atom ->
    dsRbinds rbinds		$ \ rbinds' ->
    continue_with ((sel_id, rhs_atom) : rbinds')
\end{code}	

\begin{code}
-- do_unfold ty_env val_env (Lam (TyBinder tyvar) body) (TyArg ty : args)
--   = do_unfold (addOneToTyVarEnv ty_env tyvar ty) val_env body args
-- 
-- do_unfold ty_env val_env (Lam (ValBinder binder) body) (arg@(VarArg expr) : args)
--   = dsExprToAtom arg  $ \ arg_atom ->
--     do_unfold ty_env
--      (addOneToIdEnv val_env binder (argToExpr arg_atom))
--	      body args
--
-- do_unfold ty_env val_env body args
--   = 	-- Clone the remaining part of the template
--    uniqSMtoDsM (substCoreExpr val_env ty_env body)	`thenDs` \ body' ->
--
--	-- Apply result to remaining arguments
--    mkAppDs body' args
\end{code}

Basically does the translation given in the Haskell~1.3 report:
\begin{code}
dsDo	:: DoOrListComp
	-> [TypecheckedStmt]
	-> Id		-- id for: return m
	-> Id		-- id for: (>>=) m
	-> Id		-- id for: zero m
	-> Type		-- Element type; the whole expression has type (m t)
	-> DsM CoreExpr

dsDo do_or_lc stmts return_id then_id zero_id result_ty
  = dsId return_id	`thenDs` \ return_ds -> 
    dsId then_id	`thenDs` \ then_ds -> 
    dsId zero_id	`thenDs` \ zero_ds -> 
    let
	(_, b_ty) = splitAppTy result_ty	-- result_ty must be of the form (m b)
	
	go [ReturnStmt expr] 
	  = dsExpr expr			`thenDs` \ expr2 ->
	    mkAppDs return_ds [TyArg b_ty, VarArg expr2]
    
	go (GuardStmt expr locn : stmts)
	  = do_expr expr locn			`thenDs` \ expr2 ->
	    go stmts				`thenDs` \ rest ->
	    mkAppDs zero_ds [TyArg b_ty]	`thenDs` \ zero_expr ->
	    returnDs (mkCoreIfThenElse expr2 rest zero_expr)
    
	go (ExprStmt expr locn : stmts)
	  = do_expr expr locn		`thenDs` \ expr2 ->
	    let
		(_, a_ty) = splitAppTy (coreExprType expr2)	-- Must be of form (m a)
	    in
	    if null stmts then
		returnDs expr2
	    else
		go stmts     		`thenDs` \ rest  ->
		newSysLocalDs a_ty		`thenDs` \ ignored_result_id ->
		mkAppDs then_ds [TyArg a_ty, TyArg b_ty, VarArg expr2, 
				   VarArg (mkValLam [ignored_result_id] rest)]
    
	go (LetStmt binds : stmts )
	  = dsBinds binds	`thenDs` \ binds2 ->
	    go stmts 		`thenDs` \ rest   ->
	    returnDs (mkCoLetsAny binds2 rest)
    
	go (BindStmt pat expr locn : stmts)
	  = putSrcLocDs locn $
	    dsExpr expr 	   `thenDs` \ expr2 ->
	    let
		(_, a_ty)  = splitAppTy (coreExprType expr2)	-- Must be of form (m a)
		zero_expr  = TyApp (HsVar zero_id) [b_ty]
		main_match = PatMatch pat (SimpleMatch (
			     HsDoOut do_or_lc stmts return_id then_id zero_id result_ty locn))
		the_matches
		  = if failureFreePat pat
		    then [main_match]
		    else [main_match, PatMatch (WildPat a_ty) (SimpleMatch zero_expr)]
	    in
	    matchWrapper DoBindMatch the_matches match_msg
				`thenDs` \ (binders, matching_code) ->
	    mkAppDs then_ds [TyArg a_ty, TyArg b_ty,
			     VarArg expr2, VarArg (mkValLam binders matching_code)]
    in
    go stmts

  where
    do_expr expr locn = putSrcLocDs locn (dsExpr expr)

    match_msg = case do_or_lc of
			DoStmt   -> "`do' statement"
			ListComp -> "comprehension"
\end{code}
